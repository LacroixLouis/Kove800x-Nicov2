import Foundation
import XCTest
@testable import NicoMirrorConnection

final class GPXRouteGuidanceTests: XCTestCase {
    private func track(_ segments: [[(Double, Double)]]) -> GPXTrack {
        GPXTrack(name: "Essai", segments: segments.map { segment in
            segment.map { GPXPoint(latitude: $0.0, longitude: $0.1) }
        })
    }

    func testStraightTraceRemainingDistanceAndFinish() throws {
        let navigator = GPXRouteNavigator(track: track([[(0, 0), (0, 0.01)]]))
        let mid = try XCTUnwrap(navigator.guidance(at: GPXPoint(latitude: 0, longitude: 0.005)))
        XCTAssertEqual(mid.offTrackMeters, 0, accuracy: 0.5)
        XCTAssertEqual(mid.remainingMeters, 556, accuracy: 3)
        XCTAssertNil(mid.nextManeuver)
        XCTAssertFalse(mid.nearFinish)
        XCTAssertTrue(try XCTUnwrap(navigator.guidance(at: GPXPoint(latitude: 0, longitude: 0.01))).nearFinish)
    }

    func testLeftAndRightTurnsAreDetectedWithoutNetwork() throws {
        let left = GPXRouteNavigator(track: track([[(0, 0), (0, 0.001), (0.001, 0.001)]]))
        let right = GPXRouteNavigator(track: track([[(0, 0), (0.001, 0), (0.001, 0.001)]]))
        let l = try XCTUnwrap(left.guidance(at: GPXPoint(latitude: 0, longitude: 0.0005)))
        let r = try XCTUnwrap(right.guidance(at: GPXPoint(latitude: 0.0005, longitude: 0)))
        XCTAssertEqual(l.nextManeuver, .left)
        XCTAssertEqual(r.nextManeuver, .right)
        XCTAssertEqual(try XCTUnwrap(l.distanceToManeuverMeters), 55.6, accuracy: 3)
    }

    func testNoInventedTurnAcrossDisconnectedGPXSegments() throws {
        let navigator = GPXRouteNavigator(track: track([[(0, 0), (0, 0.001)], [(10, 10), (10, 10.001)]]))
        let start = try XCTUnwrap(navigator.guidance(at: GPXPoint(latitude: 0, longitude: 0)))
        XCTAssertNil(start.nextManeuver)
        XCTAssertEqual(start.totalMeters, 220.7, accuracy: 3)
    }

    func testOffTrackWarningAndGpsNoiseFilter() throws {
        let navigator = GPXRouteNavigator(track: track([[(0, 0), (0, 0.001), (0.00001, 0.00101), (0, 0.002)]]))
        let far = try XCTUnwrap(navigator.guidance(at: GPXPoint(latitude: 0.002, longitude: 0.0005)))
        XCTAssertTrue(far.offTrack)
        XCTAssertGreaterThan(far.offTrackMeters, 200)
        XCTAssertNil(far.nextManeuver)
    }

    func testReverseDirectionUsesOriginalGPXWithoutChangingIt() throws {
        let original = track([[(0, 0), (0, 0.001), (0.001, 0.001)]])
        let reversed = original.reversedForGuidance()
        let start = try XCTUnwrap(GPXRouteNavigator(track: reversed).guidance(at: GPXPoint(latitude: 0.0005, longitude: 0.001)))
        XCTAssertEqual(start.nextManeuver, .right)
        XCTAssertEqual(original.segments[0][0].longitude, 0)
        XCTAssertEqual(reversed.segments[0][0].latitude, 0.001)
    }

    func testDatelineDoesNotCreateCircumnavigation() throws {
        let navigator = GPXRouteNavigator(track: track([[(0, 179.999), (0, -179.999)]]))
        XCTAssertEqual(navigator.totalMeters, 222.4, accuracy: 2)
        let atDateLine = try XCTUnwrap(navigator.guidance(at: GPXPoint(latitude: 0, longitude: 180)))
        XCTAssertEqual(atDateLine.offTrackMeters, 0, accuracy: 2)
    }
}
