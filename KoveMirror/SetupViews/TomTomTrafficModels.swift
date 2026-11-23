import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The personal key is a bundled resource, never a URL parameter or log value.
nonisolated struct TomTomTrafficConfiguration {
    let apiKey: String
    static let refreshInterval: TimeInterval = 60
    static let maximumAge: TimeInterval = 120

    static func bundled(in bundle: Bundle = .main) -> Self? {
        guard let url = bundle.url(forResource: "TomTomTraffic", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
              let key = values["APIKey"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return Self(apiKey: key)
    }

    func tileRequest(layer: String, z: Int, x: Int, y: Int) -> URLRequest? {
        guard ["flow", "incidents"].contains(layer), (0...22).contains(z),
              x >= 0, y >= 0, x < (1 << z), y < (1 << z) else { return nil }
        return request(path: "\(layer)/raster/tile/\(z)/\(x)/\(y)", query: [
            URLQueryItem(name: "style", value: "dark"),
            URLQueryItem(name: "tileSize", value: "256")
        ], accept: "image/png")
    }

    func incidentsRequest(around point: TrafficCoordinate) -> URLRequest? {
        guard point.isValid else { return nil }
        let latitudeDelta = 8_000.0 / 111_320.0
        let longitudeDelta = latitudeDelta / max(0.1, cos(point.latitude * .pi / 180))
        let bounds = [max(-180, point.longitude - longitudeDelta),
                      max(-85, point.latitude - latitudeDelta),
                      min(180, point.longitude + longitudeDelta),
                      min(85, point.latitude + latitudeDelta)]
        var result = request(path: "incidents/details", query: [
            URLQueryItem(name: "bbox", value: bounds.map { String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), $0) }.joined(separator: ",")),
            URLQueryItem(name: "timeValidity", value: "present")
        ], accept: "application/json")
        result?.setValue("incidents(geometry(type,coordinates),properties(id,iconCategory,magnitudeOfDelay,events(description),from,to,delayInSeconds,endTime))", forHTTPHeaderField: "Attributes")
        result?.setValue("fr-FR", forHTTPHeaderField: "Accept-Language")
        return result
    }

    private func request(path: String, query: [URLQueryItem], accept: String) -> URLRequest? {
        guard var url = URLComponents(string: "https://api.tomtom.com/maps/orbis/traffic/" + path) else { return nil }
        url.queryItems = [URLQueryItem(name: "apiVersion", value: "2")] + query
        guard let address = url.url else { return nil }
        var request = URLRequest(url: address, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue(apiKey, forHTTPHeaderField: "TomTom-Api-Key")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        return request
    }

    static func retryDelay(status: Int, retryAfter: String?) -> TimeInterval {
        if status == 401 || status == 403 { return 300 }
        if status == 429 { return max(60, min(Double(retryAfter ?? "") ?? 60, 900)) }
        return 30
    }
}

nonisolated struct TrafficCoordinate: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    var isValid: Bool { latitude.isFinite && longitude.isFinite && (-85...85).contains(latitude) && (-180...180).contains(longitude) }
    func distance(to other: Self) -> Double {
        let scale = cos((latitude + other.latitude) * .pi / 360)
        return hypot((other.longitude - longitude) * scale, other.latitude - latitude) * 111_320
    }
}

nonisolated struct TomTomIncidentResponse: Decodable { let incidents: [TomTomIncident] }

nonisolated struct TomTomIncident: Decodable {
    struct Geometry: Decodable {
        let points: [TrafficCoordinate]
        init(points: [TrafficCoordinate]) { self.points = points }
        private enum CodingKeys: String, CodingKey { case type, coordinates }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let type = try values.decode(String.self, forKey: .type)
            let raw: [[Double]]
            if type == "Point" { raw = [try values.decode([Double].self, forKey: .coordinates)] }
            else if type == "LineString" { raw = try values.decode([[Double]].self, forKey: .coordinates) }
            else { raw = [] }
            points = raw.compactMap { pair in
                guard pair.count >= 2 else { return nil }
                let point = TrafficCoordinate(latitude: pair[1], longitude: pair[0])
                return point.isValid ? point : nil
            }
        }
    }
    struct Properties: Decodable {
        private enum CodingKeys: String, CodingKey {
            case id, iconCategory, magnitudeOfDelay, events, from, to, endTime
            case delay = "delayInSeconds"
        }
        struct Event: Decodable { let description: String? }
        let id: String
        let iconCategory: String
        let magnitudeOfDelay: String?
        let events: [Event]?
        let from: String?
        let to: String?
        let delay: Double?
        let endTime: String?
    }
    let geometry: Geometry
    let properties: Properties
    var id: String { properties.id }
    var title: String {
        switch properties.iconCategory {
        case "accident": return "Accident"
        case "jam": return "Bouchon"
        case "roadWorks": return "Travaux"
        case "roadClosed": return "Route fermée"
        case "laneClosed": return "Voie fermée"
        case "brokenDownVehicle": return "Véhicule en panne"
        case "fog": return "Brouillard"
        case "ice": return "Verglas"
        case "flooding": return "Inondation"
        case "wind": return "Vent fort"
        case "rain": return "Pluie"
        default: return "Danger signalé"
        }
    }
    var detail: String { properties.events?.compactMap(\.description).joined(separator: ". ") ?? properties.from ?? title }
    var isSignificant: Bool {
        properties.iconCategory != "unknown" &&
            (properties.iconCategory != "jam" || properties.magnitudeOfDelay == "major" ||
             properties.magnitudeOfDelay == "moderate" || (properties.delay ?? 0) >= 60)
    }
    func isCurrent(at date: Date) -> Bool {
        guard let raw = properties.endTime else { return true }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let end = parser.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        return end.map { $0 > date } ?? true
    }
}

