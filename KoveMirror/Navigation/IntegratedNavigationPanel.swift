import UIKit
import MapKit
import Combine

/// A real MapKit renderer owned by Double Interface. Its view survives every
/// large/miniature exchange; the TFT snapshots its camera and navigation state.
nonisolated enum NavigationPanelKind: Equatable, Sendable { case tracks, roads, osmand }

extension Notification.Name {
    static let mapFocusChanged = Notification.Name("DoubleInterface.mapFocusChanged")
}

final class IntegratedNavigationPanel: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
    private let kind: NavigationPanelKind
    let view = UIView()
    let map = MKMapView()
    private let hud = IntegratedNavigationHUD()
    // Appartient au renderer et le suit pendant l'échange iPhone ↔ TFT.
    // Transparent : seulement le texte de la couleur de la carte.
    private let mapNameLabel = UILabel()
    private var mapNameTopConstraint: NSLayoutConstraint?
    private var mapProfile: WebMapProfile {
        switch kind {
        case .tracks: return .explorer
        case .roads: return .wize
        case .osmand: return .osmand
        }
    }
    private let nav = LocationAndNavigationManager.shared
    private var subscriptions = Set<AnyCancellable>()
    private var routeIdentity: ObjectIdentifier?
    private var accessRouteIdentity: ObjectIdentifier?
    private var trackRevision: UUID?
    private var followingTrack = false
    private var recordingPointCount = 0
    private var recordingOverlays = Set<ObjectIdentifier>()
    private var updatesPaused = false
    private var trafficLayers: [TomTomTrafficOverlay] = []
    private var trafficTimer: Timer?
    private var trafficAttribution: UILabel?
    private let trafficAlertLabel = UILabel()
    private var communityZones: [MKCircle] = []
    private var focus = MapCameraFocus()

    /// The triangle always starts at Zoom, then North, then travel direction.
    var nextFocusButtonLabel: String {
        switch focus.nextStage {
        case .zoom: return "Zoom sur ma position"
        case .northUp: return "Carte nord en haut"
        case .travelUp: return "Carte dans le sens du déplacement"
        }
    }

    /// The *active* focus mode, displayed on the button itself. Do not show
    /// the next action as the active state: the rider must know the actual mode.
    var focusButtonSymbol: String {
        if nav.mapLocationDenied { return "location.slash" }
        if focus.pending != nil { return "hourglass" }
        switch focus.activeStage {
        case .zoom: return "scope"
        case .northUp: return "safari.fill"
        case .travelUp: return "location.north.fill"
        case nil: return "location.north.fill" // Initial state; first tap zooms
        }
    }

    var focusButtonShortLabel: String {
        if nav.mapLocationDenied { return "GPS" }
        if focus.pending != nil { return "GPS…" }
        switch focus.activeStage {
        case .zoom: return "ZOOM"
        case .northUp: return "NORD"
        case .travelUp: return "CAP"
        case nil: return "GPS"
        }
    }

    var focusButtonCurrentModeLabel: String {
        if nav.mapLocationDenied { return "localisation désactivée, ouvrir les réglages" }
        if focus.pending != nil { return "recherche de ta position GPS" }
        switch focus.activeStage {
        case .zoom: return "zoom sur la position"
        case .northUp: return "nord en haut"
        case .travelUp: return "sens du déplacement en haut"
        case nil: return "aucun mode sélectionné"
        }
    }

    var hasSelectedFocusMode: Bool { focus.activeStage != nil }

    func cycleMapFocus() { requestFocus(.mode(focus.nextStage)) }

    func recenter() { requestFocus(.position) }

    private func requestFocus(_ request: MapCameraFocus.Request) {
        focus.request(request)
        if let fix = nav.currentMapLocation(including: map.userLocation.location) {
            updateCamera(with: fix)
        } else if !nav.mapLocationDenied {
            nav.requestMapCameraLocation()
        }
        if focus.pending != nil { notifyFocusChange() }
    }

    private func notifyFocusChange() {
        NotificationCenter.default.post(name: .mapFocusChanged, object: self)
    }

    private func browseMap() {
        let wasFollowing = focus.followsPosition || focus.pending != nil
        focus.browse()
        if wasFollowing { notifyFocusChange() }
    }

    @objc private func userPannedMap(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { browseMap() }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

    private var isGuiding: Bool { kind == .roads ? nav.isNavigating : nav.isFollowingGPX }

    var courseUpHeading: CLLocationDirection? {
        focus.followsCourse(navigating: isGuiding) ? nav.travelBearing : nil
    }

    private func updateCamera(with fix: CLLocation?) {
        guard !updatesPaused, !nav.mapLocationDenied, map.bounds.width > 0, map.bounds.height > 0 else { return }
        let wasRequested = focus.pending != nil
        let old = map.camera
        guard let fix, CLLocationCoordinate2DIsValid(fix.coordinate),
              ProjectionPolicy.isFresh(timestamp: fix.timestamp, accuracy: fix.horizontalAccuracy, now: Date()),
              let move = focus.consume(fix.timestamp, navigating: isGuiding) else {
            // A compass turn can arrive between GPS fixes, including while stationary.
            if let heading = courseUpHeading, MapHeading.changed(from: old.heading, to: heading) {
                old.heading = heading
                map.setCamera(old, animated: false)
            }
            return
        }
        var distance = old.centerCoordinateDistance
        if move.resetDistance || !distance.isFinite || distance <= 0 {
            distance = kind == .roads ? 950 : (kind == .osmand ? 1250 : 1400)
        }
        let heading: CLLocationDirection
        switch move.stage {
        case .zoom: heading = old.heading
        case .northUp: heading = 0
        case .travelUp: heading = nav.travelBearing ?? old.heading
        }
        let camera = MKMapCamera(lookingAtCenter: fix.coordinate, fromDistance: distance,
                                 pitch: map.isPitchEnabled ? old.pitch : 0, heading: heading)
        map.setCamera(camera, animated: false)
        if wasRequested { notifyFocusChange() }
    }

    /// The non-TFT map stops processing GPS changes while the phone is locked.
    /// Resume without recreating the renderer so its options are preserved.
    func setUpdatesPaused(_ paused: Bool) {
        guard updatesPaused != paused else { return }
        updatesPaused = paused
        if kind == .roads { refreshTrafficLayers() }
        if kind == .roads && !paused { refreshCommunityMarkers() }
        if !paused { refresh() }
    }
    // A MapKit snapshot contains a basemap and its geographic projection. Keep
    // only the most recent basemap per profile in memory. Markers are drawn anew.
    private struct CameraKey: Equatable {
        let latitude, longitude, distance, heading: Double
        let pitch: CGFloat
        let size: CGSize
        let style: UIUserInterfaceStyle

        init(_ camera: MKMapCamera, size: CGSize, style: UIUserInterfaceStyle) {
            latitude = camera.centerCoordinate.latitude
            longitude = camera.centerCoordinate.longitude
            distance = camera.centerCoordinateDistance
            heading = camera.heading
            pitch = camera.pitch
            self.size = size
            self.style = style
        }
    }

    private struct TFTBasemap {
        let snapshot: MKMapSnapshotter.Snapshot
        let key: CameraKey
        let visibleRect: MKMapRect
        let uptime: TimeInterval
    }

    private var tftBasemap: TFTBasemap?
    private var tftLines: [MKPolyline] = []
    private var tftCoordinates: [[CLLocationCoordinate2D]] = []
    private var snapshotter: MKMapSnapshotter?
    private var snapshotToken = UUID()

    // An offline raster renderer is attached only to the OsmAnd profile. It is
    // owned by the profile, so moving it between phone and TFT keeps its map.
    private var offlineTiles: OfflineMBTilesOverlay?
    private let offlinePositionAnnotation = MKPointAnnotation()
    private var hillshadeTiles: OfflineMBTilesOverlay?
    private var contourTiles: OfflineMBTilesOverlay?
    private var onlineTopo: OsmondTopoOnline?
    private var topoAttributionLabel: UILabel?
    private var osmondTopoEnabled: Bool = (UserDefaults.standard.object(forKey: "doubleInterface.osmondTopoOnline") as? Bool) ?? true
    var isOsmandTopoEnabled: Bool { osmondTopoEnabled && !isOfflineEnabled }
    private var rasterOpacities: [OsmondRasterLayer: CGFloat] = [
        .hillshade: CGFloat(UserDefaults.standard.object(forKey: OsmondRasterLayer.hillshade.opacityKey) as? Double ?? 0.50),
        .contours: CGFloat(UserDefaults.standard.object(forKey: OsmondRasterLayer.contours.opacityKey) as? Double ?? 0.85)
    ]
    func osmondRasterOpacity(for layer: OsmondRasterLayer) -> Double {
        Double(rasterOpacities[layer] ?? 0.75)
    }
    private(set) var osmondMapTheme = OsmondMapTheme(rawValue:
        UserDefaults.standard.string(forKey: "doubleInterface.osmondTheme") ?? "automatic") ?? .automatic
    var hasOsmandHillshade: Bool { hillshadeTiles != nil }
    var hasOsmandContours: Bool { contourTiles != nil }
    private var offlineEnabled = UserDefaults.standard.bool(forKey: "doubleInterface.osmandOfflineEnabled")
    var isOfflineEnabled: Bool { kind == .osmand && offlineTiles != nil && offlineEnabled }


    // Every map owns its style. Wize adds independent TomTom traffic layers.
    private var trafficEnabled: Bool
    private var perspectiveEnabled: Bool
    private var terrainEnabled: Bool
    private var osmandReliefEnabled: Bool
    private var osmandPOIEnabled: Bool
    private var osmand3DEnabled: Bool
    private var osmandGPXEnabled: Bool
    var isOsmandReliefEnabled: Bool { osmandReliefEnabled }
    var isOsmandPOIEnabled: Bool { osmandPOIEnabled }
    var isOsmand3DEnabled: Bool { osmand3DEnabled }
    var isOsmandGPXEnabled: Bool { osmandGPXEnabled }
    var isTerrainEnabled: Bool { terrainEnabled }
    var isTrafficEnabled: Bool { trafficEnabled }
    var isPerspectiveEnabled: Bool { perspectiveEnabled }
    // Keep the user's explicit base-map choice separate from MapKit's
    // computed mapType, which can change when preferredConfiguration is set.
    private var selectedMapType: MKMapType = .standard
    var currentMapType: MKMapType { selectedMapType }

    init(kind: NavigationPanelKind) {
        self.kind = kind
        self.trafficEnabled = kind == .roads ? UserDefaults.standard.object(forKey: "doubleInterface.wizeTraffic") as? Bool ?? true : false
        self.perspectiveEnabled = kind == .roads ? UserDefaults.standard.object(forKey: "doubleInterface.wize3D") as? Bool ?? true : false
        self.terrainEnabled = kind == .tracks ? UserDefaults.standard.object(forKey: "doubleInterface.explorerTerrain") as? Bool ?? true : false
        self.osmandReliefEnabled = UserDefaults.standard.object(forKey: "doubleInterface.osmandRelief") as? Bool ?? true
        self.osmandPOIEnabled = UserDefaults.standard.object(forKey: "doubleInterface.osmandPOI") as? Bool ?? true
        self.osmand3DEnabled = UserDefaults.standard.object(forKey: "doubleInterface.osmand3D") as? Bool ?? false
        self.osmandGPXEnabled = UserDefaults.standard.object(forKey: "doubleInterface.osmandGPX") as? Bool ?? true
        super.init()
        if kind == .roads {
            UserDefaults.standard.removeObject(forKey: "doubleInterface.wizeLive")
        }
        // One-time upgrade: enable automatic Osmond topo even when an older
        // build saved a disabled relief switch. Future explicit map-style choices
        // remain respected and are not reset at every application launch.
        if kind == .osmand && !UserDefaults.standard.bool(forKey: "doubleInterface.osmondReliefAutoMigrationV1") {
            osmondTopoEnabled = true
            osmandReliefEnabled = true
            UserDefaults.standard.set(true, forKey: "doubleInterface.osmondTopoOnline")
            UserDefaults.standard.set(true, forKey: "doubleInterface.osmondRelief")
            UserDefaults.standard.set(true, forKey: "doubleInterface.osmondReliefAutoMigrationV1")
        }
        view.backgroundColor = .black
        map.delegate = self
        map.isRotateEnabled = true
        let pan = UIPanGestureRecognizer(target: self, action: #selector(userPannedMap(_:)))
        pan.cancelsTouchesInView = false
        pan.delaysTouchesEnded = false
        pan.delegate = self
        map.addGestureRecognizer(pan)
        map.overrideUserInterfaceStyle = kind == .osmand ? osmondMapTheme.style : .dark
        map.showsUserLocation = !ProcessInfo.processInfo.arguments.contains("--ui-screenshots")
        let key = kind == .tracks ? "doubleInterface.trackMapType" : (kind == .roads ? "doubleInterface.roadMapType" : "doubleInterface.osmandMapType")
        if let value = UserDefaults.standard.object(forKey: key) as? UInt,
           let type = MKMapType(rawValue: value) {
            selectedMapType = type
        } else {
            selectedMapType = kind == .tracks ? .hybrid : .standard
        }
        map.mapType = selectedMapType
        applyMapConfiguration()
        map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 46.6, longitude: 2.5), latitudinalMeters: 1_000_000, longitudinalMeters: 1_000_000), animated: false)
        // Integrated map controls replace Apple's bulky overlay widgets.
        map.showsCompass = false
        map.showsScale = false
        map.isPitchEnabled = true
        map.showsBuildings = kind == .roads || (kind == .osmand && osmand3DEnabled)
        if kind == .osmand { map.pointOfInterestFilter = osmandPOIEnabled ? .includingAll : .excludingAll }
        applyPerspective(animated: false)
        hud.isUserInteractionEnabled = false
        hud.backgroundColor = .clear
        for child in [map, hud] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
            pinToEdges(child)
        }
        // Toujours au-dessus de MapKit, sans capter
        // les gestes de zoom/déplacement et sans cadre opaque.
        mapNameLabel.text = mapProfile.overlayTitle
        mapNameLabel.textColor = mapProfile.overlayColor
        mapNameLabel.font = .systemFont(ofSize: 22, weight: .heavy)
        mapNameLabel.backgroundColor = .clear
        mapNameLabel.isOpaque = false
        mapNameLabel.isUserInteractionEnabled = false
        mapNameLabel.adjustsFontSizeToFitWidth = true
        mapNameLabel.minimumScaleFactor = 0.7
        mapNameLabel.accessibilityIdentifier = "maps.activeName.\(mapProfile.rawValue)"
        mapNameLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(mapNameLabel)
        let nameTop = mapNameLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 14)
        mapNameTopConstraint = nameTop
        NSLayoutConstraint.activate([
            nameTop,
            mapNameLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            mapNameLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12)
        ])
        NotificationCenter.default.publisher(for: .nicoNavigationUpdated)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
        nav.$authorizationStatus
            .receive(on: DispatchQueue.main).sink { [weak self] status in
                guard let self, let request = self.focus.pending else { return }
                if status == .authorizedAlways || status == .authorizedWhenInUse {
                    self.requestFocus(request)
                } else { self.notifyFocusChange() }
            }
            .store(in: &subscriptions)
        TrailRecorder.shared.$points
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
        if kind == .osmand && offlineEnabled {
            if let selected = OfflineMapLibrary.shared.selected { setOfflineMap(selected) }
            else { offlineEnabled = false }
        }
        if kind == .osmand {
            refreshOsmondRasterLayers()
            refreshOsmondOnlineTopo()
        }
        if kind == .roads { configureTomTomTraffic() }
        refresh()
    }

    deinit { trafficTimer?.invalidate() }

    private func configureTomTomTraffic() {
        let service = WizeTrafficService.shared
        service.start()
        if let configuration = TomTomTrafficConfiguration.bundled() {
            trafficLayers = ["flow", "incidents"].map { TomTomTrafficOverlay(layer: $0, configuration: configuration) }
            if !UserDefaults.standard.bool(forKey: "wize.tomtomMigrationV1") {
                trafficEnabled = true
                UserDefaults.standard.set(true, forKey: "doubleInterface.wizeTraffic")
                UserDefaults.standard.set(true, forKey: "wize.tomtomMigrationV1")
            }
        }
        let label = UILabel()
        label.text = "© TomTom"
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        label.isUserInteractionEnabled = false
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        trafficAttribution = label
        trafficAlertLabel.numberOfLines = 2
        trafficAlertLabel.font = .systemFont(ofSize: 15, weight: .bold)
        trafficAlertLabel.textColor = .white
        trafficAlertLabel.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        trafficAlertLabel.isHidden = true
        trafficAlertLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(trafficAlertLabel)
        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            label.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -5),
            trafficAlertLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            trafficAlertLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -14),
            trafficAlertLabel.bottomAnchor.constraint(equalTo: label.topAnchor, constant: -8)
        ])
        service.$alertText.receive(on: DispatchQueue.main).sink { [weak self] message in
            self?.trafficAlertLabel.text = message.map { " ⚠︎ " + $0 + " " }
            self?.trafficAlertLabel.isHidden = message == nil
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .wizeCommunityUpdated)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshCommunityMarkers() }
            .store(in: &subscriptions)
        trafficTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.updatesPaused, self.trafficEnabled else { return }
                self.trafficLayers.forEach { (self.map.renderer(for: $0) as? MKTileOverlayRenderer)?.reloadData() }
            }
        }
        refreshTrafficLayers()
        refreshCommunityMarkers()
        if WizeCommunityService.shared.enabled { WizeCommunityService.shared.start() }
    }

    private func refreshCommunityMarkers() {
        guard kind == .roads, !updatesPaused else { return }
        map.removeAnnotations(map.annotations.compactMap { $0 as? WizeCommunityAnnotation })
        map.removeOverlays(communityZones)
        communityZones = []
        let community = WizeCommunityService.shared
        guard community.enabled else { return }
        for report in community.reports where report.expires > Date() {
            let coordinate = CLLocationCoordinate2D(latitude: report.latitude, longitude: report.longitude)
            if report.kind == .dangerZone {
                guard WizeSafetyZones.shared.enabled else { continue }
                let circle = MKCircle(center: coordinate, radius: 3_000)
                communityZones.append(circle)
                map.addOverlay(circle, level: .aboveRoads)
            } else { map.addAnnotation(WizeCommunityAnnotation(report: report)) }
        }
    }

    private func refreshTrafficLayers() {
        guard kind == .roads else { return }
        let visible = trafficEnabled && !updatesPaused
        for (index, layer) in trafficLayers.enumerated() {
            let attached = map.overlays.contains { ($0 as AnyObject) === layer }
            layer.setActive(visible)
            if visible && !attached { map.addOverlay(layer, level: index == 0 ? .aboveRoads : .aboveLabels) }
            else if !visible && attached { map.removeOverlay(layer) }
        }
        trafficAttribution?.isHidden = !visible || trafficLayers.isEmpty
        WizeTrafficService.shared.visualTrafficActive = visible
        if visible { WizeTrafficService.shared.refresh() }
    }

    private func pinToEdges(_ child: UIView) {
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.topAnchor.constraint(equalTo: view.topAnchor),
            child.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    func refresh(skipMapCameraUpdates: Bool = false) {
        guard !updatesPaused else { return }
        let routeID = nav.currentRoute.map(ObjectIdentifier.init)
        let accessRouteID = kind == .roads ? nil : GPXAccessManager.shared.route.map(ObjectIdentifier.init)
        let currentRecordingCount = TrailRecorder.shared.points.count
        if routeID != routeIdentity || accessRouteID != accessRouteIdentity || trackRevision != nav.importedTrackRevision
            || followingTrack != nav.isFollowingGPX || recordingPointCount != currentRecordingCount {
            routeIdentity = routeID
            accessRouteIdentity = accessRouteID
            trackRevision = nav.importedTrackRevision
            followingTrack = nav.isFollowingGPX
            recordingPointCount = currentRecordingCount
            recordingOverlays.removeAll()
            // GPX refresh must not remove the automatic online Topo background.
            // Keep both cached topo and offline raster layers while replacing route overlays.
            map.removeOverlays(map.overlays.filter {
                !($0 is OfflineMBTilesOverlay) && !($0 is OsmondTopoOnline)
                    && !($0 is TomTomTrafficOverlay) && !($0 is MKCircle)
            })
            map.removeAnnotations(map.annotations.filter {
                !($0 is MKUserLocation) && !($0 is WizeCommunityAnnotation)
                    && ($0 as AnyObject) !== offlinePositionAnnotation
            })
            if (kind == .tracks || (kind == .osmand && osmandGPXEnabled)), let track = nav.importedTrack {
                for segment in track.segments {
                    let coordinates = segment.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                    map.addOverlay(MKPolyline(coordinates: coordinates, count: coordinates.count))
                }
                if currentRecordingCount >= 2 {
                    addRecordingOverlays()
                }
            } else if (kind == .tracks || (kind == .osmand && osmandGPXEnabled)), currentRecordingCount >= 2 {
                addRecordingOverlays()
            } else if kind == .roads, let route = nav.currentRoute {
                map.addOverlay(route.polyline)
                if let destination = nav.destinationItem {
                    let pin = MKPointAnnotation()
                    pin.coordinate = destination.location.coordinate
                    pin.title = destination.name
                    map.addAnnotation(pin)
                }
            }
            if kind != .roads, let accessRoute = GPXAccessManager.shared.route {
                map.addOverlay(accessRoute.polyline, level: .aboveLabels)
                if let target = GPXAccessManager.shared.target {
                    let pin = MKPointAnnotation()
                    pin.coordinate = CLLocationCoordinate2D(latitude: target.point.latitude, longitude: target.point.longitude)
                    pin.title = GPXAccessManager.shared.mode.targetName
                    map.addAnnotation(pin)
                }
            }
        }
        // The locked TFT snapshot centers on its own fresh GPS coordinate.
        // Moving the underlying MKMapView on every background fix is redundant
        // and can block the main run loop before H.264 rendering even begins.
        if !skipMapCameraUpdates {
            updateCamera(with: nav.userLocation)
            updateOfflinePositionAnnotation()
            NavigationPositionMarker.update(on: map, bearing: nav.travelBearing,
                annotation: isOfflineEnabled ? offlinePositionAnnotation : nil)
        }
        hud.state = IntegratedNavigationState(nav: nav, kind: kind)
    }

    private func addRecordingOverlays() {
        for segment in TrailRecorder.shared.recordingSegments where segment.count >= 2 {
            let coordinates = segment.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
            recordingOverlays.insert(ObjectIdentifier(line))
            map.addOverlay(line)
        }
    }

    /// Called after the portrait/landscape layout settles, independently of GPS.
    func refreshPositionMarkerLayout() {
        view.layoutIfNeeded()
        map.layoutIfNeeded()
        if focus.pending != nil {
            updateCamera(with: nav.currentMapLocation(including: map.userLocation.location))
        } else {
            updateCamera(with: nav.userLocation)
        }
        updateOfflinePositionAnnotation()
        NavigationPositionMarker.update(on: map, bearing: nav.travelBearing,
            annotation: isOfflineEnabled ? offlinePositionAnnotation : nil)
    }

    private func updateOfflinePositionAnnotation() {
        guard isOfflineEnabled,
              let fix = nav.currentMapLocation(including: nil),
              ProjectionPolicy.isFresh(timestamp: fix.timestamp,
                  accuracy: fix.horizontalAccuracy, now: Date()) else { return }
        offlinePositionAnnotation.coordinate = fix.coordinate
        NavigationPositionMarker.update(on: map, bearing: nav.travelBearing,
            annotation: offlinePositionAnnotation)
    }

    /// Lightweight zoom controls for the visual cockpit. They adjust the
    /// currently visible MapKit region without changing the selected profile.
    func zoomIn() { zoom(by: 0.55) }
    func zoomOut() { zoom(by: 1.8) }
    private func zoom(by factor: CLLocationDegrees) {
        let camera = map.camera
        camera.centerCoordinateDistance = max(10, camera.centerCoordinateDistance * factor)
        map.setCamera(camera, animated: false)
    }

    func showRoute() {
        // The offline tile overlay covers the whole planet; using its extent
        // here would zoom to the world instead of the selected GPX route.
        let tracks = map.overlays.compactMap { $0 as? MKPolyline }
        guard let first = tracks.first else { recenter(); return }
        browseMap()
        var rect = first.boundingMapRect
        for overlay in tracks.dropFirst() { rect = rect.union(overlay.boundingMapRect) }
        map.setUserTrackingMode(.none, animated: false)
        map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 100, left: 24, bottom: 100, right: 24), animated: false)
    }

    func showTraceAccess() {
        guard kind != .roads, let route = GPXAccessManager.shared.route else { recenter(); return }
        let stage: MapFocusStage = focus.activeStage == .northUp ? .northUp : .travelUp
        requestFocus(.mode(stage))
        if focus.pending == nil { return }
        var rect = route.polyline.boundingMapRect
        if let target = GPXAccessManager.shared.target {
            let p = MKMapPoint(CLLocationCoordinate2D(latitude: target.point.latitude, longitude: target.point.longitude))
            rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 1, height: 1))
        }
        map.setUserTrackingMode(.none, animated: false)
        map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 120, left: 30, bottom: 100, right: 30), animated: false)
    }

    func setMapType(_ type: MKMapType) {
        if kind == .osmand {
            osmondTopoEnabled = false
            UserDefaults.standard.set(false, forKey: "doubleInterface.osmondTopoOnline")
            disableOffline()
            refreshOsmondOnlineTopo()
        }
        if kind == .tracks {
            terrainEnabled = false
            UserDefaults.standard.set(false, forKey: "doubleInterface.explorerTerrain")
        }
        selectedMapType = type
        map.mapType = type
        UserDefaults.standard.set(type.rawValue, forKey: kind == .tracks ? "doubleInterface.trackMapType" : (kind == .roads ? "doubleInterface.roadMapType" : "doubleInterface.osmandMapType"))
        applyMapConfiguration()
        applyPerspective(animated: true)
    }

    /// Loads an already imported map. Tiles are always read from local SQLite.
    /// Offline mode deliberately has no online fallback for missing tiles.
    func setOfflineMap(_ package: OfflineMapPackage) {
        guard kind == .osmand, let file = OfflineMapLibrary.shared.url(for: package) else { return }
        do {
            let overlay = try OfflineMBTilesOverlay(file: file)
            if let old = offlineTiles { map.removeOverlay(old) }
            offlineTiles = overlay
            offlineEnabled = true
            UserDefaults.standard.set(true, forKey: "doubleInterface.osmandOfflineEnabled")
            map.mapType = .standard
            // The app's CoreLocation stream feeds an explicit visible triangle.
            // It does not rely on MapKit's separate (and sometimes missing)
            // MKUserLocation callback while the offline tile overlay is active.
            map.showsUserLocation = false
            if !map.annotations.contains(where: { ($0 as AnyObject) === offlinePositionAnnotation }) {
                map.addAnnotation(offlinePositionAnnotation)
            }
            map.addOverlay(overlay, level: .aboveRoads)
            refreshOsmondOnlineTopo()
            refreshOsmondRasterLayers()
            if package.id == OfflineMapLibrary.bundledOverviewFilename {
                // Ne pas faire passer un aperçu de relief pour une carte
                // topographique de navigation (source NOAA ETOPO1).
                let label = UILabel()
                label.text = "Relief mondial NOAA · aperçu uniquement · non navigable"
                label.font = .systemFont(ofSize: 9, weight: .medium)
                label.textColor = .black
                label.backgroundColor = UIColor.white.withAlphaComponent(0.83)
                label.isUserInteractionEnabled = false
                label.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(label)
                NSLayoutConstraint.activate([
                    label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -5),
                    label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6)
                ])
                topoAttributionLabel = label
            }
            map.isPitchEnabled = false // Offline TFT snapshot is planar Mercator.
            let camera = map.camera
            camera.pitch = 0
            map.setCamera(camera, animated: false)
            let fix = nav.currentMapLocation(including: map.userLocation.location)
            if fix != nil {
                // Centre Rivmonde on the actual GPS coordinate, even when
                // the previous map was manually panned or a zoom was changed.
                // Missing map coverage is reported by the tile renderer.
                requestFocus(.position)
            } else {
                // Keep the recenter request until CoreLocation provides a fix.
                // The map should not remain stuck in its initial France region.
                focus.request(.position)
                if let bounds = package.bounds,
                   bounds.span.longitudeDelta < 355 { map.setRegion(bounds, animated: false) }
            }
            updateOfflinePositionAnnotation()
            // Refresh the GPX layers without replacing the basemap overlay.
            trackRevision = nil
            refresh()
        } catch {
            disableOffline()
        }
    }

    private static func region(_ region: MKCoordinateRegion, includes coordinate: CLLocationCoordinate2D?) -> Bool {
        guard let coordinate else { return false }
        let delta = abs(coordinate.longitude - region.center.longitude)
        return abs(coordinate.latitude - region.center.latitude) <= region.span.latitudeDelta / 2
            && min(delta, 360 - delta) <= region.span.longitudeDelta / 2
    }

    func disableOffline() {
        guard kind == .osmand else { return }
        if let old = offlineTiles { map.removeOverlay(old) }
        offlineTiles = nil
        offlineEnabled = false
        map.removeAnnotation(offlinePositionAnnotation)
        map.showsUserLocation = !ProcessInfo.processInfo.arguments.contains("--ui-screenshots")
        UserDefaults.standard.set(false, forKey: "doubleInterface.osmandOfflineEnabled")
        refreshOsmondRasterLayers()
        refreshOsmondOnlineTopo()
        map.isPitchEnabled = onlineTopo == nil
        applyMapConfiguration()
        applyPerspective(animated: false)
    }

    /// Online topo shows actual hillshading + contours automatically. Local
    /// MBTiles remain the only complete offline maps: no invisible download.
    func setOsmondTopoEnabled(_ enabled: Bool) {
        guard kind == .osmand else { return }
        if enabled && isOfflineEnabled { disableOffline() }
        osmondTopoEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "doubleInterface.osmondTopoOnline")
        refreshOsmondOnlineTopo()
        applyPerspective(animated: false)
    }

    private func refreshOsmondOnlineTopo() {
        guard kind == .osmand else { return }
        if let old = onlineTopo { map.removeOverlay(old); onlineTopo = nil }
        topoAttributionLabel?.removeFromSuperview()
        topoAttributionLabel = nil
        guard osmondTopoEnabled, !isOfflineEnabled else { return }
        let topo = OsmondTopoOnline()
        onlineTopo = topo
        map.mapType = .standard
        map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
        map.addOverlay(topo, level: .aboveRoads)
        map.isPitchEnabled = false // raster XY tiles cannot be tilted
        let camera = map.camera
        camera.pitch = 0
        map.setCamera(camera, animated: false)
        let label = UILabel()
        label.font = .systemFont(ofSize: 9, weight: .medium)
        label.textColor = .black
        label.backgroundColor = UIColor.white.withAlphaComponent(0.74)
        label.text = OsmondTopoOnline.attribution
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        label.isUserInteractionEnabled = false
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -4)
        ])
        topoAttributionLabel = label
        // Trails remain above the raster background.
        for line in map.overlays.compactMap({ $0 as? MKPolyline }) {
            map.removeOverlay(line)
            map.addOverlay(line, level: .aboveLabels)
        }
    }

    /// Wikiloc-style map has independent realistic-relief styling, GPX tracking,
    /// and no road traffic. This is NOT the Wikiloc app or account connection.
    func setTerrainEnabled(_ enabled: Bool) {
        guard kind == .tracks else { return }
        terrainEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "doubleInterface.explorerTerrain")
        if enabled {
            map.mapType = .standard
            // The stored base-map choice is retained for when Relief is disabled.
            // 'Relief' is a separate satellite/terrain layer, not a reset of style.
        }
        applyMapConfiguration()
        applyPerspective(animated: true)
    }

    /// Uses TomTom traffic and incidents on the native road map.
    func setTrafficEnabled(_ enabled: Bool) {
        guard kind == .roads else { return }
        trafficEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "doubleInterface.wizeTraffic")
        applyMapConfiguration()
        refreshTrafficLayers()
    }

    func setPerspectiveEnabled(_ enabled: Bool) {
        guard kind == .roads else { return }
        perspectiveEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "doubleInterface.wize3D")
        applyPerspective(animated: true)
    }

    /// OsmAnd-inspired profile: these are genuine independent MapKit controls,
    /// not OsmAnd's offline vector-map engine or its purchased contour layers.
    /// Imports selected transparent contour/relief MBTiles while retaining the base map.
    /// Topographic layers appear only when a true local offline base is active:
    /// this guarantees the iPhone and the TFT show exactly the same data.
    func refreshOsmondRasterLayers() {
        guard kind == .osmand else { return }
        if let hillshadeTiles { map.removeOverlay(hillshadeTiles) }
        if let contourTiles { map.removeOverlay(contourTiles) }
        hillshadeTiles = nil
        contourTiles = nil
        guard offlineTiles != nil && offlineEnabled else { return }
        let library = OfflineMapLibrary.shared
        if let package = library.selectedOverlay(.hillshade), let file = library.url(for: package) {
            hillshadeTiles = try? OfflineMBTilesOverlay(file: file, replacesMapContent: false)
        }
        if let package = library.selectedOverlay(.contours), let file = library.url(for: package) {
            contourTiles = try? OfflineMBTilesOverlay(file: file, replacesMapContent: false)
        }
        if let hillshadeTiles { map.addOverlay(hillshadeTiles, level: .aboveRoads) }
        if let contourTiles { map.addOverlay(contourTiles, level: .aboveRoads) }
        map.overlays.compactMap { $0 as? MKPolyline }.forEach { line in
            map.removeOverlay(line)
            map.addOverlay(line, level: .aboveLabels)
        }
    }

    func setOsmandRasterOpacity(_ value: Double, for layer: OsmondRasterLayer) {
        guard kind == .osmand else { return }
        let alpha = CGFloat(max(0.15, min(value, 1)))
        rasterOpacities[layer] = alpha
        UserDefaults.standard.set(Double(alpha), forKey: layer.opacityKey)
        let selectedOverlay = layer == .hillshade ? hillshadeTiles : contourTiles
        if let selectedOverlay,
           let renderer = map.renderer(for: selectedOverlay) as? MKTileOverlayRenderer {
            renderer.alpha = alpha
            renderer.setNeedsDisplay()
        }
    }

    func setOsmandMapTheme(_ value: OsmondMapTheme) {
        guard kind == .osmand else { return }
        osmondMapTheme = value
        UserDefaults.standard.set(value.rawValue, forKey: "doubleInterface.osmondTheme")
        map.overrideUserInterfaceStyle = value.style
        applyMapConfiguration()
    }

    func setOsmandReliefEnabled(_ enabled: Bool) {
        guard kind == .osmand else { return }
        osmandReliefEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "doubleInterface.osmandRelief")
        applyMapConfiguration()
    }
    func setOsmandPOIEnabled(_ enabled: Bool) {
        guard kind == .osmand else { return }
        osmandPOIEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "doubleInterface.osmandPOI")
        map.pointOfInterestFilter = enabled ? .includingAll : .excludingAll
    }
    func setOsmand3DEnabled(_ enabled: Bool) {
        guard kind == .osmand else { return }
        osmand3DEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "doubleInterface.osmand3D")
        map.showsBuildings = enabled
        applyPerspective(animated: true)
    }
    func setOsmandGPXEnabled(_ enabled: Bool) {
        guard kind == .osmand else { return }
        osmandGPXEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "doubleInterface.osmandGPX")
        trackRevision = nil
        recordingPointCount = -1
        refresh()
    }

    private func applyMapConfiguration() {
        tftBasemap = nil
        if kind == .osmand && onlineTopo != nil {
            map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
            return
        }
        if kind == .tracks && terrainEnabled {
            // Wukuluc visual identity: real satellite imagery with the 3D
            // terrain mesh, not a fake image under the map renderer.
            let terrain = MKHybridMapConfiguration(elevationStyle: .realistic)
            terrain.showsTraffic = false
            map.preferredConfiguration = terrain
            return
        }
        let chosen = selectedMapType
        let relief = kind == .tracks || (kind == .osmand && osmandReliefEnabled)
        switch chosen {
        case .satellite, .satelliteFlyover:
            map.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: relief ? .realistic : .flat)
        case .hybrid, .hybridFlyover:
            let config = MKHybridMapConfiguration(elevationStyle: relief ? .realistic : .flat)
            config.showsTraffic = false
            map.preferredConfiguration = config
        default:
            let config = MKStandardMapConfiguration(elevationStyle: relief ? .realistic : .flat,
                                                    emphasisStyle: kind == .tracks ? .muted : .default)
            config.showsTraffic = false
            map.preferredConfiguration = config
        }
    }

    private func applyPerspective(animated: Bool) {
        tftBasemap = nil
        guard !isOfflineEnabled, onlineTopo == nil else { return }
        let camera = map.camera
        let elevated = kind == .tracks ? terrainEnabled : (kind == .roads ? perspectiveEnabled : osmand3DEnabled)
        camera.pitch = elevated ? (kind == .tracks ? 47 : 55) : 0
        map.setCamera(camera, animated: animated)
    }

    func cancelSnapshot() {
        snapshotToken = UUID()
        snapshotter?.cancel()
        snapshotter = nil
    }

    private func snapshotPolylines() -> [[CLLocationCoordinate2D]] {
        let accessLine = kind == .roads ? nil : GPXAccessManager.shared.route?.polyline
        let lines = map.overlays.compactMap { $0 as? MKPolyline }
            .filter { $0 !== accessLine }
        // Overlays are replaced when the route, recording or GPX changes.
        if lines.count == tftLines.count && zip(lines, tftLines).allSatisfy({ $0.0 === $0.1 }) {
            return tftCoordinates
        }
        tftLines = lines
        tftCoordinates = lines.map { line in
            let step = max(1, (line.pointCount + 4095) / 4096)
            var points = stride(from: 0, to: line.pointCount, by: step).map { line.points()[$0].coordinate }
            if line.pointCount > 1 && (line.pointCount - 1) % step != 0 {
                points.append(line.points()[line.pointCount - 1].coordinate)
            }
            return points
        }
        return tftCoordinates
    }

    func setHUDTopInset(_ inset: CGFloat) {
        hud.topInset = inset
        // La miniature est redimensionnée depuis la résolution native TFT :
        // un nom de 36 pt reste visible sur la petite carte ET sur le TFT.
        // Sur l'iPhone, la zone de sécurité est déduite de l'inset HUD.
        let isTFT = inset <= 0
        mapNameLabel.font = .systemFont(ofSize: isTFT ? 36 : 22, weight: .heavy)
        mapNameTopConstraint?.constant = isTFT ? 22 : max(12, inset - 110)
    }

    func snapshot(width: CGFloat, lockedFix: CLLocation? = nil,
                  completion: @escaping (UIImage?, Error?) -> Void) {
        if let lockedFix {
            guard CLLocationCoordinate2DIsValid(lockedFix.coordinate),
                  ProjectionPolicy.isFresh(timestamp: lockedFix.timestamp,
                                           accuracy: lockedFix.horizontalAccuracy, now: Date()) else {
                completion(nil, NSError(domain: "DoubleInterface", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "En attente d’une position GPS récente."]))
                return
            }
        }
        refresh(skipMapCameraUpdates: lockedFix != nil)
        let attached = view.window != nil && view.bounds.width > 0 && view.bounds.height > 0
        guard lockedFix != nil || attached else {
            completion(nil, NSError(domain: "DoubleInterface", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "La carte de navigation n’est pas encore affichée."]))
            return
        }
        cancelSnapshot()
        let token = snapshotToken
        // The projection must not inherit the iPhone's large-map geometry
        // when the two renderers are being exchanged.
        let tftPreset = KoveScreenPreset.current
        let tftSize = CGSize(width: tftPreset.width, height: tftPreset.height)
        let accessCoordinates = kind == .roads ? [] : GPXAccessManager.shared.coordinates
        let accessTarget = kind == .roads ? nil : GPXAccessManager.shared.target.map {
            CLLocationCoordinate2D(latitude: $0.point.latitude, longitude: $0.point.longitude)
        }
        let accessState = IntegratedNavigationState(nav: nav, kind: kind)
        let fix = (lockedFix ?? nav.userLocation).flatMap { location in
            CLLocationCoordinate2DIsValid(location.coordinate) &&
                ProjectionPolicy.isFresh(timestamp: location.timestamp, accuracy: location.horizontalAccuracy, now: Date())
                ? location : nil
        }
        let mapHeading = courseUpHeading ?? (focus.activeStage == .northUp ? 0 : map.camera.heading)
        let rect = tftMapRect(around: lockedFix?.coordinate ?? map.centerCoordinate, size: tftSize,
                              locked: lockedFix != nil)
        let visibleRect = map.visibleMapRect // The MapKit traffic grid uses its actual bounding box.
        let viewport = TFTMapViewport(rect: rect, size: tftSize, heading: mapHeading)
        let segments = snapshotPolylines()
        if kind == .osmand, let offline = offlineTiles, offlineEnabled {
            // Unlike MKMapSnapshotter, this renders the actual offline map on TFT.
            let outputSize = tftSize
            let location = fix?.coordinate
            let positionBearing = nav.travelBearing
            let layers: [(tiles: OfflineMBTilesOverlay, opacity: CGFloat)] =
                [hillshadeTiles, contourTiles].compactMap { $0 }
                    .map { (tiles: $0, opacity: $0 === hillshadeTiles
                            ? (rasterOpacities[.hillshade] ?? 0.5)
                            : (rasterOpacities[.contours] ?? 0.85)) }
            let mapName = mapProfile.overlayTitle
            let mapNameColor = mapProfile.overlayColor
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let image = offline.renderFrame(mapRect: rect, output: outputSize,
                                                rasterLayers: layers,
                                                polylines: segments, position: location,
                                                bearing: positionBearing, mapHeading: mapHeading,
                                                accessCoordinates: accessCoordinates, accessTarget: accessTarget,
                                                mapName: mapName,
                                                mapNameColor: mapNameColor)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.snapshotToken == token else { return }
                    completion(self.frameWithGuidance(image, state: accessState), nil)
                }
            }
            return
        }
        let communityReports = kind == .roads && WizeCommunityService.shared.enabled
            ? WizeCommunityService.shared.reports.filter { $0.expires > Date() } : []
        let snapshotStyle: UIUserInterfaceStyle = kind == .osmand
            ? (osmondMapTheme == .automatic ? map.traitCollection.userInterfaceStyle : osmondMapTheme.style)
            : .dark
        let positionBearing = nav.travelBearing
        let positionColor = mapProfile.overlayColor
        let destination = kind == .roads ? nav.destinationItem?.location.coordinate : nil
        let lineColor: UIColor = kind == .roads ? .systemBlue : .systemOrange
        let topInset = hud.topInset
        let render: (MKMapSnapshotter.Snapshot?, MKMapRect) -> UIImage = { snapshot, trafficMapRect in
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            var transform = CGAffineTransform.identity
            if let snapshot, let lockedFix {
                let pivot = snapshot.point(for: lockedFix.coordinate)
                // Project the desired direction on the cached (possibly pitched) camera
                // at the rider's actual position, then put that direction at the top.
                let angle = NavigationPositionMarker.angle(at: lockedFix.coordinate, bearing: mapHeading) {
                    snapshot.point(for: $0)
                }
                transform = CGAffineTransform(translationX: tftSize.width / 2, y: tftSize.height / 2)
                    .rotated(by: -angle).translatedBy(x: -pivot.x, y: -pivot.y)
            }
            let project: (CLLocationCoordinate2D) -> CGPoint = { coordinate in
                if let snapshot { return snapshot.point(for: coordinate).applying(transform) }
                return viewport.point(coordinate)
            }
            return UIGraphicsImageRenderer(size: tftSize, format: format).image { context in
                let ctx = context.cgContext
                UIColor(red: 0.07, green: 0.11, blue: 0.14, alpha: 1).setFill()
                context.fill(CGRect(origin: .zero, size: tftSize))
                if let snapshot {
                    ctx.saveGState()
                    ctx.concatenate(transform)
                    snapshot.image.draw(at: .zero)
                    if self.kind == .roads, self.trafficEnabled {
                        self.trafficLayers.forEach { $0.draw(on: snapshot, mapRect: trafficMapRect, size: tftSize) }
                    }
                    ctx.restoreGState()
                }
                ctx.saveGState()
                ctx.clip(to: CGRect(origin: .zero, size: tftSize))
                for report in communityReports {
                    let coordinate = CLLocationCoordinate2D(latitude: report.latitude, longitude: report.longitude)
                    if report.kind == .dangerZone {
                        guard WizeSafetyZones.shared.enabled else { continue }
                        ctx.beginPath()
                        for index in 0...48 {
                            let angle = Double(index) * .pi * 2 / 48
                            let latitude = coordinate.latitude + sin(angle) * 3_000 / 111_320
                            let longitude = coordinate.longitude + cos(angle) * 3_000 / (111_320 * max(0.1, cos(coordinate.latitude * .pi/180)))
                            let p = project(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
                            if index == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
                        }
                        ctx.closePath()
                        ctx.setFillColor(UIColor.systemOrange.withAlphaComponent(0.08).cgColor)
                        ctx.setStrokeColor(UIColor.systemOrange.withAlphaComponent(0.5).cgColor)
                        ctx.setLineWidth(2)
                        ctx.drawPath(using: .fillStroke)
                    } else {
                        let p = project(coordinate)
                        let rect = CGRect(x: p.x-14, y: p.y-14, width: 28, height: 28)
                        UIColor.systemOrange.setFill()
                        ctx.fillEllipse(in: rect)
                        UIImage(systemName: report.kind.symbol)?.withTintColor(.white, renderingMode: .alwaysOriginal)
                            .draw(in: rect.insetBy(dx: 5, dy: 5))
                    }
                }
                ctx.setLineWidth(6)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.setStrokeColor(lineColor.cgColor)
                for coordinates in segments {
                    guard let first = coordinates.first else { continue }
                    ctx.beginPath()
                    ctx.move(to: project(first))
                    for coordinate in coordinates.dropFirst() { ctx.addLine(to: project(coordinate)) }
                    ctx.strokePath()
                }
                if let destination {
                    let point = project(destination)
                    UIColor.systemOrange.setFill()
                    ctx.fillEllipse(in: CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14))
                }
                GPXAccessRendering.draw(in: ctx, coordinates: accessCoordinates, target: accessTarget) { project($0) }
                if let fix, ProjectionPolicy.isFresh(timestamp: fix.timestamp,
                                                     accuracy: fix.horizontalAccuracy, now: Date()) {
                    let point = project(fix.coordinate)
                    let angle = NavigationPositionMarker.angle(at: fix.coordinate, bearing: positionBearing) {
                        project($0)
                    }
                    NavigationPositionMarker.draw(in: ctx, at: point, angle: angle, color: positionColor)
                }
                ctx.restoreGState()
                accessState.draw(in: CGRect(origin: .zero, size: tftSize), topInset: max(58, topInset))
                let name = self.mapProfile.overlayTitle as NSString
                let nameFont = UIFont.systemFont(ofSize: max(22, min(36, tftSize.width * 0.034)), weight: .heavy)
                name.draw(at: CGPoint(x: 22, y: 20), withAttributes: [
                    .font: nameFont, .foregroundColor: self.mapProfile.overlayColor
                ])
                if self.kind == .roads {
                    let traffic = WizeTrafficService.shared
                    if snapshot != nil && self.trafficEnabled && !self.trafficLayers.isEmpty {
                        ("© TomTom" as NSString).draw(at: CGPoint(x: tftSize.width - 88, y: tftSize.height - 20),
                            withAttributes: [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.white])
                    }
                    if let message = traffic.alertText, traffic.alertExpires > Date() {
                        (("⚠︎ " + message) as NSString).draw(at: CGPoint(x: 22, y: tftSize.height - 56),
                            withAttributes: [.font: UIFont.systemFont(ofSize: 20, weight: .bold), .foregroundColor: UIColor.white])
                    }
                }
                if snapshot == nil {
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: UIColor.white
                    ]
                    ("Fond de carte indisponible" as NSString).draw(
                        at: CGPoint(x: 16, y: tftSize.height - 108), withAttributes: attributes)
                    if let fix {
                        let orientation = MapHeading.changed(from: 0, to: mapHeading)
                            ? String(format: "%03d° ↑", Int(mapHeading.rounded()) % 360) : "Nord ↑"
                        let label = String(format: "GPS · %.5f, %.5f · %@", fix.coordinate.latitude, fix.coordinate.longitude, orientation)
                        (label as NSString).draw(at: CGPoint(x: 16, y: tftSize.height - 82), withAttributes: attributes)
                    }
                }
            }
        }

        @MainActor func renderSystemMap() {
            if let lockedFix {
                // MapKit delivers new snapshots only in the foreground. An existing
                // snapshot projects GPS points using the camera that made the image.
                if let base = tftBasemap, base.key.size == tftSize,
                   CGRect(origin: .zero, size: tftSize).insetBy(dx: 18, dy: 18)
                        .contains(base.snapshot.point(for: lockedFix.coordinate)) {
                    completion(render(base.snapshot, base.visibleRect), nil)
                } else {
                    completion(render(nil, rect), nil)
                }
                return
            }

            let camera = map.camera
            camera.heading = mapHeading
            let key = CameraKey(camera, size: tftSize, style: snapshotStyle)
            let now = ProcessInfo.processInfo.systemUptime
            if let base = tftBasemap, base.key == key, now - base.uptime < 1 {
                completion(render(base.snapshot, base.visibleRect), nil)
                return
            }
            let options = MKMapSnapshotter.Options()
            options.size = tftSize
            options.scale = 1
            options.camera = camera
            options.preferredConfiguration = map.preferredConfiguration
            options.traitCollection = UITraitCollection(userInterfaceStyle: snapshotStyle)
            let task = MKMapSnapshotter(options: options)
            snapshotter = task
            func usePreviousMapOrGPS() {
                if let base = tftBasemap, base.key == key {
                    completion(render(base.snapshot, base.visibleRect), nil)
                } else {
                    completion(render(nil, rect), nil)
                }
            }
            let timeout: DispatchWorkItem?
            if kind == .osmand {
                let work = DispatchWorkItem { [weak self, weak task] in
                    guard let self, let task, self.snapshotToken == token, self.snapshotter === task else { return }
                    self.snapshotter = nil
                    task.cancel()
                    usePreviousMapOrGPS()
                }
                timeout = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
            } else {
                timeout = nil
            }
            task.start { [weak self, weak task] snapshot, error in
                guard let self, let task, self.snapshotToken == token, self.snapshotter === task else { return }
                timeout?.cancel()
                self.snapshotter = nil
                if self.kind == .osmand, snapshot.map({ RivmondeRasterFrame.hasMapDetail($0.image) }) != true {
                    usePreviousMapOrGPS()
                    return
                }
                guard let snapshot else { completion(nil, error); return }
                self.tftBasemap = TFTBasemap(snapshot: snapshot, key: key, visibleRect: visibleRect,
                                            uptime: ProcessInfo.processInfo.systemUptime)
                completion(render(snapshot, visibleRect), nil)
            }
        }

        guard kind == .osmand, let topo = onlineTopo else {
            renderSystemMap()
            return
        }
        let title = mapProfile.overlayTitle
        DispatchQueue.global(qos: .userInitiated).async {
            let image = topo.renderFrame(mapRect: rect, output: tftSize, allowNetwork: lockedFix == nil,
                                         polylines: segments, position: fix?.coordinate, bearing: positionBearing,
                                         mapHeading: mapHeading,
                                         accessCoordinates: accessCoordinates, accessTarget: accessTarget,
                                         mapName: title, mapNameColor: positionColor)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.snapshotToken == token else { return }
                if let image { completion(self.frameWithGuidance(image, state: accessState), nil) }
                else { renderSystemMap() }
            }
        }
    }

    private func tftMapRect(around coordinate: CLLocationCoordinate2D, size: CGSize, locked: Bool) -> MKMapRect {
        let center = MKMapPoint(coordinate)
        let unitsPerMeter = MKMapPointsPerMeterAtLatitude(coordinate.latitude)
        let world = MKMapSize.world.width
        var width = map.visibleMapRect.size.width
        // visibleMapRect grows as a rectangular screen turns. Measure the horizontal
        // scale at the centre of the displayed map to keep zoom stable through turns.
        // With the phone locked we use the last known MapKit scale. Calling
        // map.convert() four times for each background frame triggers extra
        // MapKit work on the main thread even though its camera is frozen.
        if (!locked || UIApplication.shared.applicationState != .background),
           map.bounds.width > 0, map.bounds.height > 0 {
            let y = map.bounds.midY
            let span = map.bounds.width / 4
            let left = MKMapPoint(map.convert(CGPoint(x: map.bounds.midX - span, y: y), toCoordinateFrom: map))
            let right = MKMapPoint(map.convert(CGPoint(x: map.bounds.midX + span, y: y), toCoordinateFrom: map))
            let dx = abs(right.x - left.x).truncatingRemainder(dividingBy: world)
            let measured = 2 * hypot(min(dx, world - dx), right.y - left.y)
            if measured.isFinite, measured > 0 { width = measured }
        }
        if !width.isFinite || width <= 0 { width = 1_000 * unitsPerMeter }
        width = min(world, width)
        if locked && kind != .osmand { width = min(8_000 * unitsPerMeter, max(350 * unitsPerMeter, width)) }
        let height = width * size.height / max(1, size.width)
        return MKMapRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }

    private func frameWithGuidance(_ image: UIImage?, state: IntegratedNavigationState) -> UIImage? {
        guard let image else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(at: .zero)
            state.draw(in: CGRect(origin: .zero, size: image.size), topInset: 58)
        }
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let traffic = overlay as? TomTomTrafficOverlay { return MKTileOverlayRenderer(tileOverlay: traffic) }
        if let circle = overlay as? MKCircle, communityZones.contains(where: { $0 === circle }) {
            let renderer = MKCircleRenderer(circle: circle)
            renderer.fillColor = UIColor.systemOrange.withAlphaComponent(0.08)
            renderer.strokeColor = UIColor.systemOrange.withAlphaComponent(0.5)
            renderer.lineWidth = 2
            return renderer
        }
        if let tiles = overlay as? OsmondTopoOnline {
            return MKTileOverlayRenderer(tileOverlay: tiles)
        }
        if let tiles = overlay as? OfflineMBTilesOverlay {
            let renderer = MKTileOverlayRenderer(tileOverlay: tiles)
            if tiles === hillshadeTiles { renderer.alpha = rasterOpacities[.hillshade] ?? 0.5 }
            if tiles === contourTiles { renderer.alpha = rasterOpacities[.contours] ?? 0.85 }
            return renderer
        }
        guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
        let renderer = MKPolylineRenderer(polyline: line)
        if ObjectIdentifier(line) == accessRouteIdentity {
            renderer.strokeColor = .systemBlue
            renderer.lineWidth = 5
            renderer.lineDashPattern = [9, 6]
            renderer.lineCap = .round
            return renderer
        }
        renderer.strokeColor = recordingOverlays.contains(ObjectIdentifier(line))
            ? UIColor(red: 210/255, green: 243/255, blue: 107/255, alpha: 1)
            : (kind == .roads ? UIColor.systemBlue
               : (kind == .tracks ? UIColor(red: 0.30, green: 0.96, blue: 0.31, alpha: 1)
                  : UIColor(red: 0.88, green: 0.24, blue: 0.85, alpha: 1)))
        renderer.lineWidth = recordingOverlays.contains(ObjectIdentifier(line)) ? 7 : 6
        return renderer
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        if annotation is MKUserLocation || (annotation as AnyObject) === offlinePositionAnnotation {
            return NavigationPositionMarker.annotationView(for: annotation, on: mapView,
                color: mapProfile.overlayColor, bearing: nav.travelBearing)
        }
        guard let event = annotation as? WizeCommunityAnnotation else { return nil }
        let identifier = "WizeCommunityIncident"
        let marker = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView ??
            MKMarkerAnnotationView(annotation: event, reuseIdentifier: identifier)
        marker.annotation = event
        marker.markerTintColor = .systemOrange
        marker.glyphImage = UIImage(systemName: event.report.kind.symbol)
        marker.canShowCallout = true
        marker.clusteringIdentifier = "wize-community"
        return marker
    }

    func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
        NavigationPositionMarker.update(on: mapView, bearing: nav.travelBearing,
            annotation: isOfflineEnabled ? offlinePositionAnnotation : nil)
    }

    func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
        if focus.pending != nil { updateCamera(with: nav.currentMapLocation(including: userLocation.location)) }
        NavigationPositionMarker.update(on: mapView, bearing: nav.travelBearing,
            annotation: isOfflineEnabled ? offlinePositionAnnotation : nil)
    }
}

