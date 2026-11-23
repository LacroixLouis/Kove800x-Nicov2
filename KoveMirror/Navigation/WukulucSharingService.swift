import Foundation
import Combine

@MainActor
final class WukulucSharingService: ObservableObject {
    static let shared = WukulucSharingService()
    @Published private(set) var routes: [WukulucSharedRoute] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var userID: UUID?
    private let configuration = CommunityConfiguration.bundled()
    private let network = URLSession(configuration: .ephemeral)
    private var fetchID = UUID()
    private static let fields = "id,owner_id,name,activity,distance_km,ascent_m,duration_s,start_lat,start_lon,point_count,created_at"
    private init() {}

    nonisolated enum Failure: LocalizedError {
        case unavailable, denied, rateLimited, notFound, configuration
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Les parcours partagés sont momentanément indisponibles."
            case .denied: return "Ce parcours ne peut pas être modifié depuis cet appareil."
            case .rateLimited: return "Attends un instant avant de partager un autre parcours."
            case .notFound: return "Ce parcours a été retiré ou n’est plus disponible."
            case .configuration: return "Le partage de parcours n’est pas configuré."
            }
        }
    }

    private func request(path: String, method: String = "GET", body: [String: Any]? = nil,
                         token: String) async throws -> Data {
        guard let configuration,
              let url = URL(string: configuration.url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + path)
        else { throw Failure.configuration }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 40)
        request.httpMethod = method
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        }
        let (data, response) = try await network.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, data.count <= 18_000_000 else { throw Failure.unavailable }
        guard (200...299).contains(response.statusCode) else {
            if response.statusCode == 429 { throw Failure.rateLimited }
            if response.statusCode == 401 || response.statusCode == 403 { throw Failure.denied }
            let details = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if details?["code"] as? String == "P0001" { throw Failure.rateLimited }
            throw Failure.unavailable
        }
        return data
    }

    private func session() async throws -> CommunitySession {
        let session = try await WizeCommunityService.shared.authenticatedCommunitySession()
        if userID == nil {
            let data = try await request(path: "auth/v1/user", token: session.access_token)
            userID = try JSONDecoder().decode(WukulucAuthUser.self, from: data).id
        }
        return session
    }

    private func path(_ query: [URLQueryItem]) throws -> String {
        var components = URLComponents()
        components.path = "rest/v1/wukuluc_routes"
        components.queryItems = query
        guard let result = components.string else { throw Failure.configuration }
        return result
    }

    func refresh(activity: TrailActivity? = nil, query: String = "") async {
        let id = UUID(); fetchID = id; loading = true; error = nil
        defer { if fetchID == id { loading = false } }
        do {
            let auth = try await session()
            var items = [URLQueryItem(name: "select", value: Self.fields),
                         URLQueryItem(name: "order", value: "created_at.desc"),
                         URLQueryItem(name: "limit", value: "100")]
            if let activity { items.append(URLQueryItem(name: "activity", value: "eq." + activity.rawValue)) }
            let term = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
            if !term.isEmpty { items.append(URLQueryItem(name: "name", value: "ilike.*" + term + "*")) }
            let data = try await request(path: path(items), token: auth.access_token)
            let result = try JSONDecoder().decode([WukulucSharedRoute].self, from: data)
            guard fetchID == id else { return }
            routes = result
        } catch is CancellationError { }
        catch { if fetchID == id { self.error = error.localizedDescription } }
    }

    func publish(_ entry: SavedTrack, activity: TrailActivity) async throws -> WukulucSharedRoute {
        let document = try GPXDocument.load(from: TrackLibrary.shared.originalURL(entry))
        guard let start = document.track.segments.first?.first else { throw GPXError.empty }
        let auth = try await session()
        // An interrupted successful upload can be retried without duplicates.
        let lookup = try path([.init(name: "select", value: Self.fields), .init(name: "id", value: "eq." + entry.id.uuidString)])
        let existing = try await request(path: lookup, token: auth.access_token)
        if let match = try JSONDecoder().decode([WukulucSharedRoute].self, from: existing).first {
            guard match.owner_id == userID else { throw Failure.denied }
            return match
        }
        var body: [String: Any] = ["id": entry.id.uuidString, "name": String(entry.name.prefix(160)),
            "activity": activity.rawValue, "distance_km": document.track.distanceKilometers,
            "point_count": document.track.pointCount, "start_lat": start.latitude, "start_lon": start.longitude,
            "gpx_base64": document.data.base64EncodedString()]
        if let ascent = entry.elevationGainMeters { body["ascent_m"] = ascent }
        if let duration = entry.recordedDuration { body["duration_s"] = duration }
        let data = try await request(path: "rest/v1/wukuluc_routes?select=" + Self.fields,
                                     method: "POST", body: body, token: auth.access_token)
        guard let result = try JSONDecoder().decode([WukulucSharedRoute].self, from: data).first else { throw Failure.unavailable }
        routes.removeAll { $0.id == result.id }; routes.insert(result, at: 0)
        return result
    }

    func download(_ route: WukulucSharedRoute) async throws -> SavedTrack {
        try await download(id: route.id, name: route.name, activity: TrailActivity(rawValue: route.activity))
    }

    func download(id: UUID, name: String = "Parcours partagé", activity: TrailActivity? = nil) async throws -> SavedTrack {
        if let existing = TrackLibrary.shared.tracks.first(where: { $0.sourceID == id || $0.id == id }) { return existing }
        let auth = try await session()
        let query = try path([.init(name: "select", value: "gpx_base64"), .init(name: "id", value: "eq." + id.uuidString), .init(name: "limit", value: "1")])
        let data = try await request(path: query, token: auth.access_token)
        guard let document = try JSONDecoder().decode([WukulucSharedDocument].self, from: data).first else { throw Failure.notFound }
        let original = try document.data()
        return try TrackLibrary.shared.add(data: original, fallbackName: name, activity: activity, sourceID: id)
    }

    func withdraw(_ route: WukulucSharedRoute) async throws {
        let auth = try await session()
        guard route.owner_id == userID else { throw Failure.denied }
        _ = try await request(path: path([.init(name: "id", value: "eq." + route.id.uuidString)]),
                              method: "DELETE", token: auth.access_token)
        routes.removeAll { $0.id == route.id }
    }
}

extension Notification.Name {
    static let wukulucRouteReceived = Notification.Name("WukulucRouteReceived")
}
