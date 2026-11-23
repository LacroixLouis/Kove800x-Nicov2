import XCTest
@testable import NicoMirrorConnection

final class MotorcycleWiFiCredentialsTests: XCTestCase {
    func testThinkerRideConnectionCode() throws {
        let result = try MotorcycleWiFiCredentials.parse("http://g.thinkerride.com/?CQKY_TEST&12345678&ap=1")
        XCTAssertEqual(result.ssid, "CQKY_TEST")
        XCTAssertEqual(result.password, "12345678")
    }

    func testEscapedDelimitersAreDecodedAfterSplitting() throws {
        let result = try MotorcycleWiFiCredentials.parse("https://g.thinkerride.com/?CQKY%20Rally&p%26ss%2Bword%3D&ap=1")
        XCTAssertEqual(result.ssid, "CQKY Rally")
        XCTAssertEqual(result.password, "p&ss+word=")
    }

    func testLiteralPlusAndPercentAreNotDecodedTwice() throws {
        let result = try MotorcycleWiFiCredentials.parse("http://g.thinkerride.com/?CQKY_TEST&pass+%2526word&ap=1")
        XCTAssertEqual(result.password, "pass+%26word")
    }

    func testStandardWiFiCodeEscaping() throws {
        let result = try MotorcycleWiFiCredentials.parse(#"WIFI:T:WPA;S:CQKY\;Rally;P:pass\;word123;;"#)
        XCTAssertEqual(result.ssid, "CQKY;Rally")
        XCTAssertEqual(result.password, "pass;word123")
    }

    func testNamedThinkerRideCode() throws {
        let result = try MotorcycleWiFiCredentials.parse("https://g.thinkerride.com/?SSID=CQKY_RALLY&pwd=12345678&ap=1")
        XCTAssertEqual(result.ssid, "CQKY_RALLY")
        XCTAssertEqual(result.password, "12345678")
    }

    func testThinkerRideCodeWithoutScheme() throws {
        let result = try MotorcycleWiFiCredentials.parse("g.thinkerride.com/?CQKY_TEST&12345678&ap=1")
        XCTAssertEqual(result.ssid, "CQKY_TEST")
    }

    func testQRCaseInsensitiveSecurity() throws {
        let result = try MotorcycleWiFiCredentials.parse("wifi:T:WPA2/WPA3;S:CQKY_TEST;P:12345678;;")
        XCTAssertEqual(result.password, "12345678")
    }

    func testOpenNetwork() throws {
        let result = try MotorcycleWiFiCredentials.parse("WIFI:T:nopass;S:CQKY_TEST;;")
        XCTAssertNil(result.password)
    }

    func testHiddenNetworkFlagSurvivesQRDecoding() throws {
        let hidden = try MotorcycleWiFiCredentials.parse("WIFI:T:WPA;S:KOVE;P:12345678;H:true;;")
        let visible = try MotorcycleWiFiCredentials.parse("https://g.thinkerride.com/?KOVE&12345678&ap=1")
        XCTAssertTrue(hidden.hidden)
        XCTAssertFalse(visible.hidden)
    }

    func testIncompleteNamedCodeIsRejectedInsteadOfBeingMisreadAsCredentials() {
        XCTAssertThrowsError(try MotorcycleWiFiCredentials.parse("https://g.thinkerride.com/?ssid=CQKY_TEST&ap=1"))
        XCTAssertThrowsError(try MotorcycleWiFiCredentials.parse("https://g.thinkerride.com/?pwd=12345678&ap=1"))
    }

    func testEachOfThreeMapsCanBeUsedOnEitherOfTwoScreens() {
        var layout = WebPanelLayout()
        XCTAssertEqual(layout.profile(at: layout.phone), .explorer)
        XCTAssertEqual(layout.profile(at: layout.tft), .wize)
        layout.assign(.osmand, to: layout.tft)
        XCTAssertEqual(layout.profile(at: layout.tft), .osmand)
        layout.exchange()
        XCTAssertEqual(layout.profile(at: layout.phone), .osmand)
        XCTAssertEqual(layout.profile(at: layout.tft), .explorer)
        layout.assign(.wize, to: layout.phone)
        XCTAssertEqual(layout.profile(at: layout.phone), .wize)
        XCTAssertEqual(layout.profile(at: layout.tft), .explorer)
    }

    func testDownloadAndUnrelatedCodesAreRejected() {
        for code in [
            "https://g.thinkerride.com/",
            "https://apps.apple.com/app/thinkerride/id123",
            "https://example.com/?CQKY_TEST&12345678&ap=1",
            "javascript:alert(1)",
            "http://g.thinkerride.com/?download"
        ] {
            XCTAssertThrowsError(try MotorcycleWiFiCredentials.parse(code), code)
        }
    }

    func testMalformedEscapesAndInvalidPasswordsAreRejected() {
        for code in [
            "http://g.thinkerride.com/?CQKY_TEST&pass%ZZword&ap=1",
            "http://g.thinkerride.com/?CQKY_TEST&short&ap=1",
            "http://g.thinkerride.com/?CQKY_TEST&12345678%0A&ap=1",
            "WIFI:T:WEP;S:CQKY_TEST;P:12345678;;",
            "WIFI:T:WPA;S:CQKY_TEST;P:12345678",
            "WIFI:T:WPA;S:;P:12345678;;",
            "WIFI:T:WPA;T:nopass;S:CQKY_TEST;P:12345678;;"
        ] {
            XCTAssertThrowsError(try MotorcycleWiFiCredentials.parse(code), code)
        }
    }

    func testSSIDByteLimit() {
        let tooLong = String(repeating: "é", count: 17).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        XCTAssertThrowsError(try MotorcycleWiFiCredentials.parse("http://g.thinkerride.com/?\(tooLong)&12345678&ap=1"))
    }
}