private final class WizeCommunityAnnotation: MKPointAnnotation {
    let report: CommunityReport
    init(report: CommunityReport) {
        self.report = report
        super.init()
        coordinate = CLLocationCoordinate2D(latitude: report.latitude, longitude: report.longitude)
        title = report.kind.title
        subtitle = "Rivroute · \(report.confirmations) confirmation(s)"
    }
}

private final class IntegratedNavigationHUD: UIView {
    var state = IntegratedNavigationState() { didSet { setNeedsDisplay() } }
    var topInset: CGFloat = 68 { didSet { if topInset != oldValue { setNeedsDisplay() } } }
    override func draw(_ rect: CGRect) { state.draw(in: bounds, topInset: topInset) }
}

private struct IntegratedNavigationState {
    var title = "Navigation Double Interface"
    var detail = "Choisis une destination ou importe une trace GPX."
    var gpxGuidance: GPXRouteGuidance?
    var accessHeadline: String?
    var accessSecondary: String?

    init() {}
    init(nav: LocationAndNavigationManager, kind: NavigationPanelKind) {
        title = kind == .tracks ? "Rivadventure" : (kind == .roads ? "Rivroute" : "Rivmonde · hors ligne")
        detail = kind == .roads ? "Recherche une destination pour démarrer." : "Explore, importe ou enregistre une trace."
        if kind != .roads, let track = nav.importedTrack {
            title = track.name
            gpxGuidance = nav.isFollowingGPX ? nav.gpxGuidance : nil
            detail = nav.isFollowingGPX ? (nav.distanceFromGPX.map { String(format: "Écart de la trace : %.0f m", $0) } ?? "Position GPS en attente") : String(format: "%.1f km · prêt à suivre", track.distanceKilometers)
        } else if kind == .roads, nav.isNavigating {
            title = nav.currentStep?.instructions.isEmpty == false ? nav.currentStep!.instructions : "Suivre l’itinéraire"
            detail = nav.isOffRoadRoute ? "Hors itinéraire · rejoins le trajet" :
                String(format: "Prochain changement : %.0f m · %.1f km restants",
                       max(0, nav.distanceToNextStep), max(0, nav.distanceRemainingMeters) / 1000)
        }
        if kind != .roads, GPXAccessManager.shared.isActive {
            accessHeadline = GPXAccessManager.shared.instruction
            accessSecondary = GPXAccessManager.shared.detail
            if nav.userLocation.map({ ProjectionPolicy.isFresh(timestamp: $0.timestamp,
                accuracy: $0.horizontalAccuracy, now: Date()) }) != true {
                accessHeadline = "Position GPS en attente"
                accessSecondary = GPXAccessManager.shared.mode.title
            }
        }
    }

