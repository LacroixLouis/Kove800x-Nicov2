import XCTest
@testable import NicoMirrorConnection

final class WizeTrafficTests: XCTestCase {
    private let configuration = TomTomTrafficConfiguration(apiKey: "test-key")
    private func incident(_ coordinates: String, type: String = "LineString", category: String = "accident") throws -> TomTomIncident {
        let text = """
        {"geometry":{"type":"\(type)","coordinates":\(coordinates)},"properties":{"id":"test","iconCategory":"\(category)","magnitudeOfDelay":"moderate","delayInSeconds":120}}
        """
        return try JSONDecoder().decode(TomTomIncident.self, from: Data(text.utf8))
    }
    func testKeyUsesHeaderAndCurrentAPI() throws {
        let request = try XCTUnwrap(configuration.tileRequest(layer: "flow", z: 12, x: 2044, y: 1360))
        XCTAssertEqual(request.value(forHTTPHeaderField: "TomTom-Api-Key"), "test-key")
        let url = try XCTUnwrap(request.url)
        XCTAssertFalse(url.absoluteString.contains("test-key"))
        XCTAssertTrue(url.query?.contains("apiVersion=2") == true)
    }
    func testUntrustedTileCoordinatesCannotOverflow() {
        XCTAssertNil(configuration.tileRequest(layer: "flow", z: Int.max, x: 0, y: 0))
        XCTAssertNil(configuration.tileRequest(layer: "flow", z: 2, x: -1, y: 0))
        XCTAssertNil(configuration.tileRequest(layer: "incidents", z: 2, x: 0, y: 4))
        XCTAssertNil(configuration.tileRequest(layer: "unknown", z: 2, x: 0, y: 0))
    }
    func testBothGeoJSONShapesAndCurrentDelayField() throws {
        let point = try incident("[5,46]", type: "Point")
        XCTAssertEqual(point.geometry.points.first, TrafficCoordinate(latitude: 46, longitude: 5))
        XCTAssertEqual(point.properties.delay, 120)
        let line = try incident("[[5,46],[5.01,46.01]]")
        XCTAssertEqual(line.geometry.points.count, 2)
    }
    func testMalformedGeoJSONIsFiltered() throws {
        let line = try incident("[[5,46],[999,46],[5],[5.01,46.01]]")
        XCTAssertEqual(line.geometry.points.count, 2)
    }
    func testOnlyUpcomingRouteIncidentsTrigger() throws {
        let route = TrafficRouteGeometry(points: [.init(latitude: 46,longitude: 5), .init(latitude: 46.1,longitude: 5)])
        let rider = TrafficCoordinate(latitude: 46.03, longitude: 5)
        XCTAssertNotNil(route.distanceAhead(to: try incident("[[5,46.04],[5,46.045]]"), from: rider))
        XCTAssertNil(route.distanceAhead(to: try incident("[[5,46.02],[5,46.025]]"), from: rider))
        XCTAssertNil(route.distanceAhead(to: try incident("[[5.1,46.04],[5.1,46.045]]"), from: rider))
        XCTAssertNil(route.distanceAhead(to: try incident("[[5,46.045],[5,46.04]]"), from: rider))
    }
    func testAlertDeduplicationAndCooldown() {
        var policy = TrafficAlertPolicy()
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(policy.accept(id: "a", now: now))
        XCTAssertFalse(policy.accept(id: "b", now: now.addingTimeInterval(10)))
        XCTAssertFalse(policy.accept(id: "a", now: now.addingTimeInterval(60)))
        XCTAssertTrue(policy.accept(id: "b", now: now.addingTimeInterval(60)))
        XCTAssertTrue(policy.accept(id: "a", now: now.addingTimeInterval(1_801)))
    }
    func testNegativeCoordinatesKeepCorrectRealtimeBucket() {
        let buckets = CommunityReport.neighboringBuckets(.init(latitude: -0.1,longitude: -0.1))
        XCTAssertEqual(Set(buckets).count, 9)
        XCTAssertTrue(buckets.contains("-1:-1"))
        XCTAssertTrue(buckets.contains("-2:-2"))
    }
    func testCommunityReportsDecodeServerResponse() throws {
        let kinds: [(String, CommunityReportKind)] = [
            ("accident", .accident), ("jam", .jam), ("roadworks", .roadworks),
            ("hazard", .hazard), ("danger_zone", .dangerZone)
        ]
        let id = UUID(uuidString: "F8114834-D5EB-4C2D-BD76-9A6558A42C79")!
        let payload: [[String: Any]] = kinds.map { kind in
            ["id": id.uuidString, "kind": kind.0,
             "latitude": 46.0, "longitude": 5.0, "bucket": "92:10",
             "created_at": "2026-11-22T22:00:00Z", "expires_at": "2026-11-23T00:00:00Z",
             "confirmations": 3, "dismissals": 0]
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        let reports = try JSONDecoder().decode([CommunityReport].self, from: data)
        XCTAssertEqual(reports.count, kinds.count)
        XCTAssertEqual(reports.map(\.kind), kinds.map { $0.1 })
        XCTAssertTrue(reports.allSatisfy { $0.id == id && $0.confirmations == 3 && $0.dismissals == 0 })
        XCTAssertEqual(reports.first?.point, TrafficCoordinate(latitude: 46, longitude: 5))
        XCTAssertEqual(reports.first?.expires, ISO8601DateFormatter().date(from: "2026-11-23T00:00:00Z"))
    }
    func testBackoffHonorsQuotaWithoutImmediateRetry() {
        XCTAssertEqual(TomTomTrafficConfiguration.retryDelay(status: 429, retryAfter: "120"),120)
        XCTAssertEqual(TomTomTrafficConfiguration.retryDelay(status: 429, retryAfter: "invalid"),60)
        XCTAssertEqual(TomTomTrafficConfiguration.retryDelay(status: 403, retryAfter: nil),300)
    }
}
