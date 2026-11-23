import Foundation

/// A rectangle in the upright phone image, using a top-left origin.
/// Only validated coordinates can reach the broadcast renderer.
struct ScreenCrop: Codable, Equatable {
    enum Orientation: String, Codable { case portrait, landscape }
    let left: Double
    let top: Double
    let width: Double
    let height: Double
    let orientation: Orientation

    init?(left: Double, top: Double, width: Double, height: Double,
          orientation: Orientation = .portrait) {
        guard [left, top, width, height].allSatisfy({ $0.isFinite }),
              left >= 0, top >= 0, width > 0, height > 0,
              width <= 1, height <= 1, left <= 1, top <= 1,
              left + width <= 1 + 4 * Double.ulpOfOne,
              top + height <= 1 + 4 * Double.ulpOfOne else { return nil }
        self.left = min(left, 1 - width)
        self.top = min(top, 1 - height)
        self.width = width
        self.height = height
        self.orientation = orientation
    }

    private enum CodingKeys: String, CodingKey { case left, top, width, height, orientation }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let crop = try ScreenCrop(left: values.decode(Double.self, forKey: .left),
            top: values.decode(Double.self, forKey: .top),
            width: values.decode(Double.self, forKey: .width),
            height: values.decode(Double.self, forKey: .height),
            orientation: values.decode(Orientation.self, forKey: .orientation)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Invalid screen crop rectangle"))
        }
        self = crop
    }

    struct PixelBounds: Equatable {
        let left: Int
        let top: Int
        let width: Int
        let height: Int
        let bottomOriginY: Int
    }

    func pixelBounds(sourceWidth: Int, sourceHeight: Int) -> PixelBounds? {
        // Reject a rotated phone instead of accidentally sending another area.
        guard sourceWidth > 0, sourceHeight > 0,
              sourceWidth <= 32768, sourceHeight <= 32768,
              (sourceHeight >= sourceWidth) == (orientation == .portrait) else { return nil }
        let w = Double(sourceWidth), h = Double(sourceHeight)
        // Round inward so a selected region never expands beyond its boundaries.
        let x1 = Int((left * w).rounded(.up))
        let y1 = Int((top * h).rounded(.up))
        let x2 = min(sourceWidth, Int(((left + width) * w).rounded(.down)))
        let y2 = min(sourceHeight, Int(((top + height) * h).rounded(.down)))
        guard x2 > x1, y2 > y1 else { return nil }
        return PixelBounds(left: x1, top: y1, width: x2 - x1, height: y2 - y1,
                           bottomOriginY: sourceHeight - y2)
    }
}

enum BroadcastFraming: Equatable {
    case fullScreen, window(ScreenCrop), invalid

    private struct Stored: Codable {
        let mode: String
        var crop: ScreenCrop? = nil
    }

    static func load(_ raw: String?) -> Self {
        guard let raw else { return .fullScreen }
        guard let data = raw.data(using: .utf8),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return .invalid }
        switch stored.mode {
        case "fullScreen": return stored.crop == nil ? .fullScreen : .invalid
        case "window": return stored.crop.map(Self.window) ?? .invalid
        default: return .invalid
        }
    }

    var serialized: String? {
        let stored: Stored
        switch self {
        case .fullScreen: stored = Stored(mode: "fullScreen")
        case .window(let crop): stored = Stored(mode: "window", crop: crop)
        case .invalid: return nil
        }
        guard let data = try? JSONEncoder().encode(stored) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    var requiresBroadcast: Bool { self != .fullScreen }
}

enum KoveScreenPreset: String, CaseIterable, Identifiable {
    case kove800X = "Kove 800X (600 × 1024)"
    case kove450Rally = "Kove 450 Rally (480 × 800)"
    case kove510X = "Kove 510X / Colove (640 × 1284)"
    case koveLandscape = "Landscape Display (1280 × 720)"
    case koveSquare = "Square Display (800 × 800)"
    
    var id: String { rawValue }
    
    var width: Int {
        switch self {
        case .kove800X: return 600
        case .kove450Rally: return 480
        case .kove510X: return 640
        case .koveLandscape: return 1280
        case .koveSquare: return 800
        }
    }
    
    var height: Int {
        switch self {
        case .kove800X: return 1024
        case .kove450Rally: return 800
        case .kove510X: return 1284
        case .koveLandscape: return 720
        case .koveSquare: return 800
        }
    }
    
    var displayName: String {
        switch self {
        case .kove800X: return "Kove 800X / Rally (600 × 1024)"
        case .kove450Rally: return "Kove 450 Rally (480 × 800)"
        case .kove510X: return "Kove 510X / Colove (640 × 1284)"
        case .koveLandscape: return "Écran horizontal (1280 × 720)"
        case .koveSquare: return "Écran carré (800 × 800)"
        }
    }
    
    static var appGroupSuiteName: String {
        Bundle.main.object(forInfoDictionaryKey: "DoubleInterfaceAppGroup") as? String
            ?? "group.com.nicolasrivet.NicoMirror"
    }
    static let presetKey = "selected_kove_screen_preset"
    static let topPaddingKey = "screen_top_padding"
    static let bottomPaddingKey = "screen_bottom_padding"
    static let keepAspectRatioKey = "screen_keep_aspect_ratio"
    static let broadcastFramingKey = "screen_broadcast_framing"
    static let configChangedNotification = Notification.Name("KoveScreenPresetConfigChanged")

