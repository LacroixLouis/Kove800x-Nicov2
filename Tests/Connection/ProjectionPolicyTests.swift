import Foundation
import XCTest
@testable import NicoMirrorConnection

final class ProjectionPolicyTests: XCTestCase {
    func testPhoneSharingRemainsTheSelectedSourceWhenOpeningAnotherApp() {
        for foreground in [false, true] {
            for visible in [false, true] {
                XCTAssertEqual(ProjectionPolicy.dualPanelMode(connected: true, foreground: foreground,
                    cockpitVisible: visible, phoneScreenSelected: true, broadcasting: true), .broadcast)
            }
        }
    }

    func testStoppingPhoneSharingNeverSubstitutesTheSavedMiniature() {
        for foreground in [false, true] {
            for visible in [false, true] {
                XCTAssertEqual(ProjectionPolicy.dualPanelMode(connected: true, foreground: foreground,
                    cockpitVisible: visible, phoneScreenSelected: true, broadcasting: false), .paused)
            }
        }
    }

    func testMiniatureModeDoesNotBroadcastTheWholePhoneWithoutSelection() {
        for broadcasting in [false, true] {
            XCTAssertEqual(ProjectionPolicy.dualPanelMode(connected: true, foreground: true,
                cockpitVisible: true, phoneScreenSelected: false, broadcasting: broadcasting), .screen)
            XCTAssertEqual(ProjectionPolicy.dualPanelMode(connected: true, foreground: false,
                cockpitVisible: true, phoneScreenSelected: false, broadcasting: broadcasting), .paused)
            XCTAssertEqual(ProjectionPolicy.dualPanelMode(connected: false, foreground: true,
                cockpitVisible: true, phoneScreenSelected: true, broadcasting: broadcasting), .disconnected)
        }
    }

    func testSelectedWindowPausesWhenTheBroadcastEndsInsteadOfSendingTheWholeApp() {
        for background in [false, true] {
            XCTAssertEqual(ProjectionPolicy.mode(connected: true, background: background,
                navigating: true, lockedModeEnabled: true, broadcasting: false,
                restrictToBroadcast: true), .paused)
            XCTAssertEqual(ProjectionPolicy.mode(connected: true, background: background,
                navigating: true, lockedModeEnabled: true, broadcasting: true,
                restrictToBroadcast: true), .broadcast)
        }
    }

    func testWindowCropDoesNotReplaceAnIndependentBuiltInTFT() {
        XCTAssertEqual(ProjectionPolicy.mode(connected: true, background: false,
            navigating: false, lockedModeEnabled: true, broadcasting: true,
            independentPanel: true, restrictToBroadcast: true), .navigation)
    }

    func testDisconnectedWinsOverEveryOtherCondition() {
        for background in [false, true] {
            for navigating in [false, true] {
                for enabled in [false, true] {
                    for broadcasting in [false, true] {
                        XCTAssertEqual(ProjectionPolicy.mode(connected: false, background: background,
                            navigating: navigating, lockedModeEnabled: enabled, broadcasting: broadcasting), .disconnected)
                    }
                }
            }
        }
    }

    func testBackgroundUsesNavigationOrPreservesExistingBroadcast() {
        for broadcasting in [false, true] {
            XCTAssertEqual(ProjectionPolicy.mode(connected: true, background: true, navigating: true,
                lockedModeEnabled: true, broadcasting: broadcasting), .navigation)
            XCTAssertEqual(ProjectionPolicy.mode(connected: true, background: true, navigating: false,
                lockedModeEnabled: true, broadcasting: broadcasting), broadcasting ? .broadcast : .paused)
            XCTAssertEqual(ProjectionPolicy.mode(connected: true, background: true, navigating: true,
                lockedModeEnabled: false, broadcasting: broadcasting), broadcasting ? .broadcast : .paused)
        }
    }

