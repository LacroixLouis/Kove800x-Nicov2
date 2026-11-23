import SwiftUI

/// The camera stays open after a QR code that does not contain Wi-Fi details.
/// Only dismiss the sheet after the code has been validated and handed to iOS.
struct QRScannerSheet: View {
    @Binding var showScanner: Bool
    var onScanSuccess: (String) throws -> Void
    @State private var scanError: String?
    @State private var cameraError: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("Connexion Wi-Fi Kove")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                Text("Cadre le QR « connexion Wi-Fi » du compteur, pas celui du téléchargement de l’application.")
                    .foregroundStyle(RideTheme.muted)
                if let cameraError {
                    RideCard {
                        Label("Caméra indisponible", systemImage: "camera.fill").font(.headline)
                        Text(cameraError).font(.subheadline)
                        Button("Fermer") { showScanner = false }
                            .buttonStyle(RideButtonStyle())
                    }
                } else {
                    QRCodeScannerView(onScan: { code in
                        do {
                            try onScanSuccess(code)
                            scanError = nil
                            showScanner = false
                            return true
                        } catch {
                            scanError = error.localizedDescription
                            return false
                        }
                    }, onFailure: { cameraError = $0 })
                    .frame(height: 310)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20)
                        .stroke(RivetCockpit.lime, lineWidth: 2))
                    if let scanError {
                        Label(scanError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(RideTheme.orange)
                            .font(.subheadline)
                        Text("La caméra reste active. Affiche le QR Wi-Fi ou saisis le réseau manuellement.")
                            .font(.caption).foregroundStyle(RideTheme.muted)
                    } else {
                        Label("Lecture automatique du code Wi-Fi", systemImage: "qrcode.viewfinder")
                            .font(.subheadline).foregroundStyle(RideTheme.muted)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .background(RideTheme.background)
            .foregroundStyle(RideTheme.ink)
            .toolbarBackground(RivetCockpit.asphalt, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationTitle("Scanner le compteur")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { showScanner = false }
                }
            }
        }
        .tint(RivetCockpit.lime)
        .preferredColorScheme(.dark)
    }
}
