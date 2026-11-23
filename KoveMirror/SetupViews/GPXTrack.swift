import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

nonisolated struct GPXPoint: Codable, Equatable {
    let latitude: Double
    let longitude: Double
    var elevation: Double? = nil
    var timestamp: Date? = nil
}

/// Keeps segment boundaries: no invented line across recording gaps.
nonisolated struct GPXTrack: Codable {
    static let byteLimit = 10_000_000
    let name: String
    let segments: [[GPXPoint]]
    var pointCount: Int { segments.reduce(0) { $0 + $1.count } }

    var elevationGainMeters: Double {
        segments.reduce(0) { total, segment in
            total + zip(segment, segment.dropFirst()).reduce(0) { gain, pair in
                guard let first = pair.0.elevation, let second = pair.1.elevation else { return gain }
                let change = second - first
                return gain + ((change > 0 && change < 200) ? change : 0)
            }
        }
    }

    var elevationRange: ClosedRange<Double>? {
        let values = segments.flatMap { $0 }.compactMap(\.elevation)
        guard let lowest = values.min(), let highest = values.max() else { return nil }
        return lowest...highest
    }

    var recordedDuration: TimeInterval? {
        let dates = segments.flatMap { $0 }.compactMap(\.timestamp)
        guard let first = dates.min(), let last = dates.max(), last > first else { return nil }
        return last.timeIntervalSince(first)
    }

    /// Sum each segment separately; recording gaps add no fictitious distance.
    var distanceKilometers: Double {
        let radians = Double.pi / 180
        return segments.reduce(0.0) { total, segment in
            total + zip(segment, segment.dropFirst()).reduce(0.0) { sum, pair in
                let a = pair.0, b = pair.1
                let dLat = (b.latitude - a.latitude) * radians
                let dLon = (b.longitude - a.longitude) * radians
                let h = pow(sin(dLat / 2), 2) + cos(a.latitude * radians) * cos(b.latitude * radians) * pow(sin(dLon / 2), 2)
                return sum + 6371 * 2 * asin(sqrt(min(1, max(0, h))))
            }
        }
    }

    static func parse(_ data: Data, fallbackName: String) throws -> GPXTrack {
        guard data.count <= byteLimit else { throw GPXError.tooLarge }
        let delegate = GPXReader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.invalid else { throw GPXError.invalid }
        let useRoutes = delegate.tracks.isEmpty
        let segments = useRoutes ? delegate.routes : delegate.tracks
        guard !segments.isEmpty else { throw GPXError.empty }
        let name = useRoutes ? delegate.routeName : delegate.trackName
        return GPXTrack(name: name.isEmpty ? fallbackName : name, segments: segments)
    }

    /// Distance to the closest recorded segment, not a road-routing distance.
    func distanceFromTrace(to point: GPXPoint) -> Double {
        let radians = Double.pi / 180
        let scaleX = 6_371_000 * radians * cos(point.latitude * radians)
        let scaleY = 6_371_000 * radians
        func xy(_ p: GPXPoint) -> (Double, Double) {
            var delta = p.longitude - point.longitude
            if delta > 180 { delta -= 360 }
            if delta < -180 { delta += 360 }
            return (delta * scaleX, (p.latitude - point.latitude) * scaleY)
        }
        var best = Double.infinity
        for segment in segments {
            for index in 1..<segment.count {
                let a = xy(segment[index - 1]), b = xy(segment[index])
                let dx = b.0 - a.0, dy = b.1 - a.1
                let lengthSquared = dx * dx + dy * dy
                let fraction = lengthSquared > 0 ? min(1, max(0, -(a.0 * dx + a.1 * dy) / lengthSquared)) : 0
                best = min(best, hypot(a.0 + fraction * dx, a.1 + fraction * dy))
            }
        }
        return best
    }
}

/// Keep the original bytes, including waypoints and Wikiloc extensions.
nonisolated struct GPXDocument {
    let data: Data
    let track: GPXTrack

    init(data: Data, fallbackName: String) throws {
        self.data = data
        track = try GPXTrack.parse(data, fallbackName: fallbackName)
    }

    static func load(from url: URL, fallbackName: String? = nil) throws -> GPXDocument {
        guard url.isFileURL else { throw GPXError.invalid }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: GPXTrack.byteLimit + 1) ?? Data()
        let fallback = fallbackName ?? String(url.deletingPathExtension().lastPathComponent.prefix(160))
        return try GPXDocument(data: data, fallbackName: fallback)
    }
}

nonisolated enum GPXError: LocalizedError {
    case tooLarge, invalid, empty, importInProgress
    var errorDescription: String? {
        switch self {
        case .tooLarge: return "GPX trop volumineux (10 Mo ou 30 000 points maximum)."
        case .invalid: return "GPX invalide : vérifier les coordonnées et le format XML (30 000 points maximum)."
        case .empty: return "Aucune trace ou route GPX contenant au moins deux points."
        case .importInProgress: return "Une trace est déjà en cours d’importation. Réessaie dans un instant."
        }
    }
}

private nonisolated final class GPXReader: NSObject, XMLParserDelegate {
    var tracks: [[GPXPoint]] = []
    var routes: [[GPXPoint]] = []
    var trackName = ""
    var routeName = ""
    private var currentName = ""
    private var firstSegmentIndex = 0
    var invalid = false
    private var path: [String] = []
    private var points: [GPXPoint] = []
    private var count = 0
    private var text = ""
    private var pendingPoint: GPXPoint?
    private lazy var isoFormatter = ISO8601DateFormatter()
    private lazy var fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let tag = elementName.components(separatedBy: ":").last ?? elementName
        path.append(tag)
        text = ""
        if path == ["gpx", "trk"] || path == ["gpx", "rte"] {
            currentName = ""
            firstSegmentIndex = tracks.count
        }
        if path == ["gpx", "trk", "trkseg"] || path == ["gpx", "rte"] { points = [] }
        guard path == ["gpx", "trk", "trkseg", "trkpt"] || path == ["gpx", "rte", "rtept"] else { return }
        count += 1
        guard count <= 30_000,
              let latitude = Double(attributes["lat"] ?? ""),
              let longitude = Double(attributes["lon"] ?? ""),
              latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            invalid = true
            parser.abortParsing()
            return
        }
        pendingPoint = GPXPoint(latitude: latitude, longitude: longitude)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let parent = path.dropLast().last
        let pointField = parent == "trkpt" || parent == "rtept"
        if pointField, path.last == "ele", let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite {
            pendingPoint?.elevation = value
        }
        if pointField, path.last == "time" {
            let timestamp = text.trimmingCharacters(in: .whitespacesAndNewlines)
            pendingPoint?.timestamp = isoFormatter.date(from: timestamp) ?? fractionalFormatter.date(from: timestamp)
        }
        if path == ["gpx", "trk", "trkseg", "trkpt"] || path == ["gpx", "rte", "rtept"] {
            if let pendingPoint { points.append(pendingPoint) }
            pendingPoint = nil
        }
        if path == ["gpx", "trk", "name"] || path == ["gpx", "rte", "name"] {
            currentName = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        }
        if path == ["gpx", "trk", "trkseg"], points.count >= 2 { tracks.append(points) }
        if path == ["gpx", "trk"], trackName.isEmpty, tracks.count > firstSegmentIndex { trackName = currentName }
        if path == ["gpx", "rte"], points.count >= 2 {
            routes.append(points)
            if routeName.isEmpty { routeName = currentName }
        }
        if !path.isEmpty { path.removeLast() }
        text = ""
    }
}
