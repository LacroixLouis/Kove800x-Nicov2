import Foundation
import Combine
import UIKit
import CoreLocation

// Couleurs identiques sur l’iPhone, la miniature et la vidéo TFT.
// Aucune capsule, bordure ou image ne doit masquer la carte.
extension WebMapProfile {
    var overlayColor: UIColor {
        switch self {
        case .explorer: return UIColor(red: 100/255, green: 237/255, blue: 84/255, alpha: 1)
        case .wize: return UIColor(red: 57/255, green: 139/255, blue: 255/255, alpha: 1)
        case .osmand: return UIColor(red: 255/255, green: 159/255, blue: 51/255, alpha: 1)
        }
    }
}

extension Notification.Name {
    static let nicoNavigationUpdated = Notification.Name("NicoNavigationUpdated")
    static let webPanelSourceChanged = Notification.Name("DoubleInterfaceWebPanelSourceChanged")
}

/// Both renderers survive an exchange; only the miniature supplies TFT images.
final class WebCockpitSession: ObservableObject {
    static let shared = WebCockpitSession()
    private let storageKey: String
    @Published private(set) var layout: WebPanelLayout
    @Published private(set) var sourceRevision = UUID()
    @Published private(set) var lockedTFTOnly = false
    // Les cartes sont créées à leur première utilisation.
    // Chaque profil est construit lors de son premier affichage puis conservé.
    lazy var tracks = IntegratedNavigationPanel(kind: .tracks)
    lazy var roads = IntegratedNavigationPanel(kind: .roads)
    lazy var osmand = IntegratedNavigationPanel(kind: .osmand)

    var canvasSize: CGSize {
        let preset = KoveScreenPreset.current
        return CGSize(width: preset.width, height: preset.height)
    }
    private init() {
        storageKey = "doubleInterface.twoMaps.v2" + (ProcessInfo.processInfo.arguments.contains("--ui-screenshots") ? ".screenshots" : "")
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode(WebPanelLayout.self, from: data) {
            var normalized = saved
            normalized.moveMini(x: saved.miniX, y: saved.miniY)
            layout = normalized
        } else { layout = WebPanelLayout() }
    }
    func profile(_ id: WebPanelID) -> WebMapProfile { layout.profile(at: id) }
    func title(_ id: WebPanelID) -> String { profile(id).title }
    func renderer(_ id: WebPanelID) -> IntegratedNavigationPanel {
        switch profile(id) {
        case .explorer: return tracks
        case .wize: return roads
        case .osmand: return osmand
        }
    }
    func assign(_ profile: WebMapProfile, to position: WebPanelID) {
        guard layout.profile(at: position) != profile else { return }
        cancelSnapshot()
        var updated = layout
        updated.assign(profile, to: position)
        layout = updated // Explicit @Published assignment notifies both SwiftUI map hosts.
        updatePausedRenderers()
        sourceRevision = UUID()
        save()
        NotificationCenter.default.post(name: .webPanelSourceChanged, object: nil)
    }
    func showOnPhone(_ profile: WebMapProfile) {
        if layout.profile(at: layout.tft) == profile { exchange() }
        else { assign(profile, to: layout.phone) }
    }
    func exchange() {
        cancelSnapshot()
        var updated = layout
        updated.exchange()
        layout = updated // The iPhone and TFT positions must change in the same transaction.
        updatePausedRenderers()
        sourceRevision = UUID()
        save()
        NotificationCenter.default.post(name: .webPanelSourceChanged, object: nil)
    }
    func moveMini(x: Double, y: Double) {
        var updated = layout
        updated.moveMini(x: x, y: y)
        layout = updated
        save()
    }
    /// Only the selected TFT renderer receives navigation refreshes while locked.
    /// Previous profiles and their settings remain intact for the next unlock.
    func setLockedTFTOnly(_ enabled: Bool) {
        guard lockedTFTOnly != enabled else { return }
        lockedTFTOnly = enabled
        updatePausedRenderers()
        ProjectionDiagnostics.shared.setLockedTFTOnly(enabled)
    }
    private func updatePausedRenderers() {
        for (profile, panel) in [(WebMapProfile.explorer, tracks),
                                 (.wize, roads), (.osmand, osmand)] {
            panel.setUpdatesPaused(!LockedRidePolicy.rendererMayUpdate(
                lockedTFTOnly: lockedTFTOnly, isTFT: profile == self.profile(layout.tft)))
        }
    }
    func beginLocation() {
        LocationAndNavigationManager.shared.setWebMapActive(true)
        TrackLibrary.shared.restoreSelection()
    }
    func snapshotTFT(width: CGFloat, lockedFix: CLLocation? = nil,
                     completion: @escaping (UIImage?, Error?) -> Void) {
        renderer(layout.tft).snapshot(width: width, lockedFix: lockedFix, completion: completion)
    }
    func cancelSnapshot() { renderer(layout.tft).cancelSnapshot() }
    private func save() {
        if let data = try? JSONEncoder().encode(layout) { UserDefaults.standard.set(data, forKey: storageKey) }
    }
}
