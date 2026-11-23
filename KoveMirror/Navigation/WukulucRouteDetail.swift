import SwiftUI
import MapKit

struct WukulucRouteDetail: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var library = TrackLibrary.shared
    @ObservedObject private var sharing = WukulucSharingService.shared
    let entry: SavedTrack
    let onShow: () -> Void
    let onHide: () -> Void
    let onFollow: () -> Void
    let onAccess: (GPXAccessMode) -> Void
    let onTFT: () -> Void
    let onDelete: () -> Void
    @State private var track: GPXTrack?
    @State private var activity: TrailActivity = .trailMotorcycle
    @State private var publication: WukulucSharedRoute?
    @State private var publishConfirmation = false
    @State private var deleteConfirmation = false
    @State private var withdrawalConfirmation = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let track {
                        WukulucRouteMap(track: track).frame(height: 235)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    } else { ProgressView().frame(maxWidth: .infinity, minHeight: 160) }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.activity ?? "Parcours GPX").font(.caption.bold()).foregroundStyle(WukulucStyle.green)
                        Text(entry.name).font(.title2.bold()).foregroundStyle(WukulucStyle.ink)
                        Text(entry.importedAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption).foregroundStyle(WukulucStyle.muted)
                    }
                    HStack(spacing: 14) {
                        WukulucRouteMetric(value: String(format: "%.1f km", entry.distanceKilometers), label: "Distance")
                        WukulucRouteMetric(value: entry.elevationGainMeters.map { String(format: "%.0f m", $0) } ?? "—", label: "Dénivelé positif")
                        WukulucRouteMetric(value: duration, label: entry.recordedDuration == nil ? "Durée estimée" : "Durée enregistrée")
                    }
                    Divider()
                    if let track { WukulucElevationProfile(track: track) }
                    if let range = track?.elevationRange {
                        HStack {
                            Label(String(format: "Min. %.0f m", range.lowerBound), systemImage: "arrow.down")
                            Spacer()
                            Label(String(format: "Max. %.0f m", range.upperBound), systemImage: "arrow.up")
                        }.font(.caption).foregroundStyle(WukulucStyle.muted)
                    }
                    HStack {
                        Label("\(entry.pointCount) points GPS", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        Spacer()
                        Label("GPX sur cet appareil", systemImage: "checkmark.circle.fill")
                    }.font(.caption).foregroundStyle(WukulucStyle.muted)
                    if library.selectedID == entry.id {
                        Button(action: onHide) { Label("Retirer de la carte", systemImage: "eye.slash") }
                            .buttonStyle(WukulucButtonStyle(filled: false))
                            .accessibilityHint("Le parcours reste dans Mes parcours.")
                            .accessibilityIdentifier("wukuluc.detail.removeFromMap")
                        Text("Le parcours reste enregistré dans Mes parcours.")
                            .font(.caption).foregroundStyle(WukulucStyle.muted)
                    } else {
                        Button(action: onShow) { Label("Afficher sur la carte", systemImage: "map") }
                            .buttonStyle(WukulucButtonStyle(filled: false))
                    }
                    ForEach(GPXAccessMode.allCases) { mode in
                        Button { onAccess(mode) } label: {
                            Label(mode.title, systemImage: mode == .start ? "flag.fill" : "arrow.triangle.merge")
                        }.buttonStyle(WukulucButtonStyle(filled: false))
                    }
                    Text("L’accès routier nécessite du réseau. Le suivi GPX prend le relais lorsque le point choisi est atteint.")
                        .font(.caption).foregroundStyle(WukulucStyle.muted)
                    Button(action: onTFT) { Label("Envoyer au compteur TFT", systemImage: "display") }
                        .buttonStyle(WukulucButtonStyle(filled: false))
                    sharingSection
                    Button("Supprimer de cet appareil", role: .destructive) { deleteConfirmation = true }
                        .font(.caption).frame(maxWidth: .infinity).padding(.top, 8)
                }.padding(16)
            }
            .background(Color.white)
            .navigationTitle("Le parcours")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        do { try library.toggleFavorite(entry) } catch { self.error = error.localizedDescription }
                    } label: {
                        Image(systemName: library.favoriteIDs.contains(entry.id) ? "heart.fill" : "heart")
                    }.accessibilityLabel("Ajouter ou retirer des favoris")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: onFollow) { Label("Suivre ce parcours", systemImage: "location.north.fill") }
                    .buttonStyle(WukulucButtonStyle()).padding(12).background(Color.white)
            }
        }
        .tint(WukulucStyle.green)
        .preferredColorScheme(.light)
        .task(id: entry.id) {
            do { track = try library.parsedTrack(entry) } catch { self.error = error.localizedDescription }
            activity = TrailActivity(rawValue: entry.activity ?? "") ?? .trailMotorcycle
            publication = sharing.routes.first { $0.id == entry.id || $0.id == entry.sourceID }
        }
        .confirmationDialog("Publier ce parcours dans Rivadventure ?", isPresented: $publishConfirmation, titleVisibility: .visible) {
            Button("Publier le parcours") { publish() }
            Button("Annuler", role: .cancel) { }
        } message: {
            Text("Le GPX complet, ses points de départ et d’arrivée et ses éventuels repères seront accessibles aux utilisateurs de Rivadventure. Tu pourras retirer la publication depuis cet appareil.")
        }
        .confirmationDialog("Retirer le parcours partagé ?", isPresented: $withdrawalConfirmation, titleVisibility: .visible) {
            Button("Retirer de la communauté", role: .destructive) { withdraw() }
        } message: { Text("Ton fichier GPX reste sur cet appareil. Les copies déjà téléchargées par d’autres personnes restent chez elles.") }
        .confirmationDialog("Supprimer le fichier de cet appareil ?", isPresented: $deleteConfirmation, titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) { onDelete() }
        } message: { Text("Une publication communautaire doit être retirée séparément avant de supprimer sa copie locale.") }
        .alert("Rivadventure", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private var sharingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Partager le parcours").font(.headline)
            ShareLink(item: library.originalURL(entry)) {
                Label("Envoyer le fichier GPX", systemImage: "square.and.arrow.up")
            }.buttonStyle(WukulucButtonStyle())
            Text("AirDrop, Messages, Mail ou une autre application compatible. Le fichier original et ses repères sont conservés.")
                .font(.caption).foregroundStyle(WukulucStyle.muted)
            if let publication {
                ShareLink(item: publication.link) {
                    Label("Envoyer le lien Rivadventure", systemImage: "link")
                }.buttonStyle(WukulucButtonStyle(filled: false))
                Text("Le lien s’ouvre sur un appareil où Double Interface est installé.")
                    .font(.caption).foregroundStyle(WukulucStyle.muted)
                if publication.owner_id == sharing.userID {
                    Button("Retirer de la communauté", role: .destructive) { withdrawalConfirmation = true }
                        .disabled(busy).font(.caption.bold())
                }
            } else {
                Picker("Activité du parcours", selection: $activity) {
                    ForEach(TrailActivity.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu)
                Button { publishConfirmation = true } label: {
                    if busy { ProgressView() }
                    else { Label("Publier dans la communauté Rivadventure", systemImage: "person.2.fill") }
                }.buttonStyle(WukulucButtonStyle(filled: false)).disabled(busy)
            }
        }.padding(16).background(WukulucStyle.background, in: RoundedRectangle(cornerRadius: 16))
    }

    private var duration: String {
        let seconds = entry.recordedDuration ?? entry.distanceKilometers / activity.estimatedSpeed * 3600
        let minutes = max(1, Int(seconds / 60))
        return minutes >= 60 ? "\(minutes / 60) h \(String(format: "%02d", minutes % 60))" : "\(minutes) min"
    }
    private func publish() {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { publication = try await sharing.publish(entry, activity: activity) }
            catch { self.error = error.localizedDescription }
        }
    }
    private func withdraw() {
        guard let publication else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { try await sharing.withdraw(publication); self.publication = nil }
            catch { self.error = error.localizedDescription }
        }
    }
}
