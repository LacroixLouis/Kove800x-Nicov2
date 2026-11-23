import Foundation
import XCTest
@testable import NicoMirrorConnection

final class NewlinePacketBufferTests: XCTestCase {
    func testFragmentedPacketWaitsForDelimiter() throws {
        var buffer = NewlinePacketBuffer()
        XCTAssertTrue(try buffer.append(Data("{\"width\":".utf8)).isEmpty)
        XCTAssertEqual(try buffer.append(Data("600}\n".utf8)), [Data("{\"width\":600}".utf8)])
    }

    func testCombinedPacketsAndTrailingPartialPacket() throws {
        var buffer = NewlinePacketBuffer()
        XCTAssertEqual(try buffer.append(Data("first\nsecond\nthi".utf8)), [Data("first".utf8), Data("second".utf8)])
        XCTAssertEqual(try buffer.append(Data("rd\n".utf8)), [Data("third".utf8)])
    }

    func testEmptyLinesAreIgnored() throws {
        var buffer = NewlinePacketBuffer()
        XCTAssertEqual(try buffer.append(Data("\n\nconfig\n\n".utf8)), [Data("config".utf8)])
    }

    func testPacketLimitPreventsUnboundedAccumulation() throws {
        var buffer = NewlinePacketBuffer(maximumPacketBytes: 4)
        XCTAssertTrue(try buffer.append(Data("1234".utf8)).isEmpty)
        XCTAssertThrowsError(try buffer.append(Data("5".utf8)))
        XCTAssertEqual(try buffer.append(Data("ok\n".utf8)), [Data("ok".utf8)])
    }
}
