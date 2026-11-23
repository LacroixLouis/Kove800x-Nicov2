import Foundation
import XCTest
@testable import NicoMirrorConnection

final class WebPanelLayoutTests: XCTestCase {
    func testProfileDisplayNamesDoNotChangeSavedIdentifiers() {
        XCTAssertEqual(WebMapProfile.explorer.title, "Rivadventure")
        XCTAssertEqual(WebMapProfile.wize.title, "Rivroute")
        XCTAssertEqual(WebMapProfile.osmand.title, "Rivmonde")
        XCTAssertEqual(WebMapProfile.osmand.rawValue, "osmand") // Maintain backwards-compatible settings.
    }

    func testTransparentMapNameIsExactlyTheChosenProfile() {
        XCTAssertEqual(WebMapProfile.explorer.overlayTitle, "RIVADVENTURE")
        XCTAssertEqual(WebMapProfile.wize.overlayTitle, "RIVROUTE")
        XCTAssertEqual(WebMapProfile.osmand.overlayTitle, "RIVMONDE")
        var layout = WebPanelLayout()
        layout.assign(.osmand, to: layout.tft)
        XCTAssertEqual(layout.profile(at: layout.tft).overlayTitle, "RIVMONDE")
        layout.exchange()
        XCTAssertEqual(layout.profile(at: layout.phone).overlayTitle, "RIVMONDE")
        XCTAssertEqual(layout.profile(at: layout.tft).overlayTitle, "RIVADVENTURE")
    }

    func testThreeMapProfilesHaveIndependentTwoScreenAssignments() {
        var layout = WebPanelLayout()
        XCTAssertEqual(layout.profile(at: layout.phone), .explorer)
        XCTAssertEqual(layout.profile(at: layout.tft), .wize)
        layout.assign(.osmand, to: layout.tft)
        XCTAssertEqual(layout.profile(at: layout.tft), .osmand)
        XCTAssertEqual(layout.profile(at: layout.phone), .explorer)
        layout.exchange()
        XCTAssertEqual(layout.profile(at: layout.phone), .osmand)
        XCTAssertEqual(layout.profile(at: layout.tft), .explorer)
    }

    func testTapSwapKeepsTwoDifferentMapsAndTheirAssignedProfiles() {
        var layout = WebPanelLayout()
        layout.assign(.osmand, to: layout.tft)
        let phoneBefore = layout.profile(at: layout.phone)
        let tftBefore = layout.profile(at: layout.tft)
        XCTAssertNotEqual(phoneBefore, tftBefore)

        // A tap exchanges positions, not renderers or map settings.
        layout.exchange()
        XCTAssertEqual(layout.profile(at: layout.phone), tftBefore)
        XCTAssertEqual(layout.profile(at: layout.tft), phoneBefore)
        XCTAssertNotEqual(layout.profile(at: layout.phone), layout.profile(at: layout.tft))

        // A second tap restores the initial positions.
        layout.exchange()
        XCTAssertEqual(layout.profile(at: layout.phone), phoneBefore)
        XCTAssertEqual(layout.profile(at: layout.tft), tftBefore)
    }

    func testAssignAlreadyVisibleMapSwapsAssignments() {
        var layout = WebPanelLayout()
        layout.assign(.wize, to: layout.phone)
        XCTAssertEqual(layout.profile(at: layout.phone), .wize)
        XCTAssertEqual(layout.profile(at: layout.tft), .explorer)
        XCTAssertNotEqual(layout.profile(at: layout.phone), layout.profile(at: layout.tft))
    }

    func testMigrateOldSavedLayoutWithoutLosingMiniature() throws {
        let old = #"{"phone":1,"miniX":0.3,"miniY":0.7}"#
        let layout = try JSONDecoder().decode(WebPanelLayout.self, from: Data(old.utf8))
        XCTAssertEqual(layout.phone, .second)
        XCTAssertEqual(layout.profile(at: layout.phone), .wize)
        XCTAssertEqual(layout.miniX, 0.3, accuracy: 0.00001)
        XCTAssertEqual(layout.miniY, 0.7, accuracy: 0.00001)
        let roundTrip = try JSONDecoder().decode(WebPanelLayout.self, from: JSONEncoder().encode(layout))
        XCTAssertEqual(roundTrip, layout)
    }

    func testCorruptedDuplicateProfileRecovers() throws {
        let broken = #"{"phone":0,"miniX":1.0,"miniY":1.0,"firstProfile":"osmand","secondProfile":"osmand"}"#
        let result = try JSONDecoder().decode(WebPanelLayout.self, from: Data(broken.utf8))
        XCTAssertNotEqual(result.profile(at: .first), result.profile(at: .second))
    }
}
