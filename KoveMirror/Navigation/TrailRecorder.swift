import Foundation
import Combine
import CoreLocation

enum TrailActivity: String, CaseIterable, Identifiable, Codable {
    case trailMotorcycle = "Moto trail"
    case enduro = "Enduro"
    case hiking = "Randonnée"
    case mountainBike = "VTT"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .trailMotorcycle: return "motorcycle"
        case .enduro: return "mountain.2.fill"
        case .hiking: return "figure.hiking"
        case .mountainBike: return "bicycle"
        }
    }
    var estimatedSpeed: Double {
        switch self {
        case .trailMotorcycle: return 38
        case .enduro: return 22
        case .hiking: return 4.5
        case .mountainBike: return 13
        }
    }
}

enum TrailRecorderState: Equatable {
    case idle, recording, paused
}

/// Records the same filtered GPS fixes already used by navigation, then saves
/// an ordinary GPX file that remains shareable outside Double Interface.
final class TrailRecorder: ObservableObject {
    static let shared = TrailRecorder()

    @Published private(set) var state: TrailRecorderState = .idle
    @Published private(set) var points: [GPXPoint] = []
    @Published private(set) var distanceMeters = 0.0
    @Published private(set) var ascentMeters = 0.0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastAccuracy: Double?
    @Published var activity: TrailActivity = .trailMotorcycle

    private var startedAt: Date?
    private var accumulatedTime: TimeInterval = 0
    private var lastLocation: CLLocation?
    private var segmentStarts: [Int] = [0]
    private var timer: Timer?
    private var subscriptions = Set<AnyCancellable>()

    var recordingSegments: [[GPXPoint]] {
        segmentStarts.enumerated().compactMap { index, start in
            let end = index + 1 < segmentStarts.count ? segmentStarts[index + 1] : points.count
            guard start < end else { return nil }
            return Array(points[start..<end])
        }
    }

    private init() {
        LocationAndNavigationManager.shared.$userLocation
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] location in self?.receive(location) }
            .store(in: &subscriptions)
    }

    func start(activity: TrailActivity? = nil) {
        guard state == .idle else { return }
        if let activity { self.activity = activity }
        points = []
        distanceMeters = 0
        ascentMeters = 0
        elapsed = 0
        accumulatedTime = 0
        lastLocation = nil
        segmentStarts = [0]
        startedAt = Date()
        state = .recording
        LocationAndNavigationManager.shared.setTrailRecordingActive(true)
        startTimer()
    }

    func pause() {
        guard state == .recording else { return }
        updateElapsed()
        accumulatedTime = elapsed
        startedAt = nil
        state = .paused
        timer?.invalidate()
        timer = nil
    }

    func resume() {
        guard state == .paused else { return }
        lastLocation = nil // Never draw a straight line across a pause.
        if segmentStarts.last != points.count { segmentStarts.append(points.count) }
        startedAt = Date()
        state = .recording
        startTimer()
    }

    @discardableResult
    func finish(name: String, library: TrackLibrary = .shared) throws -> SavedTrack {
        guard points.count >= 2 else { throw GPXError.empty }
        updateElapsed()
        let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = gpxData(name: finalName.isEmpty ? defaultName : finalName)
        let entry = try library.add(data: data, fallbackName: defaultName, activity: activity)
        try library.select(entry)
        reset()
        return entry
    }

    func discard() { reset() }

    private var defaultName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "dd MMM yyyy 'à' HH'h'mm"
        return activity.rawValue + " · " + formatter.string(from: Date())
    }

    private func receive(_ location: CLLocation) {
        guard state == .recording,
              location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 50,
              abs(location.timestamp.timeIntervalSinceNow) < 20 else { return }
        lastAccuracy = location.horizontalAccuracy
        if let previous = lastLocation {
            let gap = location.distance(from: previous)
            let interval = location.timestamp.timeIntervalSince(previous.timestamp)
            if gap < 2 && interval < 3 { return }
            if gap < 2_000 { distanceMeters += gap }
            if previous.verticalAccuracy >= 0, previous.verticalAccuracy <= 50,
               location.verticalAccuracy >= 0, location.verticalAccuracy <= 50 {
                let rise = location.altitude - previous.altitude
                if rise > 0, rise < 200 { ascentMeters += rise }
            }
        }
        lastLocation = location
        points.append(GPXPoint(latitude: location.coordinate.latitude,
                               longitude: location.coordinate.longitude,
                               elevation: location.verticalAccuracy >= 0 ? location.altitude : nil,
                               timestamp: location.timestamp))
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateElapsed()
        }
        updateElapsed()
    }

    private func updateElapsed() {
        elapsed = accumulatedTime + (startedAt.map { Date().timeIntervalSince($0) } ?? 0)
    }

    private func reset() {
        timer?.invalidate()
        timer = nil
        LocationAndNavigationManager.shared.setTrailRecordingActive(false)
        state = .idle
        points = []
        distanceMeters = 0
        ascentMeters = 0
        elapsed = 0
        accumulatedTime = 0
        startedAt = nil
        lastLocation = nil
        segmentStarts = [0]
        lastAccuracy = nil
    }

    private func gpxData(name: String) -> Data {
        let dateFormatter = ISO8601DateFormatter()
        let segments = recordingSegments.map { segment in
            let rows = segment.map { point -> String in
                let elevation = point.elevation.map {
                    "<ele>" + String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), $0) + "</ele>"
                } ?? ""
                let time = point.timestamp.map { "<time>" + dateFormatter.string(from: $0) + "</time>" } ?? ""
                return String(format: "<trkpt lat=\"%.8f\" lon=\"%.8f\">",
                              locale: Locale(identifier: "en_US_POSIX"), point.latitude, point.longitude)
                    + elevation + time + "</trkpt>"
            }.joined()
            return "<trkseg>" + rows + "</trkseg>"
        }.joined()
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<gpx version=\"1.1\" creator=\"Double Interface\" xmlns=\"http://www.topografix.com/GPX/1/1\">"
            + "<metadata><name>" + xmlEscaped(name) + "</name></metadata>"
            + "<trk><name>" + xmlEscaped(name) + "</name><type>" + xmlEscaped(activity.rawValue) + "</type>"
            + segments + "</trk></gpx>"
        return Data(xml.utf8)
    }

    private func xmlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
