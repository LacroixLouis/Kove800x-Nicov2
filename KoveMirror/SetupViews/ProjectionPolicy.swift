import Foundation

enum ProjectionMode: String, Codable {
    case disconnected = "Vidéo du compteur déconnectée"
    case paused = "Envoi des images en pause"
    case screen = "Petite fenêtre de Double Interface"
    case broadcast = "Diffusion de l'écran"
    case navigation = "Navigation TFT indépendante · essai"
}

/// Pure decision logic, shared with the portable regression tests.
struct ProjectionPolicy {
    static func dualPanelMode(connected: Bool, foreground: Bool, cockpitVisible: Bool,
                              phoneScreenSelected: Bool = false, broadcasting: Bool = false,
                              lockedRideEnabled: Bool = false, rideActive: Bool = false) -> ProjectionMode {
        guard connected else { return .disconnected }
        // Full-phone sharing is an explicit source. It must survive opening a
        // native app, and must pause if permission/sharing ends, never substitute
        // a saved web map or a screenshot from the host app.
        if phoneScreenSelected { return broadcasting ? .broadcast : .paused }
        if LockedRidePolicy.mayAttemptTFTMap(connected: connected, foreground: foreground,
                cockpitVisible: cockpitVisible, phoneScreenSelected: phoneScreenSelected,
                enabled: lockedRideEnabled, rideActive: rideActive) { return .navigation }
        return foreground && cockpitVisible ? .screen : .paused
    }

    static func mode(connected: Bool, background: Bool, navigating: Bool,
                     lockedModeEnabled: Bool, broadcasting: Bool, independentNavigation: Bool = false,
                     preferBroadcast: Bool = false, independentPanel: Bool = false,
                     restrictToBroadcast: Bool = false) -> ProjectionMode {
        guard connected else { return .disconnected }
        // An explicit external-app shortcut must not be replaced by our GPX or
        // locked-navigation renderer when opening that app backgrounds this one.
        // If the broadcast stops, pause rather than silently show a different map.
        if preferBroadcast { return broadcasting ? .broadcast : .paused }
        if independentPanel { return .navigation }
        if navigating && independentNavigation { return .navigation }
        // A selected crop must never fall back to sending the full app window.
        if restrictToBroadcast { return broadcasting ? .broadcast : .paused }
        if background {
            if navigating && lockedModeEnabled { return .navigation }
            // Background is also entered when the user opens another app.
            // Preserve full-screen ReplayKit broadcasting in that case.
            return broadcasting ? .broadcast : .paused
        }
        return broadcasting ? .broadcast : .screen
    }

    /// Reject inaccurate, old and implausibly future-dated locations.
    static func isFresh(timestamp: Date, accuracy: Double, now: Date) -> Bool {
        let age = now.timeIntervalSince(timestamp)
        return accuracy.isFinite && accuracy >= 0 && age >= -5 && age <= 15
    }
}
