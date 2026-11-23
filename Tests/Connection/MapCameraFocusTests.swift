import Foundation
import XCTest
@testable import NicoMirrorConnection

final class MapCameraFocusTests: XCTestCase {
    private let time = Date(timeIntervalSince1970: 100)

    func testHeadingUpdatesBetweenFixesOnlyFollowTheSelectedMapMode() {
        var camera = MapCameraFocus()
        for stage in [MapFocusStage.zoom, .northUp, .travelUp] {
            camera.request(.mode(stage))
            _ = camera.consume(time, navigating: true)
            XCTAssertNil(camera.consume(time, navigating: true))
            XCTAssertEqual(camera.followsCourse(navigating: true), stage == .travelUp)
        }
        camera.browse()
        XCTAssertFalse(camera.followsCourse(navigating: true))
        XCTAssertFalse(MapHeading.changed(from: 359.8, to: 0.1))
        XCTAssertTrue(MapHeading.changed(from: 359, to: 2))
    }

    func testGPSTurnsTakePriorityInMotionAndCompassRemainsLiveAtAStop() {
        var direction = TravelDirection()
        XCTAssertNil(direction.bearing(compass: nil, at: time))
        XCTAssertEqual(direction.bearing(compass: 90, at: time), 90)
        direction.update(course: 180, speed: 12, accuracy: 3, at: time)
        XCTAssertEqual(direction.bearing(compass: 90, at: time), 180)
        direction.update(course: 270, speed: 11, accuracy: 4, at: time)
        XCTAssertEqual(direction.bearing(compass: 90, at: time), 270)
        XCTAssertEqual(direction.bearing(compass: 30, at: time.addingTimeInterval(7)), 30)
        direction.update(course: -1, speed: 0, accuracy: 5, at: time)
        XCTAssertEqual(direction.bearing(compass: 20, at: time), 20)
        XCTAssertEqual(direction.bearing(compass: nil, at: time), 270)
    }

    func testWaitingTapsApplyZoomOnceThenNorthThenCourse() {
        var camera = MapCameraFocus()
        camera.request(.mode(camera.nextStage))
        camera.request(.mode(camera.nextStage))
        XCTAssertNil(camera.activeStage)
        XCTAssertEqual(camera.pending, .mode(.zoom))
        XCTAssertEqual(camera.consume(time, navigating: false), .init(stage: .zoom, resetDistance: true))
        XCTAssertNil(camera.consume(time, navigating: false))
        for stage in [MapFocusStage.northUp, .travelUp, .zoom] {
            camera.request(.mode(camera.nextStage))
            XCTAssertEqual(camera.consume(time, navigating: false)?.stage, stage)
        }
    }

    func testPanThenPositionReusesTheSameFixWithoutLosingCourseMode() {
        var camera = MapCameraFocus()
        camera.request(.mode(.travelUp))
        _ = camera.consume(time, navigating: true)
        camera.browse()
        XCTAssertNil(camera.activeStage)
        XCTAssertEqual(camera.nextStage, .zoom)
        let latest = time.addingTimeInterval(1)
        XCTAssertNil(camera.consume(latest, navigating: true))
        camera.request(.position)
        XCTAssertEqual(camera.consume(time, navigating: true), .init(stage: .travelUp, resetDistance: true))
        XCTAssertEqual(camera.consume(latest, navigating: true), .init(stage: .travelUp, resetDistance: false))
    }

    func testRouteOverviewCancelsAPendingRequestAndOtherPanelsStayIndependent() {
        var tracks = MapCameraFocus()
        var roads = MapCameraFocus()
        tracks.request(.mode(.zoom))
        roads.request(.mode(.northUp))
        tracks.browse()
        XCTAssertNil(tracks.consume(time, navigating: false))
        XCTAssertNil(tracks.pending)
        XCTAssertEqual(roads.consume(time, navigating: true)?.stage, .northUp)
        tracks.request(.mode(tracks.nextStage))
        XCTAssertEqual(tracks.consume(time, navigating: false)?.stage, .zoom)
        XCTAssertEqual(roads.activeStage, .northUp)
    }

    func testOlderCallbackCannotConsumeARequestOrRewindTheCamera() {
        var camera = MapCameraFocus()
        XCTAssertEqual(camera.consume(time, navigating: false)?.stage, .northUp)
        camera.request(.mode(.travelUp))
        XCTAssertNil(camera.consume(time.addingTimeInterval(-1), navigating: true))
        XCTAssertEqual(camera.pending, .mode(.travelUp))
        XCTAssertEqual(camera.consume(time, navigating: true)?.stage, .travelUp)
    }
}
