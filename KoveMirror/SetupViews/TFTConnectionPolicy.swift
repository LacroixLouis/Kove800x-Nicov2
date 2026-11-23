import Foundation

enum TFTPreparationStep: Equatable {
    case connectMotorcycle, waitForVideo, startBroadcast, ready
}

enum TFTConnectionPolicy {
    static let automaticKey = "automaticTFTConnectionEnabled"
    static let lockedKey = "keepTFTConnectionWhenLocked"

    /// An existing BLE or control connection needs video, not another pairing.
    /// A ready video socket is sufficient even while Bluetooth reconnects.
    static func preparationStep(bluetooth: Bool, control: Bool, video: Bool,
                                broadcasting: Bool, requiresBroadcast: Bool) -> TFTPreparationStep {
        guard video else { return bluetooth || control ? .waitForVideo : .connectMotorcycle }
        return requiresBroadcast && !broadcasting ? .startBroadcast : .ready
    }

    /// Losing one transport must not tear down the other active transports.
    static func needsRideUpdates(requested: Bool, enabled: Bool,
                                 bluetooth: Bool, control: Bool, video: Bool) -> Bool {
        requested && enabled && (bluetooth || control || video)
    }
}
