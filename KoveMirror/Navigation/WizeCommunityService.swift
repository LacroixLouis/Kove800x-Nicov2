import Foundation
import Combine
import UIKit
import Security
import CoreLocation

@MainActor
final class WizeCommunityService: ObservableObject {
    static let shared = WizeCommunityService()
    @Published private(set) var reports: [CommunityReport] = []
    @Published private(set) var status = "Signalements partagés désactivés"
    @Published private(set) var connected = false
    @Published var enabled = UserDefaults.standard.bool(forKey: "wize.communityEnabled") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "wize.communityEnabled")
            if enabled { start() } else { stop(); reports = []; status = "Signalements partagés désactivés"; changed() }
        }
    }
    private let configuration = CommunityConfiguration.bundled()
    private let network = URLSession(configuration: .ephemeral)
    private var authentication: CommunitySession?
    private var loop: Task<Void,Never>?
    private var heartbeat: Task<Void,Never>?
    private var socket: URLSessionWebSocketTask?
    private var subscriptions = Set<AnyCancellable>()
    private var currentBuckets: [String] = []
    private var reference = 0
    private var lastMessageAt = Date()
    private let keychainService = "DoubleInterface.Wize.Community"
    private var sessionRequest: Task<CommunitySession,Error>?

    nonisolated enum Failure: LocalizedError {
        case unavailable, location, configuration, anonymousDisabled, denied, rateLimited
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Connexion aux signalements indisponible. Réessaie dans un instant."
            case .location: return "Une position GPS récente est nécessaire."
            case .configuration: return "Le serveur de signalements n’est pas configuré."
            case .anonymousDisabled: return "Les signalements partagés ne sont pas encore activés."
            case .denied: return "Action refusée : rapproche-toi de l’incident, ou attends avant de recommencer."
            case .rateLimited: return "Trop de demandes. Attends avant de recommencer."
            }
        }
    }

    private init() {
        authentication = readSession()
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self, self.enabled else { return }; self.start()
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .nicoNavigationUpdated)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.locationChanged() }.store(in: &subscriptions)
    }

    private func locationChanged() {
        guard enabled else { return }
        reports.removeAll { $0.expires <= Date() }
        guard let fix = currentFix() else { return }
        let p = TrafficCoordinate(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)
        if currentBuckets != CommunityReport.neighboringBuckets(p) || loop == nil { start() }
    }

    private func currentFix() -> CLLocation? {
        guard let fix = LocationAndNavigationManager.shared.userLocation,
              ProjectionPolicy.isFresh(timestamp: fix.timestamp, accuracy: fix.horizontalAccuracy, now: Date()) else { return nil }
        return fix
    }

    func start() {
        stop()
        guard enabled, !ProcessInfo.processInfo.arguments.contains("--ui-screenshots") else { return }
        guard configuration != nil else { status = Failure.configuration.localizedDescription; return }
        guard let fix = currentFix() else { status = "En attente du GPS pour les signalements"; return }
        currentBuckets = CommunityReport.neighboringBuckets(.init(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude))
        loop = Task { [weak self] in await self?.run() }
    }

    func stop() {
        loop?.cancel(); loop = nil
        heartbeat?.cancel(); heartbeat = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        connected = false
    }

    private func run() async {
        var retry: UInt64 = 2
        while enabled && !Task.isCancelled {
            do {
                status = "Connexion aux signalements Rivroute…"
                let auth = try await authenticate()
                try await fetchReports(token: auth.access_token)
                try await connectRealtime(token: auth.access_token)
                retry = 2
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                connected = false
                status = error.localizedDescription
                heartbeat?.cancel(); heartbeat = nil
                socket?.cancel(with: .goingAway, reason: nil); socket = nil
                if case Failure.anonymousDisabled = error { return }
                do { try await Task.sleep(nanoseconds: retry * 1_000_000_000) } catch { return }
                retry = min(60, retry * 2)
            }
        }
    }

    /// The trail-sharing module uses the same anonymous identity and Keychain
    /// session without enabling incident reports or location broadcasting.
    func authenticatedCommunitySession() async throws -> CommunitySession {
        try await authenticate()
    }

    private func authenticate() async throws -> CommunitySession {
        if let authentication, authentication.expires_at > Date().timeIntervalSince1970 + 90 { return authentication }
        if let sessionRequest { return try await sessionRequest.value }
        let request = Task<CommunitySession,Error> {
            let body: [String:Any]
            let path: String
            if let authentication {
                path = "auth/v1/token?grant_type=refresh_token"
                body = ["refresh_token":authentication.refresh_token]
            } else { path = "auth/v1/signup"; body = [:] }
            do {
                let data = try await api(path: path, method: "POST", body: body)
                return try JSONDecoder().decode(CommunitySession.self, from: data)
            } catch Failure.denied {
                authentication = nil
                deleteSession()
                throw Failure.unavailable
            }
        }
        sessionRequest = request
        defer { sessionRequest = nil }
        let session = try await request.value
        authentication = session
        saveSession(session)
        return session
    }

    private func api(path: String, method: String = "GET", body: [String:Any]? = nil, token: String? = nil) async throws -> Data {
        guard let configuration,
              let url = URL(string: configuration.url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + path) else { throw Failure.configuration }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data,response) = try await network.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw Failure.unavailable }
        guard (200...299).contains(response.statusCode), data.count < 3_000_000 else {
            let details = (try? JSONSerialization.jsonObject(with: data)) as? [String:Any]
            if details?["error_code"] as? String == "anonymous_provider_disabled" ||
                details?["code"] as? String == "anonymous_provider_disabled" { throw Failure.anonymousDisabled }
            if response.statusCode == 429 { throw Failure.rateLimited }
            if response.statusCode == 401, let saved = authentication {
                authentication = CommunitySession(access_token: saved.access_token, refresh_token: saved.refresh_token, expires_at: 0)
            }
            if response.statusCode == 401 || response.statusCode == 400 || response.statusCode == 403 { throw Failure.denied }
            throw Failure.unavailable
        }
        return data
    }

    private func fetchReports(token: String) async throws {
        guard var parts = URLComponents(string: "rest/v1/wize_reports") else { throw Failure.configuration }
        parts.queryItems = [URLQueryItem(name: "select",value: "*"),
                            URLQueryItem(name: "bucket",value: "in.(" + currentBuckets.joined(separator: ",") + ")"),
                            URLQueryItem(name: "expires_at",value: "gt." + ISO8601DateFormatter().string(from: Date())),
                            URLQueryItem(name: "order",value: "created_at.desc"), URLQueryItem(name: "limit",value: "250")]
        guard let path = parts.string else { throw Failure.configuration }
        let data = try await api(path: path, token: token)
        reports = try JSONDecoder().decode([CommunityReport].self, from: data).filter { $0.point.isValid && $0.expires > Date() }
        changed()
    }

    private func connectRealtime(token: String) async throws {
        guard let configuration,
              var parts = URLComponents(url: configuration.url, resolvingAgainstBaseURL: false) else { throw Failure.configuration }
        parts.scheme = "wss"
        parts.path = "/realtime/v1/websocket"
        parts.queryItems = [URLQueryItem(name: "apikey",value: configuration.publishableKey), URLQueryItem(name: "vsn",value: "1.0.0")]
        guard let url = parts.url else { throw Failure.configuration }
        let connection = network.webSocketTask(with: url)
        socket = connection
        lastMessageAt = Date()
        connection.resume()
        let channel = "realtime:wize-nearby"
        let join = try await send(event: "phx_join", topic: channel, payload: [
            "access_token":token,
            "config":["broadcast":["ack":false,"self":false], "presence":["enabled":false],
                      "postgres_changes":[["event":"*","schema":"public","table":"wize_reports",
                        "filter":"bucket=in.(" + currentBuckets.joined(separator: ",") + ")"]]]
        ], connection: connection)
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 25_000_000_000)
                    guard let self else { return }
                    if Date().timeIntervalSince(self.lastMessageAt) > 60 ||
                        (self.authentication?.expires_at ?? 0) < Date().timeIntervalSince1970 + 90 {
                        connection.cancel(with: .goingAway, reason: nil); return
                    }
                    _ = try await self.send(event: "heartbeat", topic: "phoenix", payload: [:], connection: connection)
                    self.reports.removeAll { $0.expires <= Date() }
                } catch { connection.cancel(with: .goingAway, reason: nil); return }
            }
        }
        while enabled && !Task.isCancelled {
            let incoming = try await connection.receive()
            try Task.checkCancellation()
            lastMessageAt = Date()
            let data: Data
            switch incoming {
            case .data(let bytes): data = bytes
            case .string(let text): data = Data(text.utf8)
            @unknown default: continue
            }
            guard data.count < 3_000_000,
                  let message = try JSONSerialization.jsonObject(with: data) as? [String:Any],
                  let event = message["event"] as? String,
                  let payload = message["payload"] as? [String:Any] else { continue }
            if event == "phx_reply", message["ref"] as? String == join {
                guard payload["status"] as? String == "ok" else { throw Failure.denied }
                connected = true
                status = "Signalements Rivroute en direct"
                // Catch inserts that happened between the initial REST read
                // and the subscription becoming active.
                try await fetchReports(token: token)
            } else if event == "system", payload["status"] as? String == "error" { throw Failure.unavailable }
            else if event == "phx_error" || event == "phx_close" { throw Failure.unavailable }
            else if event == "postgres_changes", let change = payload["data"] as? [String:Any],
                    let record = change["record"] as? [String:Any], !record.isEmpty {
                let bytes = try JSONSerialization.data(withJSONObject: record)
                if let report = try? JSONDecoder().decode(CommunityReport.self, from: bytes) { merge(report) }
            }
        }
    }

    private func send(event: String, topic: String, payload: [String:Any], connection: URLSessionWebSocketTask) async throws -> String {
        reference += 1
        let ref = String(reference)
        let bytes = try JSONSerialization.data(withJSONObject: ["event":event,"topic":topic,"payload":payload,"ref":ref])
        guard let text = String(data: bytes, encoding: .utf8) else { throw Failure.unavailable }
        try await connection.send(.string(text))
        return ref
    }

    func publish(_ kind: CommunityReportKind) async throws {
        guard enabled else { throw Failure.configuration }
        guard let fix = currentFix() else { throw Failure.location }
        let auth = try await authenticate()
        let data = try await api(path: "rest/v1/rpc/wize_publish_report", method: "POST",
            body: ["p_kind":kind.rawValue,"p_latitude":fix.coordinate.latitude,"p_longitude":fix.coordinate.longitude], token: auth.access_token)
        guard let report = decodeReport(data) else { throw Failure.unavailable }
        merge(report)
        if loop == nil { start() }
    }

    func vote(_ report: CommunityReport, confirmed: Bool) async throws {
        guard let fix = currentFix() else { throw Failure.location }
        let auth = try await authenticate()
        let data = try await api(path: "rest/v1/rpc/wize_vote_report", method: "POST",
            body: ["p_report_id":report.id.uuidString,"p_confirmed":confirmed,
                   "p_latitude":fix.coordinate.latitude,"p_longitude":fix.coordinate.longitude], token: auth.access_token)
        guard let update = decodeReport(data) else { throw Failure.unavailable }
        merge(update)
    }

    private func decodeReport(_ data: Data) -> CommunityReport? {
        (try? JSONDecoder().decode(CommunityReport.self, from: data)) ??
            (try? JSONDecoder().decode([CommunityReport].self, from: data))?.first
    }
    private func merge(_ report: CommunityReport) {
        reports.removeAll { $0.id == report.id || $0.expires <= Date() }
        if report.point.isValid, report.expires > Date(), currentBuckets.contains(report.bucket) { reports.insert(report, at: 0) }
        reports = Array(reports.prefix(250))
        changed()
    }
    private func changed() { NotificationCenter.default.post(name: .wizeCommunityUpdated, object: nil) }

    private func keychainQuery() -> [String:Any] {
        [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:keychainService,
         kSecAttrAccount as String:configuration?.url.host ?? "wize"]
    }
    private func readSession() -> CommunitySession? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { return nil }
        return try? JSONDecoder().decode(CommunitySession.self, from: data)
    }
    private func saveSession(_ session: CommunitySession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        let query = keychainQuery()
        let attributes: [String:Any] = [kSecValueData as String:data,
            kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { _,new in new } as CFDictionary, nil)
        }
    }
    private func deleteSession() { SecItemDelete(keychainQuery() as CFDictionary) }
}

extension Notification.Name {
    static let wizeCommunityUpdated = Notification.Name("WizeCommunityUpdated")
}
