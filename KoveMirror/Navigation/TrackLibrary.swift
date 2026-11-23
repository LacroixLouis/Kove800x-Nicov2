import Foundation
import Combine

struct SavedTrack: Codable, Identifiable {
    let id: UUID
    let name: String
    let importedAt: Date
    let pointCount: Int
    let distanceKilometers: Double
    let elevationGainMeters: Double?
    let recordedDuration: TimeInterval?
    var activity: String? = nil
    var sourceID: UUID? = nil
}

/// Stores the original documents, including waypoints and vendor extensions.
final class TrackLibrary: ObservableObject {
    static let shared = TrackLibrary()
    @Published private(set) var tracks: [SavedTrack] = []
    @Published private(set) var selectedID: UUID?
    @Published private(set) var error: String?
    @Published private(set) var isImporting = false
    @Published private(set) var favoriteIDs = Set<UUID>()
    private let importQueue = DispatchQueue(label: "DoubleInterface.GPXImport", qos: .userInitiated)
    private struct Index: Codable {
        var tracks: [SavedTrack]
        var selectedID: UUID?
        var favoriteIDs: Set<UUID>? = nil
    }
    private let folder: URL
    private var loadedSelectionID: UUID?
    private var indexURL: URL { folder.appendingPathComponent("index.json") }

    private init() {
        let name = ProcessInfo.processInfo.arguments.contains("--ui-screenshots") ? "DoubleInterface-Tracks-Screenshots-" + UUID().uuidString : "DoubleInterface-Tracks"
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: indexURL))
                tracks = index.tracks
                let knownIDs = Set(index.tracks.map(\.id))
                selectedID = index.selectedID.flatMap { knownIDs.contains($0) ? $0 : nil }
                favoriteIDs = (index.favoriteIDs ?? []).intersection(knownIDs)
            }
        } catch { self.error = "Impossible de relire les traces enregistrées : " + error.localizedDescription }
    }

    @discardableResult
    func add(data: Data, fallbackName: String, activity: TrailActivity? = nil, sourceID: UUID? = nil) throws -> SavedTrack {
        if let sourceID, let existing = tracks.first(where: { $0.sourceID == sourceID }) { return existing }
        return try add(document: GPXDocument(data: data, fallbackName: fallbackName),
                activity: activity, sourceID: sourceID)
    }

    private func add(document: GPXDocument, activity: TrailActivity? = nil, sourceID: UUID? = nil) throws -> SavedTrack {
        let data = document.data
        let parsed = document.track
        let ascent = parsed.elevationGainMeters
        let entry = SavedTrack(id: UUID(), name: parsed.name, importedAt: Date(),
                              pointCount: parsed.pointCount, distanceKilometers: parsed.distanceKilometers,
                              elevationGainMeters: ascent > 0 ? ascent : nil,
                              recordedDuration: parsed.recordedDuration, activity: activity?.rawValue, sourceID: sourceID)
        let url = file(entry.id)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let updated = [entry] + tracks
        do { try writeIndex(tracks: updated, selectedID: selectedID) }
        catch { try? FileManager.default.removeItem(at: url); throw error }
        tracks = updated
        self.error = nil
        return entry
    }

    /// Share-sheet and Files imports use the same bounded, coordinated path.
    func importFile(_ url: URL, completion: @escaping (Error?) -> Void) {
        guard url.isFileURL else { completion(GPXError.invalid); return }
        guard !isImporting else { completion(GPXError.importInProgress); return }
        isImporting = true
        importQueue.async { [weak self] in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            var coordinationError: NSError?
            var result: Result<GPXDocument, Error> = .failure(GPXError.invalid)
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { localURL in
                result = Result { try GPXDocument.load(from: localURL) }
            }
            if let coordinationError { result = .failure(coordinationError) }
            let finalResult = result
            DispatchQueue.main.async {
                guard let self else { return }
                self.isImporting = false
                do {
                    let document = try finalResult.get()
                    let entry = try self.add(document: document)
                    try self.select(entry, document: document)
                    completion(nil)
                } catch { completion(error) }
            }
        }
    }

    func select(_ entry: SavedTrack, document: GPXDocument? = nil) throws {
        guard tracks.contains(where: { $0.id == entry.id }) else { throw GPXError.empty }
        // Reopening Wukuluc must not reimport the same GPX and cancel an access
        // route that has just been started from its detail sheet.
        if loadedSelectionID == entry.id, LocationAndNavigationManager.shared.importedTrack != nil { return }
        let selected = try document ?? GPXDocument.load(from: file(entry.id), fallbackName: entry.name)
        let previous = selectedID
        try writeIndex(tracks: tracks, selectedID: entry.id)
        do { try LocationAndNavigationManager.shared.importGPX(selected, keepDirection: previous == entry.id) }
        catch { try? writeIndex(tracks: tracks, selectedID: previous); throw error }
        selectedID = entry.id
        loadedSelectionID = entry.id
        self.error = nil
    }

    func restoreSelection() {
        guard let entry = tracks.first(where: { $0.id == selectedID }) else {
            // Installations predating the track library kept their last GPX separately.
            if error != nil || !FileManager.default.fileExists(atPath: indexURL.path) {
                LocationAndNavigationManager.shared.restoreGPX()
            }
            return
        }
        do { try select(entry) } catch { self.error = error.localizedDescription }
    }

    /// Clears the displayed GPX while keeping its original document and metadata.
    @MainActor
    func removeFromMap(_ entry: SavedTrack) throws {
        guard selectedID == entry.id else { return }
        // Persist first: a failed save must leave the displayed route intact.
        try writeIndex(tracks: tracks, selectedID: nil)
        GPXAccessManager.shared.cancel()
        selectedID = nil
        loadedSelectionID = nil
        LocationAndNavigationManager.shared.clearGPX()
        error = nil
    }

    func originalURL(_ entry: SavedTrack) -> URL { file(entry.id) }

    func parsedTrack(_ entry: SavedTrack) throws -> GPXTrack {
        guard tracks.contains(where: { $0.id == entry.id }) else { throw GPXError.empty }
        return try GPXDocument.load(from: file(entry.id), fallbackName: entry.name).track
    }

    func remove(_ entry: SavedTrack) throws {
        let updated = tracks.filter { $0.id != entry.id }
        let selection = selectedID == entry.id ? nil : selectedID
        let favorites = favoriteIDs.subtracting([entry.id])
        try writeIndex(tracks: updated, selectedID: selection, favorites: favorites)
        tracks = updated
        favoriteIDs = favorites
        if selectedID == entry.id {
            loadedSelectionID = nil
            GPXAccessManager.shared.cancel()
            LocationAndNavigationManager.shared.clearGPX()
        }
        selectedID = selection
        try? FileManager.default.removeItem(at: file(entry.id))
    }

    func toggleFavorite(_ entry: SavedTrack) throws {
        guard tracks.contains(where: { $0.id == entry.id }) else { throw GPXError.empty }
        var updated = favoriteIDs
        if !updated.insert(entry.id).inserted { updated.remove(entry.id) }
        try writeIndex(tracks: tracks, selectedID: selectedID, favorites: updated)
        favoriteIDs = updated
    }

    private func file(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".gpx") }
    private func writeIndex(tracks: [SavedTrack], selectedID: UUID?, favorites: Set<UUID>? = nil) throws {
        let data = try JSONEncoder().encode(Index(tracks: tracks, selectedID: selectedID, favoriteIDs: favorites ?? favoriteIDs))
        try data.write(to: indexURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
