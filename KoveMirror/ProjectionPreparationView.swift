import SwiftUI
import UIKit

struct ProjectionPreparationView: View {
    @ObservedObject var bleController: BleController
    @ObservedObject private var wifi = MotorcycleWiFiManager.shared
    @ObservedObject private var diagnostics = ProjectionDiagnostics.shared
    @Binding var pairedSSID: String
    @AppStorage(TFTConnectionPolicy.lockedKey) private var lockedTFTEnabled = true
    @State private var showScanner = false
    // The iOS Wi-Fi consent dialogue must be presented AFTER the scanner sheet
    // has finished dismissing; otherwise it can appear behind the sheet.
    @State private var pendingScannedCredentials: MotorcycleWiFiCredentials?
    @State private var qrError: String?
    @State private var showManual = false
    @State private var ssid = ""
    @State private var password = ""
    @State private var confirmPairingReset = false
    @State private var diagnosticReport: URL?

    var body: some View {
        RideSheet("Connexion") {
            RideCard {
                Label(bleController.isStreaming ? "Liaison TFT établie" : "Compteur en attente",
                      systemImage: bleController.isStreaming ? "checkmark.circle.fill" : "display")
                    .font(.title3.bold()).foregroundStyle(bleController.isStreaming ? RivetCockpit.lime : RideTheme.orange)
                Text("La petite fenêtre est envoyée automatiquement au TFT quand la liaison vidéo est prête.")
                    .font(.subheadline).foregroundStyle(RideTheme.muted)
                // Distinguish the three links. A saved network, a working Bluetooth
                // connection or an open video socket do NOT prove that the TFT decodes images.
                linkStatus("Bluetooth moto", connected: bleController.connectionState == .connected)
                linkStatus("Commandes TFT", connected: bleController.isTFTControlConnected)
                linkStatus("Socket vidéo TFT", connected: bleController.isStreaming)
                Toggle("Mode trajet écran verrouillé", isOn: $lockedTFTEnabled)
                    .tint(RivetCockpit.lime)
                Text("Une seule carte continue ses mises à jour : celle du TFT. iOS peut interrompre le rendu vidéo, même si le GPS continue.")
                    .font(.caption2).foregroundStyle(RideTheme.muted)
                if bleController.isStreaming {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        let fps = TFTFrameRatePolicy.visibleFPS(
                            measured: diagnostics.submittedVideoFPS,
                            lastCaptureUptime: diagnostics.lastSubmittedFrameUptime,
                            nowUptime: ProcessInfo.processInfo.systemUptime)
                        Text("Images préparées : \(fps, specifier: "%.1f") / s · cible 15")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(fps > 0 ? RivetCockpit.lime : RideTheme.orange)
                    }
                    Text("La cadence est mesurée sur l’iPhone, pas sur le compteur. Vérifie l’image sur la moto.")
                        .font(.caption2).foregroundStyle(RideTheme.muted)
                }
            }
            RideCard {
                Label("Wi-Fi de la moto", systemImage: "wifi").font(.headline)
                if !wifi.supportsAutomaticJoin {
                    Text("Avec cette signature, le scanner mémorise le réseau. Rejoins-le dans Réglages → Wi-Fi.")
                        .font(.footnote).foregroundStyle(RideTheme.muted)
                }
                if pairedSSID.isEmpty {
                    Text(wifi.supportsAutomaticJoin
                         ? "Scanne le QR Wi-Fi du compteur, puis touche « Rejoindre » si l’iPhone le demande."
                         : "Scanne le QR du compteur pour récupérer son nom et son mot de passe.")
                        .foregroundStyle(RideTheme.muted)
                } else {
                    Text(pairedSSID).font(.subheadline.bold())
                    Text("Réseau mémorisé · connexion TFT à vérifier")
                        .font(.caption).foregroundStyle(RivetCockpit.lime)
                }
                Button("Scanner le QR du compteur", systemImage: "qrcode.viewfinder") { showScanner = true }
                    .buttonStyle(RideButtonStyle()).accessibilityIdentifier("connection.scan")
                    .disabled(wifi.isConnecting)
                DisclosureGroup("Saisir le Wi-Fi manuellement", isExpanded: $showManual) {
                    TextField("Nom du réseau", text: $ssid).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(12).background(RivetCockpit.raised, in: RoundedRectangle(cornerRadius: 10))
                    SecureField("Mot de passe (vide si réseau ouvert)", text: $password)
                        .padding(12).background(RivetCockpit.raised, in: RoundedRectangle(cornerRadius: 10))
                    Button(wifi.supportsAutomaticJoin ? "Enregistrer et connecter" : "Enregistrer le réseau") {
                        do {
                            let credentials = try MotorcycleWiFiCredentials.validated(ssid: ssid, password: password, isOpen: password.isEmpty)
                            try wifi.configure(credentials)
                            password = ""
                            qrError = nil
                            bleController.resumeConnection()
                        } catch { qrError = error.localizedDescription }
                    }.buttonStyle(RideButtonStyle(primary: false))
                        .disabled(ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.accessibilityIdentifier("connection.manual")
                if wifi.isConnecting { ProgressView("Connexion au Wi-Fi…") }
                Text(wifi.message).font(.footnote).foregroundStyle(RideTheme.muted)
                if !pairedSSID.isEmpty {
                    if wifi.offersManualJoin || !wifi.supportsAutomaticJoin {
                        Button("Copier le mot de passe", systemImage: "doc.on.doc") {
                            wifi.copyPasswordForManualJoin()
                        }.buttonStyle(RideButtonStyle(primary: false))
                    }
                    if wifi.supportsAutomaticJoin {
                        Button("Réessayer le Wi-Fi", systemImage: "arrow.clockwise") {
                        // This button must only retry Wi-Fi. Restarting BLE here
                        // cancelled healthy or pending motorcycle connections.
                            wifi.retrySavedNetwork()
                        }
                        .buttonStyle(RideButtonStyle(primary: false)).disabled(wifi.isConnecting)
                    }
                }
                if let qrError { Text(qrError).font(.subheadline).foregroundStyle(RideTheme.orange) }
            }
            RideCard {
                Label("Bluetooth", systemImage: "antenna.radiowaves.left.and.right").font(.headline)
                Text(bluetoothStatus).font(.subheadline).foregroundStyle(RideTheme.muted)
                if let name = bleController.connectedDeviceName { Text(name).font(.subheadline.bold()) }
                else if bleController.hasSavedMotorcycle { Text(bleController.savedMotorcycleName).font(.subheadline.bold()) }
                Button("Relancer la connexion", systemImage: "arrow.clockwise") { bleController.retryConnection() }
                    .buttonStyle(RideButtonStyle(primary: false))
                if bleController.hasSavedMotorcycle {
                    Button("Associer à nouveau la moto", systemImage: "link") { confirmPairingReset = true }
                        .buttonStyle(RideButtonStyle(primary: false))
                }
                Button("Autorisations iPhone", systemImage: "gearshape") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }.buttonStyle(RideButtonStyle(primary: false))
            }
            RideCard {
                Label("Diagnostic pour le prochain essai", systemImage: "stethoscope").font(.headline)
                Text("En cas de panne, prépare un rapport depuis l’iPhone et partage-le. Il indique quelles liaisons sont actives sans joindre le mot de passe Wi-Fi ni ta position.")
                    .font(.footnote).foregroundStyle(RideTheme.muted)
                if let ride = diagnostics.lastLockedRide {
                    Text("Dernier passage en arrière-plan · \(ride.duration, specifier: "%.0f") s").font(.subheadline.bold())
                    Text("\(ride.fixes) positions GPS · \(ride.frames) images envoyées")
                    Text("Moyenne \(ride.framesPerSecond, specifier: "%.1f") im/s · plus longue pause d’envoi \(ride.longestSendGap, specifier: "%.1f") s")
                        .font(.caption.monospacedDigit()).foregroundStyle(RideTheme.muted)
                    if let delay = ride.meanPositionDelay {
                        Text("Délai GPS → envoi Wi-Fi · \(delay * 1000, specifier: "%.0f") ms en moyenne sur \(ride.positionWrites) positions")
                            .font(.caption.monospacedDigit()).foregroundStyle(RideTheme.muted)
                    }
                }
                Button("Préparer le diagnostic", systemImage: "doc.text.magnifyingglass") {
                    do { diagnosticReport = try diagnostics.exportReport() }
                    catch { qrError = "Diagnostic impossible : " + error.localizedDescription }
                }.buttonStyle(RideButtonStyle(primary: false))
                if let diagnosticReport {
                    ShareLink(item: diagnosticReport) {
                        Label("Partager le diagnostic", systemImage: "square.and.arrow.up")
                    }.buttonStyle(RideButtonStyle(primary: false))
                }
            }
            Text(wifi.supportsAutomaticJoin
                 ? "Après la première association, Double Interface retrouve la moto enregistrée. iOS peut demander une autorisation pour rejoindre le Wi-Fi."
                 : "Après la première association, Double Interface retrouve la moto en Bluetooth. Vérifie que l’iPhone est connecté au Wi-Fi du compteur.")
                .font(.footnote).foregroundStyle(RideTheme.muted)
        }
        .sheet(isPresented: $showScanner, onDismiss: connectPendingScannedWiFi) {
            QRScannerSheet(showScanner: $showScanner) { code in
                // Validate while scanning, but wait for the sheet to close
                // before opening the iOS Hotspot Configuration consent alert.
                pendingScannedCredentials = try MotorcycleWiFiCredentials.parse(code)
                qrError = nil
            }
        }
        .onDisappear { password = "" }
        .confirmationDialog("Rechercher à nouveau le compteur ?", isPresented: $confirmPairingReset, titleVisibility: .visible) {
            Button("Rechercher et associer") { bleController.retryConnection(forgetSavedMotorcycle: true) }
            Button("Annuler", role: .cancel) { }
        } message: {
            Text("Place-toi près de ta moto, compteur en mode navigation. La prochaine association Bluetooth sera mémorisée.")
        }
    }

