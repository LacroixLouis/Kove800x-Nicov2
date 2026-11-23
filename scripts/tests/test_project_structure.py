"""Check links between release tools, project resources and test targets."""
import json
from pathlib import Path
import re
import sqlite3
import sys
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import xcode_project


class ProjectStructureTests(unittest.TestCase):
    def test_capture_command_selects_an_existing_ui_test(self):
        launcher = (ROOT / "Photos_des_ecrans.command").read_text()
        match = re.search(r"-only-testing:(\w+)/(\w+)/(\w+)", launcher)
        self.assertIsNotNone(match)
        target, suite, method = match.groups()
        test = (ROOT / target / (suite + ".swift")).read_text()
        self.assertRegex(test, r"\bfunc\s+" + re.escape(method) + r"\s*\(")
        self.assertIn("XCTAttachment(screenshot:", test)

    def test_shared_schemes_point_to_real_targets_and_products(self):
        project = ROOT / "NicoMirror.xcodeproj"
        objects = xcode_project.loads((project / "project.pbxproj").read_text())["objects"]
        schemes = list((project / "xcshareddata/xcschemes").glob("*.xcscheme"))
        self.assertTrue(schemes)
        for scheme in schemes:
            for ref in ET.parse(scheme).iter("BuildableReference"):
                with self.subTest(scheme=scheme.name, target=ref.get("BlueprintName")):
                    if ref.get("ReferencedContainer") != "container:" + project.name:
                        continue
                    target = objects[ref.get("BlueprintIdentifier")]
                    self.assertEqual(target["name"], ref.get("BlueprintName"))
                    self.assertEqual(objects[target["productReference"]]["path"], ref.get("BuildableName"))

    def test_sample_offline_map_contains_readable_raster_tiles(self):
        sample = ROOT / "Tests/cartes/CARTE_TEST_UNIQUEMENT_NON_NAVIGABLE.mbtiles"
        db = sqlite3.connect(sample.as_uri() + "?mode=ro", uri=True)
        self.addCleanup(db.close)
        self.assertEqual(db.execute("PRAGMA integrity_check").fetchone(), ("ok",))
        tiles = db.execute("SELECT zoom_level,tile_column,tile_row,tile_data FROM tiles").fetchall()
        self.assertGreater(len(tiles), 0)
        for zoom, column, row, data in tiles:
            self.assertTrue(0 <= column < 2 ** zoom and 0 <= row < 2 ** zoom)
            self.assertTrue(data.startswith(b"\x89PNG\r\n\x1a\n"))

    def test_assets_refer_to_files_present_in_their_set(self):
        catalog = ROOT / "KoveMirror/Assets.xcassets"
        for spec in catalog.rglob("Contents.json"):
            for item in json.loads(spec.read_text()).get("images", []):
                if "filename" in item:
                    with self.subTest(resource=spec.parent.name):
                        self.assertTrue((spec.parent / item["filename"]).is_file())

