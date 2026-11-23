import XCTest
@testable import NicoMirrorConnection

final class TFTFrameRatePolicyTests: XCTestCase {
    func testWelcomeScreenWaitsForSuccessfulLogoWrite() {
        var splash = TFTStartupSplash()
        XCTAssertFalse(splash.shouldShow(at: 0))
        splash.arm()
        XCTAssertTrue(splash.shouldShow(at: 90))
        XCTAssertFalse(splash.acceptsFrame(at: 89))
        splash.submittedLogo(at: 90)
        splash.sentFrame(capturedAt: 89.9, sentAt: 91)
        splash.sentFrame(capturedAt: nil, sentAt: 92)
        XCTAssertNil(splash.deadline)
        XCTAssertTrue(splash.shouldShow(at: 120))
        splash.sentFrame(capturedAt: 90, sentAt: 121)
        splash.sentFrame(capturedAt: 122, sentAt: 122.2)
        XCTAssertTrue(splash.shouldShow(at: 123.999))
        XCTAssertFalse(splash.shouldShow(at: 124))
    }

    func testNewConnectionRejectsPreviousLogoAndRestartsWelcomeScreen() {
        var splash = TFTStartupSplash()
        splash.arm()
        splash.submittedLogo(at: 5)
        splash.sentFrame(capturedAt: 5, sentAt: 6)
        splash.arm()
        XCTAssertFalse(splash.acceptsFrame(at: 5))
        splash.submittedLogo(at: 40)
        splash.sentFrame(capturedAt: 5, sentAt: 41)
        XCTAssertNil(splash.deadline)
        XCTAssertTrue(splash.acceptsFrame(at: 40))
        splash.sentFrame(capturedAt: 40, sentAt: 42)
        XCTAssertEqual(splash.deadline, 45)
    }

    func testFastStreamTargetIsAtLeastTwelveFPS() {
        XCTAssertGreaterThanOrEqual(TFTFrameRatePolicy.targetFPS, 12)
        XCTAssertLessThanOrEqual(TFTFrameRatePolicy.targetFPS, 30)
    }

    func testTimerIntervalMatchesTheVideoEncoderTarget() {
        XCTAssertEqual(TFTFrameRatePolicy.timerInterval,
                       1.0 / Double(TFTFrameRatePolicy.targetFPS), accuracy: 0.000001)
    }

    func testNoFrameMeansZeroFPS() {
        XCTAssertEqual(TFTFrameRatePolicy.visibleFPS(measured: 15, lastCaptureUptime: nil,
                                                    nowUptime: 100), 0)
    }

    func testRecentStreamKeepsMeasuredFPS() {
        XCTAssertEqual(TFTFrameRatePolicy.visibleFPS(measured: 14.5, lastCaptureUptime: 98,
                                                    nowUptime: 100), 14.5)
    }

    func testStalledStreamNeverShowsStaleFPS() {
        XCTAssertEqual(TFTFrameRatePolicy.visibleFPS(measured: 15, lastCaptureUptime: 90,
                                                    nowUptime: 100), 0)
    }

    func testClockRollbackOrInvalidRateIsRejected() {
        XCTAssertEqual(TFTFrameRatePolicy.visibleFPS(measured: 15, lastCaptureUptime: 101,
                                                    nowUptime: 100), 0)
        XCTAssertEqual(TFTFrameRatePolicy.visibleFPS(measured: .nan, lastCaptureUptime: 100,
                                                    nowUptime: 100), 0)
    }

    func testSnapshotRecoveryAvoidsPermanentFreeze() {
        XCTAssertGreaterThan(TFTFrameRatePolicy.snapshotTimeout, TFTFrameRatePolicy.timerInterval)
        XCTAssertLessThanOrEqual(TFTFrameRatePolicy.snapshotTimeout, 10)
    }
}
