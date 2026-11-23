import XCTest
@testable import NicoMirrorConnection

final class LockedRidePolicyTests: XCTestCase {
    func testNewHeadingCanTurnALockedFrameWithoutCountingAnotherGPSPosition() {
        let fix = Date()
        var delivery = LockedPositionDelivery()
        XCTAssertTrue(delivery.begin(fix: fix, capturedAt: 1, heading: 359.8))
        XCTAssertEqual(delivery.sent(capturedAt: 1), fix)
        XCTAssertFalse(delivery.begin(fix: fix, capturedAt: 2, heading: 0))
        XCTAssertTrue(delivery.begin(fix: fix, capturedAt: 3, heading: 90))
        XCTAssertFalse(delivery.begin(fix: fix, capturedAt: 4, heading: 135))
        XCTAssertNil(delivery.sent(capturedAt: 3))
        XCTAssertFalse(delivery.begin(fix: fix, capturedAt: 5, heading: 90))
        XCTAssertTrue(delivery.begin(fix: fix, capturedAt: 6, heading: 135))
        XCTAssertNil(delivery.sent(capturedAt: 6))
        XCTAssertFalse(delivery.begin(fix: fix.addingTimeInterval(-1), capturedAt: 7, heading: 180))
        XCTAssertTrue(delivery.begin(fix: fix.addingTimeInterval(1), capturedAt: 8, heading: 135))
    }

    func testNewFixCanStartImmediatelyAfterThePreviousSocketWrite() {
        let first = Date(timeIntervalSince1970: 100)
        let intermediate = first.addingTimeInterval(0.01)
        let newest = first.addingTimeInterval(0.02)
        var delivery = LockedPositionDelivery()
        XCTAssertTrue(delivery.begin(fix: first, capturedAt: 10))
        XCTAssertFalse(delivery.begin(fix: intermediate, capturedAt: 10.01))
        XCTAssertNil(delivery.sent(capturedAt: nil))
        XCTAssertNil(delivery.sent(capturedAt: 9)) // Previous connection or welcome frame.
        XCTAssertFalse(delivery.begin(fix: newest, capturedAt: 10.02))
        XCTAssertEqual(delivery.sent(capturedAt: 10), first)
        XCTAssertTrue(delivery.begin(fix: newest, capturedAt: 10.03))
        XCTAssertEqual(delivery.sent(capturedAt: 10.03), newest)
        XCTAssertFalse(delivery.begin(fix: newest, capturedAt: 10.04))
        XCTAssertFalse(delivery.begin(fix: intermediate, capturedAt: 10.05))
    }

    func testFailureCanRetryTheSameFixAndLateCallbacksCannotClearTheRetry() {
        let fix = Date()
        var delivery = LockedPositionDelivery()
        XCTAssertTrue(delivery.begin(fix: fix, capturedAt: 5))
        delivery.retry(capturedAt: 5)
        XCTAssertTrue(delivery.begin(fix: fix, capturedAt: 6))
        delivery.retry(capturedAt: 5)
        XCTAssertNil(delivery.sent(capturedAt: 5))
        XCTAssertTrue(delivery.isInFlight(6))
        XCTAssertEqual(delivery.sent(capturedAt: 6), fix)
    }

    func testGPSLatencyCountsOnlyMatchedPositionWritesWithinTheLock() {
        let start = Date(timeIntervalSince1970: 100)
        var ride = LockedRideMeasurement(started: start, uptime: 20)
        ride.recordFrame(captured: 20.1, sent: 20.2) // Logo.
        ride.recordFrame(captured: 20.3, sent: 20.4, fixTimestamp: start.addingTimeInterval(-1))
        XCTAssertNil(ride.meanPositionDelay)
        ride.recordFrame(captured: 21.1, sent: 21.3, fixTimestamp: start.addingTimeInterval(1))
        ride.recordFrame(captured: 22.4, sent: 22.5, fixTimestamp: start.addingTimeInterval(2))
        ride.finish(at: 23)
        ride.recordFrame(captured: 22.9, sent: 23.1, fixTimestamp: start.addingTimeInterval(2.8))
        XCTAssertEqual(ride.positionWrites, 2)
        XCTAssertEqual(ride.meanPositionDelay ?? -1, 0.4, accuracy: 0.000001)
    }

