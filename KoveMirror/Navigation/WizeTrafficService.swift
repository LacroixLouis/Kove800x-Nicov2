import Foundation
import Combine
import CoreLocation
import MapKit
import UIKit
@preconcurrency import UserNotifications

/// Independent of the on-screen renderer: an active road journey continues
/// evaluating nearby incidents when the iPhone is locked.
@MainActor
final class WizeTrafficService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = WizeTrafficService()
    @Published private(set) var status = "Trafic TomTom prêt"
    @Published private(set) var notificationStatus = "À autoriser"
    @Published private(set) var incidents: [TomTomIncident] = []
    @Published private(set) var alertText: String?
    @Published private(set) var alertExpires = Date.distantPast
    @Published var alertsEnabled = UserDefaults.standard.object(forKey: "wize.incidentAlerts") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(alertsEnabled, forKey: "wize.incidentAlerts")
            if alertsEnabled { requestNotificationAccess() }
            else { alertText = nil; UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["wize-current-traffic"]) }
        }
    }
    @Published var soundEnabled = UserDefaults.standard.object(forKey: "wize.incidentSound") as? Bool ?? true {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: "wize.incidentSound") }
    }
    var visualTrafficActive = false
    private var started = false
    private var subscriptions = Set<AnyCancellable>()
    private var timer: Timer?
    private var notificationAccessTask: Task<Void, Never>?
    private var fetchTask: URLSessionDataTask?
    private var fetchedAt = Date.distantPast
    private var retryAt = Date.distantPast
    private var lastRequest = Date.distantPast
    private var routeIdentity: ObjectIdentifier?
    private var geometry: TrafficRouteGeometry?
    private var candidatesAt = Date.distantPast
    private var candidateCache: [(TomTomIncident, Double)] = []
    private var alertPolicy = TrafficAlertPolicy()
    private var wasInCommunityZone = false
    private let configuration = TomTomTrafficConfiguration.bundled()
    private let session = URLSession(configuration: .ephemeral)

    private override init() { super.init() }

    func start() {
        guard !started, !ProcessInfo.processInfo.arguments.contains("--ui-screenshots") else { return }
        started = true
        UNUserNotificationCenter.current().delegate = self
        NotificationCenter.default.publisher(for: .nicoNavigationUpdated)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .wizeCommunityUpdated)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.candidatesAt = .distantPast; self?.refresh() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.requestNotificationAccess(); self?.refresh() }.store(in: &subscriptions)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        requestNotificationAccess()
        refresh()
    }

    func requestNotificationAccess() {
        guard alertsEnabled, UIApplication.shared.applicationState == .active,
              notificationAccessTask == nil else { return }
        // Keep the authorization flow on one actor. Nested callbacks used to
        // share a mutable weak capture and a non-Sendable notification center.
        notificationAccessTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.notificationAccessTask = nil }
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                do {
                    let allowed = try await center.requestAuthorization(options: [.alert, .sound])
                    self.notificationStatus = allowed ? "Autorisées" : "Refusées dans Réglages iPhone"
                } catch {
                    self.notificationStatus = "Autorisation indisponible · réessayer"
                }
            } else {
                self.notificationStatus = settings.authorizationStatus == .denied ? "Refusées dans Réglages iPhone" : "Autorisées"
            }
        }
    }

    func refresh() {
        let nav = LocationAndNavigationManager.shared
        let now = Date()
        if now >= alertExpires { alertText = nil }
        guard visualTrafficActive || (alertsEnabled && nav.isNavigating) else { return }
        guard let fix = nav.userLocation,
              ProjectionPolicy.isFresh(timestamp: fix.timestamp, accuracy: fix.horizontalAccuracy, now: now) else { return }
        if now.timeIntervalSince(fetchedAt) > TomTomTrafficConfiguration.maximumAge, !incidents.isEmpty {
            incidents = []; status = "Trafic en attente de connexion"
            candidatesAt = .distantPast
        }
        evaluateAlerts(at: fix, now: now)
        guard fetchTask == nil, now >= retryAt, now.timeIntervalSince(lastRequest) >= 60 else { return }
        guard let configuration,
              let request = configuration.incidentsRequest(around: TrafficCoordinate(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)) else {
            status = "Configuration TomTom manquante"; return
        }
        lastRequest = now
        fetchTask = session.dataTask(with: request) { [weak self] data, response, error in
            let http = response as? HTTPURLResponse
            let decoded: TomTomIncidentResponse? = data.flatMap {
                guard $0.count < 5_000_000 else { return nil }
                return try? JSONDecoder().decode(TomTomIncidentResponse.self, from: $0)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.fetchTask = nil
                guard error == nil, http?.statusCode == 200, let decoded else {
                    self.retryAt = Date().addingTimeInterval(TomTomTrafficConfiguration.retryDelay(
                        status: http?.statusCode ?? 0, retryAfter: http?.value(forHTTPHeaderField: "Retry-After")))
                    self.status = http?.statusCode == 429 ? "Quota TomTom atteint · nouvelle tentative différée" : "Trafic indisponible · nouvelle tentative différée"
                    return
                }
                self.fetchedAt = Date()
                self.incidents = decoded.incidents.filter { !$0.geometry.points.isEmpty && $0.isCurrent(at: Date()) }
                self.candidatesAt = .distantPast
                self.status = "TomTom · mis à jour à " + DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
                self.evaluateAlerts(at: fix, now: Date())
            }
        }
        fetchTask?.resume()
    }

    private func evaluateAlerts(at fix: CLLocation, now: Date) {
        let nav = LocationAndNavigationManager.shared
        let position = TrafficCoordinate(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)
        if alertsEnabled, nav.isNavigating || (visualTrafficActive && nav.hasActiveBackgroundRide) {
            let staticEntry = WizeSafetyZones.shared.enteredZone(at: position, now: now)
            let communityInside = WizeSafetyZones.shared.enabled && WizeCommunityService.shared.enabled &&
                WizeCommunityService.shared.reports.contains {
                    $0.kind == .dangerZone && $0.expires > now && $0.point.distance(to: position) <= 3_000
                }
            let communityEntry = communityInside && !wasInCommunityZone
            wasInCommunityZone = communityInside
            if (staticEntry || communityEntry), alertPolicy.accept(id: "vigilance:\(Int(now.timeIntervalSince1970/600))", now: now) {
                publishAlert("Zone de vigilance", detail: "Sois attentif à la signalisation et aux limitations de vitesse.", now: now)
                return
            }
        }
        guard alertsEnabled, nav.isNavigating, let route = nav.currentRoute,
              let current = nav.userLocation,
              ProjectionPolicy.isFresh(timestamp: current.timestamp, accuracy: current.horizontalAccuracy, now: now) else { return }
        if routeIdentity != ObjectIdentifier(route) {
            routeIdentity = ObjectIdentifier(route)
            candidatesAt = .distantPast
            let line = route.polyline
            geometry = TrafficRouteGeometry(points: (0..<line.pointCount).map {
                let p = line.points()[$0].coordinate
                return TrafficCoordinate(latitude: p.latitude, longitude: p.longitude)
            })
        }
        let rider = TrafficCoordinate(latitude: current.coordinate.latitude, longitude: current.coordinate.longitude)
        // Matching every incident against a road polyline is bounded to once
        // per five seconds, or immediately after new server data arrives.
        if now.timeIntervalSince(candidatesAt) >= 5 {
            let sharedIncidents = WizeCommunityService.shared.enabled ? WizeCommunityService.shared.reports
                .filter { $0.kind != .dangerZone && $0.expires > now }.map(\.trafficIncident) : []
            candidateCache = (incidents + sharedIncidents).compactMap { event -> (TomTomIncident, Double)? in
                guard event.isSignificant, event.isCurrent(at: now),
                      let distance = geometry?.distanceAhead(to: event, from: rider) else { return nil }
                return (event, distance)
            }.sorted { $0.1 < $1.1 }
            candidatesAt = now
        }
        guard let (incident, _) = candidateCache.first(where: { alertPolicy.notified[$0.0.id] == nil }),
              incident.isCurrent(at: now), let distance = geometry?.distanceAhead(to: incident, from: rider),
              alertPolicy.accept(id: incident.id, now: now) else { return }
        let distanceText = distance >= 1_000 ? String(format: "%.1f km", distance / 1_000) : "\(Int(distance / 50) * 50) m"
        let message = "\(incident.title) dans \(distanceText)"
        publishAlert(message, detail: incident.detail, now: now)
    }

    private func publishAlert(_ message: String, detail: String, now: Date) {
        let nav = LocationAndNavigationManager.shared
        alertText = message
        alertExpires = now.addingTimeInterval(14)
        let content = UNMutableNotificationContent()
        content.title = "Rivroute · " + message
        content.body = detail
        content.threadIdentifier = "wize-traffic"
        let audible = soundEnabled && !nav.isAudioMuted
        if audible { content.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "wize-current-traffic", content: content, trigger: nil))
        if audible, UIApplication.shared.applicationState == .active { nav.announceTraffic(message) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // The active app reads the alert aloud through navigation audio. Keep
        // the foreground system banner silent to avoid two sounds at once.
        completionHandler([.banner, .list])
    }
}
