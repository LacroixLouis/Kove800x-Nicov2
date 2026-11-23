import Foundation

nonisolated enum CommunityReportKind: String, Decodable, CaseIterable, Identifiable, Sendable {
    case accident, jam, roadworks, hazard, dangerZone = "danger_zone"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .accident: return "Accident"
        case .jam: return "Bouchon"
        case .roadworks: return "Travaux"
        case .hazard: return "Danger sur la route"
        case .dangerZone: return "Zone de vigilance"
        }
    }
    var symbol: String {
        switch self {
        case .accident: return "car.side.rear.and.collision.and.car.side.front"
        case .jam: return "car.2.fill"
        case .roadworks: return "cone.fill"
        case .hazard: return "exclamationmark.triangle.fill"
        case .dangerZone: return "exclamationmark.shield.fill"
        }
    }
}

nonisolated struct CommunityReport: Decodable, Identifiable, Sendable {
    let id: UUID
    let kind: CommunityReportKind
    let latitude: Double
    let longitude: Double
    let bucket: String
    let created_at: String
    let expires_at: String
    let confirmations: Int
    let dismissals: Int
    var point: TrafficCoordinate { TrafficCoordinate(latitude: latitude, longitude: longitude) }
    var expires: Date {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.date(from: expires_at) ?? ISO8601DateFormatter().date(from: expires_at) ?? .distantPast
    }
    var trafficIncident: TomTomIncident {
        TomTomIncident(geometry: .init(points: [point]), properties: .init(
            id: "community:" + id.uuidString, iconCategory: kind == .roadworks ? "roadWorks" : kind.rawValue,
            magnitudeOfDelay: kind == .jam ? "moderate" : "unknown",
            events: [.init(description: "Signalement Rivroute · \(confirmations) confirmation(s)")],
            from: nil, to: nil, delay: nil, endTime: expires_at))
    }
    static func neighboringBuckets(_ p: TrafficCoordinate) -> [String] {
        let lat = Int(floor(p.latitude * 2)), lon = Int(floor(p.longitude * 2))
        return (-1...1).flatMap { y in (-1...1).map { x in "\(lat+y):\(lon+x)" } }
    }
}

nonisolated struct CommunityConfiguration: Sendable {
    let url: URL
    let publishableKey: String
    static func bundled(in bundle: Bundle = .main) -> Self? {
        guard let resource = bundle.url(forResource: "WizeCommunity", withExtension: "plist"),
              let data = try? Data(contentsOf: resource),
              let settings = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String:String],
              let text = settings["URL"], let url = URL(string: text), url.scheme == "https",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.host?.hasSuffix(".supabase.co") == true,
              let key = settings["PublishableKey"], key.hasPrefix("sb_publishable_") else { return nil }
        return Self(url: url, publishableKey: key)
    }
}

nonisolated struct CommunitySession: Codable, Sendable {
    let access_token: String
    let refresh_token: String
    let expires_at: Double
    private enum CodingKeys: String, CodingKey { case access_token, refresh_token, expires_at, expires_in }
    init(access_token: String, refresh_token: String, expires_at: Double) {
        self.access_token = access_token
        self.refresh_token = refresh_token
        self.expires_at = expires_at
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        access_token = try c.decode(String.self, forKey: .access_token)
        refresh_token = try c.decode(String.self, forKey: .refresh_token)
        if let absolute = try c.decodeIfPresent(Double.self, forKey: .expires_at) { expires_at = absolute }
        else { expires_at = Date().timeIntervalSince1970 + (try c.decodeIfPresent(Double.self, forKey: .expires_in) ?? 3_600) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(access_token, forKey: .access_token)
        try c.encode(refresh_token, forKey: .refresh_token)
        try c.encode(expires_at, forKey: .expires_at)
    }
}
