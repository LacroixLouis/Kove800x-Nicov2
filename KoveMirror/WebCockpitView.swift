import SwiftUI
import Combine
import MapKit
import UniformTypeIdentifiers

private enum MapSheet: String, Identifiable {
    case menu, tracks, destination, connection, paste, osmandSettings, wizeSignals, wizeAlerts, maintenance
    var id: String { rawValue }
}

private enum MapControlsDismissMode: String, CaseIterable, Identifiable {
    case fourSeconds = "fourSeconds"
    case permanent = "permanent"
    case whenMoving = "whenMoving"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .fourSeconds: return "4 secondes"
        case .permanent: return "Permanent"
        case .whenMoving: return "Dès que je roule"
        }
    }
}

struct WebCockpitView: View {
    @ObservedObject var bleController: BleController
    @StateObject private var session = WebCockpitSession.shared
    @ObservedObject private var nav = LocationAndNavigationManager.shared
    @ObservedObject private var traceAccess = GPXAccessManager.shared
    @ObservedObject private var library = TrackLibrary.shared
    @ObservedObject private var recorder = TrailRecorder.shared
    @ObservedObject private var offlineLibrary = OfflineMapLibrary.shared
    @AppStorage("pairedMotorcycleSSID") private var pairedSSID = ""
    @State private var sheet: MapSheet?
    @State private var nextSheet: MapSheet?
    @State private var importing = false
    @State private var importingOfflineMap = false
    @State private var pendingRasterImport: OsmondRasterLayer?
    @State private var importAfterDismiss = false
    @State private var error: String?
    @State private var calculating = false
    @State private var oldIdleTimer = false
    @State private var startupToken = UUID()
    @State private var showTrailWorkspace = false
    @State private var wukulucInitialTab: WukulucTab = .explore
    @State private var wukulucInitialDetail: UUID?
    @State private var openTrailAfterDismiss = false
    @State private var mapToolsExpanded = false
    @State private var mapStyleRevision = UUID()
    @State private var focusButtonRevision = 0
    // Map controls fade after four seconds; expanded settings stay open until dismissed.
    // Opening settings cancels the timer so the panel and its close button remain visible.
    // The miniature remains visible and its renderer alone feeds the TFT stream.
    @State private var mapActionsVisible = true
    @State private var mapActionsToken = UUID()
    @AppStorage("doubleInterface.controlsDismissMode") private var controlsDismissModeRaw = MapControlsDismissMode.fourSeconds.rawValue
    private var controlsDismissMode: MapControlsDismissMode {
        MapControlsDismissMode(rawValue: controlsDismissModeRaw) ?? .fourSeconds
    }
    private let controlsIdleTimeout: TimeInterval = 4
    private let movingThresholdKmH: Int = 5
    @State private var showSaveRecording = false
    @State private var recordingName = ""
    private var screenshots: Bool { ProcessInfo.processInfo.arguments.contains("--ui-screenshots") }

