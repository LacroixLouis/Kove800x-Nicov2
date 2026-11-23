import Foundation
import CoreLocation
import Combine

/// GPS altitude only. Weather and maintenance are absent from this version.
final class TelemetrySyncManager {
    static let shared = TelemetrySyncManager()
    private var timer: Timer?
    private var lastLocationTelemetryAt = Date.distantPast
    weak var bleController: BleController?
    private init() {}
    func startSync(bleController: BleController) {
        self.bleController = bleController
        timer?.invalidate()
        sendTelemetryPackets()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.sendTelemetryPackets() }
    }
    func stopSync() { timer?.invalidate(); timer = nil }
    func onLocationFix() {
        guard Date().timeIntervalSince(lastLocationTelemetryAt) >= 3 else { return }
        guard bleController?.connectionState == .connected else { return }
        lastLocationTelemetryAt = Date()
        sendTelemetryPackets()
    }
    func sendTelemetryPackets() {
        guard let ble = bleController, ble.connectionState == .connected,
              let fix = LocationAndNavigationManager.shared.userLocation, fix.verticalAccuracy >= 0,
              ProjectionPolicy.isFresh(timestamp: fix.timestamp, accuracy: fix.horizontalAccuracy, now: Date()) else { return }
        let altitude = Int(fix.altitude)
        ble.sendJsonPacket("{\"msg_id\":25,\"msg_type\":9,\"msg_source\":2,\"altitude\":\(altitude),\"ave_altitude\":0,\"max_altitude\":0,\"pond_distance\":0.0,\"pond_time\":0,\"head\":0}")
    }
}
