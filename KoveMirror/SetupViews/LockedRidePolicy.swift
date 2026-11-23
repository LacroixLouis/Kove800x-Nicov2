import Foundation

/// Single-map behaviour requested for a locked iPhone.  This is only an
/// eligibility decision: iOS can still suspend video rendering and sockets.
enum LockedRidePolicy {
    static func mayAttemptTFTMap(connected: Bool, foreground: Bool,
                                 cockpitVisible: Bool, phoneScreenSelected: Bool,
                                 enabled: Bool, rideActive: Bool) -> Bool {
        connected && !foreground && cockpitVisible && !phoneScreenSelected && enabled && rideActive
    }

    static func rendererMayUpdate(lockedTFTOnly: Bool, isTFT: Bool) -> Bool {
        !lockedTFTOnly || isTFT
    }
}

/// A locked map has one frame in progress. Its GPS timestamp is committed only
/// when the matching TCP write completes. The producer can then sample the latest fix.
struct LockedPositionDelivery {
    private struct Frame {
        let fix: Date
        let capturedAt: TimeInterval
        let heading: Double?
    }
    private var inFlight: Frame?
    private var lastSent: Frame?

    mutating func begin(fix: Date, capturedAt: TimeInterval, heading: Double? = nil) -> Bool {
        guard inFlight == nil else { return false }
        if let lastSent {
            guard fix > lastSent.fix || (fix == lastSent.fix && MapHeading.changed(from: lastSent.heading, to: heading))
            else { return false }
        }
        inFlight = Frame(fix: fix, capturedAt: capturedAt, heading: heading)
        return true
    }

    func isInFlight(_ capturedAt: TimeInterval) -> Bool {
        inFlight?.capturedAt == capturedAt
    }

    mutating func sent(capturedAt: TimeInterval?) -> Date? {
        guard let frame = inFlight, frame.capturedAt == capturedAt else { return nil }
        let newPosition = lastSent?.fix != frame.fix
        inFlight = nil
        lastSent = frame
        return newPosition ? frame.fix : nil
    }

    mutating func retry(capturedAt: TimeInterval) {
        if isInFlight(capturedAt) { inFlight = nil }
    }
}

/// Local measurements from entering the background until returning to the app.
/// Frame timing uses completed socket writes and includes pauses at either end.
struct LockedRideMeasurement {
    let started: Date
    let startUptime: TimeInterval
    private(set) var endUptime: TimeInterval?
    private(set) var fixes = 0
    private(set) var frames = 0
    private(set) var positionWrites = 0
    private var totalPositionDelay: TimeInterval = 0
    private var latestFix: Date?
    private var latestSend: TimeInterval?
    private var longestCompletedGap: TimeInterval = 0

    init(started: Date, uptime: TimeInterval) {
        self.started = started
        self.startUptime = uptime
    }

    mutating func recordFix(_ timestamp: Date) {
        guard endUptime == nil, timestamp >= started,
              latestFix.map({ timestamp > $0 }) ?? true else { return }
        latestFix = timestamp
        fixes += 1
    }

    mutating func recordFrame(captured: TimeInterval, sent: TimeInterval, fixTimestamp: Date? = nil) {
        guard captured >= startUptime, sent >= captured,
              sent >= (latestSend ?? startUptime), sent <= (endUptime ?? .infinity) else { return }
        longestCompletedGap = max(longestCompletedGap, sent - (latestSend ?? startUptime))
        latestSend = sent
        frames += 1
        if let fixTimestamp, fixTimestamp >= started {
            let delay = sent - startUptime - fixTimestamp.timeIntervalSince(started)
            if delay >= 0 {
                positionWrites += 1
                totalPositionDelay += delay
            }
        }
    }

    mutating func finish(at uptime: TimeInterval) {
        if endUptime == nil { endUptime = max(startUptime, uptime) }
    }

    var duration: TimeInterval { (endUptime ?? startUptime) - startUptime }
    var meanPositionDelay: TimeInterval? {
        positionWrites > 0 ? totalPositionDelay / Double(positionWrites) : nil
    }
    var framesPerSecond: Double { duration > 0 ? Double(frames) / duration : 0 }
    var longestSendGap: TimeInterval {
        max(longestCompletedGap, (endUptime ?? startUptime) - (latestSend ?? startUptime))
    }
}
