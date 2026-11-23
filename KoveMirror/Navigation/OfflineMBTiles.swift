import Foundation
import UIKit
import MapKit
import Combine
import SQLite3

/// User-supplied raster MBTiles. This is an independent offline format and
/// does NOT parse OsmAnd's .obf vector files or contain OsmAnd copyrighted assets.
struct OfflineMapPackage: Identifiable, Hashable {
    let id: String                 // Validated local filename, not an arbitrary URL.
    let title: String
    let minZoom: Int
    let maxZoom: Int
    let bytes: Int64
    let bounds: MKCoordinateRegion?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Couche indépendante créée à partir d'un fichier MBTiles raster fourni par l'utilisateur.
/// Pas de données, de logo ou de styles OsmAnd intégrés.
enum OsmondRasterLayer: String, CaseIterable, Identifiable {
    case hillshade, contours
    var id: String { rawValue }
    var title: String { self == .hillshade ? "Ombrage du relief" : "Courbes de niveau" }
    var settingKey: String { "doubleInterface.osmondLayer.\(rawValue)" }
    var opacityKey: String { "doubleInterface.osmondLayer.\(rawValue).opacity" }
}

/// Osmond's own independent appearance, not an OsmAnd asset/theme.
enum OsmondMapTheme: String, CaseIterable, Identifiable {
    case day, night, automatic
    var id: String { rawValue }
    var title: String {
        switch self {
        case .day: return "Jour"
        case .night: return "Nuit"
        case .automatic: return "Auto"
        }
    }
    var style: UIUserInterfaceStyle {
        switch self {
        case .day: return .light
        case .night: return .dark
        case .automatic: return .unspecified
        }
    }
}

final class OfflineMapLibrary: ObservableObject {
    static let shared = OfflineMapLibrary()

    @Published private(set) var packages: [OfflineMapPackage] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var selectedHillshadeID: String?
    @Published private(set) var selectedContoursID: String?
    private let selectedKey = "doubleInterface.osmandOfflineMapID"

    private init() {
        selectedID = UserDefaults.standard.string(forKey: selectedKey)
        selectedHillshadeID = UserDefaults.standard.string(forKey: OsmondRasterLayer.hillshade.settingKey)
        selectedContoursID = UserDefaults.standard.string(forKey: OsmondRasterLayer.contours.settingKey)
        installBundledWorldReliefOverview()
        reload()
        // Le fond mondial est immédiatement présent dans la bibliothèque,
        // sans remplacer de force la carte détaillée choisie par le pilote.
        if selectedID == nil,
           let overview = packages.first(where: { $0.id == Self.bundledOverviewFilename }) {
            select(overview)
        }
    }

    private var directory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("DoubleInterfaceOfflineMaps", isDirectory: true)
    }

    // Cette carte contient une vue du relief mondial (zoom 0-5) seulement.
    // Pas de routes, sentiers, courbes de niveau ni guidage hors ligne.
    static let bundledOverviewFilename = "Rivmonde_Monde_Relief_Apercu_v1.mbtiles"
    
