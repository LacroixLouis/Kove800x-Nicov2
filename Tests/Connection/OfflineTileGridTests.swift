import XCTest
@testable import NicoMirrorConnection

final class OfflineTileGridTests: XCTestCase {
    func testRidingScaleCannotMagnifyAWorldOverview() {
        let width = 268_435_456.0 * 600 / (256 * 65_536) // zoom 16 at 600 pixels
        let levels = OfflineTileGrid.rasterZooms(viewWidth: width, outputWidth: 600, minZoom: 0, maxZoom: 17)
        XCTAssertEqual(levels.first, 16)
        XCTAssertTrue(levels.contains(14))
        XCTAssertFalse(levels.contains(13))
        XCTAssertTrue(OfflineTileGrid.rasterZooms(viewWidth: width, outputWidth: 600,
                                                   minZoom: 0, maxZoom: 8).isEmpty)
        XCTAssertEqual(OfflineTileGrid.rasterZooms(viewWidth: width * 256, outputWidth: 600,
                                                   minZoom: 0, maxZoom: 8).first, 8)
    }

    func testTMSAndXYZRows() {
        XCTAssertEqual(OfflineTileGrid.sqliteRow(z: 3, xyzY: 2, schemeXYZ: false), 5)
        XCTAssertEqual(OfflineTileGrid.sqliteRow(z: 3, xyzY: 2, schemeXYZ: true), 2)
        XCTAssertEqual(OfflineTileGrid.sqliteRow(z: 0, xyzY: 0, schemeXYZ: false), 0)
        XCTAssertNil(OfflineTileGrid.sqliteRow(z: 2, xyzY: -1, schemeXYZ: false))
        XCTAssertNil(OfflineTileGrid.sqliteRow(z: 2, xyzY: 4, schemeXYZ: false))
        XCTAssertNil(OfflineTileGrid.sqliteRow(z: 33, xyzY: 0, schemeXYZ: false))
    }
    func testAViewportSelectsFiniteTiles() {
        let w = 268_435_456.0
        let rect = OfflineTileGrid(minWorldX: w / 2, maxWorldX: w / 2 + w / 64,
                                   minWorldY: w / 2, maxWorldY: w / 2 + w / 64,
                                   outputWidth: 512, minZoom: 0, maxZoom: 19)
        XCTAssertNotNil(rect)
        XCTAssertGreaterThan(rect!.tileCount, 0)
        XCTAssertLessThanOrEqual(rect!.tileCount, 1024)
    }
    func testExcessivelyZoomedOutMapDoesNotCauseUnboundedSQLiteQueries() {
        let w = 268_435_456.0
        let grid = OfflineTileGrid(minWorldX: 0, maxWorldX: w,
                                   minWorldY: 0, maxWorldY: w,
                                   outputWidth: 800, minZoom: 15, maxZoom: 18)
        XCTAssertNil(grid)
    }
    func testExactSingleTileWorldDoesNotRequestNeighbor() {
        let w = 268_435_456.0
        let grid = OfflineTileGrid(minWorldX: 0, maxWorldX: w / 4,
                                   minWorldY: 0, maxWorldY: w / 4,
                                   outputWidth: 256, minZoom: 2, maxZoom: 2)
        XCTAssertEqual(grid?.tileCount, 1)
        XCTAssertEqual(grid?.maxX, 0)
        XCTAssertEqual(grid?.maxY, 0)
    }
    func testInvalidCoordinatesAreRejected() {
        XCTAssertNil(OfflineTileGrid(minWorldX: 1, maxWorldX: 1,
                                     minWorldY: 0, maxWorldY: 1,
                                     outputWidth: 300, minZoom: 0, maxZoom: 18))
        XCTAssertNil(OfflineTileGrid(minWorldX: .nan, maxWorldX: 1,
                                     minWorldY: 0, maxWorldY: 1,
                                     outputWidth: 300, minZoom: 0, maxZoom: 18))
    }
}
