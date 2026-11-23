import Foundation

/// Two display positions, with distinct and persistent map profiles.
enum WebPanelID: Int, CaseIterable, Codable, Identifiable {
    case first, second
    var id: Int { rawValue }
    var other: Self { self == .first ? .second : .first }
}

/// A third map is available without requiring a third physical screen.
enum WebMapProfile: String, CaseIterable, Codable, Identifiable {
    case explorer, wize, osmand
    var id: String { rawValue }
    var title: String {
        switch self {
        case .explorer: return "Rivadventure"
        case .wize: return "Rivroute"
        case .osmand: return "Rivmonde"
        }
    }
    // Identité discrète, toujours lisible et SANS fond sur chaque carte.
    var overlayTitle: String { title.uppercased() }
}

struct WebPanelLayout: Codable, Equatable {
    private(set) var phone: WebPanelID = .first
    private(set) var miniX: Double = 1
    private(set) var miniY: Double = 1
    private(set) var firstProfile: WebMapProfile = .explorer
    private(set) var secondProfile: WebMapProfile = .wize
    var tft: WebPanelID { phone.other }

    // Migration from the earlier two-map layout. Missing keys must not reset
    // existing phone / TFT positions or the draggable preview's position.
    private enum CodingKeys: String, CodingKey { case phone, miniX, miniY, firstProfile, secondProfile }
    init() {}
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        phone = try container.decodeIfPresent(WebPanelID.self, forKey: .phone) ?? .first
        miniX = try container.decodeIfPresent(Double.self, forKey: .miniX) ?? 1
        miniY = try container.decodeIfPresent(Double.self, forKey: .miniY) ?? 1
        firstProfile = try container.decodeIfPresent(WebMapProfile.self, forKey: .firstProfile) ?? .explorer
        secondProfile = try container.decodeIfPresent(WebMapProfile.self, forKey: .secondProfile) ?? .wize
        if firstProfile == secondProfile { secondProfile = firstProfile == .wize ? .explorer : .wize }
        moveMini(x: miniX, y: miniY)
    }

    func profile(at position: WebPanelID) -> WebMapProfile { position == .first ? firstProfile : secondProfile }
    mutating func exchange() { phone = phone.other }

    /// A renderer must only appear on one screen at a time. If the requested
    /// profile is already in the other slot, swap the two assignments.
    mutating func assign(_ profile: WebMapProfile, to position: WebPanelID) {
        if self.profile(at: position) == profile { return }
        if self.profile(at: position.other) == profile {
            let previous = firstProfile
            firstProfile = secondProfile
            secondProfile = previous
        } else if position == .first {
            firstProfile = profile
        } else {
            secondProfile = profile
        }
    }

    mutating func moveMini(x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { return }
        miniX = min(1, max(0, x))
        miniY = min(1, max(0, y))
    }
}

/// Geometry shared by the SwiftUI miniature and portable unit tests.
/// Only the preview must stay onscreen: there is no artificial safe-area,
/// top-toolbar or bottom-toolbar exclusion zone.
struct MiniatureBounds: Equatable {
    let left: Double
    let right: Double
    let top: Double
    let bottom: Double

    init(containerWidth: Double, containerHeight: Double,
         miniatureWidth: Double, miniatureHeight: Double, margin: Double = 2) {
        let edge = max(0, margin)
        let midX = edge + max(0, miniatureWidth) / 2
        let midY = edge + max(0, miniatureHeight) / 2
        left = midX
        top = midY
        right = max(midX, containerWidth - edge - miniatureWidth / 2)
        bottom = max(midY, containerHeight - edge - miniatureHeight / 2)
    }

    func center(normalizedX: Double, normalizedY: Double) -> (x: Double, y: Double) {
        let x = min(1, max(0, normalizedX))
        let y = min(1, max(0, normalizedY))
        return (left + (right - left) * x, top + (bottom - top) * y)
    }
}
