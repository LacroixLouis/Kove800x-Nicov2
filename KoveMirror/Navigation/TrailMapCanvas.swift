import SwiftUI
import MapKit

struct TrailCameraRequest {
    enum Target { case route, place(CLLocationCoordinate2D), position }
    let id = UUID()
    let target: Target
}

struct TrailMapCanvas: UIViewRepresentable {
    let track: GPXTrack?
    let trackRevision: UUID
    let recording: [[GPXPoint]]
    let places: [MKMapItem]
    let mapType: MKMapType
    let cameraRequest: TrailCameraRequest
    var darkStyle = true

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.panBegan(_:)))
        pan.cancelsTouchesInView = false
        pan.delaysTouchesEnded = false
        pan.delegate = context.coordinator
        map.addGestureRecognizer(pan)
        map.overrideUserInterfaceStyle = darkStyle ? .dark : .light
        map.showsUserLocation = true
        map.showsCompass = true
        map.showsScale = true
        map.pointOfInterestFilter = .includingAll
        map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 46.6, longitude: 2.5),
                                         latitudinalMeters: 1_000_000, longitudinalMeters: 1_000_000), animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        map.overrideUserInterfaceStyle = darkStyle ? .dark : .light
        if let orientation = map.window?.windowScene?.effectiveGeometry.interfaceOrientation {
            LocationAndNavigationManager.shared.alignCompassWithPhoneInterface(orientation)
        }
        if map.mapType != mapType { map.mapType = mapType }

        let geometryKey = String(trackRevision.uuidString) + ":" + recording.map { String($0.count) }.joined(separator: ",")
        if coordinator.geometryKey != geometryKey {
            coordinator.geometryKey = geometryKey
            coordinator.recordingOverlays.removeAll()
            map.removeOverlays(map.overlays)
            if let track {
                for segment in track.segments where segment.count >= 2 {
                    var coordinates = segment.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                    map.addOverlay(MKPolyline(coordinates: &coordinates, count: coordinates.count))
                }
            }
            for segment in recording where segment.count >= 2 {
                var coordinates = segment.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                let line = MKPolyline(coordinates: &coordinates, count: coordinates.count)
                coordinator.recordingOverlays.insert(ObjectIdentifier(line))
                map.addOverlay(line)
            }
        }

        let placeKey = places.map { item in
            String(format: "%.5f,%.5f", item.location.coordinate.latitude, item.location.coordinate.longitude)
        }.joined(separator: ";")
        if coordinator.placeKey != placeKey {
            coordinator.placeKey = placeKey
            map.removeAnnotations(map.annotations.filter { !($0 is MKUserLocation) })
            for item in places {
                let pin = MKPointAnnotation()
                pin.coordinate = item.location.coordinate
                pin.title = item.name
                pin.subtitle = item.address?.shortAddress
                map.addAnnotation(pin)
            }
        }

        if coordinator.requestID != cameraRequest.id {
            coordinator.requestID = cameraRequest.id
            coordinator.waitingForPosition = false
            switch cameraRequest.target {
            case .route:
                fitAll(on: map)
            case .place(let coordinate):
                map.setRegion(MKCoordinateRegion(center: coordinate, latitudinalMeters: 12_000,
                                                 longitudinalMeters: 12_000), animated: false)
            case .position:
                coordinator.waitingForPosition = true
                coordinator.centerIfReady(on: map)
                if coordinator.waitingForPosition {
                    LocationAndNavigationManager.shared.requestMapCameraLocation()
                }
            }
        } else if coordinator.waitingForPosition {
            coordinator.centerIfReady(on: map)
        }
        NavigationPositionMarker.update(on: map, bearing: LocationAndNavigationManager.shared.travelBearing)
    }

    private func fitAll(on map: MKMapView) {
        guard let first = map.overlays.first else { return }
        let rect = map.overlays.dropFirst().reduce(first.boundingMapRect) { $0.union($1.boundingMapRect) }
        guard !rect.isNull, !rect.isEmpty else { return }
        map.setUserTrackingMode(.none, animated: false)
        map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 140, left: 32, bottom: 300, right: 32), animated: false)
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var geometryKey = ""
        var placeKey = ""
        var requestID: UUID?
        var waitingForPosition = false

        @objc func panBegan(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .began { waitingForPosition = false }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

        func centerIfReady(on map: MKMapView) {
            guard waitingForPosition, map.bounds.width > 0, map.bounds.height > 0 else { return }
            let nav = LocationAndNavigationManager.shared
            guard let fix = nav.currentMapLocation(including: map.userLocation.location) else { return }
            waitingForPosition = false
            map.setRegion(MKCoordinateRegion(center: fix.coordinate, latitudinalMeters: 1400,
                                             longitudinalMeters: 1400), animated: false)
        }

        var recordingOverlays = Set<ObjectIdentifier>()

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: line)
            renderer.strokeColor = recordingOverlays.contains(ObjectIdentifier(line))
                ? UIColor(red: 100/255, green: 237/255, blue: 84/255, alpha: 1)
                : WebMapProfile.explorer.overlayColor
            renderer.lineWidth = recordingOverlays.contains(ObjectIdentifier(line)) ? 7 : 6
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation {
                return NavigationPositionMarker.annotationView(for: annotation, on: mapView,
                    color: WebMapProfile.explorer.overlayColor,
                    bearing: LocationAndNavigationManager.shared.travelBearing)
            }
            let identifier = "TrailPlace"
            let marker = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            marker.annotation = annotation
            marker.canShowCallout = true
            marker.markerTintColor = .systemOrange
            marker.glyphImage = UIImage(systemName: "mountain.2.fill")
            return marker
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            NavigationPositionMarker.update(on: mapView, bearing: LocationAndNavigationManager.shared.travelBearing)
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            centerIfReady(on: mapView)
            NavigationPositionMarker.update(on: mapView, bearing: LocationAndNavigationManager.shared.travelBearing)
        }
    }
}