    private func installBundledWorldReliefOverview() {
        let name = Self.bundledOverviewFilename
        let target = directory.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        guard let asset = Bundle.main.url(forResource: "Rivmonde_Monde_Relief_Apercu_v1",
                                          withExtension: "mbtiles") else {
            NSLog("Rivmonde: fond relief mondial absent des ressources de l’application")
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: asset, to: target)
            _ = try MBTilesReader.describe(target)
        } catch {
            try? FileManager.default.removeItem(at: target)
            NSLog("Rivmonde: installation du relief mondial impossible: %@", error.localizedDescription)
        }
    }

    var selected: OfflineMapPackage? { packages.first(where: { $0.id == selectedID }) }

    func url(for package: OfflineMapPackage) -> URL? {
        // Never accept a file name containing path separators.
        guard package.id == (package.id as NSString).lastPathComponent,
              package.id.lowercased().hasSuffix(".mbtiles") else { return nil }
        return directory.appendingPathComponent(package.id)
    }

    func reload() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        packages = urls.filter { $0.pathExtension.lowercased() == "mbtiles" }
            .compactMap { try? MBTilesReader.describe($0) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        if !packages.contains(where: { $0.id == selectedID }) { selectedID = nil }
        if !packages.contains(where: { $0.id == selectedHillshadeID }) { selectedHillshadeID = nil }
        if !packages.contains(where: { $0.id == selectedContoursID }) { selectedContoursID = nil }
    }

    func select(_ package: OfflineMapPackage?) {
        selectedID = package?.id
        UserDefaults.standard.set(selectedID, forKey: selectedKey)
    }

    func selectedOverlay(_ layer: OsmondRasterLayer) -> OfflineMapPackage? {
        let id = layer == .hillshade ? selectedHillshadeID : selectedContoursID
        return packages.first(where: { $0.id == id })
    }

    func selectOverlay(_ package: OfflineMapPackage?, for layer: OsmondRasterLayer) {
        switch layer {
        case .hillshade: selectedHillshadeID = package?.id
        case .contours: selectedContoursID = package?.id
        }
        UserDefaults.standard.set(package?.id, forKey: layer.settingKey)
    }

    @discardableResult
    func importFile(_ source: URL, selectAsBase: Bool = true) throws -> OfflineMapPackage {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        guard source.pathExtension.lowercased() == "mbtiles" else {
            throw OfflineMapError.invalid("Sélectionne un fichier de carte raster .mbtiles.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = source.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
        let target = directory.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8)).mbtiles")
        // Copy before validation, so the provider can release the security scope.
        try FileManager.default.copyItem(at: source, to: target)
        do {
            let package = try MBTilesReader.describe(target)
            reload()
            if selectAsBase { select(package) }
            return package
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    func remove(_ package: OfflineMapPackage) throws {
        guard let file = url(for: package) else { return }
        try FileManager.default.removeItem(at: file)
        if selectedID == package.id { select(nil) }
        for layer in OsmondRasterLayer.allCases where selectedOverlay(layer)?.id == package.id {
            selectOverlay(nil, for: layer)
        }
        reload()
    }
}

enum OfflineMapError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

/// SQLite MBTiles files use TMS row addressing by default. Some providers
/// explicitly set metadata scheme=xyz; both are supported.
private final class MBTilesReader {
    private var db: OpaquePointer?
    private let mutex = NSLock()

    init(_ file: URL) throws {
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(file.path, &connection, flags, nil) == SQLITE_OK,
              let connection else {
            if let connection { sqlite3_close(connection) }
            throw OfflineMapError.invalid("Fichier MBTiles illisible ou corrompu.")
        }
        db = connection
        guard hasTiles() else {
            throw OfflineMapError.invalid("Ce fichier ne contient pas de tuiles MBTiles lisibles.")
        }
    }

    deinit { if let db { sqlite3_close(db) } }

    private func hasTiles() -> Bool {
        var query: OpaquePointer?
        defer { sqlite3_finalize(query) }
        guard sqlite3_prepare_v2(db, "SELECT tile_data FROM tiles LIMIT 1", -1, &query, nil) == SQLITE_OK,
              sqlite3_step(query) == SQLITE_ROW,
              sqlite3_column_bytes(query, 0) > 0 else { return false }
        return true
    }

    func metadata(_ name: String) -> String? {
        mutex.lock()
        defer { mutex.unlock() }
        var query: OpaquePointer?
        defer { sqlite3_finalize(query) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM metadata WHERE name = ? LIMIT 1", -1,
                                  &query, nil) == SQLITE_OK else { return nil }
        let bindingStatus = name.withCString { sqlite3_bind_text(query, 1, $0, -1, SQLITE_TRANSIENT) }
        guard bindingStatus == SQLITE_OK, sqlite3_step(query) == SQLITE_ROW,
              let chars = sqlite3_column_text(query, 0) else { return nil }
        return String(cString: chars)
    }

    func zoomRange() -> (Int, Int) {
        mutex.lock()
        defer { mutex.unlock() }
        var query: OpaquePointer?
        defer { sqlite3_finalize(query) }
        // Look up both ends of the zoom index independently. A single MIN/MAX
        // aggregate walks every tile and can hold up the map on world datasets.
        let sql = "SELECT (SELECT zoom_level FROM tiles ORDER BY zoom_level ASC LIMIT 1), (SELECT zoom_level FROM tiles ORDER BY zoom_level DESC LIMIT 1)"
        guard sqlite3_prepare_v2(db, sql, -1,
                                 &query, nil) == SQLITE_OK, sqlite3_step(query) == SQLITE_ROW else { return (0, 18) }
        return (Int(sqlite3_column_int(query, 0)), Int(sqlite3_column_int(query, 1)))
    }

    func tile(z: Int, x: Int, y: Int, xyz: Bool) -> Data? {
        guard z >= 0, z <= 22, x >= 0, x < (1 << z),
              let row = OfflineTileGrid.sqliteRow(z: z, xyzY: y, schemeXYZ: xyz) else { return nil }
        mutex.lock()
        defer { mutex.unlock() }
        var query: OpaquePointer?
        defer { sqlite3_finalize(query) }
        guard sqlite3_prepare_v2(db,
              "SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=? LIMIT 1",
              -1, &query, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int(query, 1, Int32(z))
        sqlite3_bind_int(query, 2, Int32(x))
        sqlite3_bind_int(query, 3, Int32(row))
        guard sqlite3_step(query) == SQLITE_ROW,
              let ptr = sqlite3_column_blob(query, 0) else { return nil }
        let count = Int(sqlite3_column_bytes(query, 0))
        guard count > 0 else { return nil }
        return Data(bytes: ptr, count: count)
    }

    func sampleTile() -> Data? {
        mutex.lock()
        defer { mutex.unlock() }
        var query: OpaquePointer?
        defer { sqlite3_finalize(query) }
        guard sqlite3_prepare_v2(db, "SELECT tile_data FROM tiles LIMIT 1", -1,
                                 &query, nil) == SQLITE_OK,
              sqlite3_step(query) == SQLITE_ROW,
              let pointer = sqlite3_column_blob(query, 0) else { return nil }
        let count = Int(sqlite3_column_bytes(query, 0))
        guard count > 8 else { return nil }
        return Data(bytes: pointer, count: count)
    }

    static func describe(_ file: URL) throws -> OfflineMapPackage {
        let db = try MBTilesReader(file)
        let format = db.metadata("format")?.lowercased()
        if let format, !["png", "jpg", "jpeg", "webp"].contains(format) {
            throw OfflineMapError.invalid("Seules les cartes MBTiles raster PNG/JPEG/WebP sont prises en charge (pas les tuiles vectorielles PBF).")
        }
        // Verify that the payload really is a raster image. Some vector PBF
        // datasets do not set metadata.format, and would otherwise look blank.
        guard let sample = db.sampleTile(), UIImage(data: sample) != nil else {
            throw OfflineMapError.invalid("Ce MBTiles n’est pas une carte raster décodable sur iPhone. Les fichiers vectoriels .pbf/.obf ne sont pas pris en charge.")
        }
        let one = db.zoomRange()
        guard one.0 >= 0, one.1 <= 22 else { throw OfflineMapError.invalid("Zooms MBTiles hors limites.") }
        let components = db.metadata("bounds")?.split(separator: ",").compactMap { Double($0) } ?? []
        var region: MKCoordinateRegion?
        if components.count == 4,
           components[0] >= -180, components[2] <= 180,
           components[1] >= -85.0511, components[3] <= 85.0511,
           components[2] > components[0], components[3] > components[1] {
            region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: (components[1] + components[3]) / 2,
                                              longitude: (components[0] + components[2]) / 2),
                span: MKCoordinateSpan(latitudeDelta: components[3] - components[1],
                                       longitudeDelta: components[2] - components[0]))
        }
        let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return OfflineMapPackage(id: file.lastPathComponent, title: db.metadata("name") ?? file.deletingPathExtension().lastPathComponent,
                                 minZoom: one.0, maxZoom: one.1, bytes: bytes, bounds: region)
    }
}

