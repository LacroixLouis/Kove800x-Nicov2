import Foundation

/// Web-Mercator tile-grid math kept independent of UIKit/MapKit for tests.
/// A large MBTiles dataset must never trigger millions of synchronous SQLite
/// reads when the user zooms out beyond the coverage of the imported map.
nonisolated struct OfflineTileGrid {
    let z: Int
    let minX: Int
    let maxX: Int
    let minY: Int
    let maxY: Int
    let tileWorld: Double

    var tileCount: Int { (maxX - minX + 1) * (maxY - minY + 1) }

    /// Candidate levels for the actual screen and extent. Enlarging one
    /// source pixel beyond four screen pixels loses too much map detail.
    static func rasterZooms(viewWidth: Double, outputWidth: Double, minZoom: Int,
                            maxZoom: Int, worldWidth: Double = 268_435_456,
                            allowDeepUpscale: Bool = false) -> [Int] {
        guard viewWidth.isFinite, viewWidth > 0, outputWidth.isFinite, outputWidth > 0,
              worldWidth.isFinite, worldWidth > 0,
              minZoom >= 0, minZoom <= maxZoom, maxZoom <= 22 else { return [] }
        let ideal = log2(outputWidth / viewWidth * (worldWidth / 256))
        guard ideal.isFinite else { return [] }
        let preferred = Int(max(Double(minZoom), min(Double(maxZoom), floor(ideal))))
        return [preferred, preferred + 1, preferred - 1, preferred + 2, preferred - 2]
            .filter { (minZoom...maxZoom).contains($0) &&
                (allowDeepUpscale || ideal - Double($0) <= 2.000_001) }
    }

    init?(minWorldX: Double, maxWorldX: Double, minWorldY: Double, maxWorldY: Double,
          outputWidth: Double, minZoom: Int, maxZoom: Int,
          worldWidth: Double = 268_435_456, maxTiles: Int = 1024) {
        guard minWorldX.isFinite, maxWorldX.isFinite, minWorldY.isFinite, maxWorldY.isFinite,
              outputWidth.isFinite, worldWidth.isFinite,
              maxWorldX > minWorldX, maxWorldY > minWorldY,
              outputWidth > 0, worldWidth > 0, minZoom >= 0, maxZoom <= 22,
              // MKMapView may shift slightly past the dateline, but a wildly
              // out-of-range finite coordinate must never trap Int conversion.
              minWorldX >= -worldWidth, maxWorldX <= 2 * worldWidth,
              minWorldY >= -worldWidth, maxWorldY <= 2 * worldWidth,
              minZoom <= maxZoom, maxTiles >= 1 else { return nil }
        let ideal = log2((outputWidth * worldWidth) / ((maxWorldX - minWorldX) * 256.0))
        guard ideal.isFinite else { return nil }
        let zoom = min(max(Int(floor(ideal)), minZoom), maxZoom)
        let divisor = 1 << zoom
        let world = worldWidth / Double(divisor)
        let x0 = max(0, min(divisor - 1, Int(floor(minWorldX / world))))
        let x1 = max(0, min(divisor - 1, Int(ceil(maxWorldX / world)) - 1))
        let y0 = max(0, min(divisor - 1, Int(floor(minWorldY / world))))
        let y1 = max(0, min(divisor - 1, Int(ceil(maxWorldY / world)) - 1))
        guard x0 <= x1, y0 <= y1,
              Double(x1 - x0 + 1) * Double(y1 - y0 + 1) <= Double(maxTiles) else { return nil }
        self.z = zoom
        self.minX = x0
        self.maxX = x1
        self.minY = y0
        self.maxY = y1
        self.tileWorld = world
    }

    static func sqliteRow(z: Int, xyzY: Int, schemeXYZ: Bool) -> Int? {
        guard (0...22).contains(z), xyzY >= 0, xyzY < (1 << z) else { return nil }
        return schemeXYZ ? xyzY : ((1 << z) - 1 - xyzY)
    }
}
