import Testing
import Foundation
import CoreVideo
import ImageIO
@testable import KoveMirror

@MainActor
struct FrameLetterboxerTests {
    private func testImage() throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 32, 64, kCVPixelFormatType_32BGRA,
                                        attributes as CFDictionary, &result)
        #expect(status == kCVReturnSuccess)
        let buffer = try #require(result)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let address = try #require(CVPixelBufferGetBaseAddress(buffer))
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = address.assumingMemoryBound(to: UInt8.self)
        for y in 0..<64 {
            for x in 0..<32 {
                let index = y * stride + x * 4
                bytes[index] = y < 32 ? 0 : 255
                bytes[index + 1] = 0
                bytes[index + 2] = y < 32 ? 255 : 0
                bytes[index + 3] = 255
            }
        }
        return buffer
    }

    @Test func selectedTopHalfBecomesTheWholeTFTImage() throws {
        let source = try testImage()
        let crop = try #require(ScreenCrop(left: 0, top: 0, width: 1, height: 0.5))
        let output = try #require(FrameLetterboxer().letterbox(pixelBuffer: source,
            targetWidth: 60, targetHeight: 100, topPadding: 0, bottomPadding: 0, framing: .window(crop)))
        #expect(CVPixelBufferGetWidth(output) == 60)
        #expect(CVPixelBufferGetHeight(output) == 100)
        CVPixelBufferLockBaseAddress(output, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        let address = try #require(CVPixelBufferGetBaseAddress(output))
        let bytes = address.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(output)
        for y in [10, 50, 90] {
            let index = y * stride + 30 * 4
            #expect(bytes[index + 2] > 240)
            #expect(bytes[index] < 15)
        }
    }

    @Test func invalidFramingAndRotationNeverReturnAnUncroppedBuffer() throws {
        let source = try testImage()
        let renderer = FrameLetterboxer()
        #expect(renderer.letterbox(pixelBuffer: source, targetWidth: 60, targetHeight: 100,
            topPadding: 0, bottomPadding: 0, framing: .invalid) == nil)
        let crop = try #require(ScreenCrop(left: 0, top: 0, width: 0.5, height: 0.5))
        #expect(renderer.letterbox(pixelBuffer: source, targetWidth: 60, targetHeight: 100,
            topPadding: 0, bottomPadding: 0, framing: .window(crop), orientation: .right) == nil)
    }

    @Test func uprightLandscapeCropUsesTheRotatedSourceGeometry() throws {
        let source = try testImage()
        let crop = try #require(ScreenCrop(left: 0, top: 0, width: 0.5, height: 0.5,
                                           orientation: .landscape))
        let output = FrameLetterboxer().letterbox(pixelBuffer: source, targetWidth: 60,
            targetHeight: 100, topPadding: 0, bottomPadding: 0, framing: .window(crop), orientation: .right)
        #expect(output != nil)
    }
}
