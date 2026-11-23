import UIKit
import MapKit

/// One position symbol for the phone, miniature and all TFT renderers.
enum NavigationPositionMarker {
    private static let reuseIdentifier = "NavigationPositionTriangle"

    /// Project a short segment in the travel direction. This also accounts for
    /// map rotation, perspective and the raster output's aspect ratio.
    nonisolated static func angle(at coordinate: CLLocationCoordinate2D,
                                  bearing: CLLocationDirection?,
                                  project: (CLLocationCoordinate2D) -> CGPoint) -> CGFloat {
        guard let bearing, bearing.isFinite, (0..<360).contains(bearing) else { return 0 }
        let latitude = coordinate.latitude * .pi / 180
        let longitude = coordinate.longitude * .pi / 180
        let heading = bearing * .pi / 180
        let distance = 30.0 / 6_371_000
        let nextLatitude = asin(sin(latitude) * cos(distance)
                                + cos(latitude) * sin(distance) * cos(heading))
        let nextLongitude = longitude + atan2(sin(heading) * sin(distance) * cos(latitude),
                                              cos(distance) - sin(latitude) * sin(nextLatitude))
        let wrappedLongitude = (nextLongitude * 180 / .pi + 540)
            .truncatingRemainder(dividingBy: 360) - 180
        let start = project(coordinate)
        let end = project(CLLocationCoordinate2D(latitude: nextLatitude * 180 / .pi,
                                                longitude: wrappedLongitude))
        let dx = end.x - start.x, dy = end.y - start.y
        guard dx.isFinite, dy.isFinite, abs(dx) + abs(dy) > 0.0001 else { return 0 }
        return atan2(dx, -dy)
    }

    nonisolated static func draw(in context: CGContext, at point: CGPoint,
                                 angle: CGFloat, color: UIColor, size: CGFloat = 30) {
        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        context.rotate(by: angle)
        context.setShadow(offset: CGSize(width: 0, height: 1), blur: 3,
                          color: UIColor.black.withAlphaComponent(0.6).cgColor)
        context.beginPath()
        context.move(to: CGPoint(x: 0, y: -size * 0.56))
        context.addLine(to: CGPoint(x: size * 0.43, y: size * 0.40))
        context.addLine(to: CGPoint(x: -size * 0.43, y: size * 0.40))
        context.closePath()
        context.setFillColor(color.cgColor)
        context.setStrokeColor(UIColor.white.cgColor)
        context.setLineWidth(2.5)
        context.setLineJoin(.round)
        context.drawPath(using: .fillStroke)
        context.restoreGState()
    }

    static func annotationView(for annotation: MKAnnotation, on map: MKMapView,
                               color: UIColor, bearing: CLLocationDirection?) -> MKAnnotationView {
        let marker = (map.dequeueReusableAnnotationView(withIdentifier: reuseIdentifier) as? PositionTriangleAnnotationView)
            ?? PositionTriangleAnnotationView(annotation: annotation, reuseIdentifier: reuseIdentifier)
        marker.annotation = annotation
        marker.canShowCallout = false
        marker.displayPriority = .required
        marker.centerOffset = .zero
        marker.isAccessibilityElement = true
        marker.accessibilityLabel = "Ma position et mon sens de déplacement"
        let size = CGSize(width: 44, height: 44)
        marker.triangleImage = UIGraphicsImageRenderer(size: size).image { renderer in
            draw(in: renderer.cgContext, at: CGPoint(x: 22, y: 22), angle: 0, color: color)
        }
        marker.point(on: map, bearing: bearing)
        return marker
    }

    static func update(on map: MKMapView, bearing: CLLocationDirection?,
                       annotation: MKAnnotation? = nil) {
        guard let marker = map.view(for: annotation ?? map.userLocation) as? PositionTriangleAnnotationView,
              marker.reuseIdentifier == reuseIdentifier else { return }
        marker.point(on: map, bearing: bearing)
    }
}

/// MapKit owns the annotation container's transform during rotation and layout.
/// Rotate only its image, and recalculate after every layout with the new map
/// geometry, even when the phone rotates without receiving another GPS fix.
private final class PositionTriangleAnnotationView: MKAnnotationView {
    private let triangle = UIImageView()
    private weak var map: MKMapView?
    private var bearing: CLLocationDirection?
    var triangleImage: UIImage? {
        get { triangle.image }
        set { triangle.image = newValue }
    }

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        bounds = CGRect(x: 0, y: 0, width: 44, height: 44)
        triangle.isUserInteractionEnabled = false
        addSubview(triangle)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func point(on map: MKMapView, bearing: CLLocationDirection?) {
        self.map = map
        self.bearing = bearing
        updateDirection()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        triangle.bounds = bounds
        triangle.center = CGPoint(x: bounds.midX, y: bounds.midY)
        updateDirection()
    }

    private func updateDirection() {
        guard let map, let coordinate = annotation?.coordinate,
              CLLocationCoordinate2DIsValid(coordinate) else { return }
        let rotation = NavigationPositionMarker.angle(at: coordinate, bearing: bearing) {
            map.convert($0, toPointTo: map)
        }
        triangle.transform = CGAffineTransform(rotationAngle: rotation)
        accessibilityValue = bearing == nil ? "Direction en attente du GPS" : "Direction de déplacement"
    }
}
