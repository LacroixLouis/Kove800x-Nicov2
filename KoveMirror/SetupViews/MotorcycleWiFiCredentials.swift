import Foundation

/// Decodes the Wi-Fi QR displayed by a ThinkerRide instrument, without opening its URL.
/// The password is only handed to iOS Hotspot Configuration; it is never logged or saved here.
struct MotorcycleWiFiCredentials: Equatable {
    let ssid: String
    let password: String?
    var hidden: Bool = false

    enum QRCodeError: LocalizedError {
        case unsupportedCode, invalidEncoding, invalidSSID, invalidPassword, unsupportedSecurity

        var errorDescription: String? {
            switch self {
            case .unsupportedCode:
                return "Scanne le QR code de connexion Wi-Fi du compteur, pas celui de téléchargement de THINKERRIDE."
            case .invalidEncoding:
                return "Ce QR code contient un encodage invalide. Affiche-le à nouveau sur la moto."
            case .invalidSSID:
                return "Le nom du réseau Wi-Fi est absent ou invalide."
            case .invalidPassword:
                return "Le mot de passe Wi-Fi du QR code est invalide."
            case .unsupportedSecurity:
                return "Ce QR code utilise un type de réseau Wi-Fi non pris en charge."
            }
        }
    }

    static func parse(_ payload: String) throws -> Self {
        let code = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.utf8.count <= 4096 else { throw QRCodeError.unsupportedCode }

        if code.uppercased().hasPrefix("WIFI:") {
            return try parseStandardWiFi("WIFI:" + String(code.dropFirst(5)))
        }

        // Reject malformed escapes before URLComponents can silently escape a bare percent sign.
        guard code.range(of: "%(?![0-9A-Fa-f]{2})", options: .regularExpression) == nil else {
            throw QRCodeError.invalidEncoding
        }
        // Some TFT firmware encodes the Wi-Fi as a compact ThinkerRide link,
        // while others use named SSID/password parameters. Only trust the
        // documented pairing domain, never URLs that merely contain a password.
        let urlText = code.hasPrefix("g.thinkerride.com/") ? "https://" + code : code
        guard let url = URLComponents(string: urlText),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.lowercased() == "g.thinkerride.com",
              let query = url.percentEncodedQuery else {
            throw QRCodeError.unsupportedCode
        }
        // Split BEFORE decoding: passwords containing %26 must remain intact.
        // Do not replace '+' with a space; this isn't a form submission.
        let fields = query.components(separatedBy: "&")
        let named = try fields.compactMap { value -> (String, String)? in
            guard let separator = value.firstIndex(of: "=") else { return nil }
            return (try decode(String(value[..<separator])).lowercased(),
                    try decode(String(value[value.index(after: separator)...])))
        }
        let values = Dictionary(named, uniquingKeysWith: { first, _ in first })
        // Compact TFT QR codes end in a named `ap=1` flag. That flag does
        // NOT make the preceding positional SSID/password fields "named".
        let namedSSID = values["ssid"] ?? values["s"] ?? values["wifiname"] ?? values["wifi_name"]
        let namedPassword = values["password"] ?? values["pwd"] ?? values["pass"] ?? values["p"]
        if namedSSID != nil || namedPassword != nil {
            // If one explicitly named credential is missing, reject the code
            // rather than interpret "ssid=..." as a literal SSID.
            guard let ssid = namedSSID, let password = namedPassword else {
                throw QRCodeError.unsupportedCode
            }
            return try validated(ssid: ssid, password: password, isOpen: false)
        }
        guard fields.count >= 2 else { throw QRCodeError.unsupportedCode }
        let ssid = try decode(fields[0])
        let password = try decode(fields[1])
        return try validated(ssid: ssid, password: password, isOpen: false)
    }

    private static func decode(_ value: String) throws -> String {
        guard let decoded = value.removingPercentEncoding else { throw QRCodeError.invalidEncoding }
        return decoded
    }

    private static func parseStandardWiFi(_ code: String) throws -> Self {
        var fields: [String: String] = [:]
        var field = ""
        var escaping = false
        for character in code.dropFirst(5) {
            if escaping {
                field.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else if character == ";" {
                if let separator = field.firstIndex(of: ":") {
                    let key = String(field[..<separator])
                    guard fields[key] == nil else { throw QRCodeError.unsupportedCode }
                    fields[key] = String(field[field.index(after: separator)...])
                }
                field = ""
            } else {
                field.append(character)
            }
        }
        guard !escaping, field.isEmpty else { throw QRCodeError.unsupportedCode }
        let security = (fields["T"] ?? "WPA").uppercased()
        guard ["WPA", "WPA2", "WPA3", "WPA/WPA2", "WPA2/WPA3", "NOPASS"].contains(security) else {
            throw QRCodeError.unsupportedSecurity
        }
        var network = try validated(ssid: fields["S"] ?? "", password: fields["P"] ?? "", isOpen: security == "NOPASS")
        network.hidden = ["true", "1"].contains(fields["H"]?.lowercased() ?? "")
        return network
    }

    static func validated(ssid: String, password: String, isOpen: Bool) throws -> Self {
        guard (1...32).contains(ssid.utf8.count),
              !ssid.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw QRCodeError.invalidSSID
        }
        if isOpen { return Self(ssid: ssid, password: nil) }
        let bytes = Array(password.utf8)
        guard (8...63).contains(bytes.count), bytes.allSatisfy({ (32...126).contains($0) }) else {
            throw QRCodeError.invalidPassword
        }
        return Self(ssid: ssid, password: password)
    }
}
