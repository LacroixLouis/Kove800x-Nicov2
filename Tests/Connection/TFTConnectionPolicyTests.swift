import XCTest
@testable import NicoMirrorConnection

final class TFTConnectionPolicyTests: XCTestCase {
    func testChangingAppsReusesVideoEvenWhileBluetoothIsReconnecting() {
        for bluetooth in [false, true] {
            for control in [false, true] {
                XCTAssertEqual(TFTConnectionPolicy.preparationStep(bluetooth: bluetooth,
                    control: control, video: true, broadcasting: true, requiresBroadcast: true), .ready)
            }
        }
    }

    func testFirstBroadcastOnAnEstablishedLinkNeverAsksForPairing() {
        XCTAssertEqual(TFTConnectionPolicy.preparationStep(bluetooth: true, control: true,
            video: true, broadcasting: false, requiresBroadcast: true), .startBroadcast)
        XCTAssertEqual(TFTConnectionPolicy.preparationStep(bluetooth: false, control: false,
            video: true, broadcasting: false, requiresBroadcast: true), .startBroadcast)
    }

    func testExistingBluetoothOrControlWaitsForVideoInsteadOfPairingAgain() {
        for connection in [(true, false), (false, true), (true, true)] {
            XCTAssertEqual(TFTConnectionPolicy.preparationStep(bluetooth: connection.0,
                control: connection.1, video: false, broadcasting: true, requiresBroadcast: true), .waitForVideo)
        }
    }

    func testIndependentTFTNeedsNoPhoneBroadcast() {
        XCTAssertEqual(TFTConnectionPolicy.preparationStep(bluetooth: false, control: true,
            video: true, broadcasting: false, requiresBroadcast: false), .ready)
    }

    func testReconnectionSequenceDoesNotTreatAStoredOrBroadcastSessionAsLiveVideo() {
        let steps = [
            TFTConnectionPolicy.preparationStep(bluetooth: false, control: false,
                video: false, broadcasting: true, requiresBroadcast: true),
            TFTConnectionPolicy.preparationStep(bluetooth: true, control: false,
                video: false, broadcasting: true, requiresBroadcast: true),
            TFTConnectionPolicy.preparationStep(bluetooth: true, control: true,
                video: true, broadcasting: true, requiresBroadcast: true)
        ]
        XCTAssertEqual(steps, [.connectMotorcycle, .waitForVideo, .ready])
    }

    func testVideoCanStopWithoutStoppingAnActiveRideConnection() {
        XCTAssertTrue(TFTConnectionPolicy.needsRideUpdates(requested: true, enabled: true,
            bluetooth: true, control: true, video: false))
    }

    func testBLETimeoutDoesNotTearDownWorkingWiFi() {
        XCTAssertTrue(TFTConnectionPolicy.needsRideUpdates(requested: true, enabled: true,
            bluetooth: false, control: true, video: true))
        XCTAssertTrue(TFTConnectionPolicy.needsRideUpdates(requested: true, enabled: true,
            bluetooth: false, control: true, video: false))
    }

    func testWaitingForVideoCanAlreadyMaintainTheBLESession() {
        XCTAssertTrue(TFTConnectionPolicy.needsRideUpdates(requested: true, enabled: true,
            bluetooth: true, control: false, video: false))
    }

    func testExplicitStopOrDisabledSettingPreventsBackgroundRideUpdates() {
        XCTAssertFalse(TFTConnectionPolicy.needsRideUpdates(requested: false, enabled: true,
            bluetooth: true, control: true, video: true))
        XCTAssertFalse(TFTConnectionPolicy.needsRideUpdates(requested: true, enabled: false,
            bluetooth: true, control: true, video: true))
    }

    func testAllConnectionsLostStopsTheRideLocationSession() {
        XCTAssertFalse(TFTConnectionPolicy.needsRideUpdates(requested: true, enabled: true,
            bluetooth: false, control: false, video: false))
    }
}
