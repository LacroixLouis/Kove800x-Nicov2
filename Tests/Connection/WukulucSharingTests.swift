import XCTest
@testable import NicoMirrorConnection

final class WukulucSharingTests: XCTestCase {
    func testSharedGPXPreservesOriginalBytesAndWaypoints() throws {
        let xml = "<gpx><wpt lat='46' lon='5'><name>Bivouac</name></wpt><trk><trkseg><trkpt lat='46' lon='5'/><trkpt lat='46.01' lon='5.01'/></trkseg></trk></gpx>"
        let original = Data(xml.utf8)
        let payload = try JSONSerialization.data(withJSONObject: ["gpx_base64": original.base64EncodedString()])
        let document = try JSONDecoder().decode(WukulucSharedDocument.self, from: payload)
        XCTAssertEqual(try document.data(), original)
        XCTAssertEqual(try GPXTrack.parse(document.data(), fallbackName: "Partagé").pointCount, 2)
    }
    func testInvalidSharedBase64CannotBecomeAnImportedFile() throws {
        let payload = Data("{\"gpx_base64\":\"not valid base64!\"}".utf8)
        let document = try JSONDecoder().decode(WukulucSharedDocument.self, from: payload)
        XCTAssertThrowsError(try document.data())
    }
    func testOversizedSharedGPXIsRejectedBeforeImport() {
        let document = WukulucSharedDocument(gpx_base64: Data(repeating: 65, count: GPXTrack.byteLimit + 1).base64EncodedString())
        XCTAssertThrowsError(try document.data())
    }
    func testPublishedMetadataAllowsMissingAltitudeAndDuration() throws {
        let id = UUID(), owner = UUID()
        let payload: [String: Any] = ["id": id.uuidString, "owner_id": owner.uuidString,
            "name": "Piste du lac", "activity": "Moto trail", "distance_km": 12.5,
            "start_lat": 46, "start_lon": 5, "point_count": 120, "created_at": "2026-11-23T00:00:00Z"]
        let route = try JSONDecoder().decode(WukulucSharedRoute.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertNil(route.ascent_m)
        XCTAssertNil(route.duration_s)
        XCTAssertEqual(route.link.host, "trail")
        XCTAssertEqual(UUID(uuidString: route.link.lastPathComponent), id)
    }
}