    private func linkStatus(_ title: String, connected: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: connected ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(connected ? RivetCockpit.lime : RideTheme.orange)
            Text(title).font(.subheadline)
            Spacer(minLength: 0)
            Text(connected ? "Actif" : "En attente")
                .font(.caption.weight(.semibold))
                .foregroundStyle(connected ? RivetCockpit.lime : RideTheme.muted)
        }
        .accessibilityElement(children: .combine)
    }

    private func connectPendingScannedWiFi() {
        guard let credentials = pendingScannedCredentials else { return }
        pendingScannedCredentials = nil
        do {
            try wifi.configure(credentials)
            bleController.resumeConnection()
        } catch {
            qrError = error.localizedDescription
        }
    }

    private var bluetoothStatus: String {
        if bleController.isBluetoothPoweredOff { return "Active le Bluetooth dans les réglages de l’iPhone." }
        if let error = bleController.bluetoothError { return error }
        switch bleController.connectionState {
        case .connected: return "Compteur connecté. Association mémorisée."
        case .connecting: return "Reconnexion au compteur enregistré…"
        case .scanning: return "Recherche du compteur…"
        case .disconnected: return bleController.hasSavedMotorcycle ? "Moto mémorisée. En attente de reconnexion." : "Affiche le mode navigation du compteur pour la première association."
        }
    }
}