    func testLockedMeasurementRejectsOldFixesAndFramesAndIncludesPauses() {
        let start = Date()
        var ride = LockedRideMeasurement(started: start, uptime: 100)
        for delta in [-1.0, 1, 1, 2] { ride.recordFix(start.addingTimeInterval(delta)) }
        ride.recordFrame(captured: 99, sent: 101) // foreground frame completed after lock
        ride.recordFrame(captured: 103, sent: 104)
        ride.recordFrame(captured: 104.5, sent: 105)
        ride.finish(at: 116)
        ride.recordFrame(captured: 115, sent: 117) // completed after unlock
        XCTAssertEqual(ride.fixes, 2)
        XCTAssertEqual(ride.frames, 2)
        XCTAssertEqual(ride.longestSendGap, 11)
        XCTAssertEqual(ride.framesPerSecond, 2.0 / 16, accuracy: 1e-7)
    }

    func testLockWithNoImagesRecordsTheWholeInterruption() {
        var ride = LockedRideMeasurement(started: Date(), uptime: 10)
        ride.finish(at: 25)
        XCTAssertEqual(ride.frames, 0)
        XCTAssertEqual(ride.longestSendGap, 15)
        XCTAssertEqual(ride.framesPerSecond, 0)
    }

    func testOnlyTheTFTRendererKeepsReceivingRideUpdatesWhileLocked() {
        XCTAssertTrue(LockedRidePolicy.rendererMayUpdate(lockedTFTOnly: true, isTFT: true))
        XCTAssertFalse(LockedRidePolicy.rendererMayUpdate(lockedTFTOnly: true, isTFT: false))
        XCTAssertTrue(LockedRidePolicy.rendererMayUpdate(lockedTFTOnly: false, isTFT: true))
        XCTAssertTrue(LockedRidePolicy.rendererMayUpdate(lockedTFTOnly: false, isTFT: false))
    }

    func testLockRequiresRideAndTFTNotPhoneMirroring() {
        XCTAssertTrue(LockedRidePolicy.mayAttemptTFTMap(connected: true, foreground: false,
            cockpitVisible: true, phoneScreenSelected: false, enabled: true, rideActive: true))
        for connected in [false, true] {
            for foreground in [false, true] {
                for visible in [false, true] {
                    for selected in [false, true] {
                        for enabled in [false, true] {
                            for ride in [false, true] {
                                let expected = connected && !foreground && visible && !selected && enabled && ride
                                XCTAssertEqual(LockedRidePolicy.mayAttemptTFTMap(connected: connected,
                                    foreground: foreground, cockpitVisible: visible,
                                    phoneScreenSelected: selected, enabled: enabled, rideActive: ride), expected)
                            }
                        }
                    }
                }
            }
        }
    }

    func testProjectionSwitchesToBackgroundTFTRideOnlyWhenEligible() {
        XCTAssertEqual(ProjectionPolicy.dualPanelMode(connected: true, foreground: false,
            cockpitVisible: true, lockedRideEnabled: true, rideActive: true), .navigation)
        XCTAssertEqual(ProjectionPolicy.dualPanelMode(connected: true, foreground: true,
            cockpitVisible: true, lockedRideEnabled: true, rideActive: true), .screen)
        XCTAssertEqual(ProjectionPolicy.dualPanelMode(connected: true, foreground: false,
            cockpitVisible: true, lockedRideEnabled: true, rideActive: false), .paused)
        XCTAssertEqual(ProjectionPolicy.dualPanelMode(connected: true, foreground: false,
            cockpitVisible: true, lockedRideEnabled: false, rideActive: true), .paused)
        XCTAssertEqual(ProjectionPolicy.dualPanelMode(connected: true, foreground: false,
            cockpitVisible: true, phoneScreenSelected: true, broadcasting: true,
            lockedRideEnabled: true, rideActive: true), .broadcast)
    }
}
