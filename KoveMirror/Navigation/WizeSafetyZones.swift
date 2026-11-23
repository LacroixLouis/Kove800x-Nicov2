import Foundation
import Combine

/// A derived, deliberately approximate area dataset. Neither map markers nor
/// notifications expose the original camera's precise location or distance.
nonisolated struct WizeSafetyZone: Decodable, Identifiable {
    let id: String
    let latitude: Double
    let longitude: Double
    let radius: Double
    var point: TrafficCoordinate { .init(latitude: latitude, longitude: longitude) }
}

nonisolated struct WizeSafetyZoneDataset: Decodable {
    let sourceDate: String
    let zones: [WizeSafetyZone]
}

@MainActor
final class WizeSafetyZones: ObservableObject {
    static let shared = WizeSafetyZones()
    @Published var enabled = UserDefaults.standard.object(forKey: "wize.safetyZones") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "wize.safetyZones") }
    }
    let sourceDate: String
    let zoneCount: Int
    private let buckets: [String:[WizeSafetyZone]]
    private var wasInside = false
    private var lastEntry = Date.distantPast
    private init() {
        let data = Bundle.main.url(forResource: "FranceSafetyZones", withExtension: "json").flatMap { try? Data(contentsOf: $0) }
        let dataset = data.flatMap { try? JSONDecoder().decode(WizeSafetyZoneDataset.self, from: $0) }
        sourceDate = dataset?.sourceDate ?? "Indisponible"
        let valid = dataset?.zones.filter { $0.point.isValid && $0.radius >= 3_000 && $0.radius <= 10_000 } ?? []
        zoneCount = valid.count
        buckets = Dictionary(grouping: valid) { "\(Int(floor($0.latitude*2))):\(Int(floor($0.longitude*2)))" }
    }
    func containing(_ point: TrafficCoordinate) -> [WizeSafetyZone] {
        guard enabled else { return [] }
        return CommunityReport.neighboringBuckets(point).flatMap { buckets[$0] ?? [] }
            .filter { $0.point.distance(to: point) <= $0.radius }
    }
    func enteredZone(at point: TrafficCoordinate, now: Date) -> Bool {
        let inside = !containing(point).isEmpty
        defer { wasInside = inside }
        guard inside, !wasInside, now.timeIntervalSince(lastEntry) >= 600 else { return false }
        lastEntry = now
        return true
    }
}
