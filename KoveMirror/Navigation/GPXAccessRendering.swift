import UIKit
import MapKit

enum GPXAccessRendering {
    nonisolated static func draw(in context: CGContext, coordinates: [CLLocationCoordinate2D],
                                  target: CLLocationCoordinate2D?,
                                  project: (CLLocationCoordinate2D) -> CGPoint) {
        context.saveGState()
        if let first = coordinates.first, coordinates.count > 1 {
            context.setStrokeColor(UIColor.systemBlue.cgColor)
            context.setLineWidth(5)
            context.setLineJoin(.round)
            context.setLineCap(.round)
            context.setLineDash(phase: 0, lengths: [9, 6])
            context.beginPath(); context.move(to: project(first))
            for coordinate in coordinates.dropFirst() { context.addLine(to: project(coordinate)) }
            context.strokePath()
        }
        if let target, CLLocationCoordinate2DIsValid(target) {
            let point = project(target)
            context.setLineDash(phase: 0, lengths: [])
            context.setFillColor(UIColor.systemBlue.cgColor)
            context.setStrokeColor(UIColor.white.cgColor)
            context.setLineWidth(2)
            context.fillEllipse(in: CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14))
            context.strokeEllipse(in: CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14))
        }
        context.restoreGState()
    }
}
