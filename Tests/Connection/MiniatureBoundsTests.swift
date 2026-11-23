import XCTest
@testable import NicoMirrorConnection

final class MiniatureBoundsTests: XCTestCase {
    func testAllCornersReachableWithoutToolbarDeadZones() {
        let area = MiniatureBounds(containerWidth: 390, containerHeight: 844,
                                   miniatureWidth: 100, miniatureHeight: 170)
        let topLeft = area.center(normalizedX: 0, normalizedY: 0)
        let bottomRight = area.center(normalizedX: 1, normalizedY: 1)
        XCTAssertEqual(topLeft.x, 52, accuracy: 0.01)
        XCTAssertEqual(topLeft.y, 87, accuracy: 0.01)
        XCTAssertEqual(bottomRight.x, 338, accuracy: 0.01)
        XCTAssertEqual(bottomRight.y, 757, accuracy: 0.01)
    }

    func testNormalizedPositionClampsToPhysicalScreen() {
        let area = MiniatureBounds(containerWidth: 390, containerHeight: 844,
                                   miniatureWidth: 100, miniatureHeight: 170)
        let p = area.center(normalizedX: 10, normalizedY: -10)
        XCTAssertEqual(p.x, area.right, accuracy: 0.01)
        XCTAssertEqual(p.y, area.top, accuracy: 0.01)
    }

    func testNoCrashWhenPreviewExceedsContainer() {
        let area = MiniatureBounds(containerWidth: 100, containerHeight: 80,
                                   miniatureWidth: 120, miniatureHeight: 160)
        XCTAssertEqual(area.left, area.right)
        XCTAssertEqual(area.top, area.bottom)
    }
}
