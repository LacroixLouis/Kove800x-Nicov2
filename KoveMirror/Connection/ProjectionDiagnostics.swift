import Foundation
import Combine
import UIKit

/// Reports local observations. No acknowledgement of decoding exists in the
/// TFT protocol here; encoding/sending is never presented as proof of display.
final class ProjectionDiagnostics: ObservableObject {
    static let shared = ProjectionDiagnostics()
    @Published private(set) var mode: ProjectionMode = .disconnected
    @Published private(set) var encodedFrames = 0
    @Published private(set) var submittedVideoFPS: Double = 0
    @Published private(set) var lastSubmittedFrameUptime: TimeInterval?
    private var submittedFrameTimes: [TimeInterval] = []
    @Published private(set) var sentVideoBytes = 0
    @Published private(set) var lastFix: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var events: [String] = []
    @Published private(set) var backgroundLocationEnabled = false
    @Published private(set) var lockedTFTOnly = false
    @Published private(set) var bluetoothConnected = false
    @Published private(set) var controlConnected = false
    @Published private(set) var videoConnected = false
    @Published private(set) var lastControlPacketAt: Date?
    @Published private(set) var lastVideoSendCompletedAt: Date?
    @Published private(set) var lastLockedRide: LockedRideMeasurement?
    private var currentLockedRide: LockedRideMeasurement?

    func beginLockedRide() {
        guard currentLockedRide == nil else { return }
        currentLockedRide = LockedRideMeasurement(started: Date(), uptime: ProcessInfo.processInfo.systemUptime)
    }

    func finishLockedRide() {
        guard var ride = currentLockedRide else { return }
        ride.finish(at: ProcessInfo.processInfo.systemUptime)
        lastLockedRide = ride
        currentLockedRide = nil
    }

    func recordControlPacket() {
        DispatchQueue.main.async { self.lastControlPacketAt = Date() }
    }

    func setBackgroundLocation(_ enabled: Bool) {
        DispatchQueue.main.async { self.backgroundLocationEnabled = enabled }
    }

    func setLockedTFTOnly(_ enabled: Bool) {
        DispatchQueue.main.async { [self] in
            guard lockedTFTOnly != enabled else { return }
            lockedTFTOnly = enabled
            addEvent(enabled ? "Une seule carte : TFT (téléphone verrouillé)" : "Deux cartes : iPhone + TFT")
        }
    }

    func setTransports(bluetooth: Bool, control: Bool, video: Bool) {
        DispatchQueue.main.async { [self] in
            guard bluetoothConnected != bluetooth || controlConnected != control || videoConnected != video else { return }
            bluetoothConnected = bluetooth
            controlConnected = control
            videoConnected = video
            addEvent("BLE=\(bluetooth) contrôle=\(control) vidéo=\(video)")
        }
    }

    func setMode(_ value: ProjectionMode) {
        DispatchQueue.main.async { [self] in
            guard mode != value else { return }
            mode = value
            addEvent(value.rawValue)
        }
    }

    func recordFix(_ date: Date) {
        dispatchPrecondition(condition: .onQueue(.main))
        lastFix = date
        currentLockedRide?.recordFix(date)
    }
    func recordEncodedFrame() { encodedFrames += 1 }
    /// Counts accepted frames, not H.264 NAL units, and never implies TFT decoding.
    func recordCaptureSubmitted() {
        DispatchQueue.main.async { [self] in
            let now = ProcessInfo.processInfo.systemUptime
            submittedFrameTimes.append(now)
            lastSubmittedFrameUptime = now
            submittedFrameTimes.removeAll { now - $0 > 4.0 }
            if let oldest = submittedFrameTimes.first, submittedFrameTimes.count >= 2 {
                submittedVideoFPS = Double(submittedFrameTimes.count - 1) / max(0.1, now - oldest)
            } else {
                submittedVideoFPS = 0
            }
        }
    }
    func recordSentBytes(_ count: Int, capturedAt: TimeInterval?, sentAt: TimeInterval,
                         fixTimestamp: Date?) {
        dispatchPrecondition(condition: .onQueue(.main))
        sentVideoBytes += count
        lastVideoSendCompletedAt = Date()
        guard let capturedAt else { return }
        if currentLockedRide != nil {
            currentLockedRide?.recordFrame(captured: capturedAt, sent: sentAt, fixTimestamp: fixTimestamp)
        } else if let end = lastLockedRide?.endUptime, sentAt <= end {
            lastLockedRide?.recordFrame(captured: capturedAt, sent: sentAt, fixTimestamp: fixTimestamp)
        }
    }
    func recordError(_ message: String) {
        DispatchQueue.main.async { [self] in
            guard lastError != message else { return }
            lastError = message
            addEvent(message)
        }
    }

    private func addEvent(_ text: String) {
        events.append(ISO8601DateFormatter().string(from: Date()) + " " + text)
        if events.count > 60 { events.removeFirst(events.count - 60) }
    }

    /// Called from the UI. Deliberately excludes coordinates, destinations,
    /// Wi-Fi identifiers, passwords and Apple signing credentials.
    func exportReport() throws -> URL {
        dispatchPrecondition(condition: .onQueue(.main))
        let formatter = ISO8601DateFormatter()
        var report: [String: Any] = [
            "variant": "Double Interface · connexion v5",
            "created_at": formatter.string(from: Date()),
            "ios": UIDevice.current.systemVersion,
            "mode": mode.rawValue,
            "bluetooth_connected": bluetoothConnected,
            "tft_control_connected": controlConnected,
            "tft_video_connected": videoConnected,
            "background_location_enabled": backgroundLocationEnabled,
            "locked_tft_only": lockedTFTOnly,
            "locked_map_video_not_guaranteed_by_ios": true,
            "last_control_packet_at": lastControlPacketAt.map { formatter.string(from: $0) } ?? "none",
            "last_video_send_completed_at": lastVideoSendCompletedAt.map { formatter.string(from: $0) } ?? "none",
            "navigation_frames_encoded": encodedFrames,
            "video_frames_submitted_per_second": TFTFrameRatePolicy.visibleFPS(
                measured: submittedVideoFPS, lastCaptureUptime: lastSubmittedFrameUptime,
                nowUptime: ProcessInfo.processInfo.systemUptime),
            "video_bytes_send_completed": sentVideoBytes,
            "last_gps_at": lastFix.map { formatter.string(from: $0) } ?? "none",
            "last_error": lastError ?? "none",
            "events": events,
            "tft_display_confirmed": false
        ]
        if let ride = lastLockedRide {
            var summary: [String: Any] = [
                "duration_seconds": ride.duration, "fresh_gps_fixes": ride.fixes,
                "map_frames_send_completed": ride.frames, "mean_sent_fps": ride.framesPerSecond,
                "gps_positions_send_completed": ride.positionWrites,
                "longest_gap_seconds": ride.longestSendGap
            ]
            if let delay = ride.meanPositionDelay { summary["mean_gps_to_send_seconds"] = delay }
            report["last_background_ride"] = summary
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Double-Interface-diagnostic.json")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: .atomic)
        return url
    }
}
