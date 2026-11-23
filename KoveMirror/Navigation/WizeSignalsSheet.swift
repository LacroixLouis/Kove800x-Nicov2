import SwiftUI
import CoreLocation
import UIKit

struct WizeSignalsSheet: View {
    @ObservedObject private var community = WizeCommunityService.shared
    @ObservedObject private var nav = LocationAndNavigationManager.shared
    @State private var selected: CommunityReportKind?
    @State private var confirming = false
    @State private var busy = false
    @State private var message: String?
    @State private var failure: String?

    private var nearby: [CommunityReport] {
        guard let fix = nav.userLocation else { return [] }
        let point = TrafficCoordinate(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)
        return community.reports.filter { $0.expires > Date() && $0.point.distance(to: point) <= 25_000 }
            .sorted { $0.point.distance(to: point) < $1.point.distance(to: point) }
    }

    var body: some View {
        RideSheet("Signalements Rivroute") {
            Toggle("Recevoir et partager les signalements", isOn: $community.enabled)
            Text(community.status).font(.footnote).foregroundStyle(RideTheme.muted)
            Text("Les signalements sont partagés entre les utilisateurs de Rivroute. Seul l’emplacement d’un incident publié est partagé ; ton trajet n’est pas diffusé.")
                .font(.footnote).foregroundStyle(RideTheme.muted)
            if community.enabled {
                if !community.connected { Button("Réessayer la connexion") { community.start() } }
                Text("SIGNALER ICI").font(.caption.bold())
                ForEach(CommunityReportKind.allCases) { kind in
                    Button {
                        selected = kind
                        confirming = true
                    } label: { Label(kind.title, systemImage: kind.symbol).frame(maxWidth: .infinity, alignment: .leading) }
                    .buttonStyle(.bordered)
                    .disabled(busy || nav.userLocation == nil)
                }
                if busy { ProgressView("Envoi en cours…") }
                if let message { Text(message).foregroundStyle(.green) }
                Text("À PROXIMITÉ").font(.caption.bold())
                if nearby.isEmpty { Text("Aucun signalement Rivroute reçu à proximité.").font(.footnote).foregroundStyle(RideTheme.muted) }
                ForEach(nearby) { report in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(report.kind.title, systemImage: report.kind.symbol).font(.headline)
                        Text("\(report.confirmations) confirmation(s) · \(report.dismissals) fin(s) signalée(s)")
                            .font(.caption).foregroundStyle(RideTheme.muted)
                        HStack {
                            Button("Toujours là") { vote(report, confirmed: true) }
                            Button("Terminé") { vote(report, confirmed: false) }
                        }.buttonStyle(.bordered).disabled(busy)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                }
            }
        }
        .onAppear { if community.enabled { community.start() } }
        .confirmationDialog(selected?.title ?? "Signaler", isPresented: $confirming, titleVisibility: .visible) {
            Button("Publier ici") {
                guard let selected else { return }
                busy = true; message = nil
                Task {
                    do { try await community.publish(selected); message = "Signalement partagé avec Rivroute." }
                    catch { failure = error.localizedDescription }
                    busy = false
                }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text(selected == .dangerZone ? "Une zone approximative sera partagée avec les utilisateurs de Rivroute." : "Le signalement sera placé à ta position actuelle et visible par les utilisateurs de Rivroute.")
        }
        .alert("Signalement Rivroute", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }

    private func vote(_ report: CommunityReport, confirmed: Bool) {
        busy = true
        Task {
            do { try await community.vote(report, confirmed: confirmed); message = "Confirmation prise en compte." }
            catch { failure = error.localizedDescription }
            busy = false
        }
    }
}

struct WizeAlertsSheet: View {
    @ObservedObject private var traffic = WizeTrafficService.shared
    @ObservedObject private var zones = WizeSafetyZones.shared
    @ObservedObject private var nav = LocationAndNavigationManager.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        RideSheet("Alertes Rivroute") {
            Toggle("Alertes sur le trajet", isOn: $traffic.alertsEnabled)
            Toggle("Son des alertes", isOn: $traffic.soundEnabled)
            Text("Le bouton Muet du guidage coupe aussi le son des alertes.")
                .font(.footnote).foregroundStyle(RideTheme.muted)
            if nav.isAudioMuted { Text("Le guidage est actuellement en mode Muet.").font(.footnote) }
            Text("Notifications : " + traffic.notificationStatus).font(.footnote)
            Button("Réglages des notifications sur l’iPhone") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            Text(traffic.status).font(.footnote).foregroundStyle(RideTheme.muted)
            Toggle("Zones de vigilance en France", isOn: $zones.enabled)
            Text("\(zones.zoneCount) zones approximatives, dérivées de la liste publique des radars fixes. Données : Ministère de l’intérieur · \(zones.sourceDate) · Licence Ouverte 2.0. Cette base n’indique pas les contrôles mobiles en direct.")
                .font(.footnote).foregroundStyle(RideTheme.muted)
            Text("Les notifications fonctionnent pendant une sortie GPS active, avec Internet pour les incidents et les signalements partagés. Les zones enregistrées restent disponibles sans Internet. iOS peut limiter les connexions en arrière-plan ; les alertes ne fonctionnent pas après fermeture forcée de l’application.")
                .font(.footnote).foregroundStyle(RideTheme.muted)
        }
        .onAppear { traffic.requestNotificationAccess() }
    }
}
