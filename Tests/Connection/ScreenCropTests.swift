import Foundation
import XCTest
@testable import NicoMirrorConnection

final class ScreenCropTests: XCTestCase {
    func testTopRightRegionUsesTopLeftPhoneCoordinates() throws {
        let crop = try XCTUnwrap(ScreenCrop(left: 0.5, top: 0, width: 0.5, height: 0.25))
        let bounds = try XCTUnwrap(crop.pixelBounds(sourceWidth: 1200, sourceHeight: 2400))
        XCTAssertEqual(bounds.left, 600)
        XCTAssertEqual(bounds.top, 0)
        XCTAssertEqual(bounds.width, 600)
        XCTAssertEqual(bounds.height, 600)
        XCTAssertEqual(bounds.bottomOriginY, 1800)
    }

    func testBottomRegionIsConvertedToCoreImageBottomOrigin() throws {
        let crop = try XCTUnwrap(ScreenCrop(left: 0, top: 0.75, width: 1, height: 0.25))
        let bounds = try XCTUnwrap(crop.pixelBounds(sourceWidth: 1200, sourceHeight: 2400))
        XCTAssertEqual(bounds.top, 1800)
        XCTAssertEqual(bounds.bottomOriginY, 0)
    }

    func testRoundingNeverExpandsSelectedRegion() throws {
        let crop = try XCTUnwrap(ScreenCrop(left: 0.101, top: 0.203, width: 0.401, height: 0.301))
        let bounds = try XCTUnwrap(crop.pixelBounds(sourceWidth: 1179, sourceHeight: 2556))
        XCTAssertGreaterThanOrEqual(Double(bounds.left), crop.left * 1179)
        XCTAssertGreaterThanOrEqual(Double(bounds.top), crop.top * 2556)
        XCTAssertLessThanOrEqual(Double(bounds.left + bounds.width), (crop.left + crop.width) * 1179)
        XCTAssertLessThanOrEqual(Double(bounds.top + bounds.height), (crop.top + crop.height) * 2556)
    }

    func testAllRegionsStayWithinDifferentPhoneSizes() throws {
        for w in [750, 1179, 1320] {
            for step in 0..<10 {
                let left = Double(step) / 20
                let crop = try XCTUnwrap(ScreenCrop(left: left, top: left, width: 0.5, height: 0.5))
                let bounds = try XCTUnwrap(crop.pixelBounds(sourceWidth: w, sourceHeight: w * 2))
                XCTAssertGreaterThan(bounds.width, 0)
                XCTAssertGreaterThan(bounds.height, 0)
                XCTAssertLessThanOrEqual(bounds.left + bounds.width, w)
                XCTAssertLessThanOrEqual(bounds.top + bounds.height, w * 2)
                XCTAssertEqual(bounds.bottomOriginY, w * 2 - bounds.top - bounds.height)
            }
        }
    }

    func testRotationRequiresAnExplicitNewCrop() throws {
        let portrait = try XCTUnwrap(ScreenCrop(left: 0, top: 0, width: 0.5, height: 0.5))
        XCTAssertNil(portrait.pixelBounds(sourceWidth: 2400, sourceHeight: 1200))
        let landscape = try XCTUnwrap(ScreenCrop(left: 0, top: 0, width: 0.5, height: 0.5,
                                                orientation: .landscape))
        XCTAssertNotNil(landscape.pixelBounds(sourceWidth: 2400, sourceHeight: 1200))
        XCTAssertNil(landscape.pixelBounds(sourceWidth: 1200, sourceHeight: 2400))
    }

    func testInvalidOrEmptyDimensionsAreRejected() {
        XCTAssertNil(ScreenCrop(left: -0.1, top: 0, width: 0.5, height: 0.5))
        XCTAssertNil(ScreenCrop(left: 0.8, top: 0, width: 0.5, height: 0.5))
        XCTAssertNil(ScreenCrop(left: 0, top: 0, width: 0, height: 0.5))
        for bad in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(ScreenCrop(left: bad, top: 0, width: 0.5, height: 0.5))
            XCTAssertNil(ScreenCrop(left: 0, top: bad, width: 0.5, height: 0.5))
            XCTAssertNil(ScreenCrop(left: 0, top: 0, width: bad, height: 0.5))
        }
    }

    func testEdgeCoordinatesTolerateFloatingPointRounding() throws {
        let crop = try XCTUnwrap(ScreenCrop(left: 0.2, top: 0.2, width: 0.8, height: 0.8))
        XCTAssertLessThanOrEqual(crop.left + crop.width, 1)
        XCTAssertNotNil(crop.pixelBounds(sourceWidth: 1000, sourceHeight: 2000))
    }

    func testSubpixelAndInvalidSourceSizesAreRejected() throws {
        let crop = try XCTUnwrap(ScreenCrop(left: 0.001, top: 0.001, width: 0.001, height: 0.001))
        XCTAssertNil(crop.pixelBounds(sourceWidth: 10, sourceHeight: 20))
        XCTAssertNil(crop.pixelBounds(sourceWidth: 0, sourceHeight: 100))
        XCTAssertNil(crop.pixelBounds(sourceWidth: 1, sourceHeight: 1000000))
    }

    func testSavedWindowRoundTripsWithoutEnablingFullScreen() throws {
        let crop = try XCTUnwrap(ScreenCrop(left: 0.5, top: 0.1, width: 0.4, height: 0.25))
        let setting = BroadcastFraming.window(crop)
        XCTAssertEqual(BroadcastFraming.load(setting.serialized), setting)
        XCTAssertTrue(setting.requiresBroadcast)
        XCTAssertEqual(BroadcastFraming.load(nil), .fullScreen)
        XCTAssertEqual(BroadcastFraming.load(BroadcastFraming.fullScreen.serialized), .fullScreen)
    }

    func testCorruptConfigurationNeverFallsBackToFullScreen() {
        let invalid = ["", "{}", "invalid", "{\"mode\":\"window\"}",
            "{\"mode\":\"unknown\"}",
            "{\"mode\":\"window\",\"crop\":{\"left\":0.8,\"top\":0,\"width\":0.5,\"height\":0.5,\"orientation\":\"portrait\"}}"]
        for raw in invalid {
            let setting = BroadcastFraming.load(raw)
            XCTAssertEqual(setting, .invalid)
            XCTAssertTrue(setting.requiresBroadcast)
            XCTAssertNil(setting.serialized)
        }
    }
}
