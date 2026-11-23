import SwiftUI
import MapKit
import UniformTypeIdentifiers

enum WukulucTab: String, CaseIterable, Identifiable {
    case explore = "Explorer", record = "Enregistrer", saved = "Mes parcours"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .explore: return "map"
        case .record: return "record.circle"
        case .saved: return "bookmark"
        }
    }
}

struct WukulucWorkspaceView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var library = TrackLibrary.shared
    @ObservedObject private var nav = LocationAndNavigationManager.shared
    @ObservedObject private var recorder = TrailRecorder.shared
    @ObservedObject private var sharing = WukulucSharingService.shared
    @State private var tab: WukulucTab
    @State private var community = true
    @State private var showMap = false
    @State private var query = ""
    @State private var activity: TrailActivity?
    @State private var recordingActivity = TrailActivity.trailMotorcycle
    @State private var mapType: MKMapType = .standard
    @State private var places: [MKMapItem] = []
    @State private var cameraRequest = TrailCameraRequest(target: .route)
    @State private var searchTask: MKLocalSearch?
    @State private var searchID = UUID()
    @State private var searching = false
    @State private var importing = false
    @State private var filters = false
    @State private var favoritesOnly = false
    @State private var maximumDistance = 0.0
    @State private var maximumAscent = 0.0
    @State private var sort = "Récents"
    @State private var detail: SavedTrack?
    @State private var returnToCockpit = false
    @State private var busyRoute: UUID?
    @State private var recordingName = ""
    @State private var saveRecording = false
    @State private var discardRecording = false
    @State private var error: String?

    init(initialTab: WukulucTab = .explore, initialDetailID: UUID? = nil) {
        _tab = State(initialValue: initialTab)
        _detail = State(initialValue: TrackLibrary.shared.tracks.first { $0.id == initialDetailID })
    }

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            VStack(spacing: 0) {
                header
                if tab != .record { searchBar; filterBar }
                if tab == .explore && !showMap { sourcePicker }
                ZStack(alignment: landscape ? .trailing : .bottom) {
                    if tab == .record || (tab == .explore && showMap) {
                        map
                        if tab == .record {
                            recordingPanel.frame(maxWidth: landscape ? 340 : .infinity)
                                .padding(landscape ? 10 : 14)
                        } else if let selected = library.tracks.first(where: { $0.id == library.selectedID }) {
                            mapSummary(selected).frame(maxWidth: landscape ? 320 : .infinity).padding(12)
                        }
                    } else { routeList }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                dock
            }
            .background(WukulucStyle.background)
        }
        .foregroundStyle(WukulucStyle.ink)
        .tint(WukulucStyle.green)
        .preferredColorScheme(.light)
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "gpx") ?? .xml, .xml]) { result in
            switch result {
            case .success(let url):
                library.importFile(url) { failure in
                    if let failure { error = failure.localizedDescription }
                    else { tab = .saved }
                }
            case .failure(let failure):
                if (failure as NSError).code != NSUserCancelledError { error = failure.localizedDescription }
            }
        }
        .sheet(item: $detail, onDismiss: {
            if returnToCockpit { returnToCockpit = false; dismiss() }
        }) { entry in
            WukulucRouteDetail(entry: entry, onShow: { show(entry, follow: false) },
                onHide: { hide(entry) },
                onFollow: { show(entry, follow: true) }, onAccess: { access(entry, mode: $0) }, onTFT: { sendToTFT(entry) },
                onDelete: { remove(entry) })
        }
        .sheet(isPresented: $filters) { filterSheet }
        .alert("Enregistrer le parcours", isPresented: $saveRecording) {
            TextField("Nom du parcours", text: $recordingName)
            Button("Enregistrer") { finishRecording() }
            Button("Annuler", role: .cancel) { }
        } message: { Text("Le GPX sera conservé sur cet appareil. Tu pourras ensuite le partager.") }
        .confirmationDialog("Abandonner cet enregistrement ?", isPresented: $discardRecording, titleVisibility: .visible) {
            Button("Abandonner", role: .destructive) { recorder.discard() }
        }
        .alert("Rivadventure", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .task(id: activity?.rawValue ?? "all") {
            await sharing.refresh(activity: activity, query: query)
        }
        .onReceive(NotificationCenter.default.publisher(for: .wukulucRouteReceived)) { message in
            guard let id = message.userInfo?["id"] as? UUID else { return }
            detail = library.tracks.first { $0.id == id }
            tab = .saved
        }
        .onDisappear { searchTask?.cancel() }
        .environment(\.rideMapProfile, WebMapProfile.explorer)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 36, height: 42) }
                .accessibilityLabel("Revenir aux cartes et au TFT")
            Text("Rivadventure").font(.system(.title2, design: .rounded).bold()).foregroundStyle(Color.white)
            Spacer()
            if tab == .explore {
                Button { showMap.toggle() } label: {
                    Label(showMap ? "Liste" : "Carte", systemImage: showMap ? "list.bullet" : "map")
                        .font(.subheadline.bold()).padding(.horizontal, 12).frame(height: 38)
                        .background(Color.white.opacity(0.12), in: Capsule())
                }
            }
            Button { importing = true } label: { Image(systemName: "square.and.arrow.down").frame(width: 40, height: 42) }
                .accessibilityLabel("Importer un fichier GPX")
        }
        .padding(.horizontal, 12)
        .foregroundStyle(Color.white)
        .tint(.white)
        .background(WebMapProfile.explorer.menuSurface)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(WukulucStyle.muted)
            TextField("Lieu ou nom du parcours", text: $query)
                .submitLabel(.search).onSubmit { search() }
            if searching { ProgressView() }
            if !query.isEmpty {
                Button {
                    query = ""; places = []; searchTask?.cancel(); searchID = UUID(); searching = false
                    Task { await sharing.refresh(activity: activity) }
                } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(WukulucStyle.muted) }
                    .accessibilityLabel("Effacer la recherche")
            }
        }.padding(.horizontal, 14).frame(height: 46)
            .background(WukulucStyle.background, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 14).padding(.vertical, 8).background(Color.white)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                Menu {
                    Button("Toutes les activités") { activity = nil }
                    ForEach(TrailActivity.allCases) { value in
                        Button(value.rawValue, systemImage: value.symbol) { activity = value }
                    }
                } label: { Label(activity?.rawValue ?? "Activités", systemImage: activity?.symbol ?? "figure.hiking") }
                Button { filters = true } label: {
                    Label(maximumDistance > 0 || maximumAscent > 0 ? "Filtres actifs" : "Filtres", systemImage: "slider.horizontal.3")
                }
                Menu {
                    ForEach(["Récents", "Distance", "Dénivelé", "Nom"], id: \.self) { value in
                        Button(value) { sort = value }
                    }
                } label: { Label(sort, systemImage: "arrow.up.arrow.down") }
                if tab == .saved || !community {
                    Button { favoritesOnly.toggle() } label: {
                        Label("Favoris", systemImage: favoritesOnly ? "heart.fill" : "heart")
                    }.foregroundStyle(favoritesOnly ? WukulucStyle.green : WukulucStyle.ink)
                }
            }.font(.caption.bold()).padding(.horizontal, 14).padding(.vertical, 10)
                .buttonStyle(.bordered)
        }.background(Color.white)
    }

    private var sourcePicker: some View {
        Picker("Origine des parcours", selection: $community) {
            Text("Communauté Rivadventure").tag(true)
            Text("Sur cet appareil").tag(false)
        }.pickerStyle(.segmented).padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var routeList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if !places.isEmpty {
                    Text("Lieux trouvés").font(.headline)
                    ForEach(Array(places.prefix(4).enumerated()), id: \.offset) { _, place in
                        Button {
                            cameraRequest = TrailCameraRequest(target: .place(place.location.coordinate))
                            tab = .explore; showMap = true
                        } label: {
                            Label(place.name ?? "Lieu", systemImage: "mappin.circle.fill")
                                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                if tab == .explore && community {
                    sharedList
                } else {
                    HStack {
                        Text(favoritesOnly ? "Parcours favoris" : "Mes parcours").font(.title3.bold())
                        Spacer()
                        Text("\(localTracks.count)").foregroundStyle(WukulucStyle.muted)
                    }
                    if localTracks.isEmpty {
                        emptyState("Tes parcours, toujours avec toi", detail: "Importe un GPX, enregistre une sortie ou garde un parcours partagé.")
                        Button { importing = true } label: { Label("Importer un GPX", systemImage: "plus") }
                            .buttonStyle(WukulucButtonStyle())
                    } else {
                        ForEach(localTracks) { localRow($0) }
                    }
                }
            }.padding(14)
        }.refreshable { await sharing.refresh(activity: activity, query: query) }
    }

    @ViewBuilder private var sharedList: some View {
        Text("Parcours partagés").font(.title3.bold())
        Text("Des parcours publiés par les utilisateurs de Rivadventure.")
            .font(.caption).foregroundStyle(WukulucStyle.muted)
        if sharing.loading && sharing.routes.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(30) }
        if let issue = sharing.error {
            Text(issue).font(.subheadline).foregroundStyle(WukulucStyle.muted)
            Button("Réessayer") { Task { await sharing.refresh(activity: activity, query: query) } }
                .buttonStyle(WukulucButtonStyle(filled: false))
        } else if !sharing.loading && sharedRoutes.isEmpty {
            emptyState("Le prochain parcours peut être le tien", detail: "Aucun parcours partagé ne correspond à cette recherche. Tu peux publier un GPX depuis Mes parcours.")
            Button("Ouvrir mes parcours") { tab = .saved }.buttonStyle(WukulucButtonStyle())
        }
        ForEach(sharedRoutes) { route in
            Button { receive(route) } label: {
                HStack(spacing: 12) {
                    Image(systemName: TrailActivity(rawValue: route.activity)?.symbol ?? "map")
                        .font(.title2).foregroundStyle(WukulucStyle.green)
                        .frame(width: 64, height: 76).background(WukulucStyle.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(route.name).font(.headline).lineLimit(2)
                        Text(route.activity).font(.caption).foregroundStyle(WukulucStyle.green)
                        Text(routeStats(distance: route.distance_km, ascent: route.ascent_m))
                            .font(.caption).foregroundStyle(WukulucStyle.muted)
                        Text("Enregistrer et voir").font(.caption.bold()).foregroundStyle(WukulucStyle.green)
                    }
                    Spacer(minLength: 0)
                    if busyRoute == route.id { ProgressView() }
                    else { Image(systemName: "arrow.down.circle").foregroundStyle(WukulucStyle.green) }
                }.padding(12).background(Color.white, in: RoundedRectangle(cornerRadius: 16))
            }.buttonStyle(.plain).disabled(busyRoute != nil)
        }
    }

    private func localRow(_ entry: SavedTrack) -> some View {
        HStack(spacing: 8) {
            Button { detail = entry } label: {
                WukulucTraceThumbnail(entry: entry).frame(width: 84, height: 90)
            }.buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                Button { detail = entry } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(entry.name).font(.headline).lineLimit(2)
                        Text(entry.activity ?? "GPX importé").font(.caption).foregroundStyle(WukulucStyle.green)
                        Text(routeStats(distance: entry.distanceKilometers, ascent: entry.elevationGainMeters))
                            .font(.caption).foregroundStyle(WukulucStyle.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                if library.selectedID == entry.id {
                    Button { hide(entry) } label: {
                        Label("Retirer de la carte", systemImage: "eye.slash")
                            .font(.caption.bold()).foregroundStyle(WukulucStyle.green)
                            .frame(minHeight: 44, alignment: .leading)
                    }.buttonStyle(.plain)
                        .accessibilityLabel("Retirer " + entry.name + " de la carte")
                        .accessibilityHint("Le parcours reste dans Mes parcours.")
                        .accessibilityIdentifier("wukuluc.removeFromMap.\(entry.id)")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 14) {
                Button {
                    do { try library.toggleFavorite(entry) } catch { self.error = error.localizedDescription }
                } label: { Image(systemName: library.favoriteIDs.contains(entry.id) ? "heart.fill" : "heart") }
                    .accessibilityLabel("Ajouter ou retirer des favoris")
                ShareLink(item: library.originalURL(entry)) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Partager le GPX de " + entry.name)
            }.foregroundStyle(WukulucStyle.green).frame(width: 34)
        }.padding(12).background(Color.white, in: RoundedRectangle(cornerRadius: 16))
    }

    private var map: some View {
        TrailMapCanvas(track: nav.importedTrack, trackRevision: nav.importedTrackRevision,
            recording: recorder.recordingSegments, places: places, mapType: mapType,
            cameraRequest: cameraRequest, darkStyle: false)
        .overlay(alignment: .topTrailing) {
            VStack(spacing: 8) {
                Button {
                    cameraRequest = TrailCameraRequest(target: .position)
                    if nav.mapLocationDenied, let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: { Image(systemName: "location.fill").frame(width: 44, height: 44) }
                    .accessibilityLabel("Ma position")
                Menu {
                    Button("Carte") { mapType = .standard }
                    Button("Satellite") { mapType = .hybrid }
                    Button("Voir tout le parcours") { cameraRequest = TrailCameraRequest(target: .route) }
                } label: { Image(systemName: "square.3.layers.3d").frame(width: 44, height: 44) }
            }.background(Color.white, in: RoundedRectangle(cornerRadius: 12)).padding(12)
        }
    }

    private func mapSummary(_ entry: SavedTrack) -> some View {
        Button { detail = entry } label: {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.name).font(.headline).lineLimit(1)
                    Text(routeStats(distance: entry.distanceKilometers, ascent: entry.elevationGainMeters))
                        .font(.caption).foregroundStyle(WukulucStyle.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(WukulucStyle.green)
            }.padding(16).background(Color.white, in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }

    private var recordingPanel: some View {
        VStack(spacing: 14) {
            HStack {
                Label(recorder.state == .recording ? "Enregistrement en cours" : (recorder.state == .paused ? "En pause" : "Ton prochain parcours"),
                      systemImage: recorder.state == .recording ? "record.circle.fill" : "figure.hiking")
                    .font(.subheadline.bold()).foregroundStyle(recorder.state == .recording ? .red : WukulucStyle.green)
                Spacer(minLength: 0)
            }
            if recorder.state == .idle {
                Picker("Activité", selection: $recordingActivity) {
                    ForEach(TrailActivity.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu)
            }
            HStack(spacing: 12) {
                WukulucRouteMetric(value: String(format: "%.2f km", recorder.distanceMeters / 1000), label: "Distance")
                WukulucRouteMetric(value: elapsed, label: "Temps actif")
                WukulucRouteMetric(value: String(format: "%.0f m", recorder.ascentMeters), label: "Dénivelé +")
            }
            if let accuracy = recorder.lastAccuracy, recorder.state != .idle {
                Text("GPS ±\(Int(accuracy)) m · \(recorder.points.count) points")
                    .font(.caption).foregroundStyle(WukulucStyle.muted)
            }
            HStack(spacing: 10) {
                if recorder.state == .idle {
                    Button { recorder.start(activity: recordingActivity); nav.requestWebMapLocation() } label: {
                        Label("Démarrer", systemImage: "record.circle")
                    }.buttonStyle(WukulucButtonStyle())
                } else {
                    Button {
                        if recorder.state == .paused { recorder.resume() } else { recorder.pause() }
                    } label: {
                        Label(recorder.state == .paused ? "Reprendre" : "Pause", systemImage: recorder.state == .paused ? "play.fill" : "pause.fill")
                    }.buttonStyle(WukulucButtonStyle(filled: false))
                    Button { recordingName = ""; saveRecording = true } label: { Label("Terminer", systemImage: "stop.fill") }
                        .buttonStyle(WukulucButtonStyle())
                }
            }
            if recorder.state != .idle {
                Button("Abandonner", role: .destructive) { discardRecording = true }.font(.caption)
            }
        }.padding(16).background(Color.white, in: RoundedRectangle(cornerRadius: 18))
    }

    private var dock: some View {
        HStack(spacing: 0) {
            ForEach(WukulucTab.allCases) { value in
                Button { tab = value } label: {
                    VStack(spacing: 5) {
                        Image(systemName: value.symbol).font(.system(size: 21, weight: .semibold))
                        Text(value.rawValue).font(.caption.bold())
                    }.foregroundStyle(tab == value ? RivetCockpit.asphalt : Color.white.opacity(0.88))
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .background(tab == value ? WebMapProfile.explorer.menuAccent : WebMapProfile.explorer.menuSecondary,
                                    in: RoundedRectangle(cornerRadius: 12))
                }.accessibilityAddTraits(tab == value ? .isSelected : [])
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 5)
        .padding(.vertical, 5)
        .background(WebMapProfile.explorer.menuSurface)
        .overlay(alignment: .top) { Divider().overlay(WebMapProfile.explorer.menuSurface) }
    }

    private var filterSheet: some View {
        NavigationStack {
            Form {
                Section("Distance maximale") {
                    Text(maximumDistance == 0 ? "Sans limite" : String(format: "%.0f km", maximumDistance))
                    Slider(value: $maximumDistance, in: 0...300, step: 5)
                }
                Section("Dénivelé positif maximal") {
                    Text(maximumAscent == 0 ? "Sans limite" : String(format: "%.0f m", maximumAscent))
                    Slider(value: $maximumAscent, in: 0...5000, step: 100)
                }
                Section { Button("Réinitialiser") { maximumDistance = 0; maximumAscent = 0; activity = nil; favoritesOnly = false } }
            }.navigationTitle("Filtrer les parcours")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Afficher") { filters = false } } }
        }.tint(WukulucStyle.green).preferredColorScheme(.light)
    }

    private var localTracks: [SavedTrack] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = library.tracks.filter { entry in
            (term.isEmpty || entry.name.localizedCaseInsensitiveContains(term))
                && (activity == nil || entry.activity == activity?.rawValue)
                && (!favoritesOnly || library.favoriteIDs.contains(entry.id))
                && (maximumDistance == 0 || entry.distanceKilometers <= maximumDistance)
                && (maximumAscent == 0 || (entry.elevationGainMeters.map { $0 <= maximumAscent } ?? false))
        }
        return entries.sorted {
            switch sort {
            case "Distance": return $0.distanceKilometers < $1.distanceKilometers
            case "Dénivelé": return ($0.elevationGainMeters ?? .infinity) < ($1.elevationGainMeters ?? .infinity)
            case "Nom": return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            default: return $0.importedAt > $1.importedAt
            }
        }
    }
    private var sharedRoutes: [WukulucSharedRoute] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = sharing.routes.filter {
            (activity == nil || $0.activity == activity?.rawValue)
                && (term.isEmpty || $0.name.localizedCaseInsensitiveContains(term))
                && (maximumDistance == 0 || $0.distance_km <= maximumDistance)
                && (maximumAscent == 0 || ($0.ascent_m.map { $0 <= maximumAscent } ?? false))
        }
        return entries.sorted {
            switch sort {
            case "Distance": return $0.distance_km < $1.distance_km
            case "Dénivelé": return ($0.ascent_m ?? .infinity) < ($1.ascent_m ?? .infinity)
            case "Nom": return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            default: return $0.created_at > $1.created_at
            }
        }
    }
    private var elapsed: String {
        let seconds = max(0, Int(recorder.elapsed))
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    private func routeStats(distance: Double, ascent: Double?) -> String {
        String(format: "%.1f km", distance) + " · " + (ascent.map { String(format: "%.0f m D+", $0) } ?? "D+ non renseigné")
    }
    private func emptyState(_ title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "map").font(.largeTitle).foregroundStyle(WukulucStyle.green)
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(WukulucStyle.muted).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(28)
    }
    private func receive(_ route: WukulucSharedRoute) {
        busyRoute = route.id
        Task { @MainActor in
            defer { busyRoute = nil }
            do { detail = try await sharing.download(route) }
            catch { self.error = error.localizedDescription }
        }
    }
    private func show(_ entry: SavedTrack, follow: Bool) {
        do {
            try library.select(entry)
            if follow {
                GPXAccessManager.shared.cancel()
                nav.startFollowingGPX()
                let session = WebCockpitSession.shared
                session.showOnPhone(.explorer); session.tracks.refresh(); session.tracks.recenter()
                returnToCockpit = true
            } else { tab = .explore; showMap = true; cameraRequest = TrailCameraRequest(target: .route) }
            detail = nil
        } catch { self.error = error.localizedDescription }
    }
    private func sendToTFT(_ entry: SavedTrack) {
        do {
            try library.select(entry)
            let session = WebCockpitSession.shared
            session.assign(.explorer, to: session.layout.tft)
            session.tracks.refresh(); session.tracks.showRoute()
            returnToCockpit = true; detail = nil
        } catch { self.error = error.localizedDescription }
    }
    private func access(_ entry: SavedTrack, mode: GPXAccessMode) {
        do {
            try library.select(entry)
            let session = WebCockpitSession.shared
            session.showOnPhone(.explorer)
            GPXAccessManager.shared.start(mode, profile: .explorer)
            returnToCockpit = true; detail = nil
        } catch { self.error = error.localizedDescription }
    }
    private func remove(_ entry: SavedTrack) {
        do { try library.remove(entry); detail = nil }
        catch { self.error = error.localizedDescription }
    }
    private func hide(_ entry: SavedTrack) {
        do { try library.removeFromMap(entry) }
        catch { self.error = error.localizedDescription }
    }
    private func finishRecording() {
        do { _ = try recorder.finish(name: recordingName); tab = .saved }
        catch { self.error = error.localizedDescription }
    }
    private func search() {
        searchTask?.cancel(); let id = UUID(); searchID = id
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await sharing.refresh(activity: activity, query: term) }
        guard !term.isEmpty else { places = []; searching = false; return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = term
        if let fix = nav.userLocation { request.region = MKCoordinateRegion(center: fix.coordinate, latitudinalMeters: 100000, longitudinalMeters: 100000) }
        let task = MKLocalSearch(request: request); searchTask = task; searching = true
        task.start { response, failure in
            DispatchQueue.main.async {
                guard searchID == id else { return }
                searching = false; searchTask = nil
                places = response?.mapItems ?? []
                if let failure, localTracks.isEmpty, sharing.routes.isEmpty { error = failure.localizedDescription }
            }
        }
    }
}