/// Replaces Apple's online basemap for the OsmAnd-like profile only.
final class OfflineMBTilesOverlay: MKTileOverlay {
    private let reader: MBTilesReader
    private let xyz: Bool
    /// Maximum level genuinely present in the MBTiles file. The MKTileOverlay
    /// may request higher levels; those are cropped from an existing parent tile.
    private(set) var sourceMaximumZ: Int = 0
    private let imageCache = NSCache<NSString, UIImage>()
    private let absentTiles = NSCache<NSString, NSNumber>()

    init(file: URL, replacesMapContent: Bool = true) throws {
        reader = try MBTilesReader(file)
        xyz = reader.metadata("scheme")?.lowercased() == "xyz"
        super.init(urlTemplate: nil)
        canReplaceMapContent = replacesMapContent
        tileSize = CGSize(width: 256, height: 256)
        let range = reader.zoomRange()
        minimumZ = range.0
        sourceMaximumZ = range.1
        // MapKit does not automatically overzoom an MKTileOverlay. Without this,
        // the overview disappears once the rider pinches beyond native zoom 5.
        maximumZ = 22
        imageCache.countLimit = 160
        absentTiles.countLimit = 512
    }

    override func loadTile(at path: MKTileOverlayPath,
                           result: @escaping (Data?, Error?) -> Void) {
        if path.z <= sourceMaximumZ {
            guard let data = reader.tile(z: path.z, x: path.x, y: path.y, xyz: xyz) else {
                result(nil, OfflineMapError.invalid("Tuile absente de la zone téléchargée."))
                return
            }
            result(data, nil)
            return
        }
        // Overzoom: show an enlarged part of the last available tile instead
        // of a blank background. This does NOT create real geographic detail.
        let shift = path.z - sourceMaximumZ
        guard shift > 0, shift <= 22,
              let source = image(z: sourceMaximumZ, x: path.x >> shift, y: path.y >> shift),
              let cgImage = source.cgImage else {
            result(nil, OfflineMapError.invalid("Tuile parent absente."))
            return
        }
        let subdivisions = 1 << shift
        let subX = path.x % subdivisions
        let subY = path.y % subdivisions
        let px = Double(cgImage.width) / Double(subdivisions)
        let py = Double(cgImage.height) / Double(subdivisions)
        let x0 = min(cgImage.width - 1, Int(Double(subX) * px))
        let y0 = min(cgImage.height - 1, Int(Double(subY) * py))
        let crop = CGRect(x: x0, y: y0,
                          width: max(1, min(cgImage.width - x0, Int(ceil(px)))),
                          height: max(1, min(cgImage.height - y0, Int(ceil(py)))))
        guard let fragment = cgImage.cropping(to: crop) else {
            result(nil, OfflineMapError.invalid("Zoom hors ligne indisponible."))
            return
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let scaled = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format).image { _ in
            UIImage(cgImage: fragment).draw(in: CGRect(x: 0, y: 0, width: 256, height: 256))
        }
        result(scaled.jpegData(compressionQuality: 0.85), nil)
    }

