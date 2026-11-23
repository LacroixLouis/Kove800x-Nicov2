import Foundation
import MapKit
import Combine

/// An access route belongs to the GPX maps. Wize keeps its own route/state.
@MainActor
final class GPXAccessManager: ObservableObject {
    static let shared = GPXAccessManager()
    @Published private(set) var route: MKRoute?
    @Published private(set) var routeRevision = UUID()
    @Published private(set) var isCalculating = false
    @Published private(set) var error: String?
    @Published private(set) var instruction = ""
    @Published private(set) var detail = ""
    @Published private(set) var mode: GPXAccessMode = .nearest
    @Published private(set) var profile: WebMapProfile = .explorer
    @Published private(set) var target: GPXAccessTarget?
    private(set) var coordinates: [CLLocationCoordinate2D] = []
    var isActive: Bool { isCalculating || route != nil }
    private let nav = LocationAndNavigationManager.shared
    private var directions: MKDirections?
    private var requestID = UUID()
    private var timeout: DispatchWorkItem?
    private var trackRevision: UUID?
    private var reversed = false
    private var startedCalculation = false
    private var progress: RoadRouteProgress?
    private var stepProgress: RoadStepProgress?
    private var previousProgress: Double?
    private var stepIndex = 0
    private var remainingMeters = Double.infinity
    private var reachedRoadEnd = false
    private var offRouteAnnounced = false
    private var subscriptions = Set<AnyCancellable>()