    private var windowSafeArea: UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })?.safeAreaInsets ?? .zero
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                // The geometry reader itself spans the complete display. Previously
                // only this child ignored safe areas, leaving a black strip below
                // its fixed-size UIKit map view on modern iPhones.
                maps(in: geometry)
                // The preview is a top-level overlay so it can reach every
                // corner, even where the transient map buttons are displayed.
                miniature(in: geometry).zIndex(4)
                // The validated visual direction: brand + three compact map
                // profiles at the top, contextual controls on the left and a
                // small bottom dock. All are iPhone chrome, NEVER TFT pixels.
                mapControls(in: geometry)

                VStack {
                    Spacer(minLength: 0)
                    HStack {
                        if geometry.size.height >= 560 {
                            quickMapRail
                        } else {
                            focusTriangleButton
                        }
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, max(geometry.safeAreaInsets.leading, windowSafeArea.left) + 12)
                .padding(.top, max(geometry.safeAreaInsets.top, windowSafeArea.top) + (geometry.size.height >= 560 ? 150 : 85))
                .padding(.bottom, max(geometry.safeAreaInsets.bottom, windowSafeArea.bottom) + (geometry.size.height >= 560 ? 90 : 70))
                .opacity(mapActionsVisible ? 1 : 0)
                .allowsHitTesting(mapActionsVisible)
                .accessibilityHidden(!mapActionsVisible)
                .animation(.easeOut(duration: 0.28), value: mapActionsVisible)
                .zIndex(2)

                // In permanent mode this small handle is the only remaining control
                // when the rider hides all menus. It does not alter the TFT stream.
                if controlsDismissMode == .permanent && !mapActionsVisible {
                    VStack {
                        HStack {
                            Spacer(minLength: 0)
                            Button { revealMapActions() } label: {
                                Label("Afficher le menu", systemImage: "line.3.horizontal")
                                    .font(.system(size: 12, weight: .bold))
                                    .padding(11)
                                    .background(activeSurface, in: Capsule())
                            }
                            .accessibilityIdentifier("maps.showPermanentMenu")
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, max(geometry.safeAreaInsets.top, windowSafeArea.top) + 12)
                    .padding(.trailing, max(geometry.safeAreaInsets.trailing, windowSafeArea.right) + 12)
                    .zIndex(7)
                }
                // Controls belong to the iPhone overlay, not to the TFT video.
                // Keep stop and voice controls immediately available on every map.
                if nav.isNavigating || nav.isFollowingGPX || traceAccess.isActive {
                    VStack {
                        Spacer(minLength: 0)
                        HStack {
                            Spacer(minLength: 0)
                            navigationQuickActions
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.trailing, max(geometry.safeAreaInsets.trailing, windowSafeArea.right) + 12)
                    .padding(.top, max(geometry.safeAreaInsets.top, windowSafeArea.top) + 146)
                    .padding(.bottom, max(geometry.safeAreaInsets.bottom, windowSafeArea.bottom) + 95)
                    .opacity(mapActionsVisible ? 1 : 0)
                    .allowsHitTesting(mapActionsVisible)
                    .accessibilityHidden(!mapActionsVisible)
                    .animation(.easeOut(duration: 0.28), value: mapActionsVisible)
                    .zIndex(3)
                }
                if calculating || library.isImporting || traceAccess.isCalculating {
                    ProgressView(library.isImporting ? "Import du GPX…" : "GPS / calcul du trajet…").padding(20)
                        .background(RivetCockpit.asphalt, in: Capsule())
                        .frame(maxHeight: .infinity).zIndex(3)
                }
            }
        }
        // Safe-area clipping was the origin of the empty black bottom band.
        // Draw the entire cockpit all the way to the home-indicator edge.
        .ignoresSafeArea(.container, edges: .all)
        .background(RivetCockpit.asphalt).foregroundStyle(RivetCockpit.paper)
        .preferredColorScheme(.dark).tint(activeAccent)
        
        .onAppear {
            oldIdleTimer = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            UserDefaults.standard.set(true, forKey: TFTConnectionPolicy.automaticKey)
            bleController.selectMiniature()
            bleController.beginWebPanelProjection()
            revealMapActions()
            if !screenshots {
                // Les données GPX peuvent être volumineuses. Ne pas les décoder
                // ni lancer les transports pendant la première image à l'écran.
                let token = UUID()
                startupToken = token
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                    guard startupToken == token else { return }
                    session.beginLocation()
                    bleController.resumeAutomaticConnection()
                }
            }
        }
        .onDisappear {
            startupToken = UUID() // Ignore les reprises retardées après fermeture.
            nav.cancelRouteCalculation()
            calculating = false
            bleController.endWebPanelProjection()
            mapActionsToken = UUID() // Cancel pending auto-hide callbacks.
            nav.setWebMapActive(false)
            UIApplication.shared.isIdleTimerDisabled = oldIdleTimer
        }
        .sheet(item: $sheet, onDismiss: {
            revealMapActions()
            if openTrailAfterDismiss {
                openTrailAfterDismiss = false
                wukulucInitialTab = .explore; wukulucInitialDetail = nil; showTrailWorkspace = true
            }
            else if importAfterDismiss { importAfterDismiss = false; importing = true }
            else if let nextSheet { self.nextSheet = nil; sheet = nextSheet }
        }) { page in
            switch page {
            case .menu: menu
            case .maintenance: MaintenanceHomeView(bleController: bleController)
            case .tracks: tracks
            case .osmandSettings: osmandSettings
            case .wizeSignals: WizeSignalsSheet()
            case .wizeAlerts: WizeAlertsSheet()
            case .paste: PasteGPXSheet { data in try importTrack(data, name: "Trace collée") }
            case .connection: ProjectionPreparationView(bleController: bleController, pairedSSID: $pairedSSID)
            case .destination:
                DestinationSearchSheet(userRegion: nav.userLocation.map {
                    MKCoordinateRegion(center: $0.coordinate, latitudinalMeters: 20_000, longitudinalMeters: 20_000)
                }) { destination in sheet = nil; calculate(to: destination) }
            }
        }
        .fullScreenCover(isPresented: $showTrailWorkspace) {
            WukulucWorkspaceView(initialTab: wukulucInitialTab, initialDetailID: wukulucInitialDetail)
        }
        .environment(\.rideMapProfile, activeProfile)
        .onChange(of: controlsDismissModeRaw) {
            revealMapActions()
        }
        .onReceive(nav.$currentSpeedKmH.receive(on: DispatchQueue.main)) { speed in
            guard controlsDismissMode == .whenMoving else { return }
            if speed >= movingThresholdKmH {
                if mapActionsVisible { hideMapActions() }
            } else if speed <= 2 && !mapActionsVisible {
                // Show tools again automatically once the bike stops.
                revealMapActions()
            }
        }
        .onChange(of: activeProfile) {
            // Keep the panel open while replacing its controls with this map's settings.
            mapStyleRevision = UUID()
            revealMapActions()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mapFocusChanged)
            .receive(on: DispatchQueue.main)) { note in
            if let panel = note.object as? IntegratedNavigationPanel,
               panel === session.renderer(session.layout.phone) { focusButtonRevision += 1 }
        }
        .onChange(of: traceAccess.routeRevision) {
            guard traceAccess.route != nil else { return }
            let renderer = traceAccess.profile == .osmand ? session.osmand : session.tracks
            renderer.refresh(); renderer.showTraceAccess()
        }
        .alert("Enregistrer la trace", isPresented: $showSaveRecording) {
            TextField("Ma sortie", text: $recordingName)
            Button("Sauvegarder") {
                do {
                    _ = try recorder.finish(name: recordingName)
                    session.tracks.refresh()
                    session.tracks.showRoute()
                } catch { self.error = error.localizedDescription }
            }
            Button("Annuler", role: .cancel) { }
        } message: {
            Text("Le parcours est ajouté à Mes traces en GPX. Il faut au moins deux points GPS.")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "gpx") ?? .xml, .xml]) { result in
            switch result {
            case .success(let url):
                library.importFile(url) { failure in
                    if let failure { error = failure.localizedDescription }
                    else { session.tracks.refresh(); session.tracks.showRoute() }
                }
            case .failure(let failure):
                if (failure as NSError).code != NSUserCancelledError { error = failure.localizedDescription }
            }
        }
        .fileImporter(isPresented: $importingOfflineMap,
                      allowedContentTypes: [UTType(filenameExtension: "mbtiles") ?? .data, .data]) { result in
            switch result {
            case .success(let url):
                do {
                    let importingLayer = pendingRasterImport
                    pendingRasterImport = nil
                    let package = try offlineLibrary.importFile(url, selectAsBase: importingLayer == nil)
                    if let importingLayer {
                        offlineLibrary.selectOverlay(package, for: importingLayer)
                        session.osmand.refreshOsmondRasterLayers()
                    } else {
                        session.osmand.setOfflineMap(package)
                    }
                } catch { self.error = error.localizedDescription }
            case .failure(let failure):
                pendingRasterImport = nil
                if (failure as NSError).code != NSUserCancelledError { error = failure.localizedDescription }
            }
        }
        .alert("Double Interface", isPresented: Binding(get: { error != nil || traceAccess.error != nil }, set: {
            if !$0 { error = nil; traceAccess.clearError() }
        })) {
            Button("OK", role: .cancel) { error = nil; traceAccess.clearError() }
        } message: { Text(error ?? traceAccess.error ?? "") }
    }

    // A single persistent UIKit surface owns both renderer views. On an exchange
    // UIKit moves them in one update; no independent SwiftUI host can detach a
    // renderer while the other host is still attaching it (black phone map).
    private func maps(in geometry: GeometryProxy) -> some View {
        let metrics = MapPanelMetrics(area: geometry.size,
                                      insets: geometry.safeAreaInsets,
                                      source: session.canvasSize)
        return DualMapRendererHost(
            phoneRenderer: session.renderer(session.layout.phone),
            tftRenderer: session.renderer(session.layout.tft),
            metrics: metrics,
            normalizedX: session.layout.miniX,
            normalizedY: session.layout.miniY,
            topInset: max(geometry.safeAreaInsets.top, windowSafeArea.top) + (geometry.size.height < 560 ? 102 : 126),
            onUserTap: {
                revealMapActions()
            }
        )
        .frame(width: geometry.size.width, height: geometry.size.height)
        .transaction { $0.disablesAnimations = true }
    }

    private func miniature(in geometry: GeometryProxy) -> some View {
        let metrics = MapPanelMetrics(area: geometry.size,
                                      insets: geometry.safeAreaInsets,
                                      source: session.canvasSize)
        return DraggableTFTMiniature(
            accent: session.profile(session.layout.tft).menuAccent,
            metrics: metrics,
            normalizedX: session.layout.miniX,
            normalizedY: session.layout.miniY,
            onExchange: { session.exchange() },
            onMove: { x, y in session.moveMini(x: x, y: y) },
            onInteraction: { revealMapActions() }
        )
    }

    // MARK: - Three visual identities, with one common map/TFT workflow

    private func mapControls(in geometry: GeometryProxy) -> some View {
        let safeArea = windowSafeArea
        return VStack(spacing: 0) {
            mapHeader(compact: geometry.size.height < 560)
                .fixedSize(horizontal: false, vertical: true)
            if mapToolsExpanded {
                // Use only the space between the header and dock. In a short
                // viewport the settings scroll instead of pushing either offscreen.
                ScrollView(.vertical) {
                    mapToolsPanel
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 302, maxHeight: .infinity, alignment: .topTrailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.vertical, 9)
                .accessibilityIdentifier("maps.settingsScroll")
                // Keep this heavyweight map settings panel stable while the GPS updates.
                // A transition here rebuilds all of its controls on slower iPhones.
            } else {
                Spacer(minLength: 0)
            }
            profileDock
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, max(geometry.safeAreaInsets.leading, safeArea.left) + 10)
        .padding(.trailing, max(geometry.safeAreaInsets.trailing, safeArea.right) + 10)
        .padding(.top, max(geometry.safeAreaInsets.top, safeArea.top) + 7)
        .padding(.bottom, max(geometry.safeAreaInsets.bottom, safeArea.bottom) + 7)
        .opacity(mapActionsVisible ? 1 : 0)
        .allowsHitTesting(mapActionsVisible)
        .accessibilityHidden(!mapActionsVisible)
        .animation(.easeOut(duration: 0.28), value: mapActionsVisible)
        // The draggable preview must not cover settings or intercept their taps.
        .zIndex(mapToolsExpanded ? 5 : 2)
    }

    private var activeProfile: WebMapProfile { session.profile(session.layout.phone) }
    private var activeAccent: Color { activeProfile.menuAccent }
    private var activeSurface: Color { activeProfile.menuSurface }

    private func profileAccent(_ profile: WebMapProfile) -> Color {
        profile.menuAccent
    }

    private func profileLabel(_ profile: WebMapProfile) -> String {
        switch profile {
        case .explorer: return "Rivadventure"
        case .wize: return "Rivroute"
        case .osmand: return "Rivmonde"
        }
    }

    private func profileSymbol(_ profile: WebMapProfile) -> String {
        switch profile {
        case .explorer: return "mountain.2.fill"
        case .wize: return "car.side.fill"
        case .osmand: return "map.fill"
        }
    }

    // The live map IS the home page. Only the iPhone overlays are restyled;
    // the actual MapKit/Wize/Osmond renderers still supply all map pixels.
    private func mapHeader(compact: Bool) -> some View {
        VStack(spacing: compact ? 4 : 9) {
            HStack(alignment: .center, spacing: 6) {
                Button {
                    revealMapActions()
                    sheet = .menu
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 24, weight: .bold))
                        .frame(width: 46, height: 46)
                        .background(activeSurface, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(activeSurface, lineWidth: 1.1))
                }
                .accessibilityLabel("Menu général")
                .accessibilityIdentifier("maps.menu")
                Spacer(minLength: 1)
                VStack(spacing: 0) {
                    Image("MountainGreenWhite")
                        .resizable()
                        .scaledToFit()
                        .frame(width: compact ? 25 : 37, height: compact ? 16 : 25)
                        .accessibilityHidden(true)
                    Text("Double Interface")
                        .font(.system(size: compact ? 16 : 19, weight: .heavy, design: .rounded))
                        .tracking(-0.55)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    HStack(spacing: 5) {
                        Capsule().fill(RivetCockpit.blue).frame(width: 18, height: 2)
                        Text("R I V E T")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .tracking(1)
                        Capsule().fill(RivetCockpit.orange).frame(width: 18, height: 2)
                    }
                }
                .shadow(color: .black.opacity(0.90), radius: 7, y: 2)
                .accessibilityElement(children: .combine)
                Spacer(minLength: 1)
                if controlsDismissMode == .permanent {
                    Button { hideMapActions() } label: {
                        Image(systemName: "eye.slash.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 40, height: 40)
                            .background(activeSurface, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .accessibilityLabel("Masquer le menu permanent")
                    .accessibilityIdentifier("maps.hidePermanentMenu")
                }
                if mapToolsExpanded {
                    mapToolsCloseButton
                } else if controlsDismissMode != .permanent {
                    Color.clear.frame(width: 40, height: 40)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: compact ? 46 : 65)

            HStack(spacing: 4) {
                ForEach(WebMapProfile.allCases) { profile in
                    let selected = activeProfile == profile
                    let accent = profileAccent(profile)
                    Button {
                        revealMapActions()
                        session.showOnPhone(profile)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: profileSymbol(profile))
                                .font(.system(size: 13, weight: .bold))
                            Text(profileLabel(profile))
                                .font(.system(size: 12, weight: .heavy, design: .rounded))
                                .lineLimit(1).minimumScaleFactor(0.70)
                        }
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .foregroundStyle(selected ? RivetCockpit.asphalt : accent)
                        .background(selected ? accent : profile.menuSecondary,
                            in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(selected ? accent : Color.clear, lineWidth: 1.35))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Afficher \(profileLabel(profile)) sur l’iPhone")
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                    .accessibilityIdentifier("maps.profile.\(profile.rawValue)")
                }
            }
            .padding(5)
            .background(activeSurface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18)
                .strokeBorder(activeSurface, lineWidth: 1))

            if nav.isFollowingGPX, let guidance = nav.gpxGuidance, activeProfile != .wize {
                HStack(spacing: 13) {
                    Image(systemName: guidance.offTrack ? "exclamationmark.triangle.fill" :
                          (guidance.nextManeuver?.systemImage ?? "point.topleft.down.to.point.bottomright.curvepath"))
                        .font(.system(size: 24, weight: .heavy))
                        .frame(width: 38)
                        .foregroundStyle(guidance.offTrack ? RivetCockpit.orange : profileAccent(activeProfile))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(guidance.offTrack ? "Hors de la trace · \(Int(guidance.offTrackMeters)) m" :
                             (guidance.nearFinish ? "Arrivée sur la trace" :
                              (guidance.nextManeuver?.instruction ?? "Suivre la trace GPX")))
                            .font(.system(size: 13, weight: .bold)).lineLimit(2)
                        Text(guidance.distanceToManeuverMeters.map {
                            String(format: "Virage dans %.0f m · %.1f km restants", $0, guidance.remainingMeters / 1000)
                        } ?? String(format: "%.1f km restants · sans réseau", guidance.remainingMeters / 1000))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.80))
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(activeSurface, in: RoundedRectangle(cornerRadius: 17))
                .overlay(RoundedRectangle(cornerRadius: 17)
                    .strokeBorder(activeSurface, lineWidth: 1))
                .accessibilityIdentifier("maps.offlineGPXGuidance")
            }

            if activeProfile == .wize && nav.isNavigating, let step = nav.currentStep {
                HStack(spacing: 12) {
                    Image(systemName: step.maneuverIconName)
                        .font(.system(size: 27, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 35)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(nav.distanceToNextStep < 1000
                             ? "\(Int(nav.distanceToNextStep)) m"
                             : String(format: "%.1f km", nav.distanceToNextStep / 1000))
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                        Text(step.instructions)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(2)
                    }
                    Spacer(minLength: 3)
                    Rectangle().fill(.white.opacity(0.28))
                        .frame(width: 1, height: 42)
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(String(format: "%.0f km", max(0, nav.distanceRemainingMeters) / 1000))
                        Text(String(format: "%.0f min", max(0, nav.timeRemainingSeconds) / 60))
                    }
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .foregroundStyle(.white)
                .background(activeSurface, in: RoundedRectangle(cornerRadius: 17))
                .overlay(RoundedRectangle(cornerRadius: 17)
                    .strokeBorder(activeSurface, lineWidth: 1.45))
                .accessibilityIdentifier("maps.wizeNavigationBanner")
            }
        }
        .buttonStyle(.plain)
    }

    private var navigationQuickActions: some View {
        VStack(spacing: 10) {
            Button {
                revealMapActions()
                nav.isAudioMuted.toggle()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: nav.isAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 21, weight: .bold))
                    Text(nav.isAudioMuted ? "Muet" : "Son")
                        .font(.system(size: 10, weight: .bold))
                }
                .frame(width: 61, height: 58)
                .background(activeSurface, in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15)
                    .strokeBorder(activeSurface, lineWidth: 1.8))
            }
            .accessibilityLabel(nav.isAudioMuted ? "Activer le guidage vocal" : "Couper le guidage vocal")
            .accessibilityIdentifier("maps.toggleGuidanceAudio")
            Button {
                revealMapActions()
                traceAccess.cancel()
                if nav.isNavigating { nav.stopNavigation() }
                if nav.isFollowingGPX { nav.stopFollowingGPX() }
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 20, weight: .heavy))
                    Text("Arrêter")
                        .font(.system(size: 10, weight: .bold))
                }
                .frame(width: 61, height: 58)
                .background(Color(hex: "461619").opacity(0.97), in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15)
                    .strokeBorder(RivetCockpit.red, lineWidth: 1.8))
                .shadow(color: RivetCockpit.red.opacity(0.30), radius: 6)
            }
            .accessibilityLabel("Arrêter le guidage actif")
            .accessibilityIdentifier("maps.stopGuidance")
        }
        .buttonStyle(.plain)
    }

    /// Same control in both the side rail and settings. Its symbol and tiny
    /// mode tag reflect the CURRENT camera mode, not the next tap's action.
    private func focusControl(compact: Bool) -> some View {
        let renderer = session.renderer(session.layout.phone)
        let _ = focusButtonRevision // Force a visual refresh after every tap.
        return Button {
            revealMapActions()
            cycleActiveMapFocus()
            if compact { expandTools() }
        } label: {
            VStack(spacing: 0) {
                Image(systemName: renderer.focusButtonSymbol)
                    .font(.system(size: compact ? 15 : 17, weight: .semibold))
                    .frame(height: compact ? 18 : 23)
                Text(renderer.focusButtonShortLabel)
                    .font(.system(size: compact ? 8 : 9, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(renderer.hasSelectedFocusMode ? activeAccent : RivetCockpit.paper)
            .frame(width: compact ? 35 : 43, height: compact ? 32 : 43)
            .background(compact ? activeProfile.menuSecondary : activeSurface,
                        in: RoundedRectangle(cornerRadius: compact ? 9 : 13))
            .overlay(RoundedRectangle(cornerRadius: compact ? 9 : 13)
                .strokeBorder(compact && renderer.hasSelectedFocusMode ? activeAccent : activeSurface, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mode actuel : \(renderer.focusButtonCurrentModeLabel). Prochain appui : \(renderer.nextFocusButtonLabel)")
    }

    private var focusTriangleButton: some View {
        focusControl(compact: false)
            .accessibilityIdentifier("maps.focusTriangle")
    }

    private func cycleActiveMapFocus() {
        session.renderer(session.layout.phone).cycleMapFocus()
        openLocationSettingsIfDenied()
    }

    private var quickMapRail: some View {
        VStack(spacing: 9) {
            focusTriangleButton
            railButton("plus.magnifyingglass", title: "Zoom avant") { session.renderer(session.layout.phone).zoomIn() }
            railButton("minus.magnifyingglass", title: "Zoom arrière") { session.renderer(session.layout.phone).zoomOut() }
            if activeProfile == .explorer {
                railButton("point.topleft.down.to.point.bottomright.curvepath", title: "Traces GPX") {
                    session.tracks.showRoute()
                }
            } else if activeProfile == .wize {
                railButton("magnifyingglass", title: "Rechercher une destination") { sheet = .destination }
            } else {
                railButton("square.3.layers.3d", title: "Carte et couches") { sheet = .osmandSettings }
            }
        }
    }

    private func railButton(_ icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button {
            revealMapActions()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 43, height: 43)
                .background(activeSurface, in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(activeSurface, lineWidth: 0.95))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var profileDock: some View {
        HStack(spacing: 2) {
            switch activeProfile {
            case .explorer:
                dockAction("Explorer", icon: "map", selected: true) {
                    wukulucInitialTab = .explore; wukulucInitialDetail = nil; showTrailWorkspace = true
                }
                dockAction("Enregistrer", icon: "record.circle", selected: recorder.state != .idle) {
                    wukulucInitialTab = .record; wukulucInitialDetail = nil; showTrailWorkspace = true
                }
                dockAction("Mes parcours", icon: "bookmark") {
                    wukulucInitialTab = .saved; wukulucInitialDetail = nil; showTrailWorkspace = true
                }
                dockAction("Partager", icon: "square.and.arrow.up") {
                    wukulucInitialTab = .saved; wukulucInitialDetail = library.selectedID; showTrailWorkspace = true
                }
                dockAction("Plus", icon: "slider.horizontal.3") { expandTools() }
                    .accessibilityIdentifier("maps.openSettings")
            case .wize:
                dockAction("Trajet", icon: "arrow.triangle.turn.up.right.diamond.fill", selected: true) { sheet = .destination }
                dockAction("Trafic", icon: "car.side.fill", selected: session.roads.isTrafficEnabled) {
                    session.roads.setTrafficEnabled(!session.roads.isTrafficEnabled)
                }
                dockAction("Signaler", icon: "exclamationmark.bubble.fill") { sheet = .wizeSignals }
                dockAction("Position", icon: "location.fill") { recenter() }
                dockAction("Plus", icon: "slider.horizontal.3") { expandTools() }
                    .accessibilityIdentifier("maps.openSettings")
            case .osmand:
                dockAction("Cartes", icon: "map.fill", selected: true) { sheet = .osmandSettings }
                dockAction("Traces", icon: "point.topleft.down.to.point.bottomright.curvepath") { sheet = .tracks }
                dockAction("Repères", icon: "mappin.and.ellipse", selected: session.osmand.isOsmandPOIEnabled) {
                    session.osmand.setOsmandPOIEnabled(!session.osmand.isOsmandPOIEnabled)
                }
                dockAction("Hors ligne", icon: "square.and.arrow.down") { sheet = .osmandSettings }
                dockAction("Outils", icon: "wrench.and.screwdriver.fill") { expandTools() }
                    .accessibilityIdentifier("maps.openSettings")
            }
        }
        .padding(.vertical, 7).padding(.horizontal, 4)
        .background(activeSurface, in: RoundedRectangle(cornerRadius: 21))
        .overlay(RoundedRectangle(cornerRadius: 21)
            .strokeBorder(activeSurface, lineWidth: 1))
        .shadow(color: .black.opacity(0.43), radius: 10, y: 3)
        .accessibilityIdentifier("maps.profileDock")
    }

    private func dockAction(_ title: String, icon: String, selected: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button {
            revealMapActions()
            action()
        } label: {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 17, weight: .semibold))
                Text(title).font(.system(size: 9, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.72)
            }
            .foregroundStyle(selected ? RivetCockpit.asphalt : RivetCockpit.paper)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(selected ? activeAccent : activeProfile.menuSecondary,
                        in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13)
                .strokeBorder(selected ? activeAccent : activeAccent.opacity(0.18), lineWidth: 1.2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    // MARK: - Map settings (independent of the TFT miniature)

    private var mapToolsCloseButton: some View {
        Button { collapseTools() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(activeSurface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(activeSurface, lineWidth: 1.1))
        }
        .accessibilityLabel("Fermer les réglages de carte")
        .accessibilityIdentifier("maps.mapTools")
    }

    // Lightweight settings view: avoid constructing the previous large, deeply
    // nested SwiftUI view hierarchy when the Outils button is pressed.
    private var mapToolsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "slider.horizontal.3")
                Text("OUTILS · CARTE iPHONE").font(.caption.bold())
                Spacer(minLength: 0)
                Button("Fermer") { collapseTools() }
                    .accessibilityIdentifier("maps.closeTools")
            }
            .foregroundStyle(activeAccent)

            menuDismissSettings

            HStack(spacing: 6) {
                toolChip("Plan", icon: "map") { chooseMapType(.standard) }
                toolChip("Mixte", icon: "square.3.layers.3d") { chooseMapType(.hybrid) }
                toolChip("Satellite", icon: "globe.europe.africa.fill") { chooseMapType(.satellite) }
            }
            HStack(spacing: 6) {
                toolChip("Recentrer", icon: "location.fill") { recenter() }
                toolChip("Traces GPX", icon: "point.topleft.down.to.point.bottomright.curvepath") {
                    sheet = .tracks
                }
            }
            Text("Les réglages avancés restent accessibles dans chaque carte.")
                .font(.system(size: 10))
                .foregroundStyle(RivetCockpit.paper.opacity(0.75))
        }
        .padding(12)
        .frame(maxWidth: 302)
        .background(activeSurface, in: RoundedRectangle(cornerRadius: 17))
        .accessibilityIdentifier("maps.optionsPanel")
    }

    private var menuDismissSettings: some View {
            VStack(alignment: .leading, spacing: 5) {
                Text("FERMETURE DU MENU")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(activeAccent)
                HStack(spacing: 5) {
                    toolChip("4 sec", icon: "timer", selected: controlsDismissMode == .fourSeconds) {
                        setControlsDismissMode(.fourSeconds)
                    }
                    toolChip("Permanent", icon: "pin.fill", selected: controlsDismissMode == .permanent) {
                        setControlsDismissMode(.permanent)
                    }
                    toolChip("En roulant", icon: "speedometer", selected: controlsDismissMode == .whenMoving) {
                        setControlsDismissMode(.whenMoving)
                    }
                }
                if controlsDismissMode == .permanent {
                    Text("Le bouton œil masque le menu. Le bouton Afficher le menu le rétablit.")
                        .font(.system(size: 10))
                        .foregroundStyle(RivetCockpit.paper.opacity(0.75))
                } else if controlsDismissMode == .whenMoving {
                    Text("Le menu se cache à partir de 5 km/h et reste accessible à l’arrêt.")
                        .font(.system(size: 10))
                        .foregroundStyle(RivetCockpit.paper.opacity(0.75))
                }
            }
    }

    private func toolChip(_ name: String, icon: String, selected: Bool = false,
                          action: @escaping () -> Void) -> some View {
        Button(action: { revealMapActions(); action() }) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(name).lineLimit(1).minimumScaleFactor(0.82)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(selected ? RivetCockpit.asphalt : RivetCockpit.paper)
            .frame(maxWidth: .infinity, minHeight: 33)
            .padding(.horizontal, 5)
            .background(selected ? activeAccent : activeProfile.menuSecondary,
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? activeAccent : activeAccent.opacity(0.28), lineWidth: 1))
        }
        .accessibilityLabel(name)
    }

    private var recordingLabel: String {
        switch recorder.state {
        case .idle: return "Enregistrer"
        case .recording: return "Pause"
        case .paused: return "Reprendre"
        }
    }
    private var recordingIcon: String {
        switch recorder.state {
        case .idle: return "record.circle"
        case .recording: return "pause.fill"
        case .paused: return "play.fill"
        }
    }
    private func recordingAction() {
        switch recorder.state {
        case .idle: recorder.start(activity: .trailMotorcycle)
        case .recording: recorder.pause()
        case .paused: recorder.resume()
        }
    }

    private func chooseMapType(_ type: MKMapType) {
        session.renderer(session.layout.phone).setMapType(type)
        expandTools()
    }

    private func expandTools() {
        // Open without animating a large ScrollView over a live MapKit render.
        mapToolsExpanded = true
        revealMapActions()
    }
    private func collapseTools() {
        mapToolsExpanded = false
        revealMapActions()
    }

    private func setControlsDismissMode(_ mode: MapControlsDismissMode) {
        controlsDismissModeRaw = mode.rawValue
        if mode == .whenMoving && nav.currentSpeedKmH >= movingThresholdKmH {
            hideMapActions()
        } else {
            revealMapActions()
        }
    }

    private func hideMapActions() {
        mapActionsToken = UUID() // Invalidate any pending 4-second callback.
        withAnimation(.easeOut(duration: 0.25)) {
            mapToolsExpanded = false
            mapActionsVisible = false
        }
    }

    /// Three user-selected behaviours: four seconds, permanent toggle or hide
    /// after a reliable moving-speed fix. These are phone-only controls.
    private func revealMapActions() {
        mapActionsVisible = true
        let token = UUID()
        mapActionsToken = token
        switch controlsDismissMode {
        case .permanent:
            return
        case .whenMoving:
            if nav.currentSpeedKmH >= movingThresholdKmH {
                hideMapActions()
            }
            return
        case .fourSeconds:
            DispatchQueue.main.asyncAfter(deadline: .now() + controlsIdleTimeout) {
                guard mapActionsToken == token,
                      controlsDismissMode == .fourSeconds,
                      !mapToolsExpanded else { return }
                hideMapActions()
            }
        }
    }

    private var menu: some View {
        RideSheet("Double Interface") {
            HStack(spacing: 10) {
                Image("MountainGreenWhite").resizable().scaledToFit().frame(width: 58, height: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Double Interface").font(.title3.bold())
                    Text("TABLEAU DE BORD").font(.caption2.weight(.semibold)).tracking(2)
                        .foregroundStyle(RideTheme.muted)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                menuTile("Mon garage", subtitle: "Motos · Entretien · Factures", icon: "motorcycle", tint: WebMapProfile.explorer.menuAccent) {
                    present(.maintenance)
                }.accessibilityIdentifier("menu.maintenance")
                menuTile("Connexions", subtitle: "Wi-Fi · Bluetooth · TFT", icon: "wifi", tint: WebMapProfile.wize.menuAccent) {
                    present(.connection)
                }.accessibilityIdentifier("menu.connection")
            }
            VStack(alignment: .leading, spacing: 14) {
                Label("Cartes & écrans", systemImage: "square.stack.3d.up.fill")
                    .font(.headline).foregroundStyle(.white)
                Divider()
                mapPicker(for: session.layout.phone, screenName: "Grand écran · iPhone")
                mapPicker(for: session.layout.tft, screenName: "Petit écran · TFT")
                Button {
                    session.exchange(); sheet = nil
                } label: {
                    Label("Échanger les deux cartes", systemImage: "arrow.left.arrow.right")
                        .font(.subheadline.bold()).frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).accessibilityIdentifier("menu.exchange")
            }
            .padding(14)
            .background(RivetCockpit.panel, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(RideTheme.line))
        }
    }

    private func menuTile(_ title: String, subtitle: String, icon: String, tint: Color,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon).font(.title2.bold()).foregroundStyle(tint)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(tint)
                }
                Text(title).font(.headline).foregroundStyle(.white)
                Text(subtitle).font(.caption2).foregroundStyle(RideTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12).frame(maxWidth: .infinity, minHeight: 105, alignment: .leading)
            .background(LinearGradient(colors: [tint.opacity(0.13), RivetCockpit.panel], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(tint.opacity(0.55)))
        }.buttonStyle(.plain)
    }

    private func mapPicker(for position: WebPanelID, screenName: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(screenName).font(.subheadline.bold())
            HStack(spacing: 8) {
                ForEach(WebMapProfile.allCases) { profile in
                    Button {
                        session.assign(profile, to: position)
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: profile == .explorer ? "mountain.2.fill" : (profile == .wize ? "car.side.fill" : "map.fill"))
                            Text(profileLabel(profile)).font(.caption2.bold())
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(profile.menuAccent)
                        .background(session.profile(position) == profile ? profile.menuAccent.opacity(0.24) : Color.white.opacity(0.035),
                                    in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(
                            profile.menuAccent.opacity(session.profile(position) == profile ? 1 : 0.35), lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("menu.map.\(position.rawValue).\(profile.rawValue)")
                }
            }
        }
    }

    /// Native map selection plus real offline MBTiles raster (user-imported).
    /// OsmAnd's own .obf engine is not embedded.
    private var osmandSettings: some View {
        RideSheet("Configurer la carte · Rivmonde") {
            RideCard {
                Label("Cartes hors ligne · MBTiles", systemImage: "square.and.arrow.down.fill")
                    .font(.headline)
                Text("Importe une carte MBTiles raster depuis Fichiers. Elle reste sur ton iPhone et s’affiche sans réseau sur l’iPhone comme sur le TFT.")
                    .font(.footnote).foregroundStyle(RideTheme.muted)
                Button("Importer une carte .mbtiles", systemImage: "square.and.arrow.down") {
                    pendingRasterImport = nil
                    importAfterDismiss = false
                    sheet = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { importingOfflineMap = true }
                }.buttonStyle(RideButtonStyle())
                if offlineLibrary.packages.isEmpty {
                    Text("Aucune carte installée. Import obligatoire avant l’utilisation hors ligne.")
                        .font(.footnote).foregroundStyle(RideTheme.muted)
                }
                ForEach(offlineLibrary.packages) { package in
                    if package.id == OfflineMapLibrary.bundledOverviewFilename {
                        Text("Relief mondial fourni avec l’application. Vue générale zoom 0–5 : pas de routes, sentiers ou courbes de niveau. Ne pas utiliser pour naviguer sur les pistes.")
                            .font(.caption).foregroundStyle(RideTheme.muted)
                    }
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(package.title).font(.subheadline.bold()).lineLimit(1)
                            Text("Zoom \(package.minZoom)–\(package.maxZoom) · \(ByteCountFormatter.string(fromByteCount: package.bytes, countStyle: .file))")
                                .font(.caption2).foregroundStyle(RideTheme.muted)
                        }
                        Spacer(minLength: 0)
                        if offlineLibrary.selectedID == package.id && session.osmand.isOfflineEnabled {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(activeAccent)
                        }
                        Button("Utiliser") {
                            offlineLibrary.select(package)
                            session.osmand.setOfflineMap(package)
                        }.buttonStyle(.bordered)
                        Button(role: .destructive) {
                            do {
                                if offlineLibrary.selectedID == package.id { session.osmand.disableOffline() }
                                try offlineLibrary.remove(package)
                            } catch { self.error = error.localizedDescription }
                        } label: { Image(systemName: "trash") }
                            .accessibilityLabel("Supprimer \(package.title)")
                    }
                }
                if session.osmand.isOfflineEnabled {
                    Button("Revenir aux cartes en ligne", systemImage: "network") {
                        session.osmand.disableOffline()
                    }.buttonStyle(RideButtonStyle(primary: false))
                }
            }
            RideCard {
                Label("Style de carte en ligne", systemImage: "map.fill").font(.headline)
                ScrollView(.horizontal, showsIndicators: false) {
                  HStack(spacing: 8) {
                    toolChip("Topo", icon: "mountain.2", selected: session.osmand.isOsmandTopoEnabled) {
                        session.osmand.setOsmondTopoEnabled(true)
                        mapStyleRevision = UUID()
                    }
                    toolChip("Plan", icon: "map", selected: !session.osmand.isOsmandTopoEnabled && session.osmand.currentMapType == .standard) {
                        session.osmand.setMapType(.standard)
                    }
                    toolChip("Mixte", icon: "square.3.layers.3d", selected: !session.osmand.isOsmandTopoEnabled && session.osmand.currentMapType == .hybrid) {
                        session.osmand.setMapType(.hybrid)
                    }
                    toolChip("Satellite", icon: "globe.europe.africa", selected: !session.osmand.isOsmandTopoEnabled && session.osmand.currentMapType == .satellite) {
                        session.osmand.setMapType(.satellite)
                    }
                  }
                }
            }
            RideCard {
                Label("Apparence de Rivmonde", systemImage: "sun.max.fill").font(.headline)
                HStack(spacing: 8) {
                    ForEach(OsmondMapTheme.allCases) { theme in
                        toolChip(theme.title, icon: theme == .day ? "sun.max.fill" :
                                 (theme == .night ? "moon.fill" : "circle.lefthalf.filled"),
                                 selected: session.osmand.osmondMapTheme == theme) {
                            session.osmand.setOsmandMapTheme(theme)
                            mapStyleRevision = UUID()
                        }
                    }
                }
                Text("Jour / nuit s'applique au fond MapKit. Une carte MBTiles hors ligne conserve ses couleurs d'origine.")
                    .font(.caption).foregroundStyle(RideTheme.muted)
            }
            RideCard {
                Label("Relief automatique", systemImage: "mountain.2.fill").font(.headline)
                Text("Sur le fond Topo, les courbes de niveau et l’ombrage sont déjà intégrés : aucun bouton Relief ni import nécessaire. Connexion Internet requise pour les tuiles non chargées. Les cartes MBTiles hors ligne restent disponibles.")
                    .font(.caption).foregroundStyle(RideTheme.muted)
                osmandOption("Points d’intérêt", icon: "mappin.and.ellipse", enabled: session.osmand.isOsmandPOIEnabled) {
                    session.osmand.setOsmandPOIEnabled(!session.osmand.isOsmandPOIEnabled)
                }
                osmandOption("Perspective 3D", icon: "cube.transparent", enabled: session.osmand.isOsmand3DEnabled) {
                    session.osmand.setOsmand3DEnabled(!session.osmand.isOsmand3DEnabled)
                }
                osmandOption("Afficher les traces GPX", icon: "point.topleft.down.to.point.bottomright.curvepath", enabled: session.osmand.isOsmandGPXEnabled) {
                    session.osmand.setOsmandGPXEnabled(!session.osmand.isOsmandGPXEnabled)
                }
            }
            Button("Importer ou choisir une trace GPX", systemImage: "square.and.arrow.down") {
                present(.tracks)
            }.buttonStyle(RideButtonStyle())
            if nav.importedTrack != nil {
                Button(nav.gpxReversed ? "Sens du GPX : retour" : "Sens du GPX : aller",
                       systemImage: "arrow.left.arrow.right") {
                    nav.toggleGPXDirection()
                }.buttonStyle(RideButtonStyle(primary: false))
            }
            Button("Afficher la trace entière", systemImage: "arrow.up.left.and.arrow.down.right") {
                session.osmand.showRoute(); sheet = nil
            }.buttonStyle(RideButtonStyle(primary: false))
            Text("Rivmonde affiche le relief et les courbes de niveau avec OpenTopoMap. Une connexion Internet est nécessaire pour charger de nouvelles zones. Pour rouler hors ligne, sélectionne une carte raster MBTiles. Le suivi GPX fonctionne sans recalcul d’itinéraire.")
                .font(.footnote).foregroundStyle(RideTheme.muted)
        }
    }

    private func osmandOption(_ name: String, icon: String, enabled: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 24)
                Text(name).font(.subheadline)
                Spacer()
                Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(enabled ? activeAccent : RideTheme.muted)
            }
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
    }

    private var tracks: some View {
        RideSheet("Mes traces GPX") {
            Button("Importer un fichier GPX", systemImage: "square.and.arrow.down") { importAfterDismiss = true; sheet = nil }
                .buttonStyle(RideButtonStyle()).accessibilityIdentifier("tracks.import")
            Button("Coller le contenu d’un GPX", systemImage: "doc.on.clipboard") { present(.paste) }
                .buttonStyle(RideButtonStyle(primary: false)).accessibilityIdentifier("tracks.paste")
            if nav.importedTrack != nil {
                Button(nav.gpxReversed ? "Suivi GPX : sens retour" : "Suivi GPX : sens aller",
                       systemImage: "arrow.left.arrow.right") { nav.toggleGPXDirection() }
                    .buttonStyle(RideButtonStyle(primary: false))
            }
            if let message = library.error { Text(message).foregroundStyle(RideTheme.orange) }
            if let error { Text(error).foregroundStyle(RideTheme.orange) }
            if library.tracks.isEmpty {
                RideCard {
                    Label("Tes traces, au même endroit", systemImage: "map").font(.headline)
                    Text("Importe un fichier .gpx depuis Fichiers ou partage-le vers Double Interface. Tes fichiers restent enregistrés sur l’iPhone.")
                        .foregroundStyle(RideTheme.muted)
                }
            }
            ForEach(library.tracks) { entry in
                RideCard {
                    HStack {
                        Text(entry.name).font(.headline)
                        Spacer()
                        if library.selectedID == entry.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(activeAccent) }
                    }
                    Text(String(format: "%.1f km · %d points", entry.distanceKilometers, entry.pointCount))
                        .font(.subheadline).foregroundStyle(RideTheme.muted)
                    if library.selectedID == entry.id {
                        Button("Retirer de la carte", systemImage: "eye.slash") {
                            do { try library.removeFromMap(entry) }
                            catch { self.error = error.localizedDescription }
                        }.buttonStyle(RideButtonStyle(primary: false))
                            .accessibilityHint("Le parcours reste enregistré sur cet appareil.")
                            .accessibilityIdentifier("tracks.removeFromMap.\(entry.id)")
                    }
                    Button("Suivre cette trace", systemImage: "location.fill") {
                        do {
                            traceAccess.cancel()
                            try library.select(entry); nav.startFollowingGPX()
                            let profile: WebMapProfile = activeProfile == .osmand ? .osmand : .explorer
                            if profile == .osmand { session.osmand.setOsmandGPXEnabled(true) }
                            let renderer = profile == .osmand ? session.osmand : session.tracks
                            renderer.refresh(); renderer.showRoute()
                            session.showOnPhone(profile)
                            sheet = nil
                        } catch { self.error = error.localizedDescription }
                    }.buttonStyle(RideButtonStyle(primary: false))
                    ForEach(GPXAccessMode.allCases) { mode in
                        Button(mode.title, systemImage: mode == .start ? "flag.fill" : "arrow.triangle.merge") {
                            do { try library.select(entry); startTraceAccess(mode); sheet = nil }
                            catch { self.error = error.localizedDescription }
                        }.buttonStyle(RideButtonStyle(primary: false))
                    }
                    HStack {
                        ShareLink(item: library.originalURL(entry)) { Label("Partager", systemImage: "square.and.arrow.up") }
                        Spacer()
                        Button("Supprimer", role: .destructive) {
                            do { try library.remove(entry) } catch { self.error = error.localizedDescription }
                        }
                    }.font(.subheadline)
                }
            }
        }
    }

    private func present(_ page: MapSheet) { nextSheet = page; sheet = nil }

    private var traceAccessActions: some View {
        HStack(spacing: 8) {
            toolChip("Rejoindre", icon: "arrow.triangle.merge", selected: traceAccess.isActive && traceAccess.mode == .nearest) {
                startTraceAccess(.nearest)
            }
            toolChip("Au départ", icon: "flag.fill", selected: traceAccess.isActive && traceAccess.mode == .start) {
                startTraceAccess(.start)
            }
            if traceAccess.isActive {
                toolChip("Recalculer", icon: "arrow.clockwise") { startTraceAccess(traceAccess.mode) }
            }
        }
    }

    private func startTraceAccess(_ mode: GPXAccessMode) {
        guard nav.importedTrack != nil else { sheet = .tracks; return }
        let profile: WebMapProfile = activeProfile == .osmand ? .osmand : .explorer
        if profile == .osmand { session.osmand.setOsmandGPXEnabled(true) }
        session.showOnPhone(profile)
        traceAccess.start(mode, profile: profile)
        session.renderer(session.layout.phone).recenter()
    }
    private func recenter() {
        session.renderer(session.layout.phone).recenter()
        openLocationSettingsIfDenied()
    }

    private func openLocationSettingsIfDenied() {
        guard nav.mapLocationDenied else { return }
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
    private func importTrack(_ data: Data, name: String) throws {
        let entry = try library.add(data: data, fallbackName: name)
        try library.select(entry); session.tracks.refresh(); session.tracks.showRoute()
    }
    private func calculate(to destination: MKMapItem) {
        calculating = true
        nav.calculateRoute(to: destination) { result in
            calculating = false
            switch result {
            case .success(let route):
                nav.startNavigation(route: route, destination: destination)
                session.roads.refresh(); session.roads.showRoute()
                session.showOnPhone(.wize)
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
}

// The pan gesture updates only the miniature position, without re-rendering
// the full-screen map. The normalized position is saved once, on finger-up.
private struct DraggableTFTMiniature: View {
    @GestureState private var translation = CGSize.zero
    let accent: Color
    let metrics: MapPanelMetrics
    let normalizedX: Double
    let normalizedY: Double
    let onExchange: () -> Void
    let onMove: (Double, Double) -> Void
    let onInteraction: () -> Void

    private var positionX: CGFloat {
        let proposed = metrics.left + (metrics.right - metrics.left) * CGFloat(normalizedX) + translation.width
        return min(metrics.right, max(metrics.left, proposed))
    }

    private var positionY: CGFloat {
        let proposed = metrics.top + (metrics.bottom - metrics.top) * CGFloat(normalizedY) + translation.height
        return min(metrics.bottom, max(metrics.top, proposed))
    }

    var body: some View {
        // The map pixels below are drawn by DualMapRendererHost. Keep this
        // foreground layer gesture-only: no second UIKit renderer owner.
        Color.clear
            .frame(width: metrics.mini.width, height: metrics.mini.height)
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(accent, lineWidth: 2.5)
                    .shadow(color: accent.opacity(0.34), radius: 6)
                    .allowsHitTesting(false)
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .updating($translation) { value, state, transaction in
                        transaction.disablesAnimations = true
                        state = value.translation
                    }
                    .onEnded { value in
                        onInteraction()
                        let delta = value.translation
                        if abs(delta.width) < 7 && abs(delta.height) < 7 {
                            onExchange()
                        } else {
                            let rangeX = max(1, metrics.right - metrics.left)
                            let rangeY = max(1, metrics.bottom - metrics.top)
                            onMove(normalizedX + Double(delta.width / rangeX),
                                   normalizedY + Double(delta.height / rangeY))
                        }
                    }
            )
            .accessibilityLabel("Petite fenêtre TFT. Toucher pour échanger les cartes.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onInteraction(); onExchange() }
            .accessibilityIdentifier("maps.miniature")
            .position(x: positionX, y: positionY)
    }
}

// Calculs de dimensions isoles hors de la hierarchie SwiftUI.
private struct MapPanelMetrics {
    let area: CGSize
    let insets: EdgeInsets
    let source: CGSize
    let scale: CGFloat
    let mini: CGSize
    let left: CGFloat
    let right: CGFloat
    let top: CGFloat
    let bottom: CGFloat

    init(area: CGSize, insets: EdgeInsets, source: CGSize) {
        self.area = area
        self.insets = insets
        self.source = source
        let width = min(104, max(76, area.width * 0.24))
        let scale = min(
            width / max(1, source.width),
            max(1, area.height * 0.38) / max(1, source.height)
        )
        self.scale = scale
        let mini = CGSize(width: source.width * scale, height: source.height * scale)
        self.mini = mini
        // A 2 pt guard is enough to keep the preview visible and graspable.
        // No reservation for top menus, home indicator, or the old 110 pt
        // bottom dead zone: the user can drag into every corner.
        let bounds = MiniatureBounds(containerWidth: Double(area.width),
                                     containerHeight: Double(area.height),
                                     miniatureWidth: Double(mini.width),
                                     miniatureHeight: Double(mini.height))
        self.left = CGFloat(bounds.left)
        self.right = CGFloat(bounds.right)
        self.top = CGFloat(bounds.top)
        self.bottom = CGFloat(bounds.bottom)
    }
}

/// One UIKit host owns the two visible renderers throughout every exchange.
/// Avoid two independent UIViewRepresentable updates racing to remove a map.
private struct DualMapRendererHost: UIViewRepresentable {
    let phoneRenderer: IntegratedNavigationPanel
    let tftRenderer: IntegratedNavigationPanel
    let metrics: MapPanelMetrics
    let normalizedX: Double
    let normalizedY: Double
    let topInset: CGFloat
    var onUserTap: (() -> Void)?

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onUserTap: (() -> Void)?
        @objc func tapped(_ sender: UITapGestureRecognizer) {
            if sender.state == .ended { onUserTap?() }
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }

    final class Surface: UIView {
        let phoneHolder = UIView()
        let miniHolder = UIView()
        let miniContent = UIView()
        private var phone: IntegratedNavigationPanel?
        private var tft: IntegratedNavigationPanel?
        private var screenSize: CGSize = .zero
        private var sourceSize: CGSize = .zero
        private var miniSize: CGSize = .zero
        private var miniCenter: CGPoint = .zero
        private var miniScale: CGFloat = 1

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            phoneHolder.backgroundColor = .black
            miniHolder.backgroundColor = .black
            miniHolder.layer.cornerRadius = 16
            miniHolder.clipsToBounds = true
            miniContent.backgroundColor = .black
            addSubview(phoneHolder)
            addSubview(miniHolder)
            miniHolder.addSubview(miniContent)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

        func configure(phone incomingPhone: IntegratedNavigationPanel,
                       tft incomingTFT: IntegratedNavigationPanel,
                       metrics: MapPanelMetrics,
                       normalizedX: Double, normalizedY: Double,
                       topInset: CGFloat) {
            assert(incomingPhone !== incomingTFT, "The phone and TFT cannot share one renderer")
            // Always take both renderers out first, then reparent. This is
            // atomic for UIKit in one main-thread layout pass.
            if phone !== incomingPhone || tft !== incomingTFT {
                phone?.view.removeFromSuperview()
                tft?.view.removeFromSuperview()
                incomingPhone.view.removeFromSuperview()
                incomingTFT.view.removeFromSuperview()
                phone = incomingPhone
                tft = incomingTFT
                incomingPhone.view.frame = phoneHolder.bounds
                incomingPhone.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                phoneHolder.addSubview(incomingPhone.view)
                incomingTFT.view.frame = miniContent.bounds
                incomingTFT.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                miniContent.addSubview(incomingTFT.view)
            }
            incomingPhone.setHUDTopInset(topInset)
            incomingTFT.setHUDTopInset(0)
            screenSize = metrics.area
            sourceSize = metrics.source
            miniSize = metrics.mini
            miniScale = metrics.scale
            let bounds = MiniatureBounds(containerWidth: Double(metrics.area.width),
                                         containerHeight: Double(metrics.area.height),
                                         miniatureWidth: Double(metrics.mini.width),
                                         miniatureHeight: Double(metrics.mini.height))
            let pos = bounds.center(normalizedX: normalizedX, normalizedY: normalizedY)
            miniCenter = CGPoint(x: pos.x, y: pos.y)
            setNeedsLayout()
            layoutIfNeeded()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let orientation = window?.windowScene?.effectiveGeometry.interfaceOrientation {
                LocationAndNavigationManager.shared.alignCompassWithPhoneInterface(orientation)
            }
            phoneHolder.frame = CGRect(origin: .zero, size: screenSize)
            phone?.view.frame = phoneHolder.bounds
            miniHolder.frame = CGRect(x: miniCenter.x - miniSize.width / 2,
                                      y: miniCenter.y - miniSize.height / 2,
                                      width: miniSize.width, height: miniSize.height)
            // The TFT renderer keeps its native 600x1024 coordinate space
            // regardless of the zoom/position of its on-phone preview.
            miniContent.transform = .identity
            miniContent.bounds = CGRect(origin: .zero, size: sourceSize)
            tft?.view.frame = miniContent.bounds
            miniContent.transform = CGAffineTransform(scaleX: miniScale, y: miniScale)
            miniContent.center = CGPoint(x: miniHolder.bounds.midX, y: miniHolder.bounds.midY)
            bringSubviewToFront(miniHolder)
            phone?.refreshPositionMarkerLayout()
            tft?.refreshPositionMarkerLayout()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> Surface {
        let surface = Surface(frame: .zero)
        let recognizer = UITapGestureRecognizer(target: context.coordinator,
                                                action: #selector(Coordinator.tapped(_:)))
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = context.coordinator
        surface.phoneHolder.addGestureRecognizer(recognizer)
        updateUIView(surface, context: context)
        return surface
    }

    func updateUIView(_ surface: Surface, context: Context) {
        context.coordinator.onUserTap = onUserTap
        surface.configure(phone: phoneRenderer, tft: tftRenderer,
                          metrics: metrics, normalizedX: normalizedX,
                          normalizedY: normalizedY, topInset: topInset)
    }

    static func dismantleUIView(_ surface: Surface, coordinator: Coordinator) {
        surface.phoneHolder.subviews.forEach { $0.removeFromSuperview() }
        surface.miniContent.subviews.forEach { $0.removeFromSuperview() }
    }
}

struct PasteGPXSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    let onImport: (Data) throws -> Void
    var body: some View {
        RideSheet("Coller un GPX") {
            Text("Colle le texte XML du fichier GPX, puis touche Importer. Un lien vers un site n’est pas un fichier GPX.")
                .font(.subheadline).foregroundStyle(RideTheme.muted)
            TextEditor(text: $text).font(.system(.footnote, design: .monospaced))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .frame(minHeight: 280).padding(10).background(RivetCockpit.panel, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityIdentifier("paste.editor")
            PasteButton(payloadType: String.self) { strings in if let value = strings.first { text = value } }
            Button("Importer la trace", systemImage: "square.and.arrow.down") {
                do { try onImport(Data(text.utf8)); dismiss() } catch { self.error = error.localizedDescription }
            }.buttonStyle(RideButtonStyle()).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let error { Text(error).font(.subheadline).foregroundStyle(RideTheme.orange) }
        }
    }
}