    static var broadcastFraming: BroadcastFraming {
        get {
            let shared = UserDefaults(suiteName: appGroupSuiteName)
            let store = shared?.object(forKey: broadcastFramingKey) != nil ? shared : UserDefaults.standard
            guard let store, store.object(forKey: broadcastFramingKey) != nil else { return .fullScreen }
            guard let raw = store.string(forKey: broadcastFramingKey) else { return .invalid }
            return BroadcastFraming.load(raw)
        }
        set {
            guard let raw = newValue.serialized else { return }
            let shared = UserDefaults(suiteName: appGroupSuiteName)
            shared?.set(raw, forKey: broadcastFramingKey)
            UserDefaults.standard.set(raw, forKey: broadcastFramingKey)
            NotificationCenter.default.post(name: configChangedNotification, object: nil)
        }
    }
    
    static var current: KoveScreenPreset {
        get {
            let suiteDefaults = UserDefaults(suiteName: appGroupSuiteName) ?? UserDefaults.standard
            if let savedRaw = suiteDefaults.string(forKey: presetKey),
               let preset = KoveScreenPreset(rawValue: savedRaw) {
                return preset
            }
            return .kove800X
        }
        set {
            let suiteDefaults = UserDefaults(suiteName: appGroupSuiteName) ?? UserDefaults.standard
            suiteDefaults.set(newValue.rawValue, forKey: presetKey)
            suiteDefaults.synchronize()
            UserDefaults.standard.set(newValue.rawValue, forKey: presetKey)
            NotificationCenter.default.post(name: configChangedNotification, object: nil)
        }
    }
    
    static var topPadding: Int {
        get {
            let suiteDefaults = UserDefaults(suiteName: appGroupSuiteName) ?? UserDefaults.standard
            if suiteDefaults.object(forKey: topPaddingKey) != nil {
                return max(0, min(suiteDefaults.integer(forKey: topPaddingKey), 300))
            }
            return max(0, min(UserDefaults.standard.integer(forKey: topPaddingKey), 300))
        }
        set {
            let clamped = max(0, min(newValue, 300))
            let suiteDefaults = UserDefaults(suiteName: appGroupSuiteName) ?? UserDefaults.standard
            suiteDefaults.set(clamped, forKey: topPaddingKey)
            suiteDefaults.synchronize()
            UserDefaults.standard.set(clamped, forKey: topPaddingKey)
            NotificationCenter.default.post(name: configChangedNotification, object: nil)
        }
    }
    
    static var bottomPadding: Int {
        get {
            let suiteDefaults = UserDefaults(suiteName: appGroupSuiteName) ?? UserDefaults.standard
            if suiteDefaults.object(forKey: bottomPaddingKey) != nil {
                return max(0, min(suiteDefaults.integer(forKey: bottomPaddingKey), 300))
            }
            return max(0, min(UserDefaults.standard.integer(forKey: bottomPaddingKey), 300))
        }
        set {
            let clamped = max(0, min(newValue, 300))
            let suiteDefaults = UserDefaults(suiteName: appGroupSuiteName) ?? UserDefaults.standard
            suiteDefaults.set(clamped, forKey: bottomPaddingKey)
            suiteDefaults.synchronize()
            UserDefaults.standard.set(clamped, forKey: bottomPaddingKey)
            NotificationCenter.default.post(name: configChangedNotification, object: nil)
        }
    }
    
    static var keepAspectRatio: Bool {
        get {
            let suiteDefaults = UserDefaults(suiteName: appGroupSuiteName) ?? UserDefaults.standard
            if suiteDefaults.object(forKey: keepAspectRatioKey) != nil {
                return suiteDefaults.bool(forKey: keepAspectRatioKey)
            }
            return UserDefaults.standard.bool(forKey: keepAspectRatioKey)
        }
        set {
            let suiteDefaults = UserDefaults(suiteName: appGroupSuiteName) ?? UserDefaults.standard
            suiteDefaults.set(newValue, forKey: keepAspectRatioKey)
            suiteDefaults.synchronize()
            UserDefaults.standard.set(newValue, forKey: keepAspectRatioKey)
            NotificationCenter.default.post(name: configChangedNotification, object: nil)
        }
    }
}

/// Shared by the phone, the broadcast target and the portable tests.
nonisolated enum TFTFrameRatePolicy {
    static let targetFPS: Int32 = 15
    static var timerInterval: TimeInterval { 1.0 / TimeInterval(targetFPS) }
    static let maxPendingVideoBytes = 256 * 1024
    static let snapshotTimeout: TimeInterval = 8

    static func visibleFPS(measured: Double, lastCaptureUptime: TimeInterval?,
                           nowUptime: TimeInterval, maxAge: TimeInterval = 3) -> Double {
        guard let last = lastCaptureUptime, measured.isFinite, measured > 0,
              nowUptime.isFinite, nowUptime >= last, nowUptime - last <= maxAge else { return 0 }
        return measured
    }
}

/// One welcome screen per video connection. Its three seconds start with a
/// successful socket write of a logo frame, including after a slow connection.
nonisolated struct TFTStartupSplash {
    private(set) var pending = false
    private var firstLogoTimestamp: TimeInterval?
    private(set) var deadline: TimeInterval?

    mutating func arm() {
        pending = true
        firstLogoTimestamp = nil
        deadline = nil
    }

    mutating func submittedLogo(at timestamp: TimeInterval) {
        if pending && firstLogoTimestamp == nil { firstLogoTimestamp = timestamp }
    }

    func acceptsFrame(at timestamp: TimeInterval) -> Bool {
        !pending || firstLogoTimestamp.map { timestamp >= $0 } == true
    }

    mutating func sentFrame(capturedAt: TimeInterval?, sentAt: TimeInterval) {
        guard pending, deadline == nil, let capturedAt, let firstLogoTimestamp,
              capturedAt >= firstLogoTimestamp else { return }
        deadline = sentAt + 3
    }

    mutating func shouldShow(at now: TimeInterval) -> Bool {
        if let deadline, now >= deadline { self = Self() }
        return pending
    }
}
