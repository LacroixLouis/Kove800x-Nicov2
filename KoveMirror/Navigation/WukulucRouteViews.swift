import SwiftUI
import MapKit
import Charts

enum WukulucStyle {
    static let green = Color(red: 0.20, green: 0.48, blue: 0.15)
    static let background = Color(red: 0.96, green: 0.97, blue: 0.95)
    static let ink = Color(red: 0.13, green: 0.17, blue: 0.12)
    static let muted = Color(red: 0.43, green: 0.47, blue: 0.41)
}

struct WukulucButtonStyle: ButtonStyle {
    var filled = true
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.bold())
            .frame(maxWidth: .infinity, minHeight: 48).padding(.horizontal, 12)
            .foregroundStyle(filled ? Color.white : WukulucStyle.green)
            .background(filled ? WukulucStyle.green : WukulucStyle.green.opacity(0.09),
                        in: RoundedRectangle(cornerRadius: 12))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
    }
}

/// A drawing of the actual GPX, never a stock route or invented map image.
struct WukulucTraceThumbnail: View {
    let entry: SavedTrack
    @State private var segments: [[CGPoint]] = []
    var body: some View {
        Canvas { context, size in
            for segment in segments where segment.count > 1 {
                var path = Path()
                for (index, point) in segment.enumerated() {
                    let p = CGPoint(x: 9 + point.x * max(1, size.width - 18),
                                    y: 9 + point.y * max(1, size.height - 18))
                    if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                context.stroke(path, with: .color(WukulucStyle.green), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
        }
        .background(WukulucStyle.green.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("Tracé GPX de " + entry.name)
        .task(id: entry.id) {
            guard let track = try? TrackLibrary.shared.parsedTrack(entry) else { return }
            let origin = track.segments.first?.first?.longitude ?? 0
            let latitude = track.segments.first?.first?.latitude ?? 0
            let projected = track.segments.map { segment in
                let step = max(1, segment.count / 400)
                var points = stride(from: 0, to: segment.count, by: step).map { segment[$0] }
                if let last = segment.last { points.append(last) }
                return points.map { p -> CGPoint in
                    var longitude = p.longitude - origin
                    if longitude > 180 { longitude -= 360 }
                    if longitude < -180 { longitude += 360 }
                    return CGPoint(x: longitude * cos(latitude * .pi / 180), y: -p.latitude)
                }
            }
            let all = projected.flatMap { $0 }
            guard let minX = all.map(\.x).min(), let maxX = all.map(\.x).max(),
                  let minY = all.map(\.y).min(), let maxY = all.map(\.y).max() else { return }
            let scale = max(0.000001, max(maxX - minX, maxY - minY))
            segments = projected.map { $0.map { CGPoint(x: ($0.x - (minX + maxX) / 2) / scale + 0.5,
                                                      y: ($0.y - (minY + maxY) / 2) / scale + 0.5) } }
        }
    }
}

struct WukulucRouteMap: UIViewRepresentable {
    let track: GPXTrack
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.overrideUserInterfaceStyle = .light
        map.showsScale = true
        map.showsUserLocation = true
        return map
    }
    func updateUIView(_ map: MKMapView, context: Context) {
        let identity = track.name + ":" + String(track.pointCount)
            + ":" + String(track.segments.first?.first?.latitude ?? 0)
            + ":" + String(track.segments.first?.first?.longitude ?? 0)
        guard context.coordinator.identity != identity else { return }
        context.coordinator.identity = identity
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations.filter { !($0 is MKUserLocation) })
        var bounds = MKMapRect.null
        for segment in track.segments where segment.count > 1 {
            let coordinates = segment.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
            bounds = bounds.union(line.boundingMapRect)
            map.addOverlay(line)
        }
        if !bounds.isNull { map.setVisibleMapRect(bounds, edgePadding: .init(top: 36, left: 30, bottom: 36, right: 30), animated: false) }
        for (label, point) in [("Départ", track.segments.first?.first), ("Arrivée", track.segments.last?.last)] {
            guard let point else { continue }
            let pin = MKPointAnnotation()
            pin.coordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
            pin.title = label
            map.addAnnotation(pin)
        }
    }
    final class Coordinator: NSObject, MKMapViewDelegate {
        var identity = ""
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: line)
            renderer.strokeColor = WebMapProfile.explorer.overlayColor
            renderer.lineWidth = 5
            renderer.lineJoin = .round
            renderer.lineCap = .round
            return renderer
        }
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation is MKUserLocation else { return nil }
            return NavigationPositionMarker.annotationView(for: annotation, on: mapView,
                color: WebMapProfile.explorer.overlayColor, bearing: LocationAndNavigationManager.shared.travelBearing)
        }
        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            NavigationPositionMarker.update(on: mapView, bearing: LocationAndNavigationManager.shared.travelBearing)
        }
    }
}

struct WukulucElevationProfile: View {
    let track: GPXTrack
    @State private var selectedDistance: Double?
    @State private var values: [Sample] = []
    private struct Sample: Identifiable {
        let id: Int
        let distance: Double
        let elevation: Double
        let section: Int
    }
    private var samples: [Sample] {
        var result: [Sample] = []
        var meters = 0.0, section = 0
        let step = max(1, track.pointCount / 1000)
        for segment in track.segments {
            section += 1
            var previous: GPXPoint?
            for (index, point) in segment.enumerated() {
                if let previous {
                    meters += CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                        .distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude))
                }
                previous = point
                guard let elevation = point.elevation else { section += 1; continue }
                if index % step == 0 || index == segment.count - 1 {
                    result.append(Sample(id: result.count, distance: meters / 1000,
                                         elevation: elevation, section: section))
                }
            }
        }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Profil d’altitude").font(.headline)
                Spacer()
                if let selectedDistance,
                   let closest = values.min(by: { abs($0.distance - selectedDistance) < abs($1.distance - selectedDistance) }) {
                    Text(String(format: "%.1f km · %.0f m", closest.distance, closest.elevation))
                        .font(.caption.monospacedDigit()).foregroundStyle(WukulucStyle.green)
                }
            }
            if values.count < 2 {
                Text("Ce GPX ne contient pas assez d’altitudes pour tracer le profil.")
                    .font(.caption).foregroundStyle(WukulucStyle.muted)
            } else {
                Chart {
                    ForEach(values) { sample in
                        LineMark(x: .value("Distance (km)", sample.distance),
                                 y: .value("Altitude (m)", sample.elevation),
                                 series: .value("Segment", sample.section))
                            .foregroundStyle(WukulucStyle.green)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    if let selectedDistance {
                        RuleMark(x: .value("Distance", selectedDistance))
                            .foregroundStyle(WukulucStyle.ink.opacity(0.4))
                    }
                }
                .chartLegend(.hidden)
                .chartXSelection(value: $selectedDistance)
                .chartXAxisLabel("Distance · km")
                .chartYAxisLabel("Altitude · m")
                .frame(height: 155)
                .accessibilityLabel("Profil d’altitude du parcours. Déplacer le doigt pour lire l’altitude.")
            }
        }.task(id: track.name + ":" + String(track.pointCount)) { values = samples }
    }
}

struct WukulucRouteMetric: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(.title3, design: .rounded).bold()).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(WukulucStyle.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
