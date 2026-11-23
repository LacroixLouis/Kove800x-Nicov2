"""Static regression guards for iOS-only GPS/video paths."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class LockedGPSLatencyTests(unittest.TestCase):
    def source(self, name):
        return (ROOT / name).read_text()

    def test_locked_gps_keeps_background_activity(self):
        src = self.source('KoveMirror/Connection/LocationAndNavigationManager.swift')
        self.assertIn('locationManager.allowsBackgroundLocationUpdates = needed && authorized', src)
        self.assertIn('backgroundActivitySession = CLBackgroundActivitySession()', src)
        self.assertIn('locationManager.requestAlwaysAuthorization()', src)
        self.assertIn('requestedAlwaysForRide', src)
        self.assertIn('needed ? kCLDistanceFilterNone : 2', src)
        self.assertIn('locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation', src)
        self.assertIn('locationManager.pausesLocationUpdatesAutomatically = false', src)

    def test_rejects_cached_locations(self):
        src = self.source('KoveMirror/Connection/LocationAndNavigationManager.swift')
        self.assertIn('locations.last(where:', src)
        self.assertIn('ProjectionPolicy.isFresh(timestamp: $0.timestamp', src)
        self.assertIn('location.timestamp <= previous.timestamp', src)

    def test_tcp_video_backpressure_without_dropping_delta_frames(self):
        tcp = self.source('KoveMirror/Connection/TcpServerManager.swift')
        stream = self.source('KoveMirror/Connection/WebPanelStream.swift')
        self.assertIn('NWProtocolTCP.Options)?.noDelay = true', tcp)
        self.assertIn('pendingVideoBytes += data.count', tcp)
        self.assertIn('canAcceptNewVideoFrame(maxPendingWrites: backgroundLocationDriven ? 1 : 2)', stream)
        self.assertIn('maxPendingVideoBytes', tcp)

    def test_video_pacing_uses_one_source_in_both_xcode_targets_and_swiftpm(self):
        path = 'SetupViews/KoveScreenPreset.swift'
        self.assertIn('enum TFTFrameRatePolicy', self.source('KoveMirror/' + path))
        self.assertIn(path, self.source('NicoMirror.xcodeproj/project.pbxproj'))
        self.assertIn('"KoveScreenPreset.swift"', self.source('Package.swift'))
        self.assertNotIn('enum TFTFrameRatePolicy', self.source('KoveMirror/Connection/TcpServerManager.swift'))

    def test_ride_survives_temporary_connection_loss(self):
        ble = self.source('KoveMirror/Connection/BleController.swift')
        self.assertIn('hasStartedTFTRide = true', ble)
        self.assertIn('(transportReady || hasStartedTFTRide)', ble)
        self.assertIn('hasStartedTFTRide = false', ble)

    def test_locked_fix_is_submitted_without_a_pacing_timer(self):
        src = self.source('KoveMirror/Connection/WebPanelStream.swift')
        admission = src.split('var lockedFix: CLLocation?', 1)[1].split('let nameProfile = session.profile(id)', 1)[0]
        self.assertIn('ProjectionPolicy.isFresh', admission)
        self.assertIn('lockedDelivery.begin(fix: fix.timestamp, capturedAt: pts.seconds,', admission)
        self.assertIn('heading: session.renderer(id).courseUpHeading', admission)
        self.assertNotIn('asyncAfter', admission)
        self.assertNotIn('lastBackgroundAttemptUptime', src)
        self.assertIn('lockedDelivery.sent(capturedAt: capturedAt)', src)

    def test_intermittent_locked_frames_flush_the_encoder(self):
        stream = self.source('KoveMirror/Connection/WebPanelStream.swift')
        encoder = self.source('KoveMirror/Connection/H264Encoder.swift')
        self.assertIn('let flushImmediately = lockedFix != nil', stream)
        self.assertIn('pts: pts, flushImmediately: flushImmediately', stream)
        self.assertIn('VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: pts)', encoder)

    def test_locked_snapshot_avoids_moving_mapkit_camera(self):
        panel = self.source('KoveMirror/Navigation/IntegratedNavigationPanel.swift')
        self.assertIn('refresh(skipMapCameraUpdates: lockedFix != nil)', panel)
        self.assertIn('if !skipMapCameraUpdates {', panel)
        self.assertIn('(!locked || UIApplication.shared.applicationState != .background)', panel)

    def test_no_second_map_render_after_a_new_gps_fix(self):
        stream = self.source('KoveMirror/Connection/WebPanelStream.swift')
        self.assertNotIn('consecutiveObsoleteSnapshots', stream)
        self.assertNotIn('newestFix.timestamp.timeIntervalSince(lockedFix.timestamp) >= 0.75', stream)
        self.assertIn('Do not discard a successfully rendered locked-map image', stream)
        self.assertIn('let flushImmediately = lockedFix != nil', stream)

    def test_ble_position_update_runs_on_gps_callback(self):
        gps = self.source('KoveMirror/Connection/LocationAndNavigationManager.swift')
        ble = self.source('KoveMirror/Connection/TelemetrySyncManager.swift')
        self.assertIn('TelemetrySyncManager.shared.onLocationFix()', gps)
        self.assertIn('lastLocationTelemetryAt', ble)


if __name__ == '__main__':
    unittest.main()
