import Foundation
import XCTest
@testable import NicoMirrorConnection

final class GPXTrackTests: XCTestCase {
    func testDistanceDoesNotBridgeRecordingGaps() throws {
        let track = try parse("<gpx><trk><trkseg><trkpt lat='0' lon='0'/><trkpt lat='0' lon='0.01'/></trkseg><trkseg><trkpt lat='30' lon='30'/><trkpt lat='30' lon='30.01'/></trkseg></trk></gpx>")
        XCTAssertEqual(track.distanceKilometers * 1000, 2074.9, accuracy: 2)
        XCTAssertEqual(track.segments.count, 2)
    }

    func testFileImportPreservesOriginalExtensionsAndUsesFilename() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gpx")
        defer { try? FileManager.default.removeItem(at: url) }
        let xml = "<gpx><wpt lat='0' lon='0'><name>Pause</name></wpt><trk><trkseg><trkpt lat='0' lon='0'/><trkpt lat='0' lon='0.01'/></trkseg><extensions><source>Wikiloc</source></extensions></trk></gpx>"
        let original = Data(xml.utf8)
        try original.write(to: url)
        let document = try GPXDocument.load(from: url)
        XCTAssertEqual(document.data, original)
        XCTAssertEqual(document.track.name, url.deletingPathExtension().lastPathComponent)
        XCTAssertEqual(document.track.pointCount, 2)
    }

    func testOversizedFileIsRejectedBeforeXMLParsing() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gpx")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0, count: GPXTrack.byteLimit + 1).write(to: url)
        XCTAssertThrowsError(try GPXDocument.load(from: url)) { error in
            switch error as? GPXError {
            case .tooLarge?: break
            default: XCTFail("Expected the file size limit, got \(error)")
            }
        }
    }


    private func parse(_ xml: String) throws -> GPXTrack {
        try GPXTrack.parse(Data(xml.utf8), fallbackName: "Wikiloc")
    }
    func testTrackSegmentsAreNotJoinedAcrossGaps() throws {
        let track = try parse("<gpx><trk><name>Pistes</name><trkseg><trkpt lat='0' lon='0'/><trkpt lat='0' lon='0.001'/></trkseg><trkseg><trkpt lat='0' lon='1'/><trkpt lat='0' lon='1.001'/></trkseg></trk></gpx>")
        XCTAssertEqual(track.name, "Pistes")
        XCTAssertEqual(track.segments.count, 2)
        XCTAssertGreaterThan(track.distanceFromTrace(to: GPXPoint(latitude: 0, longitude: 0.5)), 50_000)
    }
    func testDistanceUsesSegmentRatherThanClosestVertex() throws {
        let track = try parse("<gpx><rte><rtept lat='0' lon='0'/><rtept lat='0' lon='0.01'/></rte></gpx>")
        XCTAssertEqual(track.distanceFromTrace(to: GPXPoint(latitude: 0.001, longitude: 0.005)), 111.2, accuracy: 1)
    }
    func testWaypointsAloneAreNotAnOrderedTrace() {
        XCTAssertThrowsError(try parse("<gpx><wpt lat='1' lon='1'/><wpt lat='2' lon='2'/></gpx>"))
    }
    func testInvalidCoordinatesAndMalformedXMLFail() {
        for xml in ["<gpx>", "<gpx><trk><trkseg><trkpt lat='nan' lon='0'/></trkseg></trk></gpx>", "<gpx><rte><rtept lat='91' lon='0'/></rte></gpx>"] {
            XCTAssertThrowsError(try parse(xml))
        }
    }
    func testNamespacedTrackAndRouteFallback() throws {
        let track = try parse("<g:gpx xmlns:g='http://www.topografix.com/GPX/1/1'><g:rte><g:rtept lat='1' lon='1'/><g:rtept lat='2' lon='2'/></g:rte></g:gpx>")
        XCTAssertEqual(track.name, "Wikiloc")
        XCTAssertEqual(track.pointCount, 2)
    }
    func testTrackWinsOverRoute() throws {
        let track = try parse("<gpx><rte><rtept lat='1' lon='1'/><rtept lat='2' lon='2'/></rte><trk><trkseg><trkpt lat='3' lon='3'/><trkpt lat='4' lon='4'/></trkseg></trk></gpx>")
        XCTAssertEqual(track.segments[0][0].latitude, 3)
    }

    func testUsableRouteWinsOverAnEmptyTrackAndKeepsItsName() throws {
        let track = try parse("<gpx><trk><name>Vide</name><trkseg/></trk><rte><name>Col</name><rtept lat='1' lon='1'/><rtept lat='2' lon='2'/></rte></gpx>")
        XCTAssertEqual(track.name, "Col")
        XCTAssertEqual(track.pointCount, 2)
    }

    func testTrackKeepsItsNameAndIgnoresExtensionElevation() throws {
        let track = try parse("""
        <gpx><rte><name>Autre</name></rte><trk><name>Crête</name><trkseg>
        <trkpt lat='1' lon='1'><ele>20</ele><time>2026-11-20T10:00:00.125Z</time><extensions><ele>999</ele></extensions></trkpt>
        <trkpt lat='2' lon='2'><time>2026-11-20T10:00:01.125Z</time></trkpt></trkseg></trk></gpx>
        """)
        XCTAssertEqual(track.name, "Crête")
        XCTAssertEqual(track.segments.first?.first?.elevation, 20)
        XCTAssertEqual(try XCTUnwrap(track.recordedDuration), 1, accuracy: 0.001)
    }
    func testPointBudgetIsEnforced() {
        let points = String(repeating: "<trkpt lat='0' lon='0'/>", count: 30_001)
        XCTAssertThrowsError(try parse("<gpx><trk><trkseg>" + points + "</trkseg></trk></gpx>"))
    }

    func testElevationAndTimeStatisticsAreReadFromGPX() throws {
        let track = try parse("""
        <gpx><trk><trkseg>
          <trkpt lat='45' lon='5'><ele>100</ele><time>2026-11-20T10:00:00Z</time></trkpt>
          <trkpt lat='45.001' lon='5.001'><ele>145</ele><time>2026-11-20T10:10:00Z</time></trkpt>
          <trkpt lat='45.002' lon='5.002'><ele>130</ele><time>2026-11-20T10:20:00Z</time></trkpt>
        </trkseg></trk></gpx>
        """)
        XCTAssertEqual(track.elevationGainMeters, 45, accuracy: 0.1)
        let range = try XCTUnwrap(track.elevationRange)
        XCTAssertEqual(range.lowerBound, 100)
        XCTAssertEqual(range.upperBound, 145)
        XCTAssertEqual(try XCTUnwrap(track.recordedDuration), 1_200, accuracy: 0.1)
    }
}