    func draw(in bounds: CGRect, topInset: CGFloat) {
        // Seulement en suivi GPX : un repère discret, PAS un bandeau fixe
        // ni les boutons iPhone. Visible aussi dans le rendu de la petite
        // carte envoyé au TFT, sans service de cartographie en ligne.
        guard bounds.width > 140, bounds.height > 150 else { return }
        let headline: String
        let secondary: String
        let accent: UIColor
        if let accessHeadline {
            headline = accessHeadline
            secondary = accessSecondary ?? "Rejoindre la trace"
            accent = .systemBlue
        } else if let guide = gpxGuidance {
            if guide.offTrack { headline = "HORS TRACE · \(Int(guide.offTrackMeters)) m" }
            else if guide.nearFinish { headline = "ARRIVÉE" }
            else { headline = guide.nextManeuver?.instruction ?? "SUIVRE LA TRACE" }
            secondary = guide.distanceToManeuverMeters.map {
                String(format: "Dans %.0f m · %.1f km restants", $0, guide.remainingMeters / 1000)
            } ?? String(format: "%.1f km restants", guide.remainingMeters / 1000)
            accent = guide.offTrack ? UIColor.systemOrange : UIColor(red: 0.44, green: 0.95, blue: 0.38, alpha: 1)
        } else { return }
        let width = min(bounds.width - 24, 286)
        let rect = CGRect(x: 12, y: min(max(10, topInset + 6), max(10, bounds.height - 78)),
                          width: width, height: 60)
        UIColor.black.withAlphaComponent(0.76).setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: 12).fill()
        accent.setFill()
        UIBezierPath(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: 3, height: rect.height),
                     cornerRadius: 1.5).fill()
        let titleStyle: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 14, weight: .bold), .foregroundColor: UIColor.white
        ]
        let subStyle: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: UIColor.white.withAlphaComponent(0.82)
        ]
        (headline as NSString).draw(in: CGRect(x: rect.minX + 12, y: rect.minY + 9,
                                               width: rect.width - 20, height: 23), withAttributes: titleStyle)
        (secondary as NSString).draw(in: CGRect(x: rect.minX + 12, y: rect.minY + 34,
                                                width: rect.width - 20, height: 20), withAttributes: subStyle)
    }
}
