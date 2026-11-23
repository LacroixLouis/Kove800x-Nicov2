"""Validate bundled non-navigable world relief and Rivmonde installation path."""
from pathlib import Path
import sqlite3
import unittest

ROOT=Path(__file__).resolve().parents[2]
FILE=ROOT/'KoveMirror/Rivmonde_Monde_Relief_Apercu_v1.mbtiles'

class BundledWorldReliefTests(unittest.TestCase):
    def test_mbtiles_real_raster_and_world_coverage(self):
        self.assertTrue(FILE.is_file())
        with sqlite3.connect(FILE) as db:
            self.assertEqual(db.execute('PRAGMA integrity_check').fetchone()[0],'ok')
            metadata=dict(db.execute('SELECT name,value FROM metadata'))
            self.assertEqual(metadata['format'],'jpg')
            self.assertEqual(metadata['scheme'],'tms')
            self.assertEqual(metadata['minzoom'],'0')
            self.assertEqual(metadata['maxzoom'],'5')
            self.assertEqual(db.execute('SELECT COUNT(*) FROM tiles').fetchone()[0],1365)
            self.assertTrue(db.execute('SELECT tile_data FROM tiles LIMIT 1').fetchone()[0].startswith(b'\xff\xd8'))
    def test_install_bundled_and_non_navigation_label(self):
        model=(ROOT/'KoveMirror/Navigation/OfflineMBTiles.swift').read_text()
        panel=(ROOT/'KoveMirror/Navigation/IntegratedNavigationPanel.swift').read_text()
        ui=(ROOT/'KoveMirror/WebCockpitView.swift').read_text()
        self.assertIn('installBundledWorldReliefOverview()',model)
        self.assertIn('Bundle.main.url(forResource: "Rivmonde_Monde_Relief_Apercu_v1"',model)
        self.assertIn('Relief mondial NOAA · aperçu uniquement · non navigable',panel)
        self.assertIn('Ne pas utiliser pour naviguer sur les pistes.',ui)

if __name__=='__main__': unittest.main()
