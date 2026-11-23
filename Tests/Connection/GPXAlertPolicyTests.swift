import XCTest
@testable import NicoMirrorConnection

final class GPXAlertPolicyTests: XCTestCase {
    func testOnlyOneAlertWhileOutsideTrack() {
        var policy = GPXAlertPolicy()
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(policy.shouldAnnounce(deviationMeters: 100, gpsAccuracyMeters: 8, now: start))
        XCTAssertFalse(policy.shouldAnnounce(deviationMeters: 110, gpsAccuracyMeters: 8, now: start.addingTimeInterval(121)))
    }

    func testAlertsAgainAfterReturningAndLaterDeparting() {
        var policy = GPXAlertPolicy()
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(policy.shouldAnnounce(deviationMeters: 110, gpsAccuracyMeters: 10, now: start))
        XCTAssertFalse(policy.shouldAnnounce(deviationMeters: 25, gpsAccuracyMeters: 10, now: start.addingTimeInterval(30)))
        XCTAssertTrue(policy.shouldAnnounce(deviationMeters: 120, gpsAccuracyMeters: 10, now: start.addingTimeInterval(125)))
    }

    func testShortGpsNoiseOrBadAccuracyDoesNotWarn() {
        var policy = GPXAlertPolicy()
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(policy.shouldAnnounce(deviationMeters: 105, gpsAccuracyMeters: 100, now: start))
        XCTAssertFalse(policy.shouldAnnounce(deviationMeters: 70, gpsAccuracyMeters: 8, now: start))
        XCTAssertFalse(policy.shouldAnnounce(deviationMeters: .nan, gpsAccuracyMeters: 8, now: start))
        XCTAssertTrue(policy.shouldAnnounce(deviationMeters: 100, gpsAccuracyMeters: 8, now: start))
    }

    func testResetAllowsNewTraceAlert() {
        var policy = GPXAlertPolicy()
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(policy.shouldAnnounce(deviationMeters: 100, gpsAccuracyMeters: 8, now: start))
        policy.reset()
        XCTAssertTrue(policy.shouldAnnounce(deviationMeters: 100, gpsAccuracyMeters: 8, now: start.addingTimeInterval(1)))
    }
}
