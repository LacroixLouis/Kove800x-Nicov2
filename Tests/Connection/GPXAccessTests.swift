import XCTest
@testable import NicoMirrorConnection

final class GPXAccessTests: XCTestCase {
    private func track(_ segments: [[(Double, Double)]]) -> GPXTrack {
        GPXTrack(name: "Accès", segments: segments.map { $0.map { GPXPoint(latitude: $0.0, longitude: $0.1) } })
    }

    func testNearestPointProjectsOntoSparseGPXInsteadOfChoosingAVertex() throws {
        let route = track([[(0, 0), (0, 0.02)]])
        let target = try XCTUnwrap(GPXAccessTargetPlanner.target(track: route, mode: .nearest, reversed: false,
            from: GPXPoint(latitude: 0.001, longitude: 0.01)))
        XCTAssertEqual(target.point.latitude, 0, accuracy: 0.000001)
        XCTAssertEqual(target.point.longitude, 0.01, accuracy: 0.000001)
        XCTAssertEqual(target.distanceMeters, 111.2, accuracy: 2)
        XCTAssertEqual(target.progressMeters, 1112, accuracy: 3)
    }

    func testStartHonorsTheSelectedGPXDirectionWithoutChangingOriginal() throws {
        let route = track([[(46, 5), (46.1, 5.2)], [(46.2, 5.3), (46.3, 5.4)]])
        let origin = GPXPoint(latitude: 46, longitude: 5)
        let outward = try XCTUnwrap(GPXAccessTargetPlanner.target(track: route, mode: .start, reversed: false, from: origin))
        let returning = try XCTUnwrap(GPXAccessTargetPlanner.target(track: route, mode: .start, reversed: true, from: origin))
        XCTAssertEqual(outward.point, route.segments[0][0])
        XCTAssertEqual(returning.point, route.segments[1][1])
        XCTAssertEqual(route.segments[0][0], origin)
    }

    func testDisconnectedSegmentsDoNotCreateAnAccessPointInsideAGap() throws {
        let route = track([[(0, 0), (0, 0.001)], [(0, 1), (0, 1.001)]])
        let target = try XCTUnwrap(GPXAccessTargetPlanner.target(track: route, mode: .nearest, reversed: false,
            from: GPXPoint(latitude: 0, longitude: 0.5)))
        XCTAssertEqual(target.point.longitude, 0.001, accuracy: 0.000001)
        XCTAssertGreaterThan(target.distanceMeters, 50_000)
        XCTAssertLessThan(target.progressMeters, 120)
    }

    func testDatelineKeepsTheNearestPointOnTheActualCrossing() throws {
        let route = track([[(0, 179.99), (0, -179.99)]])
        let target = try XCTUnwrap(GPXAccessTargetPlanner.target(track: route, mode: .nearest, reversed: false,
            from: GPXPoint(latitude: 0.001, longitude: 180)))
        XCTAssertEqual(abs(target.point.longitude), 180, accuracy: 0.000001)
        XCTAssertEqual(target.distanceMeters, 111.2, accuracy: 2)
        XCTAssertEqual(target.progressMeters, 1112, accuracy: 3)
    }

    func testInvalidOrEmptyPositionsDoNotCreateRoutes() {
        let route = track([[(0, 0), (0, 0.01)]])
        XCTAssertNil(GPXAccessTargetPlanner.target(track: route, mode: .nearest, reversed: false,
            from: GPXPoint(latitude: .nan, longitude: 0)))
        XCTAssertNil(GPXAccessTargetPlanner.target(track: track([]), mode: .start, reversed: false,
            from: GPXPoint(latitude: 0, longitude: 0)))
    }

    func testRetracedSectionsKeepTheChosenJoinProgressAtHandoff() throws {
        let route = track([[(0, 0), (0, 0.01), (0, 0.02), (0, 0.01), (0, 0)]])
        let target = try XCTUnwrap(GPXAccessTargetPlanner.target(track: route, mode: .nearest, reversed: false,
            from: GPXPoint(latitude: 0.001, longitude: 0.015), previousMeters: 2800))
        XCTAssertGreaterThan(target.progressMeters, 2000)
        let guide = try XCTUnwrap(GPXRouteNavigator(track: route).guidance(at: target.point, previousMeters: target.progressMeters))
        XCTAssertEqual(guide.travelledMeters, target.progressMeters, accuracy: 3)
    }

    func testGeographicProximityAloneCannotFinishALoopingAccessRoute() {
        XCTAssertFalse(GPXAccessArrivalPolicy.canHandoff(targetDistance: 5, routeRemaining: 12_000, accuracy: 5))
        XCTAssertFalse(GPXAccessArrivalPolicy.canHandoff(targetDistance: 150, routeRemaining: 0, accuracy: 5))
        XCTAssertFalse(GPXAccessArrivalPolicy.canHandoff(targetDistance: 10, routeRemaining: 5, accuracy: 90))
        XCTAssertTrue(GPXAccessArrivalPolicy.canHandoff(targetDistance: 12, routeRemaining: 10, accuracy: 5))
        XCTAssertFalse(GPXAccessArrivalPolicy.canHandoff(targetDistance: 0, routeRemaining: 0, accuracy: -1))
    }
}