/// Alert matching is independent of the map viewport. Only the road route
/// ahead of the rider is eligible; panning a map cannot trigger an alert.
nonisolated struct TrafficRouteGeometry {
    let points: [TrafficCoordinate]
    private let cumulative: [Double]
    init(points: [TrafficCoordinate]) {
        self.points = points.filter(\.isValid)
        var totals = [0.0]
        if self.points.count > 1 {
            for index in 1..<self.points.count { totals.append(totals.last! + self.points[index - 1].distance(to: self.points[index])) }
        }
        cumulative = totals
    }
    private func projection(_ p: TrafficCoordinate, from start: Int = 0, to end: Int? = nil) -> (along: Double, lateral: Double, segment: Int)? {
        guard points.count >= 2 else { return nil }
        let scaleX = 111_320 * cos(p.latitude * .pi / 180)
        var best: (along: Double, lateral: Double, segment: Int)?
        for i in start..<min(end ?? (points.count - 1), points.count - 1) {
            let ax = (points[i].longitude - p.longitude) * scaleX
            let ay = (points[i].latitude - p.latitude) * 111_320
            let bx = (points[i + 1].longitude - p.longitude) * scaleX
            let by = (points[i + 1].latitude - p.latitude) * 111_320
            let dx = bx - ax, dy = by - ay
            let denominator = dx * dx + dy * dy
            let t = denominator > 0 ? max(0, min(1, -(ax * dx + ay * dy) / denominator)) : 0
            let distance = hypot(ax + t * dx, ay + t * dy)
            if best == nil || distance < best!.lateral {
                best = (cumulative[i] + t * (cumulative[i + 1] - cumulative[i]), distance, i)
            }
        }
        return best
    }
    func distanceAhead(to incident: TomTomIncident, from rider: TrafficCoordinate) -> Double? {
        guard let origin = projection(rider), origin.lateral <= 100 else { return nil }
        let last = cumulative.firstIndex(where: { $0 > origin.along + 5_000 }) ?? (points.count - 1)
        var nearest: Double?
        let geometry = incident.geometry.points
        let step = max(1, geometry.count / 64)
        for index in stride(from: 0, to: geometry.count, by: step) {
            guard let hit = projection(geometry[index], from: origin.segment, to: max(origin.segment + 1, last)),
                  hit.lateral <= 60 else { continue }
            let ahead = hit.along - origin.along
            guard ahead >= 100, ahead <= 3_000 else { continue }
            // Oriented incident LineStrings allow opposite-direction events
            // to be ignored. Point events have no heading information.
            if geometry.count > 1, let first = geometry.first, let end = geometry.last,
               first.distance(to: end) > 30 {
                let a = points[hit.segment], b = points[hit.segment + 1]
                let scale = cos(a.latitude * .pi / 180)
                let dot = (end.longitude - first.longitude) * (b.longitude - a.longitude) * scale * scale +
                    (end.latitude - first.latitude) * (b.latitude - a.latitude)
                if dot < 0 { continue }
            }
            nearest = min(nearest ?? ahead, ahead)
        }
        return nearest
    }
}

nonisolated struct TrafficAlertPolicy {
    private(set) var notified: [String: Date] = [:]
    private var lastAlert = Date.distantPast
    mutating func accept(id: String, now: Date) -> Bool {
        notified = notified.filter { now.timeIntervalSince($0.value) < 1_800 }
        guard notified[id] == nil, now.timeIntervalSince(lastAlert) >= 45 else { return false }
        notified[id] = now
        lastAlert = now
        return true
    }
}
