"""Map camera integration checks and execution of the offline reader's zoom query."""
import re
import sqlite3
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class MapPositionTests(unittest.TestCase):
    def test_compass_can_turn_a_camera_between_position_updates(self):
        panel = (ROOT / "KoveMirror/Navigation/IntegratedNavigationPanel.swift").read_text()
        camera = panel.split("private func updateCamera(with fix:", 1)[1].split("func setUpdatesPaused", 1)[0]
        self.assertIn("map.isRotateEnabled = true", panel)
        self.assertIn("focus.followsCourse(navigating: isGuiding)", panel)
        self.assertIn("MapHeading.changed(from: old.heading, to: heading)", camera)
        self.assertIn("old.heading = heading", camera)
        self.assertIn("case .northUp: heading = 0", camera)

    def test_raster_tiles_and_gps_use_the_same_course_projection(self):
        for filename in ("OfflineMBTiles.swift", "OsmondTopoOnline.swift"):
            with self.subTest(renderer=filename):
                src = (ROOT / "KoveMirror/Navigation" / filename).read_text().split("func renderFrame(", 1)[1]
                self.assertIn("TFTMapViewport(rect: mapRect, size:", src)
                self.assertIn("ctx.concatenate(viewport.sourceToScreen)", src)
                self.assertIn("project: viewport.point", src)
                self.assertLess(src.index("ctx.restoreGState()"), src.index("mapName as NSString"))

    def test_cached_map_and_overlays_share_the_locked_camera_transform(self):
        panel = (ROOT / "KoveMirror/Navigation/IntegratedNavigationPanel.swift").read_text()
        self.assertIn(".rotated(by: -angle).translatedBy(x: -pivot.x, y: -pivot.y)", panel)
        self.assertIn("snapshot.point(for: coordinate).applying(transform)", panel)
        self.assertIn("ctx.concatenate(transform)", panel)
        self.assertIn("return viewport.point(coordinate)", panel)
        self.assertIn("camera.heading = mapHeading", panel)

    def test_pending_fix_reaches_each_camera_entry_point(self):
        panel = (ROOT / "KoveMirror/Navigation/IntegratedNavigationPanel.swift").read_text()
        self.assertIn("func recenter() { requestFocus(.position) }", panel)
        self.assertIn("func cycleMapFocus() { requestFocus(.mode(focus.nextStage)) }", panel)
        self.assertIn("updateCamera(with: nav.userLocation)", panel)
        delegate = panel.split("didUpdate userLocation: MKUserLocation", 1)[1].split("\n}", 1)[0]
        self.assertIn("updateCamera(with: nav.currentMapLocation(including: userLocation.location))", delegate)
        self.assertNotIn("setUserTrackingMode(.follow", panel)
        canvas = (ROOT / "KoveMirror/Navigation/TrailMapCanvas.swift").read_text()
        self.assertIn("switch cameraRequest.target", canvas)
        self.assertIn("centerIfReady(on: mapView)", canvas)

    def test_one_shot_uses_a_separate_manager_and_validates_location(self):
        manager = (ROOT / "KoveMirror/Connection/LocationAndNavigationManager.swift").read_text()
        camera_request = manager.split("func requestMapCameraLocation()", 1)[1].split("\n    }", 1)[0]
        self.assertIn("let manager = CLLocationManager()", camera_request)
        self.assertIn("cameraFixManager == nil", camera_request)
        self.assertIn("manager.requestLocation()", camera_request)
        fresh = manager.split("func currentMapLocation(", 1)[1].split("\n    }", 1)[0]
        for requirement in ("CLLocationCoordinate2DIsValid", "ProjectionPolicy.isFresh", "locationManager.location"):
            self.assertIn(requirement, fresh)

    def test_world_zoom_range_uses_index_endpoints_for_flat_and_normalized_maps(self):
        source = (ROOT / "KoveMirror/Navigation/OfflineMBTiles.swift").read_text()
        query = re.search(r'func zoomRange\(\).*?let sql = "([^"]+)"', source, re.S).group(1)
        for normalized in (False, True):
            with self.subTest(normalized=normalized), sqlite3.connect(":memory:") as db:
                table = "map" if normalized else "tiles"
                db.execute(f"CREATE TABLE {table}(zoom_level, tile_column, tile_row, tile_id)")
                db.execute(f"CREATE UNIQUE INDEX xyz ON {table}(zoom_level,tile_column,tile_row)")
                db.executemany(f"INSERT INTO {table} VALUES (?, ?, 0, 1)",
                               ((6 + i % 8, i) for i in range(12000)))
                if normalized:
                    db.execute("CREATE TABLE images(tile_id INTEGER PRIMARY KEY, tile_data BLOB)")
                    db.execute("INSERT INTO images VALUES (1, X'00')")
                    db.execute("CREATE VIEW tiles AS SELECT map.zoom_level, map.tile_column, map.tile_row, "
                               "images.tile_data FROM map JOIN images USING(tile_id)")
                # Even this small sample takes far more than 500 VM instructions to scan.
                db.set_progress_handler(lambda: 1, 500)
                self.assertEqual(db.execute(query).fetchone(), (6, 13))