    func testLockStopNavigationUnlockAndDisconnectSequence() {
        let inputs: [(Bool, Bool, Bool, Bool, Bool)] = [
            (true, false, true, true, true),
            (true, true, true, true, true),
            (true, true, false, true, true),
            (true, false, false, true, false),
            (false, false, false, true, false)
        ]
        let modes = inputs.map { ProjectionPolicy.mode(connected: $0.0, background: $0.1,
            navigating: $0.2, lockedModeEnabled: $0.3, broadcasting: $0.4) }
        XCTAssertEqual(modes, [.broadcast, .navigation, .broadcast, .screen, .disconnected])
    }

    func testIndependentOutputDoesNotFollowPhoneForegroundOrBroadcast() {
        for background in [false, true] {
            for broadcasting in [false, true] {
                XCTAssertEqual(ProjectionPolicy.mode(connected: true, background: background, navigating: true,
                    lockedModeEnabled: false, broadcasting: broadcasting, independentNavigation: true), .navigation)
            }
        }
        XCTAssertEqual(ProjectionPolicy.mode(connected: false, background: false, navigating: true,
            lockedModeEnabled: true, broadcasting: false, independentNavigation: true), .disconnected)
        XCTAssertEqual(ProjectionPolicy.mode(connected: true, background: false, navigating: false,
            lockedModeEnabled: true, broadcasting: false, independentNavigation: true), .screen)
    }

    func testIndependentCockpitStaysOnTFTInForegroundAndBackgroundWithoutRoute() {
        for background in [false, true] {
            for broadcasting in [false, true] {
                XCTAssertEqual(ProjectionPolicy.mode(connected: true, background: background,
                    navigating: false, lockedModeEnabled: false, broadcasting: broadcasting,
                    independentPanel: true), .navigation)
            }
        }
    }

    func testExternalAppSelectionStillTakesPriorityOverOwnCockpit() {
        XCTAssertEqual(ProjectionPolicy.mode(connected: true, background: true, navigating: true,
            lockedModeEnabled: true, broadcasting: true, preferBroadcast: true,
            independentPanel: true), .broadcast)
        XCTAssertEqual(ProjectionPolicy.mode(connected: true, background: true, navigating: true,
            lockedModeEnabled: true, broadcasting: false, preferBroadcast: true,
            independentPanel: true), .paused)
        XCTAssertEqual(ProjectionPolicy.mode(connected: false, background: true, navigating: true,
            lockedModeEnabled: true, broadcasting: true, independentPanel: true), .disconnected)
    }

    func testGPSRejectsInvalidStaleAndFuturePositions() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(ProjectionPolicy.isFresh(timestamp: now, accuracy: 3, now: now))
        XCTAssertTrue(ProjectionPolicy.isFresh(timestamp: now.addingTimeInterval(-15), accuracy: 0, now: now))
        XCTAssertFalse(ProjectionPolicy.isFresh(timestamp: now.addingTimeInterval(-15.1), accuracy: 3, now: now))
        XCTAssertFalse(ProjectionPolicy.isFresh(timestamp: now.addingTimeInterval(6), accuracy: 3, now: now))
        XCTAssertFalse(ProjectionPolicy.isFresh(timestamp: now, accuracy: -1, now: now))
        XCTAssertFalse(ProjectionPolicy.isFresh(timestamp: now, accuracy: .nan, now: now))
    }

    func testExternalShortcutKeepsBroadcastWhileOurNavigationIsRunning() {
        for background in [false, true] {
            for independent in [false, true] {
                XCTAssertEqual(ProjectionPolicy.mode(connected: true, background: background,
                    navigating: true, lockedModeEnabled: true, broadcasting: true,
                    independentNavigation: independent, preferBroadcast: true), .broadcast)
            }
        }
    }

    func testExternalShortcutDoesNotFallBackToADifferentMapWhenBroadcastStops() {
        for background in [false, true] {
            XCTAssertEqual(ProjectionPolicy.mode(connected: true, background: background,
                navigating: true, lockedModeEnabled: true, broadcasting: false,
                independentNavigation: true, preferBroadcast: true), .paused)
        }
        XCTAssertEqual(ProjectionPolicy.mode(connected: false, background: true,
            navigating: true, lockedModeEnabled: true, broadcasting: true,
            independentNavigation: true, preferBroadcast: true), .disconnected)
    }
}
