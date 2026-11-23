import Foundation
import CoreLocation
import MapKit
import AVFoundation
import Combine
import UIKit

class LocationAndNavigationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationAndNavigationManager()
    
    private let locationManager = CLLocationManager()
    private var cameraFixManager: CLLocationManager?
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var routeCalculation: MKDirections?
    private var routeRequestID = UUID()
    // Hold a requested destination until CoreLocation delivers a fresh GPS fix.
    // Never use a stale/cached location as the departure point.
    private var pendingRoute: (destination: MKMapItem, completion: (Result<MKRoute, Error>) -> Void, token: UUID)?
    private var pendingRouteTimeout: DispatchWorkItem?
    private var tftRideActive = false
    @Published private(set) var isJoiningGPX = false
    /// A valid ongoing GPS ride, whether following a road/GPX or feeding the TFT.
    /// No background video task is started solely because the app was opened.
    var hasActiveBackgroundRide: Bool {
        isNavigating || isFollowingGPX || tftRideActive || isJoiningGPX || trailRecordingActive
    }
    private var webMapActive = false
    private var trailRecordingActive = false
    private var dashboardWeatherOnlyRequest = false
    private var backgroundActivitySession: CLBackgroundActivitySession?
    private var locationServiceSession: CLServiceSession?
    // iOS controls permission upgrades; request only once for an explicitly active ride.
    private var requestedAlwaysForRide = false
    
    // Location & Heading
    @Published var userLocation: CLLocation?
    @Published var userHeading: CLHeading?
    private var travelDirection = TravelDirection()
    private var headingReferenceTimestamp = Date.distantPast
    var travelBearing: CLLocationDirection? {
        travelDirection.bearing(compass: compassBearing, at: Date())
    }
    private var compassBearing: CLLocationDirection? {
        guard let heading = userHeading, heading.headingAccuracy >= 0,
              heading.timestamp >= headingReferenceTimestamp,
              abs(heading.timestamp.timeIntervalSinceNow) <= 15 else { return nil }
        let value = heading.trueHeading >= 0 ? heading.trueHeading : heading.magneticHeading
        return value.isFinite && (0..<360).contains(value) ? value : nil
    }

    /// Compass fallback follows the top of the visible phone interface.
    /// GPS course is geographic and must never receive a screen-rotation offset.
    func alignCompassWithPhoneInterface(_ interfaceOrientation: UIInterfaceOrientation) {
        let reference: CLDeviceOrientation
        switch interfaceOrientation {
        case .portrait: reference = .portrait
        case .portraitUpsideDown: reference = .portraitUpsideDown
        // UIKit and CoreLocation name landscape orientations oppositely.
        case .landscapeLeft: reference = .landscapeRight
        case .landscapeRight: reference = .landscapeLeft
        default: return
        }
        guard locationManager.headingOrientation != reference else { return }
        headingReferenceTimestamp = Date()
        locationManager.headingOrientation = reference
    }
    @Published var currentSpeedKmH: Int = 0
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    
    // Route & Navigation State
    @Published var independentGPXOutput = true {
        didSet { NotificationCenter.default.post(name: .nicoNavigationUpdated, object: nil) }
    }
    @Published var importedTrack: GPXTrack?
    @Published private(set) var importedTrackRevision = UUID()
    @Published var isFollowingGPX = false
    @Published var distanceFromGPX: Double?
    @Published private(set) var gpxGuidance: GPXRouteGuidance?
    private var gpxNavigator: GPXRouteNavigator?
    private var gpxAlertPolicy = GPXAlertPolicy()
    @Published private(set) var gpxReversed = UserDefaults.standard.bool(forKey: "doubleInterface.gpxReversed")
    private let gpxReversedKey = "doubleInterface.gpxReversed"
    @Published var isNavigating: Bool = false

    private var savedGPXURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProcessInfo.processInfo.arguments.contains("--ui-screenshots") ? "NicoMirror-Screenshots" : "NicoMirror", isDirectory: true).appendingPathComponent("last-track.gpx")
    }

    func importGPX(_ document: GPXDocument, keepDirection: Bool) throws {
        let track = document.track
        let url = savedGPXURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try document.data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        // GPX and road navigation are independent.
        importedTrack = track
        if !keepDirection {
            gpxReversed = false
            UserDefaults.standard.set(false, forKey: gpxReversedKey)
        }
        gpxNavigator = GPXRouteNavigator(track: gpxReversed ? track.reversedForGuidance() : track)
        gpxAlertPolicy.reset()
        gpxGuidance = nil
        importedTrackRevision = UUID()
        distanceFromGPX = nil
        NotificationCenter.default.post(name: .nicoNavigationUpdated, object: nil)
    }

    func restoreGPX() {
        guard importedTrack == nil,
              let document = try? GPXDocument.load(from: savedGPXURL, fallbackName: "Trace enregistrée") else { return }
        importedTrack = document.track
        gpxNavigator = GPXRouteNavigator(track: gpxReversed ? document.track.reversedForGuidance() : document.track)
        gpxAlertPolicy.reset()
        gpxGuidance = nil
        importedTrackRevision = UUID()
        NotificationCenter.default.post(name: .nicoNavigationUpdated, object: nil)
    }

    /// Shares the original document: do not lose waypoints or vendor extensions
    /// by re-encoding only the simplified geometry used by our preview.
    func gpxForSharing() throws -> URL {
        guard importedTrack != nil else { throw GPXError.empty }
        let data = try Data(contentsOf: savedGPXURL)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Double-Interface-GPX-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Trace-Double-Interface.gpx")
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    func startFollowingGPX(atProgressMeters: Double? = nil) {
        guard importedTrack != nil else { return }
        isFollowingGPX = true
        gpxAlertPolicy.reset()
        if gpxNavigator == nil, let importedTrack {
            gpxNavigator = GPXRouteNavigator(track: gpxReversed ? importedTrack.reversedForGuidance() : importedTrack)
        }
        gpxGuidance = nil
        distanceFromGPX = nil
        if let location = userLocation { updateGPX(location, initialProgress: atProgressMeters) }
        if !ProcessInfo.processInfo.arguments.contains("--ui-screenshots") { startUpdating() }
        NotificationCenter.default.post(name: .nicoNavigationUpdated, object: nil)
    }

    /// Inverse le sens du suivi sans altérer les données GPX originales.
    func toggleGPXDirection() {
        guard let importedTrack else { return }
        gpxReversed.toggle()
        gpxAlertPolicy.reset()
        UserDefaults.standard.set(gpxReversed, forKey: gpxReversedKey)
        gpxNavigator = GPXRouteNavigator(track: gpxReversed ? importedTrack.reversedForGuidance() : importedTrack)
        gpxGuidance = nil
        if isFollowingGPX, let location = userLocation { updateGPX(location) }
        NotificationCenter.default.post(name: .nicoNavigationUpdated, object: nil)
    }

    func stopFollowingGPX() {
        isFollowingGPX = false
        gpxAlertPolicy.reset()
        gpxGuidance = nil
        distanceFromGPX = nil
        updateBackgroundActivity()
        stopUpdating()
        NotificationCenter.default.post(name: .nicoNavigationUpdated, object: nil)
    }

    func clearGPX() {
        stopFollowingGPX()
        importedTrack = nil
        gpxNavigator = nil
        gpxGuidance = nil
        gpxReversed = false
        UserDefaults.standard.set(false, forKey: gpxReversedKey)
        importedTrackRevision = UUID()
        try? FileManager.default.removeItem(at: savedGPXURL)
        NotificationCenter.default.post(name: .nicoNavigationUpdated, object: nil)
    }

    private func updateGPX(_ location: CLLocation, initialProgress: Double? = nil) {
        guard ProjectionPolicy.isFresh(timestamp: location.timestamp, accuracy: location.horizontalAccuracy, now: Date()) else {
            distanceFromGPX = nil
            gpxGuidance = nil
            return
        }
        let coordinate = GPXPoint(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        gpxGuidance = gpxNavigator?.guidance(at: coordinate, previousMeters: initialProgress ?? gpxGuidance?.travelledMeters)
        distanceFromGPX = gpxGuidance?.offTrackMeters
        if let gpxGuidance, gpxAlertPolicy.shouldAnnounce(
            deviationMeters: gpxGuidance.offTrackMeters,
            gpsAccuracyMeters: location.horizontalAccuracy,
            now: Date()
        ) {
            speakInstruction("Attention, tu t'éloignes de la trace GPX.")
        }
    }
    @Published var destinationItem: MKMapItem?
    @Published var currentRoute: MKRoute?
    @Published private(set) var isOffRoadRoute = false
    private var roadRouteProgress: RoadRouteProgress?
    private var roadStepProgress: RoadStepProgress?
    private var lastRoadProgressMeters: Double?
    @Published var currentStepIndex: Int = 0
    @Published var distanceToNextStep: CLLocationDistance = 0
    @Published var distanceRemainingMeters: CLLocationDistance = 0
    @Published var timeRemainingSeconds: TimeInterval = 0
    @Published var isAudioMuted: Bool = UserDefaults.standard.bool(forKey: "doubleInterface.voiceMuted") {
        didSet {
            UserDefaults.standard.set(isAudioMuted, forKey: "doubleInterface.voiceMuted")
            if isAudioMuted { speechSynthesizer.stopSpeaking(at: .immediate) }
        }
    }
    
    // Computed Current Step
    var currentStep: MKRoute.Step? {
        guard let route = currentRoute, currentStepIndex < route.steps.count else { return nil }
        return route.steps[currentStepIndex]
    }
    
    var nextStep: MKRoute.Step? {
        guard let route = currentRoute, (currentStepIndex + 1) < route.steps.count else { return nil }
        return route.steps[currentStepIndex + 1]
    }
    
    override private init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = 2 // Foreground map browsing.
        locationManager.headingFilter = 3.0   // Update every 3 degrees
        locationManager.allowsBackgroundLocationUpdates = false
        locationManager.showsBackgroundLocationIndicator = true
        locationManager.activityType = .automotiveNavigation
        locationManager.pausesLocationUpdatesAutomatically = false
        
        self.authorizationStatus = locationManager.authorizationStatus
    }
    
    func requestLocationPermission() {
        dashboardWeatherOnlyRequest = false
        switch locationManager.authorizationStatus {
        case .notDetermined:
            // Ask for foreground access first. An Always upgrade can be requested
            // after that choice, only during a real background ride.
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            startUpdating()
            // A background activity session supports many When-In-Use rides, but
            // Always provides a more reliable permission for longer locked trips.
            if hasActiveBackgroundRide && !requestedAlwaysForRide && UIApplication.shared.applicationState == .active {
                requestedAlwaysForRide = true
                locationManager.requestAlwaysAuthorization()
            }
        case .authorizedAlways:
            startUpdating()
        case .denied, .restricted:
            ProjectionDiagnostics.shared.recordError("GPS interdit : autorise la position dans Réglages > Double Interface > Position.")
        @unknown default:
            break
        }
    }

    /// Embedded web maps only need location while their screen is open.
    func setWebMapActive(_ active: Bool) {
        webMapActive = active
        if active { requestWebMapLocation() }
        else { stopUpdating() }
    }

    func requestWebMapLocation() {
        dashboardWeatherOnlyRequest = false
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            startUpdating()
        default:
            break
        }
    }

    var mapLocationDenied: Bool {
        let status = locationManager.authorizationStatus
        return status == .denied || status == .restricted
    }

    /// MapKit may already display a newer fix than the navigation delegate.
    func currentMapLocation(including mapFix: CLLocation? = nil) -> CLLocation? {
        let status = locationManager.authorizationStatus
        guard status == .authorizedAlways || status == .authorizedWhenInUse else { return nil }
        let now = Date()
        return [userLocation, mapFix, locationManager.location].compactMap { $0 }.filter {
            CLLocationCoordinate2DIsValid($0.coordinate) &&
                ProjectionPolicy.isFresh(timestamp: $0.timestamp, accuracy: $0.horizontalAccuracy, now: now)
        }.max {
            if $0.timestamp == $1.timestamp { return $0.horizontalAccuracy > $1.horizontalAccuracy }
            return $0.timestamp < $1.timestamp
        }
    }

    /// A separate one-shot can get a fix while stopped without interrupting
    /// the continuous manager used by navigation, recording and the TFT.
    func requestMapCameraLocation() {
        requestWebMapLocation()
        let status = locationManager.authorizationStatus
        guard status == .authorizedAlways || status == .authorizedWhenInUse,
              cameraFixManager == nil else { return }
        let manager = CLLocationManager()
        cameraFixManager = manager
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.delegate = self
        manager.requestLocation()
    }

    /// A foreground one-shot fix for the weather widget, without starting a ride.
    func requestDashboardWeatherLocation() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            dashboardWeatherOnlyRequest = !isNavigating && !tftRideActive && !webMapActive
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.requestLocation()
        default: break
        }
    }
    
    func startUpdating() {
        dashboardWeatherOnlyRequest = false
        updateBackgroundActivity()
        guard locationManager.authorizationStatus == .authorizedWhenInUse ||
                locationManager.authorizationStatus == .authorizedAlways else { return }
        locationManager.startUpdatingLocation()
        locationManager.startUpdatingHeading()
    }

    /// The TFT consumes real speed/altitude updates even without an entered destination.
    func setTFTRideActive(_ active: Bool) {
        guard tftRideActive != active else { return }
        tftRideActive = active
        if active {
            requestLocationPermission()
        } else {
            requestedAlwaysForRide = false
            updateBackgroundActivity()
            if !isNavigating { stopUpdating() }
        }
    }

    func setTrailRecordingActive(_ active: Bool) {
        guard trailRecordingActive != active else { return }
        trailRecordingActive = active
        if active {
            requestLocationPermission()
        } else {
            updateBackgroundActivity()
            stopUpdating()
        }
    }

    private func updateBackgroundActivity() {
        let needed = hasActiveBackgroundRide
        let authorized = locationManager.authorizationStatus == .authorizedAlways
            || locationManager.authorizationStatus == .authorizedWhenInUse
        // The active ride requests every movement, including slow starts and tight turns.
        let distanceFilter: CLLocationDistance = needed ? kCLDistanceFilterNone : 2
        if locationManager.distanceFilter != distanceFilter {
            locationManager.distanceFilter = distanceFilter
        }
        locationManager.allowsBackgroundLocationUpdates = needed && authorized
        if needed && authorized {
            // Start the visible ride session before the person locks the phone.
            if backgroundActivitySession == nil && UIApplication.shared.applicationState != .background {
                locationServiceSession = CLServiceSession(authorization: .whenInUse)
                backgroundActivitySession = CLBackgroundActivitySession()
            }
        } else {
            backgroundActivitySession?.invalidate()
            backgroundActivitySession = nil
            locationServiceSession?.invalidate()
            locationServiceSession = nil
        }
        ProjectionDiagnostics.shared.setBackgroundLocation(needed && authorized)
    }
    
    func stopUpdating() {
        guard !isNavigating, !isFollowingGPX, !tftRideActive, !trailRecordingActive, !webMapActive, !isJoiningGPX else { return }
        locationManager.stopUpdatingLocation()
        locationManager.stopUpdatingHeading()
        updateBackgroundActivity()
    }
    
    // MARK: - Route Calculation

    func setTraceAccessActive(_ active: Bool) {
        guard isJoiningGPX != active else { return }
        isJoiningGPX = active
        if active { startUpdating() } else { updateBackgroundActivity(); stopUpdating() }
        NotificationCenter.default.post(name: .nicoNavigationUpdated, object: nil)
    }

    func announceTraceAccess(_ text: String) { speakInstruction(text, forTraceAccess: true) }
    
    func cancelRouteCalculation() {
        routeRequestID = UUID()
        routeCalculation?.cancel()
        routeCalculation = nil
        pendingRouteTimeout?.cancel()
        pendingRouteTimeout = nil
        pendingRoute = nil
    }

    func calculateRoute(to destination: MKMapItem, completion: @escaping (Result<MKRoute, Error>) -> Void) {
        cancelRouteCalculation()
        let token = routeRequestID
        if let origin = userLocation,
           ProjectionPolicy.isFresh(timestamp: origin.timestamp, accuracy: origin.horizontalAccuracy, now: Date()) {
            calculateRoute(from: origin, to: destination, token: token, completion: completion)
            return
        }

        // A temporary GPS gap is not a navigation failure. Wait for a new fix
        // and keep the progress indicator visible while location is acquired.
        switch locationManager.authorizationStatus {
        case .denied, .restricted:
            completion(.failure(NSError(domain: "DoubleInterface", code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Active la localisation pour Double Interface dans les réglages de l’iPhone."])))
            return
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            startUpdating()
        @unknown default:
            break
        }
        pendingRoute = (destination: destination, completion: completion, token: token)
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.pendingRoute?.token == token else { return }
            self.failPendingRoute("GPS indisponible. Vérifie la localisation de l’iPhone et réessaie à l’extérieur.")
        }
        pendingRouteTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
    }

    private func failPendingRoute(_ message: String) {
        guard let pending = pendingRoute else { return }
        pendingRoute = nil
        pendingRouteTimeout?.cancel()
        pendingRouteTimeout = nil
        pending.completion(.failure(NSError(domain: "DoubleInterface", code: 12,
            userInfo: [NSLocalizedDescriptionKey: message])))
    }

    private func calculateRoute(from origin: CLLocation, to destination: MKMapItem, token: UUID,
                                completion: @escaping (Result<MKRoute, Error>) -> Void) {
        guard routeRequestID == token else { return }
        let request = MKDirections.Request()
        request.source = MKMapItem(location: origin, address: nil)
        request.destination = destination
        request.transportType = .automobile
        request.requestsAlternateRoutes = false
        let directions = MKDirections(request: request)
        routeCalculation = directions
        directions.calculate { [weak self] response, error in
            DispatchQueue.main.async {
                guard let self, self.routeRequestID == token else { return }
                self.routeCalculation = nil
                if let error { completion(.failure(error)); return }
                guard let route = response?.routes.first else {
                    completion(.failure(NSError(domain: "DoubleInterface", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Aucun itinéraire routier trouvé pour cette destination."])))
                    return
                }
                completion(.success(route))
            }
        }
    }

    // MARK: - Navigation Control
    
    func startNavigation(route: MKRoute, destination: MKMapItem) {
        self.currentRoute = route
        self.destinationItem = destination
        let polyline = route.polyline
        if polyline.pointCount >= 2 {
            var coordinates = Array(repeating: CLLocationCoordinate2D(), count: polyline.pointCount)
            polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
            roadRouteProgress = RoadRouteProgress(coordinates.map {
                RoadRouteCoordinate(latitude: $0.latitude, longitude: $0.longitude)
            })
        } else {
            roadRouteProgress = nil
        }
        roadStepProgress = RoadStepProgress(stepDistances: route.steps.map(\.distance))
        lastRoadProgressMeters = nil
        isOffRoadRoute = false
        
        // Skip initial departure step if it has empty instructions or 0 distance
        var initialIndex = 0
        if route.steps.count > 1 && (route.steps[0].instructions.isEmpty || route.steps[0].distance == 0) {
            initialIndex = 1
        }
        self.currentStepIndex = initialIndex
        self.isNavigating = true
        self.distanceRemainingMeters = route.distance
        self.timeRemainingSeconds = route.expectedTravelTime
        
        if initialIndex < route.steps.count {
            let step = route.steps[initialIndex]
            self.distanceToNextStep = step.distance
        }
        
        startUpdating()
        
        // Announce navigation start
        let destName = destination.name ?? "destination"
        speakInstruction("Départ vers \(destName). Bonne route.")
        
        // Sync turn-by-turn navigation with Kove TFT Dashboard over BLE
        NavigationSyncManager.shared.startNavigation(route: route, destination: destination)
        
        if let firstStep = currentStep {
            updateStepInfo(step: firstStep)
        }
        NotificationCenter.default.post(name: .nicoNavigationUpdated, object: nil)
    }
    
    func stopNavigation(announce: Bool = true) {
        guard isNavigating else { return }
        isNavigating = false
        updateBackgroundActivity()
        currentRoute = nil
        destinationItem = nil
        roadRouteProgress = nil
        roadStepProgress = nil
        lastRoadProgressMeters = nil
        isOffRoadRoute = false
        currentStepIndex = 0
        if announce { speakInstruction("Guidage routier terminé.") }
        stopUpdating()
        
        // Notify Kove TFT Dashboard that navigation ended
        NavigationSyncManager.shared.stopNavigation()
        NotificationCenter.default.post(name: .nicoNavigationUpdated, object: nil)
    }
    
    // MARK: - CLLocationManagerDelegate
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager === locationManager else { return }
        DispatchQueue.main.async {
            self.authorizationStatus = manager.authorizationStatus
            if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
                if self.dashboardWeatherOnlyRequest && !self.isNavigating && !self.tftRideActive && !self.webMapActive {
                    self.dashboardWeatherOnlyRequest = false
                    manager.requestLocation()
                } else {
                    self.startUpdating()
                    if manager.authorizationStatus == .authorizedWhenInUse,
                       self.hasActiveBackgroundRide, UIApplication.shared.applicationState == .active,
                       !self.requestedAlwaysForRide {
                        self.requestedAlwaysForRide = true
                        manager.requestAlwaysAuthorization()
                    }
                }
            } else {
                self.updateBackgroundActivity()
                if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
                    self.userLocation = nil
                    self.userHeading = nil
                    self.travelDirection = TravelDirection()
                    self.cameraFixManager?.stopUpdatingLocation()
                    self.cameraFixManager = nil
                    self.failPendingRoute("Localisation refusée. Autorise Double Interface dans Réglages > Confidentialité et sécurité > Service de localisation.")
                    ProjectionDiagnostics.shared.recordError("Localisation désactivée : la continuité du trajet écran verrouillé est indisponible.")
                }
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if manager === cameraFixManager { cameraFixManager = nil }
        // One-shot weather fixes can fail indoors. Keep the last real fix and
        // let the widget show its waiting/error state instead of a fake position.
        ProjectionDiagnostics.shared.recordError("Position GPS momentanément indisponible.")
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if manager === cameraFixManager { cameraFixManager = nil }
        guard locationManager.authorizationStatus == .authorizedAlways ||
                locationManager.authorizationStatus == .authorizedWhenInUse else { return }
        // CoreLocation may replay cached positions on wake. Never overwrite a fresh
        // motorcycle fix with an older one or make the TFT jump backwards.
        let now = Date()
        guard let location = locations.last(where: {
            CLLocationCoordinate2DIsValid($0.coordinate) &&
                ProjectionPolicy.isFresh(timestamp: $0.timestamp, accuracy: $0.horizontalAccuracy, now: now)
        }) else { return }

        // Both managers are created on the main run loop, which delivers their delegate callbacks.
        if let previous = userLocation, location.timestamp <= previous.timestamp { return }
        travelDirection.update(course: location.course, speed: location.speed,
                               accuracy: location.horizontalAccuracy, at: location.timestamp)
        userLocation = location
        ProjectionDiagnostics.shared.recordFix(location.timestamp)
        if let pending = pendingRoute {
            pendingRoute = nil
            pendingRouteTimeout?.cancel()
            pendingRouteTimeout = nil
            calculateRoute(from: location, to: pending.destination, token: pending.token,
                           completion: pending.completion)
        }
        currentSpeedKmH = Int(max(0, location.speed) * 3.6)
        TelemetrySyncManager.shared.onLocationFix()
        if isFollowingGPX { updateGPX(location) }
        if isNavigating { updateNavigationProgress(currentLocation: location) }
        NotificationCenter.default.post(name: .nicoNavigationUpdated, object: nil)
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard manager === locationManager, newHeading.headingAccuracy >= 0,
              newHeading.timestamp >= headingReferenceTimestamp,
              newHeading.timestamp >= (userHeading?.timestamp ?? .distantPast) else { return }
        let previous = travelBearing
        userHeading = newHeading
        if MapHeading.changed(from: previous, to: travelBearing) {
            NotificationCenter.default.post(name: .nicoNavigationUpdated, object: nil)
        }
    }
    
    // MARK: - Navigation Step Tracking
    
    private func updateNavigationProgress(currentLocation: CLLocation) {
        guard let route = currentRoute, let path = roadRouteProgress, path.totalMeters > 0 else { return }
        let gps = RoadRouteCoordinate(latitude: currentLocation.coordinate.latitude,
                                      longitude: currentLocation.coordinate.longitude)
        guard let position = path.project(gps, previousMeters: lastRoadProgressMeters) else { return }

        // On ne projette pas une position lointaine sur une route comme si le motard
        // la suivait. Un recalcul d'itineraire reste a implementer separement.
        let maximumGap = max(120.0, currentLocation.horizontalAccuracy * 3.0)
        guard position.deviationMeters <= maximumGap else {
            isOffRoadRoute = true
            return
        }
        isOffRoadRoute = false
        lastRoadProgressMeters = position.travelledMeters

        let remaining = path.remainingRoadMeters(at: position, mapKitRouteMeters: route.distance)
        distanceRemainingMeters = remaining
        timeRemainingSeconds = max(0, route.expectedTravelTime * remaining / max(1, route.distance))

        // Double protection contre une fausse arrivee sur une route qui croise
        // ou repasse pres de sa propre destination.
        if remaining < 30,
           let destination = destinationItem?.location,
           currentLocation.distance(from: destination) < 45 {
            NavigationSyncManager.shared.triggerArrival()
            speakInstruction("Tu es arrivé à destination.")
            stopNavigation(announce: false)
            return
        }

        // Les instructions avancent selon la distance parcourue sur l'itineraire,
        // et non en fonction de la distance a vol d'oiseau au prochain virage.
        let stepDistanceTotal = route.steps.reduce(0.0) { $0 + max(0, $1.distance) }
        let stepTravelled = position.travelledMeters / path.totalMeters * stepDistanceTotal
        if let stepPath = roadStepProgress, currentStepIndex < route.steps.count {
            let nextIndex = stepPath.nextIndex(current: currentStepIndex, travelledMeters: stepTravelled)
            if nextIndex != currentStepIndex {
                currentStepIndex = nextIndex
                if let step = currentStep { updateStepInfo(step: step) }
            }
            distanceToNextStep = stepPath.distanceToStepEnd(index: currentStepIndex,
                                                             travelledMeters: stepTravelled)
        }

        NavigationSyncManager.shared.updateProgress(
            stepIndex: currentStepIndex,
            distanceToStep: distanceToNextStep,
            totalRemainingDistance: remaining,
            timeRemaining: timeRemainingSeconds,
            speedKmH: currentSpeedKmH
        )
    }

    private func updateStepInfo(step: MKRoute.Step) {
        guard !step.instructions.isEmpty else { return }
        let distanceKm = String(format: "%.1f km", step.distance / 1000.0)
        let distText = step.distance < 1000 ? "\(Int(step.distance)) mètres" : distanceKm
        
        speakInstruction("Dans \(distText), \(step.instructions)")
    }
    
    /// A traffic alert never interrupts an ongoing turn instruction.
    func announceTraffic(_ text: String) {
        guard !isAudioMuted, !speechSynthesizer.isSpeaking else { return }
        speakInstruction(text)
    }

    private func speakInstruction(_ text: String, forTraceAccess: Bool = false) {
        guard !isAudioMuted, !isJoiningGPX || forTraceAccess else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.language.languageCode?.identifier ?? "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        speechSynthesizer.speak(utterance)
    }
}

// Helper extension for maneuver icon mapping
extension MKRoute.Step {
    var maneuverIconName: String {
        let lower = instructions.lowercased()
        if lower.contains("right") {
            return "arrow.turn.up.right"
        } else if lower.contains("left") {
            return "arrow.turn.up.left"
        } else if lower.contains("roundabout") || lower.contains("circle") {
            return "arrow.triangle.turn.clockwise.around.railway"
        } else if lower.contains("u-turn") {
            return "arrow.uturn.backward"
        } else if lower.contains("merge") || lower.contains("keep") {
            return "arrow.triangle.merge"
        } else if lower.contains("arrive") || lower.contains("destination") {
            return "mappin.circle.fill"
        } else {
            return "arrow.up"
        }
    }
}
