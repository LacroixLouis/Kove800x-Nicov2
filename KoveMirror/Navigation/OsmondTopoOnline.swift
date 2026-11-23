import Foundation
import MapKit
import UIKit

/// Online topographic background for Osmond: OpenTopoMap raster tiles already
/// contain contours and hillshading. The provider is independent of OsmAnd.
/// The phone and the TFT request only tiles in their visible viewport.
/// A small on-disk cache lets the TFT use the SAME tiles as the iPhone.
nonisolated final class OsmondTopoOnline: MKTileOverlay, @unchecked Sendable {
    static let attribution = "© OpenStreetMap contributors, SRTM · © opentopomap.org (CC BY-SA)"
    private let cacheDirectory: URL
    private let lock = NSLock()
    private typealias TileResult = (Data?, Error?) -> Void
    private var pending: [String: [TileResult]] = [:]
    private let retryAfter = NSCache<NSString, NSDate>()
    private let images = NSCache<NSString, UIImage>()
    private let missingFiles = NSCache<NSString, NSDate>()
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    override init(urlTemplate: String? = nil) {
        cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OsmondOpenTopoMap", isDirectory: true)
        super.init(urlTemplate: "https://tile.opentopomap.org/{z}/{x}/{y}.png")
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 0
        maximumZ = 17
        // If OpenTopoMap is temporarily unavailable, retain MapKit's real
        // basemap underneath instead of showing a blank white map on iPhone.
        canReplaceMapContent = false
        images.countLimit = 96
        missingFiles.countLimit = 512
        retryAfter.countLimit = 256
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    private func file(z: Int, x: Int, y: Int) -> URL {
        cacheDirectory.appendingPathComponent("\(z)-\(x)-\(y).png", isDirectory: false)
    }

    private func cachedImage(z: Int, x: Int, y: Int) -> UIImage? {
        let url = file(z: z, x: x, y: y)
        let key = url.lastPathComponent as NSString
        if let hit = images.object(forKey: key) { return hit }
        if let miss = missingFiles.object(forKey: key), miss.timeIntervalSinceNow > 0 { return nil }
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
            missingFiles.setObject(Date().addingTimeInterval(2) as NSDate, forKey: key)
            return nil
        }
        images.setObject(image, forKey: key)
        return image
    }

    override func loadTile(at path: MKTileOverlayPath,
                           result: @escaping (Data?, Error?) -> Void) {
        guard (0...17).contains(path.z), path.x >= 0, path.y >= 0,
              path.x < (1 << path.z), path.y < (1 << path.z) else {
            result(nil, nil)
            return
        }
        let cached = file(z: path.z, x: path.x, y: path.y)
        if let data = try? Data(contentsOf: cached), let image = UIImage(data: data) {
            images.setObject(image, forKey: cached.lastPathComponent as NSString)
            result(data, nil)
            return
        }
        requestTile(z: path.z, x: path.x, y: path.y, result: result)
    }

    /// Both displays share in-flight requests. Limit TFT-only loads while
    /// leaving MapKit free to request its visible tiles.
    private func requestTile(z: Int, x: Int, y: Int, result: TileResult? = nil) {
        let cached = file(z: z, x: x, y: y)
        let key = cached.lastPathComponent
        lock.lock()
        if let delay = retryAfter.object(forKey: key as NSString), delay.timeIntervalSinceNow > 0 {
            lock.unlock()
            result?(nil, URLError(.resourceUnavailable))
            return
        }
        if pending[key] != nil {
            if let result { pending[key]?.append(result) }
            lock.unlock()
            return
        }
        if result == nil && pending.count >= 4 {
            lock.unlock()
            return
        }
        pending[key] = result.map { [$0] } ?? []
        lock.unlock()

        let url = URL(string: "https://tile.opentopomap.org/\(z)/\(x)/\(y).png")!
        var request = URLRequest(url: url)
        request.setValue("DoubleInterface-iOS/1.0 (Rivmonde map viewer)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { data, response, error in
            let valid: Data?
            if error == nil, (response as? HTTPURLResponse)?.statusCode == 200,
               let data, data.count < 2_000_000, let image = UIImage(data: data) {
                self.images.setObject(image, forKey: key as NSString)
                try? data.write(to: cached, options: .atomic)
                valid = data
            } else {
                self.retryAfter.setObject(Date().addingTimeInterval(20) as NSDate, forKey: key as NSString)
                valid = nil
            }
            self.lock.lock()
            let callbacks = self.pending.removeValue(forKey: key) ?? []
            self.lock.unlock()
            for callback in callbacks { callback(valid, valid == nil ? (error ?? URLError(.resourceUnavailable)) : nil) }
        }.resume()
    }

    /// TFT rasterization uses already fetched map tiles. GPX/position remain
    /// separate overlays to avoid baking stale navigation into the tile cache.
    func renderFrame(mapRect: MKMapRect, output: CGSize, allowNetwork: Bool,
                     polylines: [[CLLocationCoordinate2D]], position: CLLocationCoordinate2D?,
                     bearing: CLLocationDirection? = nil, mapHeading: CLLocationDirection = 0,
                     accessCoordinates: [CLLocationCoordinate2D] = [], accessTarget: CLLocationCoordinate2D? = nil,
                     mapName: String, mapNameColor: UIColor) -> UIImage? {
        let size = CGSize(width: max(2, output.width), height: max(2, output.height))
        let viewport = TFTMapViewport(rect: mapRect, size: size, heading: mapHeading)
        let zooms = OfflineTileGrid.rasterZooms(viewWidth: mapRect.size.width, outputWidth: Double(size.width),
                                                minZoom: 0, maxZoom: 17)
        let base = RivmondeRasterFrame.best(in: viewport.sourceRect, output: viewport.sourceSize, zooms: zooms,
                                           inspectDetail: true, image: cachedImage)
        if allowNetwork, let zoom = zooms.first, base?.zoom != zoom || (base?.coverage ?? 0) < 0.999_999,
           let grid = RivmondeRasterFrame.grid(viewport.sourceRect, output: viewport.sourceSize, zoom: zoom) {
            for y in grid.minY...grid.maxY {
                for x in grid.minX...grid.maxX where cachedImage(z: zoom, x: x, y: y) == nil {
                    requestTile(z: zoom, x: x, y: y)
                }
            }
        }
        guard let base, !base.lacksDetail else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            // Missing raster tiles must NEVER result in a giant white frame
            // on the TFT. Visible cache tiles are drawn over this dark fallback.
            UIColor(red: 0.11, green: 0.16, blue: 0.20, alpha: 1).setFill()
            renderer.fill(CGRect(origin: .zero, size: size))
            let ctx = renderer.cgContext
            ctx.saveGState()
            ctx.concatenate(viewport.sourceToScreen)
            base.draw()
            ctx.restoreGState()
            if base.coverage < 0.999_999 {
                RivmondeRasterFrame.drawStatus("Couverture topo partielle", in: size)
            }
            ctx.saveGState()
            ctx.setStrokeColor(UIColor.systemPurple.cgColor)
            ctx.setLineWidth(5)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            for line in polylines where line.count > 1 {
                ctx.beginPath()
                ctx.move(to: viewport.point(line[0]))
                for coordinate in line.dropFirst() { ctx.addLine(to: viewport.point(coordinate)) }
                ctx.strokePath()
            }
            GPXAccessRendering.draw(in: ctx, coordinates: accessCoordinates, target: accessTarget, project: viewport.point)
            if let position, CLLocationCoordinate2DIsValid(position) {
                let center = viewport.point(position)
                let angle = NavigationPositionMarker.angle(at: position, bearing: bearing, project: viewport.point)
                NavigationPositionMarker.draw(in: ctx, at: center, angle: angle, color: mapNameColor)
            }
            ctx.restoreGState()
            let font = UIFont.systemFont(ofSize: max(22, min(36, size.width * 0.034)), weight: .heavy)
            (mapName as NSString).draw(at: CGPoint(x: 22, y: 20), withAttributes: [
                .font: font, .foregroundColor: mapNameColor])
            let label = Self.attribution as NSString
            let labelFont = UIFont.systemFont(ofSize: max(10, min(14, size.width * 0.011)), weight: .medium)
            let box = label.size(withAttributes: [.font: labelFont])
            label.draw(at: CGPoint(x: 12, y: size.height - box.height - 9), withAttributes: [
                .font: labelFont, .foregroundColor: UIColor.black])
        }
    }
}
