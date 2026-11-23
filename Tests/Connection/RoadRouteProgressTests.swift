import XCTest
@testable import NicoMirrorConnection

final class RoadRouteProgressTests: XCTestCase {
    func testTravelledDistanceFollowsRoadBendsNotStraightLine() throws {
        let points = [RoadRouteCoordinate(latitude: 45, longitude: 5),
                      RoadRouteCoordinate(latitude: 45, longitude: 5.01),
                      RoadRouteCoordinate(latitude: 45.01, longitude: 5.01)]
        let path = RoadRouteProgress(points)
        let atBend = try XCTUnwrap(path.project(points[1]))
        XCTAssertEqual(atBend.remainingMeters, 1112, accuracy: 10)
        XCTAssertEqual(atBend.deviationMeters, 0, accuracy: 1)
        XCTAssertGreaterThan(path.totalMeters, 1800)
        // Destination is only ~1.3 km away as the crow flies; the route is longer.
        XCTAssertGreaterThan(path.totalMeters, 1800)
    }

    func testProgressNormalizesToActualMapKitRouteLength() throws {
        let path = RoadRouteProgress([.init(latitude: 0, longitude: 0),
                                      .init(latitude: 0, longitude: 0.01)])
        let midpoint = try XCTUnwrap(path.project(.init(latitude: 0, longitude: 0.005)))
        XCTAssertEqual(path.remainingRoadMeters(at: midpoint, mapKitRouteMeters: 2000), 1000, accuracy: 3)
    }

    func testStepDistancesAndSkippingExpiredInstructions() {
        let cursor = RoadStepProgress(stepDistances: [0, 100, 200, 300])
        XCTAssertEqual(cursor.nextIndex(current: 0, travelledMeters: 0), 1)
        XCTAssertEqual(cursor.nextIndex(current: 1, travelledMeters: 285), 3)
        XCTAssertEqual(cursor.distanceToStepEnd(index: 1, travelledMeters: 50), 50, accuracy: 0.01)
        XCTAssertEqual(cursor.distanceToStepEnd(index: 1, travelledMeters: 250), 0, accuracy: 0.01)
    }

    func testBadGpsDoesNotProduceValidProjection() {
        let path = RoadRouteProgress([.init(latitude: 0, longitude: 0), .init(latitude: 0, longitude: 0.01)])
        XCTAssertNil(path.project(.init(latitude: 95, longitude: 0)))
        XCTAssertNil(path.project(.init(latitude: .nan, longitude: 0)))
    }

    func testDatelineCrossingIsShort() {
        let path = RoadRouteProgress([.init(latitude: 0, longitude: 179.999),
                                     .init(latitude: 0, longitude: -179.999)])
        XCTAssertEqual(path.totalMeters, 222.4, accuracy: 2)
        let location = path.project(.init(latitude: 0, longitude: 180))
        XCTAssertEqual(try XCTUnwrap(location).deviationMeters, 0, accuracy: 2)
    }

    func testOffRouteDeviationIsMeasured() throws {
        let path = RoadRouteProgress([.init(latitude: 45, longitude: 5), .init(latitude: 45, longitude: 5.01)])
        let off = try XCTUnwrap(path.project(.init(latitude: 45.002, longitude: 5.005)))
        XCTAssertGreaterThan(off.deviationMeters, 150)
    }
}
