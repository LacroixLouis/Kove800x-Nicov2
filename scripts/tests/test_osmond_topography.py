"""Static regression tests for the independent Osmond layers and TFT paths.

These do not replace building/running the iOS target with Xcode.
"""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

def source(relative_path):
    return (ROOT / relative_path).read_text()

class OsmondTopoTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tiles = source('KoveMirror/Navigation/OfflineMBTiles.swift')
        cls.panel = source('KoveMirror/Navigation/IntegratedNavigationPanel.swift')
        cls.ui = source('KoveMirror/WebCockpitView.swift')
        cls.project = source('NicoMirror.xcodeproj/project.pbxproj')

    def test_overlay_is_not_base_map(self):
        self.assertIn('enum OsmondRasterLayer', self.tiles)
        self.assertIn('case hillshade, contours', self.tiles)
        self.assertIn('selectAsBase: importingLayer == nil', self.ui)
        self.assertIn('canReplaceMapContent = replacesMapContent', self.tiles)
        self.assertIn('replacesMapContent: false', self.panel)

    def test_layer_selections_are_independent(self):
        for name in ['selectedHillshadeID', 'selectedContoursID', 'selectedOverlay(', 'selectOverlay(']:
            self.assertIn(name, self.tiles)
        self.assertIn('guard kind == .osmand', self.panel)
        self.assertIn('guard offlineTiles != nil && offlineEnabled else { return }', self.panel)

    def test_overlay_order_and_gpx_readability(self):
        hill = self.panel.index('if let hillshadeTiles { map.addOverlay(hillshadeTiles')
        curves = self.panel.index('if let contourTiles { map.addOverlay(contourTiles')
        self.assertLess(hill, curves)
        self.assertIn('map.addOverlay(line, level: .aboveLabels)', self.panel)
        base = self.tiles.index('drawTiles(in: context, mapRect: viewport.sourceRect, output: viewport.sourceSize, opacity: 1)')
        layers = self.tiles.index('for layer in rasterLayers')
        route = self.tiles.index('for line in polylines where line.count > 1')
        self.assertLess(base, layers)
        self.assertLess(layers, route)

    def test_individual_opacity_is_saved_and_applied(self):
        self.assertIn('layer.opacityKey', self.panel)
        self.assertIn('renderer.alpha = alpha', self.panel)
        self.assertIn('renderer.alpha = rasterOpacities[.hillshade]', self.panel)
        self.assertIn('renderer.alpha = rasterOpacities[.contours]', self.panel)
        self.assertNotIn('session.osmand.osmondRasterOpacity(for: layer)', self.ui)  # hidden with relief controls

    def test_tft_contains_offline_base_layers_and_title(self):
        self.assertIn('offline.renderFrame(mapRect: rect', self.panel)
        self.assertIn('rasterLayers: layers', self.panel)
        self.assertIn('layer.tiles.drawTiles(in: context', self.tiles)
        self.assertIn('let mapName = mapProfile.overlayTitle', self.panel)
        self.assertIn('mapNameColor: mapNameColor', self.panel)
        self.assertIn('mapName as NSString', self.tiles)

    def test_automatic_relief_no_buttons_and_theme(self):
        # Osmond relief is displayed in the base Topo tiles, not toggled manually.
        self.assertIn('Label("Relief automatique"', self.ui)
        for hidden in ['toolChip("Relief",', 'osmandOption("Relief du terrain"',
                       'ForEach(OsmondRasterLayer.allCases)']:
            self.assertNotIn(hidden, self.ui)
        self.assertIn('osmandOption("Points d’intérêt"', self.ui)
        self.assertIn('toolChip("Topo"', self.ui)  # base-map selection remains possible
        self.assertIn('enum OsmondMapTheme', self.tiles)
        self.assertIn('case day, night, automatic', self.tiles)
        self.assertIn('setOsmandMapTheme', self.panel)
        self.assertIn('options.traitCollection = UITraitCollection(userInterfaceStyle: snapshotStyle)', self.panel)
        self.assertIn('Apparence de Rivmonde', self.ui)

    def test_builtin_online_topo_and_tft_cache(self):
        topo = source('KoveMirror/Navigation/OsmondTopoOnline.swift')
        self.assertIn('https://tile.opentopomap.org/', topo)
        # Keep the MapKit fallback introduced by the latest white-TFT fix.
        self.assertIn('canReplaceMapContent = false', topo)
        self.assertIn('OpenStreetMap contributors', topo)
        self.assertIn('func renderFrame(mapRect:', topo)
        self.assertIn('loadTile(at path:', topo)
        self.assertIn('setOsmondTopoEnabled(true)', self.ui)
        self.assertIn('refreshOsmondOnlineTopo()', self.panel)
        self.assertIn('topo.renderFrame(mapRect:', self.panel)
        self.assertIn('OfflineTileGrid.rasterZooms(viewWidth: mapRect.size.width', topo)
        self.assertIn('allowNetwork: lockedFix == nil', self.panel)
        self.assertIn('guard let base, !base.lacksDetail else { return nil }', topo)
        self.assertIn('else { renderSystemMap() }', self.panel)
        self.assertIn('RivmondeRasterFrame.hasMapDetail($0.image)', self.panel)
        self.assertNotIn('loadedZoom', topo)

    def test_gpx_refresh_preserves_topo(self):
        self.assertIn('!($0 is OsmondTopoOnline)', self.panel)
        self.assertIn('!($0 is OfflineMBTilesOverlay)', self.panel)
        self.assertIn('doubleInterface.osmondReliefAutoMigrationV1', self.panel)
        self.assertIn('osmondTopoEnabled = true', self.panel)

    def test_no_claim_of_osmand_offline_vector_engine(self):
        self.assertIn('ne sont pas pris en charge', self.tiles)
        self.assertIn('Pour rouler hors ligne, sélectionne une carte raster MBTiles.', self.ui)
        self.assertIn('PBXFileSystemSynchronizedRootGroup', self.project)

if __name__ == '__main__':
    unittest.main()