    private init() {
        NotificationCenter.default.publisher(for: .nicoNavigationUpdated)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.locationChanged() }
            .store(in: &subscriptions)
    }

    func start(_ mode: GPXAccessMode, profile: WebMapProfile) {
        cancel()
        guard nav.importedTrack != nil else { error = "Importe ou sélectionne d’abord une trace GPX."; return }
        self.mode = mode
        self.profile = profile == .osmand ? .osmand : .explorer
        trackRevision = nav.importedTrackRevision
        reversed = nav.gpxReversed
        isCalculating = true
        instruction = "Acquisition de la position GPS…"
        detail = mode.title
        nav.setTraceAccessActive(true)
        nav.requestWebMapLocation()
        let token = requestID
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.requestID == token, self.isCalculating else { return }
            self.fail("Position GPS ou calcul d’accès indisponible. Réessaie avec du réseau et une position précise.")
        }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 40, execute: timeout)
        locationChanged()
        changed()
    }

    func cancel() {
        requestID = UUID()
        directions?.cancel(); directions = nil
        timeout?.cancel(); timeout = nil
        trackRevision = nil
        startedCalculation = false
        route = nil; coordinates = []; target = nil
        progress = nil; stepProgress = nil; previousProgress = nil
        stepIndex = 0; remainingMeters = .infinity; reachedRoadEnd = false; offRouteAnnounced = false
        isCalculating = false; instruction = ""; detail = ""; error = nil
        nav.setTraceAccessActive(false)
        routeRevision = UUID()
    }

    func clearError() { error = nil }

    private func fail(_ message: String) {
        cancel()
        error = message
        changed()
    }

    private func locationChanged() {
        guard isActive else { return }
        guard trackRevision == nav.importedTrackRevision, reversed == nav.gpxReversed else {
            cancel(); changed(); return
        }
        if route != nil, nav.isFollowingGPX { cancel(); changed(); return }
        guard let location = nav.userLocation,
              ProjectionPolicy.isFresh(timestamp: location.timestamp, accuracy: location.horizontalAccuracy, now: Date()) else { return }
        if isCalculating {
            if !startedCalculation { calculate(from: location) }
        } else { updateProgress(location) }
    }

    private func calculate(from origin: CLLocation) {
        guard let track = nav.importedTrack,
              let target = GPXAccessTargetPlanner.target(track: track, mode: mode, reversed: reversed,
                from: GPXPoint(latitude: origin.coordinate.latitude, longitude: origin.coordinate.longitude),
                previousMeters: nav.gpxGuidance?.travelledMeters) else {
            fail("Impossible de déterminer un point d’accès valide sur cette trace."); return
        }
        self.target = target
        if GPXAccessArrivalPolicy.canHandoff(targetDistance: target.distanceMeters, routeRemaining: 0,
                                               accuracy: origin.horizontalAccuracy) {
            finish(); return
        }
        startedCalculation = true
        instruction = "Calcul de l’accès routier…"
        detail = mode.title
        let destination = MKMapItem(location: CLLocation(latitude: target.point.latitude, longitude: target.point.longitude), address: nil)
        destination.name = mode.targetName
        let request = MKDirections.Request()
        request.source = MKMapItem(location: origin, address: nil)
        request.destination = destination
        request.transportType = .automobile
        request.requestsAlternateRoutes = false
        let directions = MKDirections(request: request)
        self.directions = directions
        let token = requestID
        directions.calculate { [weak self] response, failure in
            DispatchQueue.main.async {
                guard let self, self.requestID == token else { return }
                self.directions = nil
                guard self.trackRevision == self.nav.importedTrackRevision,
                      self.reversed == self.nav.gpxReversed else { self.cancel(); self.changed(); return }
                guard failure == nil, let route = response?.routes.first, route.polyline.pointCount >= 2 else {
                    self.fail("Aucun accès routier n’a pu être calculé jusqu’à ce point. Vérifie le réseau ou essaie l’autre option d’accès.")
                    return
                }
                self.timeout?.cancel(); self.timeout = nil
                let line = route.polyline
                let step = max(1, (line.pointCount + 4095) / 4096)
                self.coordinates = stride(from: 0, to: line.pointCount, by: step).map { line.points()[$0].coordinate }
                self.coordinates.append(line.points()[line.pointCount - 1].coordinate)
                self.progress = RoadRouteProgress(self.coordinates.map { RoadRouteCoordinate(latitude: $0.latitude, longitude: $0.longitude) })
                guard (self.progress?.totalMeters ?? 0) > 0 else {
                    self.fail("Le service n’a pas renvoyé d’itinéraire d’accès utilisable jusqu’à ce point."); return
                }
                self.stepProgress = RoadStepProgress(stepDistances: route.steps.map(\.distance))
                self.stepIndex = route.steps.count > 1 && route.steps[0].instructions.isEmpty ? 1 : 0
                self.remainingMeters = route.distance
                self.route = route
                self.isCalculating = false
                self.nav.stopFollowingGPX()
                self.instruction = self.stepInstruction(route)
                self.detail = self.mode.title + String(format: " · %.1f km", route.distance / 1000)
                self.nav.announceTraceAccess(self.mode.title + ". " + self.instruction)
                self.routeRevision = UUID()
                if let current = self.nav.userLocation { self.updateProgress(current) }
                self.changed()
            }
        }
    }

    private func updateProgress(_ location: CLLocation) {
        guard let route, let target, let progress else { return }
        let targetLocation = CLLocation(latitude: target.point.latitude, longitude: target.point.longitude)
        let gap = location.distance(from: targetLocation)
        let roadEnd = coordinates.last.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        let fix = RoadRouteCoordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        if !reachedRoadEnd, let position = progress.project(fix, previousMeters: previousProgress) {
            let tolerance = max(90, min(150, location.horizontalAccuracy * 3))
            if position.deviationMeters > tolerance {
                instruction = "Hors itinéraire d’accès"
                detail = "Rejoins l’itinéraire bleu ou recalcule l’accès."
                if !offRouteAnnounced { nav.announceTraceAccess(instruction); offRouteAnnounced = true }
                return
            }
            offRouteAnnounced = false
            previousProgress = position.travelledMeters
            remainingMeters = progress.remainingRoadMeters(at: position, mapKitRouteMeters: route.distance)
            if remainingMeters <= 45, let roadEnd, location.distance(from: roadEnd) <= 40,
               location.horizontalAccuracy <= 35 { reachedRoadEnd = true }
            let stepDistance = route.steps.reduce(0) { $0 + max(0, $1.distance) }
            let travelled = position.travelledMeters / max(1, progress.totalMeters) * stepDistance
            if let stepProgress {
                let next = stepProgress.nextIndex(current: stepIndex, travelledMeters: travelled)
                if next != stepIndex { stepIndex = next; nav.announceTraceAccess(stepInstruction(route)) }
                let distance = stepProgress.distanceToStepEnd(index: stepIndex, travelledMeters: travelled)
                instruction = stepInstruction(route)
                detail = String(format: "Dans %.0f m · %.1f km jusqu’à la trace", distance, remainingMeters / 1000)
            }
        }
        if GPXAccessArrivalPolicy.canHandoff(targetDistance: gap,
            routeRemaining: reachedRoadEnd ? 0 : remainingMeters, accuracy: location.horizontalAccuracy) {
            finish(); return
        }
        if reachedRoadEnd {
            instruction = "Fin de l’accès routier calculé"
            detail = String(format: "Trace à %.0f m · rejoins le repère", gap)
        }
    }

    private func stepInstruction(_ route: MKRoute) -> String {
        guard route.steps.indices.contains(stepIndex), !route.steps[stepIndex].instructions.isEmpty else { return "Suivre l’itinéraire d’accès" }
        return route.steps[stepIndex].instructions
    }

    private func finish() {
        let progress = target?.progressMeters
        // Keep the ride alive while switching from road access to the GPX.
        requestID = UUID(); directions?.cancel(); directions = nil
        timeout?.cancel(); timeout = nil
        trackRevision = nil; route = nil; coordinates = []; target = nil; isCalculating = false
        self.progress = nil; stepProgress = nil; previousProgress = nil
        instruction = ""; detail = ""
        nav.startFollowingGPX(atProgressMeters: progress)
        nav.setTraceAccessActive(false)
        nav.announceTraceAccess("Trace rejointe. Le suivi du GPX commence.")
        routeRevision = UUID()
        changed()
    }

    private func changed() { NotificationCenter.default.post(name: .nicoNavigationUpdated, object: nil) }
}
