import Foundation

/// Mesures un itinéraire routier suivant sa géométrie, sans confondre la distance
/// à vol d'oiseau jusqu'à la destination avec la distance encore à parcourir.
/// Ce composant est autonome pour être testé sans MapKit ni réseau.
struct RoadRouteCoordinate: Equatable {
    let latitude: Double
    let longitude: Double
}

struct RoadRoutePosition: Equatable {
    let travelledMeters: Double
    let remainingMeters: Double
    let deviationMeters: Double
}

struct RoadRouteProgress {
    private struct Segment {
        let start: RoadRouteCoordinate
        let end: RoadRouteCoordinate
        let offsetMeters: Double
        let lengthMeters: Double
    }

    private let segments: [Segment]
    let totalMeters: Double

    init(_ coordinates: [RoadRouteCoordinate]) {
        var segments: [Segment] = []
        var cumulative = 0.0
        for (a, b) in zip(coordinates, coordinates.dropFirst()) {
            guard a.latitude.isFinite, a.longitude.isFinite,
                  b.latitude.isFinite, b.longitude.isFinite,
                  abs(a.latitude) <= 90, abs(b.latitude) <= 90,
                  abs(a.longitude) <= 180, abs(b.longitude) <= 180 else { continue }
            let distance = Self.distance(a, b)
            guard distance > 0.05, distance.isFinite else { continue }
            segments.append(Segment(start: a, end: b, offsetMeters: cumulative,
                                    lengthMeters: distance))
            cumulative += distance
        }
        self.segments = segments
        self.totalMeters = cumulative
    }

    func project(_ position: RoadRouteCoordinate, previousMeters: Double? = nil) -> RoadRoutePosition? {
        guard !segments.isEmpty,
              position.latitude.isFinite, position.longitude.isFinite,
              abs(position.latitude) <= 90, abs(position.longitude) <= 180 else { return nil }
        var bestDeviation = Double.infinity
        var bestProgress = 0.0
        for segment in segments {
            let start = Self.localXY(from: position, to: segment.start)
            let end = Self.localXY(from: position, to: segment.end)
            let dx = end.x - start.x
            let dy = end.y - start.y
            let squared = dx * dx + dy * dy
            let fraction = squared > 0.01 ? max(0, min(1, -(start.x * dx + start.y * dy) / squared)) : 0
            let deviation = hypot(start.x + fraction * dx, start.y + fraction * dy)
            let progress = segment.offsetMeters + fraction * segment.lengthMeters
            // For intersections/loops, prefer continuity only when the GPS
            // fits two branches equally well (within ordinary GPS noise).
            let continuityWins = abs(deviation - bestDeviation) < 3.0 &&
                previousMeters.map { abs(progress - $0) < abs(bestProgress - $0) } == true
            if deviation + 3.0 < bestDeviation || continuityWins {
                bestDeviation = deviation
                bestProgress = progress
            }
        }
        return RoadRoutePosition(travelledMeters: bestProgress,
                                 remainingMeters: max(0, totalMeters - bestProgress),
                                 deviationMeters: bestDeviation)
    }

    /// MapKit's published route length and the length of the drawn polyline
    /// can differ slightly. Normalize our geometric progress to the MKRoute units.
    func remainingRoadMeters(at position: RoadRoutePosition, mapKitRouteMeters: Double) -> Double {
        guard totalMeters > 0, mapKitRouteMeters.isFinite, mapKitRouteMeters > 0 else { return 0 }
        return max(0, min(mapKitRouteMeters, position.remainingMeters / totalMeters * mapKitRouteMeters))
    }

    private static func distance(_ a: RoadRouteCoordinate, _ b: RoadRouteCoordinate) -> Double {
        let radians = Double.pi / 180
        let deltaLatitude = (b.latitude - a.latitude) * radians
        let deltaLongitude = wrapped(b.longitude - a.longitude) * radians
        let haversine = pow(sin(deltaLatitude / 2), 2)
            + cos(a.latitude * radians) * cos(b.latitude * radians) * pow(sin(deltaLongitude / 2), 2)
        return 12_742_000 * asin(sqrt(min(1, max(0, haversine))))
    }

    private static func wrapped(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value < -180 { value += 360 }
        return value
    }

    private static func localXY(from origin: RoadRouteCoordinate, to target: RoadRouteCoordinate) -> (x: Double, y: Double) {
        let radians = Double.pi / 180
        let latitude = (origin.latitude + target.latitude) * 0.5 * radians
        return (wrapped(target.longitude - origin.longitude) * radians * 6_371_000 * cos(latitude),
                (target.latitude - origin.latitude) * radians * 6_371_000)
    }
}

/// Cumulated MKRoute.Step distances, used to advance instructions in the
/// correct order without the unreliable GPS straight-line distance to a bend.
struct RoadStepProgress {
    private let ends: [Double]

    init(stepDistances: [Double]) {
        var distance = 0.0
        ends = stepDistances.map { step in
            distance += max(0, step.isFinite ? step : 0)
            return distance
        }
    }

    func nextIndex(current: Int, travelledMeters: Double, toleranceMeters: Double = 20) -> Int {
        guard !ends.isEmpty else { return 0 }
        var index = min(max(0, current), ends.count - 1)
        while index < ends.count - 1 && travelledMeters >= ends[index] - toleranceMeters {
            index += 1
        }
        return index
    }

    func distanceToStepEnd(index: Int, travelledMeters: Double) -> Double {
        guard ends.indices.contains(index) else { return 0 }
        return max(0, ends[index] - travelledMeters)
    }
}
