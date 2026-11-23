import Foundation
import MapKit
import UIKit
import CoreImage

/// Transparent, current traffic tiles. The TFT reuses these exact tiles;
/// taking a video frame never starts another HTTP request.
nonisolated final class TomTomTrafficOverlay: MKTileOverlay, @unchecked Sendable {
    private final class Tile {
        let data: Data
        let expires: Date
        init(_ data: Data, expires: Date) { self.data = data; self.expires = expires }
    }
    private struct Pending {
        let id: UUID
        let task: URLSessionDataTask
        var callbacks: [(Data?, Error?) -> Void]
    }
    private let configuration: TomTomTrafficConfiguration
    private let layer: String
    private let cache = NSCache<NSString, Tile>()
    private let lock = NSLock()
    private var pending: [String: Pending] = [:]
    private var active = true
    private var retryAt = Date.distantPast
    private var recentZoom = 12
    private let session: URLSession
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    init(layer: String, configuration: TomTomTrafficConfiguration) {
        self.layer = layer
        self.configuration = configuration
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 12
        settings.httpMaximumConnectionsPerHost = 4
        settings.urlCache = nil
        session = URLSession(configuration: settings)
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 0
        maximumZ = 22
        canReplaceMapContent = false
        cache.countLimit = 160
        cache.totalCostLimit = 12 * 1024 * 1024
    }

    deinit { session.invalidateAndCancel() }

    func setActive(_ enabled: Bool) {
        lock.lock()
        active = enabled
        let cancelled = enabled ? [] : Array(pending.values)
        if !enabled { pending.removeAll(); cache.removeAllObjects() }
        lock.unlock()
        for request in cancelled {
            request.task.cancel()
            request.callbacks.forEach { $0(nil, URLError(.cancelled)) }
        }
    }

    private func tileKey(z: Int, x: Int, y: Int) -> String { "\(z)/\(x)/\(y)" }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        guard let request = configuration.tileRequest(layer: layer, z: path.z, x: path.x, y: path.y) else {
            result(nil, URLError(.badURL)); return
        }
        let key = tileKey(z: path.z, x: path.x, y: path.y)
        lock.lock()
        guard active, Date() >= retryAt else { lock.unlock(); result(nil, URLError(.resourceUnavailable)); return }
        recentZoom = path.z
        if let tile = cache.object(forKey: key as NSString), tile.expires > Date() {
            lock.unlock(); result(tile.data, nil); return
        }
        if pending[key] != nil {
            pending[key]?.callbacks.append(result)
            lock.unlock(); return
        }
        let id = UUID()
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let http = response as? HTTPURLResponse
            let valid = error == nil && http?.statusCode == 200 &&
                data.map { $0.count < 2_000_000 && UIImage(data: $0) != nil } == true
            self.lock.lock()
            guard let work = self.pending[key], work.id == id else { self.lock.unlock(); return }
            self.pending.removeValue(forKey: key)
            if valid, let data, self.active {
                let header = http?.value(forHTTPHeaderField: "Cache-Control") ?? "max-age=60"
                let maxAge = header.split(separator: ",").compactMap { part -> Double? in
                    let value = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
                    return value.count == 2 && value[0] == "max-age" ? Double(value[1]) : nil
                }.first ?? 60
                if !header.contains("no-store") {
                    self.cache.setObject(Tile(data, expires: Date().addingTimeInterval(min(60, max(0, maxAge)))),
                                         forKey: key as NSString, cost: data.count)
                }
            } else if let status = http?.statusCode, status != 200 {
                self.retryAt = Date().addingTimeInterval(TomTomTrafficConfiguration.retryDelay(
                    status: status, retryAfter: http?.value(forHTTPHeaderField: "Retry-After")))
            }
            self.lock.unlock()
            let failure = valid ? nil : (error ?? URLError(.badServerResponse))
            work.callbacks.forEach { $0(valid ? data : nil, failure) }
        }
        pending[key] = Pending(id: id, task: task, callbacks: [result])
        lock.unlock()
        task.resume()
    }

    /// Project each cached tile into the snapshot's camera, including north,
    /// travel heading and perspective. Core Image maps all four corners.
    @MainActor
    func draw(on snapshot: MKMapSnapshotter.Snapshot, mapRect: MKMapRect, size: CGSize) {
        lock.lock()
        let zoom = recentZoom
        let enabled = active
        lock.unlock()
        guard enabled else { return }
        for z in [zoom, zoom - 1, zoom - 2].filter({ (0...22).contains($0) }) {
            guard let grid = OfflineTileGrid(minWorldX: mapRect.minX, maxWorldX: mapRect.maxX,
                    minWorldY: mapRect.minY, maxWorldY: mapRect.maxY, outputWidth: Double(size.width),
                    minZoom: z, maxZoom: z, maxTiles: 80) else { continue }
            var drewTile = false
            for y in grid.minY...grid.maxY {
                for x in grid.minX...grid.maxX {
                    guard let tile = cache.object(forKey: tileKey(z: z, x: x, y: y) as NSString),
                          tile.expires > Date(), let image = UIImage(data: tile.data)?.cgImage,
                          let filter = CIFilter(name: "CIPerspectiveTransform") else { continue }
                    func corner(_ dx: Double, _ dy: Double) -> CIVector {
                        let coordinate = MKMapPoint(x: (Double(x) + dx) * grid.tileWorld,
                                                    y: (Double(y) + dy) * grid.tileWorld).coordinate
                        let p = snapshot.point(for: coordinate)
                        return CIVector(x: p.x, y: size.height - p.y)
                    }
                    filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
                    filter.setValue(corner(0, 0), forKey: "inputTopLeft")
                    filter.setValue(corner(1, 0), forKey: "inputTopRight")
                    filter.setValue(corner(0, 1), forKey: "inputBottomLeft")
                    filter.setValue(corner(1, 1), forKey: "inputBottomRight")
                    guard let warped = filter.outputImage else { continue }
                    let extent = warped.extent.intersection(CGRect(origin: .zero, size: size)).integral
                    guard !extent.isEmpty, !extent.isInfinite, !extent.isNull,
                          let rendered = Self.ciContext.createCGImage(warped, from: extent) else { continue }
                    UIImage(cgImage: rendered).draw(in: CGRect(x: extent.minX, y: size.height - extent.maxY,
                                                             width: extent.width, height: extent.height))
                    drewTile = true
                }
            }
            if drewTile { return }
        }
    }
}
