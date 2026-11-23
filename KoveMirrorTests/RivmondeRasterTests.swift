import MapKit
import Testing
import UIKit
@testable import KoveMirror

@MainActor
struct RivmondeRasterTests {
    @Test func courseUpPutsTheRoadAheadAtTheTopWithAllFourCornersCovered() {
        let center = MKMapPoint(CLLocationCoordinate2D(latitude: 45, longitude: 5))
        for size in [CGSize(width: 600, height: 1024), CGSize(width: 1024, height: 600)] {
            let rect = MKMapRect(x: center.x - size.width, y: center.y - size.height,
                                 width: size.width * 2, height: size.height * 2)
            for heading in [0.0, 45, 90, 135, 180, 270, 359] {
                let viewport = TFTMapViewport(rect: rect, size: size, heading: heading)
                let angle = heading * .pi / 180
                let forward = MKMapPoint(x: center.x + 100 * sin(angle), y: center.y - 100 * cos(angle))
                let p = viewport.point(forward.coordinate)
                #expect(abs(p.x - size.width / 2) < 0.01)
                #expect(abs(p.y - (size.height / 2 - 50)) < 0.01)
                let inverse = viewport.sourceToScreen.inverted()
                let source = CGRect(origin: .zero, size: viewport.sourceSize).insetBy(dx: -0.01, dy: -0.01)
                for x in [CGFloat.zero, size.width] {
                    for y in [CGFloat.zero, size.height] {
                        #expect(source.contains(CGPoint(x: x, y: y).applying(inverse)))
                    }
                }
            }
        }
    }

    private func mapImage(_ color: UIColor, road: Bool = false) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: 600, height: 1024)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            // A tiny corner attribution can exist even on a placeholder.
            UIColor.black.setFill()
            context.fill(CGRect(x: 5, y: 1008, width: 90, height: 10))
            if road {
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 60, y: 170))
                path.addLine(to: CGPoint(x: 490, y: 810))
                path.lineWidth = 3
                UIColor.gray.setStroke()
                path.stroke()
            }
        }
    }

    @Test func rejectsUniformBeigeWhiteAndNightImagesButKeepsASingleRoad() {
        let beige = UIColor(red: 0.94, green: 0.91, blue: 0.68, alpha: 1)
        for color in [beige, .white, .darkGray] {
            #expect(!RivmondeRasterFrame.hasMapDetail(mapImage(color)))
        }
        #expect(RivmondeRasterFrame.hasMapDetail(mapImage(beige, road: true)))
        #expect(RivmondeRasterFrame.hasMapDetail(mapImage(.white, road: true)))
    }

    @Test func usesAvailableNeighbouringZoomAndReportsMissingCoverage() throws {
        let world = MKMapSize.world.width
        let rect = MKMapRect(x: world / 4, y: world / 4, width: world / 4, height: world / 4)
        let size = CGSize(width: 512, height: 512)
        let tile = mapImage(.white, road: true)
        let levels = OfflineTileGrid.rasterZooms(viewWidth: rect.size.width, outputWidth: 512,
                                                minZoom: 0, maxZoom: 17)
        #expect(levels.first == 3)
        let complete = try #require(RivmondeRasterFrame.best(in: rect, output: size, zooms: levels) { z, x, y in
            z == 2 || (z == 3 && x == 2 && y == 2) ? tile : nil
        })
        #expect(complete.zoom == 2 && complete.coverage == 1)
        let partial = try #require(RivmondeRasterFrame.best(in: rect, output: size, zooms: levels) { z, x, y in
            z == 3 && x == 2 && y == 2 ? tile : nil
        })
        #expect(partial.coverage == 0.25)
        #expect(RivmondeRasterFrame.best(in: rect, output: size, zooms: levels) { _, _, _ in nil } == nil)
    }

    @Test func featurelessCachedTileCannotHideDetailedNeighbouringLevel() throws {
        let tileWidth = MKMapSize.world.width / 4
        let rect = MKMapRect(x: tileWidth, y: tileWidth, width: tileWidth, height: tileWidth)
        let size = CGSize(width: 256, height: 256)
        let beige = mapImage(UIColor(red: 0.94, green: 0.91, blue: 0.68, alpha: 1))
        let road = mapImage(.white, road: true)
        let replacement = try #require(RivmondeRasterFrame.best(in: rect, output: size, zooms: [2, 3],
                                                               inspectDetail: true) { z, _, _ in z == 2 ? beige : road })
        #expect(replacement.zoom == 3)
        #expect(!replacement.lacksDetail)
        let empty = try #require(RivmondeRasterFrame.best(in: rect, output: size, zooms: [2],
                                                          inspectDetail: true) { _, _, _ in beige })
        #expect(empty.coverage == 1 && empty.lacksDetail)
    }
}
