import Foundation
import Combine
import NetworkExtension
import Security
import UIKit

/// Stores the motorcycle network in this app's device-only Keychain. Automatic
/// system configuration is opt-in and requires the signed Hotspot entitlement.
final class MotorcycleWiFiManager: ObservableObject {
    static let shared = MotorcycleWiFiManager()
    static let configurationAccepted = Notification.Name("DoubleInterface.motorcycleWiFiConfigurationAccepted")
    @Published private(set) var isConnecting = false
    @Published private(set) var offersManualJoin = false
    @Published private(set) var message = "Scanne une fois le QR Wi-Fi du compteur."
    var supportsAutomaticJoin: Bool {
        Bundle.main.object(forInfoDictionaryKey: "DoubleInterfaceAutomaticWiFiJoinEnabled") as? Bool == true
    }
    // Applying a saved configuration can display system consent. Attempt it
    // once per launch; a refusal or an error requires an explicit retry.
    private var attemptedAutomaticJoin = false
    var hasSavedNetwork: Bool {
        savedNetwork() != nil
    }
    private struct SavedNetwork: Codable {
        let ssid: String
        let password: String?
        let hidden: Bool?
        // Optional for networks saved before the app recorded iOS approval.
        let approvedBySystem: Bool?
    }

    private var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "NicoMirror") + ".motorcycle-wifi",
         kSecAttrAccount as String: "tft-network"]
    }

    private func savedNetwork() -> SavedNetwork? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(SavedNetwork.self, from: data)
    }

    private func save(_ credentials: MotorcycleWiFiCredentials, approved: Bool) throws {
        let data = try JSONEncoder().encode(SavedNetwork(ssid: credentials.ssid, password: credentials.password,
                                                        hidden: credentials.hidden, approvedBySystem: approved))
        let query = keychainQuery
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Impossible d’enregistrer le Wi-Fi de la moto."])
        }
        UserDefaults.standard.set(credentials.ssid, forKey: "pairedMotorcycleSSID")
    }

    /// Called after a validated QR scan. Report failures to the scanner so
    /// it does not close while the new Wi-Fi has not been saved or requested.
    func configure(_ credentials: MotorcycleWiFiCredentials) throws {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isConnecting else {
            throw NSError(domain: "DoubleInterface.WiFi", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Connexion précédente en cours. Réessaie le QR dans un instant."])
        }
        guard UIApplication.shared.applicationState == .active else {
            throw NSError(domain: "DoubleInterface.WiFi", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Ouvre Double Interface au premier plan pour rejoindre le Wi-Fi."])
        }
        try save(credentials, approved: false)
        apply(credentials)
    }

    /// A saved credential is not a live Wi-Fi connection. Request a real join
    /// in the foreground instead of merely reporting that it was saved.
    func resumeSavedNetwork() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard supportsAutomaticJoin, !isConnecting, !attemptedAutomaticJoin,
              UIApplication.shared.applicationState == .active,
              let saved = savedNetwork(), saved.approvedBySystem == true else { return }
        apply(MotorcycleWiFiCredentials(ssid: saved.ssid, password: saved.password, hidden: saved.hidden ?? false))
    }

    /// An explicit retry is allowed even after an automatic attempt failed.
    func retrySavedNetwork() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isConnecting else { return }
        guard let saved = savedNetwork() else {
            message = "Scanne le QR du compteur pour mémoriser son Wi-Fi."
            return
        }
        guard UIApplication.shared.applicationState == .active else {
            message = "Ouvre l’application pour modifier la connexion Wi-Fi."
            return
        }
        apply(MotorcycleWiFiCredentials(ssid: saved.ssid, password: saved.password, hidden: saved.hidden ?? false))
    }

    func copyPasswordForManualJoin() {
        guard let password = savedNetwork()?.password else {
            message = "Ce réseau ne contient pas de mot de passe mémorisé."
            return
        }
        UIPasteboard.general.setItems([["public.utf8-plain-text": password]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
        message = "Mot de passe copié pour 2 minutes. Colle-le dans Réglages → Wi-Fi."
    }

    private func apply(_ credentials: MotorcycleWiFiCredentials) {
        guard !isConnecting else { return }
        guard UIApplication.shared.applicationState == .active else {
            message = "Ouvre l’application pour autoriser la première connexion Wi-Fi."
            return
        }
        attemptedAutomaticJoin = true
        guard supportsAutomaticJoin else {
            offersManualJoin = true
            message = "Choisis le réseau du compteur dans Réglages → Wi-Fi, puis reviens dans l’app."
            return
        }
        let configuration: NEHotspotConfiguration
        if let password = credentials.password {
            configuration = NEHotspotConfiguration(ssid: credentials.ssid, passphrase: password, isWEP: false)
        } else {
            configuration = NEHotspotConfiguration(ssid: credentials.ssid)
        }
        // A temporary joinOnce network is removed when the display sleeps.
        configuration.joinOnce = false
        configuration.hidden = credentials.hidden
        offersManualJoin = false
        isConnecting = true
        message = "Connexion au Wi-Fi du compteur…"
        NEHotspotConfigurationManager.shared.apply(configuration) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isConnecting = false
                let nsError = error as NSError?
                let alreadyAssociated = nsError?.domain == NEHotspotConfigurationErrorDomain
                    && nsError?.code == NEHotspotConfigurationError.alreadyAssociated.rawValue
                if error == nil || alreadyAssociated {
                    try? self.save(credentials, approved: true)
                    self.message = alreadyAssociated
                        ? "Wi-Fi du compteur déjà rejoint. En attente de la liaison TFT."
                        : "Demande Wi-Fi acceptée. En attente de la liaison TFT."
                    NotificationCenter.default.post(name: Self.configurationAccepted, object: self)
                } else if nsError?.domain == NEHotspotConfigurationErrorDomain
                            && nsError?.code == NEHotspotConfigurationError.userDenied.rawValue {
                    try? self.save(credentials, approved: false)
                    self.message = "Connexion refusée. Touche Réessayer lorsque tu veux l’autoriser."
                } else {
                    self.offersManualJoin = true
                    self.message = "iOS n’a pas pu rejoindre le réseau. Affiche le Wi-Fi sur la moto et touche Réessayer."
                    ProjectionDiagnostics.shared.recordError("Configuration Wi-Fi indisponible (code " + String(nsError?.code ?? -1) + ").")
                }
            }
        }
    }
}
