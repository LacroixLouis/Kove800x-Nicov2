import Foundation

nonisolated enum MapHeading {
    static func changed(from old: Double?, to new: Double?) -> Bool {
        guard let new, new.isFinite else { return false }
        guard let old, old.isFinite else { return true }
        let delta = abs(new - old).truncatingRemainder(dividingBy: 360)
        return min(delta, 360 - delta) >= 1
    }
}

/// A moving GPS course has priority. At a stop, regain the live compass
/// and keep the last course as a fallback when the compass is unavailable.
nonisolated struct TravelDirection {
    private var course: Double?
    private var validUntil: Date?

    mutating func update(course: Double, speed: Double, accuracy: Double, at time: Date) {
        guard course.isFinite, (0..<360).contains(course), speed >= 1.5,
              (0...65).contains(accuracy) else {
            validUntil = nil
            return
        }
        self.course = course
        validUntil = time.addingTimeInterval(5)
    }

    func bearing(compass: Double?, at time: Date) -> Double? {
        if let validUntil, time <= validUntil { return course }
        return compass ?? course
    }
}

nonisolated enum MapFocusStage: Equatable, Sendable {
    case zoom, northUp, travelUp

    var next: Self {
        switch self {
        case .zoom: return .northUp
        case .northUp: return .travelUp
        case .travelUp: return .zoom
        }
    }
}

/// One instance per map. Only a usable fix delivered to a laid-out map
/// consumes a button press. A drag or a route overview cancels that intent.
nonisolated struct MapCameraFocus: Sendable {
    enum Request: Equatable, Sendable { case position, mode(MapFocusStage) }
    struct Move: Equatable, Sendable {
        let stage: MapFocusStage
        let resetDistance: Bool
    }
    private var stage: MapFocusStage?
    private var lastTimestamp: Date?
    private(set) var followsPosition = true
    private(set) var pending: Request?
    var activeStage: MapFocusStage? { followsPosition ? stage : nil }
    var nextStage: MapFocusStage { activeStage?.next ?? .zoom }

    func followsCourse(navigating: Bool) -> Bool {
        followsPosition && pending == nil && lastTimestamp != nil &&
            (stage == .travelUp || (stage == nil && navigating))
    }

    mutating func request(_ action: Request) { pending = action }

    mutating func browse() {
        followsPosition = false
        pending = nil
    }

    mutating func consume(_ timestamp: Date, navigating: Bool) -> Move? {
        guard followsPosition || pending != nil else { return nil }
        if let lastTimestamp {
            guard timestamp >= lastTimestamp, timestamp != lastTimestamp || pending != nil else { return nil }
        }
        let reset = lastTimestamp == nil || !followsPosition || pending == .position || pending == .mode(.zoom)
        if case let .mode(selected)? = pending { stage = selected }
        pending = nil
        followsPosition = true
        lastTimestamp = timestamp
        return Move(stage: stage ?? (navigating ? .travelUp : .northUp), resetDistance: reset)
    }
}
