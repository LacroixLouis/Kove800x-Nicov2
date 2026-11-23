import Foundation

enum GPXAccessMode: String, CaseIterable, Identifiable {
    case nearest, start
    var id: String { rawValue }
    var title: String { self == .nearest ? "Rejoindre la trace" : "Aller au départ" }
    var targetName: String { self == .nearest ? "Point de jonction de la trace" : "Départ de la trace" }
}

struct GPXAccessTarget: Equatable {
    let point: GPXPoint
    let progressMeters: Double
    let distanceMeters: Double
}

/// Projects onto actual GPX legs, without joining disconnected segments or
/// mistaking the nearest recorded vertex for the closest point of a sparse GPX.
struct GPXAccessTargetPlanner {
    static func target(track original: GPXTrack, mode: GPXAccessMode, reversed: Bool,
                       from origin: GPXPoint, previousMeters: Double? = nil) -> GPXAccessTarget? {
        guard valid(origin) else { return nil }
        let track = reversed ? original.reversedForGuidance() : original
        if mode == .start {
            guard let point = track.segments.first(where: { $0.count >= 2 })?.first, valid(point) else { return nil }
            return GPXAccessTarget(point: point, progressMeters: 0, distanceMeters: meters(origin, point))
        }
        var best: GPXAccessTarget?
        var cumulative = 0.0
        for segment in track.segments {
            for (a, b) in zip(segment, segment.dropFirst()) {
                guard valid(a), valid(b) else { continue }
                let length = meters(a, b)
                guard length.isFinite, length > 0.01 else { continue }
                let latitude = origin.latitude * .pi / 180
                let x1 = wrapped(a.longitude - origin.longitude) * .pi / 180 * 6_371_000 * cos(latitude)
                let y1 = (a.latitude - origin.latitude) * .pi / 180 * 6_371_000
                let dx = wrapped(b.longitude - a.longitude) * .pi / 180 * 6_371_000 * cos(latitude)
                let dy = (b.latitude - a.latitude) * .pi / 180 * 6_371_000
                let square = dx * dx + dy * dy
                let fraction = square > 0 ? max(0, min(1, -(x1 * dx + y1 * dy) / square)) : 0
                let point = GPXPoint(latitude: a.latitude + (b.latitude - a.latitude) * fraction,
                                     longitude: wrapped(a.longitude + wrapped(b.longitude - a.longitude) * fraction))
                let candidate = GPXAccessTarget(point: point, progressMeters: cumulative + fraction * length,
                                                 distanceMeters: meters(origin, point))
                let continuity = best.map { current in
                    abs(candidate.distanceMeters - current.distanceMeters) < 1
                        && previousMeters.map { abs(candidate.progressMeters - $0) < abs(current.progressMeters - $0) } == true
                } ?? false
                if best == nil || candidate.distanceMeters < best!.distanceMeters - 0.001 || continuity { best = candidate }
                cumulative += length
            }
        }
        return best
    }

    private static func valid(_ point: GPXPoint) -> Bool {
        point.latitude.isFinite && point.longitude.isFinite
            && (-90...90).contains(point.latitude) && (-180...180).contains(point.longitude)
    }
    private static func wrapped(_ degrees: Double) -> Double {
        var result = degrees.truncatingRemainder(dividingBy: 360)
        if result > 180 { result -= 360 }
        if result < -180 { result += 360 }
        return result
    }
    private static func meters(_ a: GPXPoint, _ b: GPXPoint) -> Double {
        let rad = Double.pi / 180
        let longitudeTerm = pow(sin(wrapped(b.longitude - a.longitude) * rad / 2), 2)
        let h = pow(sin((b.latitude - a.latitude) * rad / 2), 2)
            + cos(a.latitude * rad) * cos(b.latitude * rad) * longitudeTerm
        return 12_742_000 * asin(sqrt(max(0, min(1, h))))
    }
}

struct GPXAccessArrivalPolicy {
    static func canHandoff(targetDistance: Double, routeRemaining: Double, accuracy: Double) -> Bool {
        targetDistance.isFinite && routeRemaining.isFinite && accuracy.isFinite
            && accuracy >= 0 && accuracy <= 35
            && targetDistance >= 0 && targetDistance <= 30
            && routeRemaining >= 0 && routeRemaining <= 45
    }
}
