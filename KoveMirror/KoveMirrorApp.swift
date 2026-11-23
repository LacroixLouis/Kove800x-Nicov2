import SwiftUI

@main
struct KoveMirrorApp: App {
    @State private var importError: String?
    var body: some Scene {
        WindowGroup {
            BootView()
                .preferredColorScheme(.dark).tint(RivetCockpit.lime)
                .onOpenURL { url in
                    if ["gpx", "xml"].contains(url.pathExtension.lowercased()) {
                        TrackLibrary.shared.importFile(url) { failure in
                            if let failure { importError = failure.localizedDescription }
                            else {
                                let session = WebCockpitSession.shared
                                session.showOnPhone(.explorer)
                                session.tracks.refresh()
                                session.tracks.showRoute()
                                if let id = TrackLibrary.shared.selectedID {
                                    NotificationCenter.default.post(name: .wukulucRouteReceived, object: nil, userInfo: ["id": id])
                                }
                            }
                        }
                    } else if url.scheme == "nicomirror", url.host == "trail",
                              let id = UUID(uuidString: url.lastPathComponent) {
                        Task { @MainActor in
                            do {
                                let entry = try await WukulucSharingService.shared.download(id: id)
                                try TrackLibrary.shared.select(entry)
                                let session = WebCockpitSession.shared
                                session.showOnPhone(.explorer)
                                session.tracks.refresh()
                                session.tracks.showRoute()
                                NotificationCenter.default.post(name: .wukulucRouteReceived, object: nil, userInfo: ["id": entry.id])
                            } catch { importError = error.localizedDescription }
                        }
                    } else if url.scheme == "nicomirror", url.host == "start" || url.host == "mirror" {
                        BleController.shared?.resumeConnection()
                    }
                }
                .alert("Import GPX", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                    Button("OK", role: .cancel) { importError = nil }
                } message: { Text(importError ?? "") }
        }
    }
}


/// Affiche une première image SwiftUI avant d'initialiser Bluetooth et MapKit.
/// Ce lancement par étapes permet de distinguer l'écran iOS (statique) d'un
/// démarrage interne devenu lent, sans désactiver les fonctionnalités TFT.
private struct BootView: View {
    @State private var cockpitReady = false

    var body: some View {
        Group {
            if cockpitReady {
                ConnectionStatusView()
            } else {
                GeometryReader { geometry in
                    ZStack {
                        Color(red: 0.027, green: 0.075, blue: 0.122)
                            .ignoresSafeArea()
                        // Identique à LaunchScreen et au premier flux vidéo du TFT.
                        Image("StartupLogoV2")
                            .resizable()
                            .scaledToFit()
                            .frame(width: min(322, geometry.size.width * 0.82),
                                   height: min(322, geometry.size.width * 0.82))
                            .accessibilityLabel("Double Interface")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .accessibilityIdentifier("startup.bootView")
            }
        }
        .task {
            guard !cockpitReady else { return }
            // Laisser iOS afficher la première vue et traiter ses événements.
            // Laisser le visuel exact à l'écran pendant trois secondes.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            cockpitReady = true
        }
    }
}
