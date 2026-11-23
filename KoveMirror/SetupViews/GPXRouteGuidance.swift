import Foundation

/// Guidage d'une trace GPX déjà importée. Fonctionne sans connexion Internet.
/// Ce n'est PAS un moteur de calcul d'itinéraire routier : le motard suit
/// uniquement la géométrie du GPX, sans recalcul de chemin en cas de sortie.
enum GPXManeuver: String, Codable {
    case slightLeft, left, sharpLeft, slightRight, right, sharpRight, uTurn

    var instruction: String {
        switch self {
        case .slightLeft: return "Légèrement à gauche"
        case .left: return "Tourner à gauche"
        case .sharpLeft: return "Virage serré à gauche"
        case .slightRight: return "Légèrement à droite"
        case .right: return "Tourner à droite"
        case .sharpRight: return "Virage serré à droite"
        case .uTurn: return "Demi-tour sur la trace"
        }
    }

    var systemImage: String {
        switch self {
        case .slightLeft: return "arrow.up.left"
        case .left, .sharpLeft: return "arrow.turn.up.left"
        case .slightRight: return "arrow.up.right"
        case .right, .sharpRight: return "arrow.turn.up.right"
        case .uTurn: return "arrow.uturn.backward"
        }
    }
}

struct GPXRouteGuidance: Equatable {
    let offTrackMeters: Double
    let travelledMeters: Double
    let remainingMeters: Double
    let totalMeters: Double
    let nextManeuver: GPXManeuver?
    let distanceToManeuverMeters: Double?
    let nearFinish: Bool

    var offTrack: Bool { offTrackMeters > 60 }
}

/// Pré-calculé une seule fois à l'import du GPX. Ne relie JAMAIS les segments
/// discontinus. Les manoeuvres sont des estimations géométriques, pas des
/// indications de circulation ou de priorité routière.
struct GPXRouteNavigator {
    private struct Leg {
        let a: GPXPoint
        let b: GPXPoint
        let from: Double
        let length: Double
    }
    private struct Bend {
        let distance: Double
        let maneuver: GPXManeuver
    }
    private let legs: [Leg]
    private let bends: [Bend]
    let totalMeters: Double

    init(track: GPXTrack) {
        var segments: [Leg] = []
        var corners: [Bend] = []
        var cumulative = 0.0
        for points in track.segments where points.count >= 2 {
            var distances: [Double] = [cumulative]
            for (a, b) in zip(points, points.dropFirst()) {
                let length = Self.meters(a, b)
                if length.isFinite && length > 0.01 {
                    segments.append(Leg(a: a, b: b, from: cumulative, length: length))
                    cumulative += length
                }
                distances.append(cumulative)
            }
            if points.count >= 3 {
                for i in 1..<(points.count - 1) {
                    let before = points[i - 1], middle = points[i], after = points[i + 1]
                    // Ignore noisy GPS zigzags shorter than 12 metres.
                    guard Self.meters(before, middle) >= 12,
                          Self.meters(middle, after) >= 12 else { continue }
                    let incoming = Self.xy(from: middle, to: before)
                    let outgoing = Self.xy(from: middle, to: after)
                    // Vector from previous point to bend, then bend to next.
                    let cross = (-incoming.0) * outgoing.1 - (-incoming.1) * outgoing.0
                    let dot = (-incoming.0) * outgoing.0 + (-incoming.1) * outgoing.1
                    let degrees = atan2(cross, dot) * 180 / .pi
                    let magnitude = abs(degrees)
                    guard magnitude >= 40 else { continue }
                    let turn: GPXManeuver
                    if magnitude >= 155 { turn = .uTurn }
                    else if degrees > 0 {
                        turn = magnitude >= 120 ? .sharpLeft : (magnitude < 70 ? .slightLeft : .left)
                    } else {
                        turn = magnitude >= 120 ? .sharpRight : (magnitude < 70 ? .slightRight : .right)
                    }
                    corners.append(Bend(distance: distances[i], maneuver: turn))
                }
            }
        }
        legs = segments
        bends = corners
        totalMeters = cumulative
    }

    /// Aide à rester sur le bon tronçon quand la trace se croise elle-même.
    /// Une meilleure proximité GPS prime toujours sur l'historique.
    func guidance(at position: GPXPoint, previousMeters: Double? = nil) -> GPXRouteGuidance? {
        guard !legs.isEmpty, totalMeters > 0 else { return nil }
        var closest = Double.infinity
        var distanceAlong = 0.0
        for leg in legs {
            let a = Self.xy(from: position, to: leg.a)
            let b = Self.xy(from: position, to: leg.b)
            let dx = b.0 - a.0, dy = b.1 - a.1
            let square = dx * dx + dy * dy
            let fraction = square > 0 ? min(1, max(0, -(a.0 * dx + a.1 * dy) / square)) : 0
            let gap = hypot(a.0 + fraction * dx, a.1 + fraction * dy)
            let progress = leg.from + fraction * leg.length
            if gap < closest - 0.001 ||
                (abs(gap - closest) <= 0.001 && previousMeters != nil &&
                 abs(progress - previousMeters!) < abs(distanceAlong - previousMeters!)) {
                closest = gap
                distanceAlong = progress
            }
        }
        let distanceLeft = max(0, totalMeters - distanceAlong)
        let next = bends.first(where: { $0.distance > distanceAlong + 5 })
        return GPXRouteGuidance(offTrackMeters: closest,
                                travelledMeters: distanceAlong,
                                remainingMeters: distanceLeft,
                                totalMeters: totalMeters,
                                nextManeuver: next?.maneuver,
                                distanceToManeuverMeters: next.map { max(0, $0.distance - distanceAlong) },
                                nearFinish: distanceLeft < 30 && closest < 40)
    }

    private static func meters(_ a: GPXPoint, _ b: GPXPoint) -> Double {
        let rad = Double.pi / 180
        let dLat = (b.latitude - a.latitude) * rad
        let dLon = wrappedLongitude(b.longitude - a.longitude) * rad
        let h = pow(sin(dLat / 2), 2) + cos(a.latitude * rad) * cos(b.latitude * rad) * pow(sin(dLon / 2), 2)
        return 12_742_000 * asin(sqrt(max(0, min(1, h))))
    }

    private static func wrappedLongitude(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value < -180 { value += 360 }
        return value
    }

    private static func xy(from origin: GPXPoint, to target: GPXPoint) -> (Double, Double) {
        let rad = Double.pi / 180
        let latitude = (origin.latitude + target.latitude) * 0.5 * rad
        return (wrappedLongitude(target.longitude - origin.longitude) * rad * 6_371_000 * cos(latitude),
                (target.latitude - origin.latitude) * rad * 6_371_000)
    }
}


extension GPXTrack {
    /// Reprend exactement les mêmes points dans l'autre sens, sans modifier
    /// le fichier GPX original enregistré ou partagé.
    func reversedForGuidance() -> GPXTrack {
        GPXTrack(name: name, segments: segments.reversed().map { Array($0.reversed()) })
    }
}
