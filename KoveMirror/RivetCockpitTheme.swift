import SwiftUI

/// Shared palette for the cockpit, settings, forms and navigation controls.
enum RivetCockpit {
    static let asphalt = Color(hex: "07131F")
    static let panel = Color(hex: "102437")
    static let raised = Color(hex: "1B354C")
    static let paper = Color(hex: "F6FAFF")
    static let lime = Color(hex: "23AFFF")
    static let orange = Color(hex: "FF9F33")
    static let blue = Color(hex: "16B8FF")
    static let red = Color(hex: "FF464D")
    static let secondary = Color(hex: "BDD1E5")
    static let line = Color.white.opacity(0.12)
}

extension WebMapProfile {
    var menuAccent: Color {
        switch self {
        case .explorer: return Color(hex: "64ED54")
        case .wize: return Color(hex: "398BFF")
        case .osmand: return Color(hex: "FF9F33")
        }
    }

    var menuSurface: Color {
        // Every map shares the same navy chrome; only its buttons carry the accent.
        RivetCockpit.panel
    }

    var menuSecondary: Color {
        menuAccent.opacity(0.18)
    }
}

private struct RideMapProfileKey: EnvironmentKey {
    nonisolated static let defaultValue: WebMapProfile? = nil
}

extension EnvironmentValues {
    var rideMapProfile: WebMapProfile? {
        get { self[RideMapProfileKey.self] }
        set { self[RideMapProfileKey.self] = newValue }
    }
}