    private func image(z: Int, x: Int, y: Int) -> UIImage? {
        let key = "\(z)-\(x)-\(y)" as NSString
        if let hit = imageCache.object(forKey: key) { return hit }
        if absentTiles.object(forKey: key) != nil { return nil }
        guard let data = reader.tile(z: z, x: x, y: y, xyz: xyz),
              let img = UIImage(data: data) else {
            absentTiles.setObject(NSNumber(value: true), forKey: key)
            return nil
        }
        imageCache.setObject(img, forKey: key)
        return img
    }

    /// Draws an optional transparent raster MBTiles layer on the TFT.
    /// It uses the *same* Mercator rectangle as the base to avoid drift.
    @discardableResult
    private func drawTiles(in context: UIGraphicsImageRendererContext,
                           mapRect: MKMapRect, output: CGSize, opacity: CGFloat) -> RivmondeRasterFrame? {
        let zooms = OfflineTileGrid.rasterZooms(viewWidth: mapRect.size.width,
            outputWidth: Double(output.width), minZoom: minimumZ, maxZoom: sourceMaximumZ,
            allowDeepUpscale: canReplaceMapContent)
        guard let frame = RivmondeRasterFrame.best(in: mapRect, output: output, zooms: zooms,
                                                   inspectDetail: canReplaceMapContent, image: image)
        else { return nil }
        context.cgContext.saveGState()
        context.cgContext.setAlpha(max(0, min(1, opacity)))
        frame.draw()
        context.cgContext.restoreGState()
        return frame
    }

