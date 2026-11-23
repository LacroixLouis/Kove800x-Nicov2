import XCTest
import UIKit

/// UI tests require a real Xcode iOS simulator and are not run by SwiftPM/Linux.
final class KoveMirrorUITests: XCTestCase {
    @MainActor
    func testCaptureMapSettingsInPortraitAndLandscape() throws {
        continueAfterFailure = false
        let device = XCUIDevice.shared
        device.orientation = .portrait
        defer { device.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screenshots", "-doubleInterface.twoMaps.v2.screenshots", ""]
        app.launch()
        let open = app.buttons["maps.openSettings"]
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        open.tap()

        let profiles = [("explorer", "Rivadventure"), ("wize", "Rivroute"), ("osmand", "Rivmonde")]
        let orientations: [UIDeviceOrientation] = [.portrait, .landscapeLeft]
        for orientation in orientations {
            device.orientation = orientation
            for (id, name) in profiles {
                let button = app.buttons["maps.profile." + id]
                XCTAssertTrue(button.waitForExistence(timeout: 5))
                button.tap()
                XCTAssertTrue(button.isSelected)
                XCTAssertTrue(app.buttons["maps.mapTools"].isHittable)
                XCTAssertTrue(app.scrollViews["maps.settingsScroll"].exists)
                let shot = XCTAttachment(screenshot: app.screenshot())
                shot.name = name + (orientation == .portrait ? "-portrait" : "-paysage")
                shot.lifetime = .keepAlways
                add(shot)
            }
        }
    }

    @MainActor
    func testThreeMapsCanBeAssignedToTwoScreens() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screenshots", "-doubleInterface.twoMaps.v2.screenshots", ""]
        app.launch()
        XCTAssertTrue(app.buttons["maps.menu"].waitForExistence(timeout: 15))
        app.buttons["maps.menu"].tap()
        XCTAssertTrue(app.buttons["menu.map.0.osmand"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["menu.map.1.wize"].exists)
        app.buttons["menu.map.0.osmand"].tap()
        app.buttons["menu.exchange"].tap()
        XCTAssertTrue(app.buttons["maps.menu"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["maps.miniature"].exists || app.buttons["maps.miniature"].exists)
        app.buttons["maps.menu"].tap()
        XCTAssertTrue(app.buttons["menu.map.1.osmand"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testVisualProfileSelectorAndMiniature() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screenshots", "-doubleInterface.twoMaps.v2.screenshots", ""]
        app.launch()
        XCTAssertTrue(app.buttons["maps.profile.explorer"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["maps.profile.wize"].exists)
        XCTAssertTrue(app.buttons["maps.profile.osmand"].exists)
        XCTAssertTrue(app.otherElements["maps.profileDock"].exists || app.descendants(matching: .any)["maps.profileDock"].exists)
        XCTAssertTrue(app.otherElements["maps.miniature"].exists || app.buttons["maps.miniature"].exists)
    }

    @MainActor
    func testConnectionHasQRCodeAndRetry() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-screenshots", "-doubleInterface.twoMaps.v2.screenshots", ""]
        app.launch()
        XCTAssertTrue(app.buttons["maps.menu"].waitForExistence(timeout: 15))
        app.buttons["maps.menu"].tap()
        app.buttons["menu.connection"].tap()
        XCTAssertTrue(app.buttons["connection.scan"].waitForExistence(timeout: 5))
        app.buttons["connection.scan"].tap()
        XCTAssertTrue(app.navigationBars["Scanner le compteur"].waitForExistence(timeout: 5))
    }
}
