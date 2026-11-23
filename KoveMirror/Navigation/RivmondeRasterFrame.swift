import MapKit
import UIKit

/// Screen coordinates are east-right and south-down before the map turns.
/// Fetch the bounding box of the rotated viewport so all four corners have tiles.
nonisolated struct TFTMapViewport {
    let sourceSize: CGSize
    let sourceRect: MKMapRect
    let sourceToScreen: CGAffineTransform

    init(rect: MKMapRect, size: CGSize, heading: Double) {
        let radians = CGFloat(heading.isFinite ? heading : 0) * .pi / 180
        let c = abs(cos(radians)), s = abs(sin(radians))
        let width = max(1, ceil(size.width * c + size.height * s - 1e-9))
        let height = max(1, ceil(size.width * s + size.height * c - 1e-9))
        sourceSize = CGSize(width: width, height: height)
        let mapWidth = rect.size.width * Double(width / size.width)
        let mapHeight = rect.size.height * Double(height / size.height)
        sourceRect = MKMapRect(x: rect.midX - mapWidth / 2, y: rect.midY - mapHeight / 2,
                               width: mapWidth, height: mapHeight)
        sourceToScreen = CGAffineTransform(translationX: size.width / 2, y: size.height / 2)
            .rotated(by: -radians).translatedBy(x: -width / 2, y: -height / 2)
    }

    func point(_ coordinate: CLLocationCoordinate2D) -> CGPoint {
        let p = MKMapPoint(coordinate)
        let world = MKMapSize.world.width
        var dx = (p.x - sourceRect.midX).truncatingRemainder(dividingBy: world)
        if dx > world / 2 { dx -= world }
        if dx < -world / 2 { dx += world }
        return CGPoint(x: (0.5 + dx / sourceRect.size.width) * sourceSize.width,
                       y: (p.y - sourceRect.minY) / sourceRect.size.height * sourceSize.height)
            .applying(sourceToScreen)
    }
}

/// Tiles that actually decoded for this viewport, before GPS and GPX are drawn.
nonisolated struct RivmondeRasterFrame {
    let zoom: Int
    let coverage: Double
    private(set) var lacksDetail = false
    private let tiles: [(image: UIImage, rect: CGRect)]

    static func grid(_ rect: MKMapRect, output: CGSize, zoom: Int) -> OfflineTileGrid? {
        OfflineTileGrid(minWorldX: rect.minX, maxWorldX: rect.maxX,
                        minWorldY: rect.minY, maxWorldY: rect.maxY,
                        outputWidth: Double(output.width), minZoom: zoom, maxZoom: zoom,
                        worldWidth: MKMapSize.world.width, maxTiles: 160)
    }

    static func best(in rect: MKMapRect, output: CGSize, zooms: [Int], inspectDetail: Bool = false,
                     image: (Int, Int, Int) -> UIImage?) -> Self? {
        let viewport = CGRect(origin: .zero, size: output)
        guard output.width > 0, output.height > 0 else { return nil }
        var best: Self?
        var uniform: Self?
        for zoom in zooms {
            guard let grid = grid(rect, output: output, zoom: zoom) else { continue }
            var tiles: [(image: UIImage, rect: CGRect)] = []
            var coveredArea: CGFloat = 0
            let scaleX = output.width / rect.size.width
            let scaleY = output.height / rect.size.height
            for y in grid.minY...grid.maxY {
                for x in grid.minX...grid.maxX {
                    guard let tile = image(zoom, x, y) else { continue }
                    let target = CGRect(x: (Double(x) * grid.tileWorld - rect.minX) * scaleX,
                                        y: (Double(y) * grid.tileWorld - rect.minY) * scaleY,
                                        width: grid.tileWorld * scaleX, height: grid.tileWorld * scaleY)
                    let visible = target.intersection(viewport)
                    guard !visible.isEmpty else { continue }
                    coveredArea += visible.width * visible.height
                    tiles.append((tile, target))
                }
            }
            let fraction = Double(coveredArea / (output.width * output.height))
            guard fraction > (best?.coverage ?? 0) + 0.000_001 else { continue }
            var candidate = Self(zoom: zoom, coverage: fraction, tiles: tiles)
            if inspectDetail && !candidate.hasVisibleDetail(in: output) {
                candidate.lacksDetail = true
                if fraction > (uniform?.coverage ?? 0) { uniform = candidate }
                continue
            }
            best = candidate
            if fraction >= 0.999_999 { break }
        }
        return best ?? uniform
    }

    func draw() {
        for tile in tiles {
            var rect = tile.rect
            rect.size.width += 0.5
            rect.size.height += 0.5
            tile.image.draw(in: rect)
        }
    }

    /// MapKit can succeed with a featureless image. Inspect the base alone,
    /// ignoring the attribution at the edge. A single visible road is enough.
    static func hasMapDetail(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        return containsDetail { context, bounds in context.draw(cgImage, in: bounds) }
    }

    private func hasVisibleDetail(in size: CGSize) -> Bool {
        Self.containsDetail { context, bounds in
            context.scaleBy(x: bounds.width / size.width, y: bounds.height / size.height)
            for tile in tiles {
                guard let image = tile.image.cgImage else { continue }
                var target = tile.rect
                target.origin.y = size.height - target.maxY
                context.draw(image, in: target)
            }
        }
    }

    private static func containsDetail(_ draw: (CGContext, CGRect) -> Void) -> Bool {
        let side = 128
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let sampled = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let data = bytes.baseAddress,
                  let context = CGContext(data: data, width: side, height: side, bitsPerComponent: 8,
                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            draw(context, CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard sampled else { return false }
        func differs(_ first: Int, _ second: Int) -> Bool {
            // Uncovered areas are transparent. A missing tile boundary is
            // not a road or a contour and must not count as geographic detail.
            guard pixels[first + 3] >= 250, pixels[second + 3] >= 250 else { return false }
            return (0..<3).contains { abs(Int(pixels[first + $0]) - Int(pixels[second + $0])) >= 6 }
        }
        var edges = 0
        let interior = 10..<(side - 10)
        for y in interior {
            for x in interior {
                let i = (y * side + x) * 4
                if differs(i, i + 4) || differs(i, i + side * 4) {
                    edges += 1
                    if edges >= 12 { return true }
                }
            }
        }
        return false
    }

    static func drawStatus(_ message: String, in size: CGSize) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: UIColor.white, .backgroundColor: UIColor.black.withAlphaComponent(0.8)
        ]
        (message as NSString).draw(in: CGRect(x: 16, y: size.height - 90, width: size.width - 32,
                                               height: 62), withAttributes: attributes)
    }
}