    /// Osmond TFT offline rendering: base -> relief -> contours -> GPX -> GPS.
    /// MapKit's snapshotter does not capture local tile overlays automatically.
    func renderFrame(mapRect: MKMapRect, output: CGSize,
                     rasterLayers: [(tiles: OfflineMBTilesOverlay, opacity: CGFloat)] = [],
                     polylines: [[CLLocationCoordinate2D]], position: CLLocationCoordinate2D?,
                     bearing: CLLocationDirection? = nil, mapHeading: CLLocationDirection = 0,
                     accessCoordinates: [CLLocationCoordinate2D] = [], accessTarget: CLLocationCoordinate2D? = nil,
                     mapName: String = "", mapNameColor: UIColor = .systemOrange) -> UIImage {
        let renderSize = CGSize(width: max(2, output.width), height: max(2, output.height))
        let viewport = TFTMapViewport(rect: mapRect, size: renderSize, heading: mapHeading)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: renderSize, format: format).image { context in
            UIColor(red: 0.09, green: 0.12, blue: 0.14, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: renderSize))
            let ctx = context.cgContext
            ctx.saveGState()
            ctx.concatenate(viewport.sourceToScreen)
            let base = drawTiles(in: context, mapRect: viewport.sourceRect, output: viewport.sourceSize, opacity: 1)
            for layer in rasterLayers {
                layer.tiles.drawTiles(in: context, mapRect: viewport.sourceRect,
                                      output: viewport.sourceSize, opacity: layer.opacity)
            }
            ctx.restoreGState()
            if let base {
                if base.coverage < 0.999_999 {
                    RivmondeRasterFrame.drawStatus("Couverture de la carte hors ligne partielle", in: renderSize)
                } else if base.lacksDetail {
                    RivmondeRasterFrame.drawStatus("Aucun détail visible à ce zoom", in: renderSize)
                }
            } else {
                RivmondeRasterFrame.drawStatus("Carte hors ligne indisponible à cet endroit ou à ce zoom", in: renderSize)
            }
            ctx.setStrokeColor(UIColor.systemOrange.cgColor)
            ctx.setLineWidth(5)
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            for line in polylines where line.count > 1 {
                let first = viewport.point(line[0])
                ctx.beginPath()
                ctx.move(to: first)
                for coordinate in line.dropFirst() { ctx.addLine(to: viewport.point(coordinate)) }
                ctx.strokePath()
            }
            GPXAccessRendering.draw(in: ctx, coordinates: accessCoordinates, target: accessTarget, project: viewport.point)
            if let position, CLLocationCoordinate2DIsValid(position) {
                let point = viewport.point(position)
                let angle = NavigationPositionMarker.angle(at: position, bearing: bearing, project: viewport.point)
                NavigationPositionMarker.draw(in: ctx, at: point, angle: angle, color: mapNameColor)
            }
            if !mapName.isEmpty {
                let font = UIFont.systemFont(ofSize: max(22, min(36, renderSize.width * 0.034)), weight: .heavy)
                (mapName as NSString).draw(at: CGPoint(x: 22, y: 20), withAttributes: [
                    .font: font, .foregroundColor: mapNameColor
                ])
            }
        }
    }
}

// sqlite3_bind_text requires a destructor that does not free the temporary
// C string: SQLite makes its own private copy before the closure exits.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
