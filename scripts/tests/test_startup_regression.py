"""Lightweight source invariants for the staged iOS startup."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class StartupRegressionTests(unittest.TestCase):
    def test_tft_welcome_starts_from_written_logo_frame(self):
        tcp = (ROOT / 'KoveMirror/Connection/TcpServerManager.swift').read_text()
        ble = (ROOT / 'KoveMirror/Connection/BleController.swift').read_text()
        stream = (ROOT / 'KoveMirror/Connection/WebPanelStream.swift').read_text()
        header = tcp.split('private func sendVideoSizeHeader', 1)[1].split('private func startVideoHeartbeat', 1)[0]
        self.assertLess(header.index('connection.send(content: header'), header.index('self.onVideoConnectCallback?()'))
        self.assertIn('webPanelStream.videoFrameSent(capturedAt: capturedAt, sentAt: sentAt)', ble)
        self.assertIn('splash.submittedLogo(at: pts.seconds)', stream)
        self.assertIn('forceKeyframe: forceKeyframe', stream)
        self.assertLess(stream.index('if splash.shouldShow(at: now)'), stream.index('session.snapshotTFT('))
        self.assertIn('scheduleLockedSplashEnd()', stream)

    def test_native_swiftui_first_frame(self):
        app = (ROOT / 'KoveMirror/KoveMirrorApp.swift').read_text()
        self.assertIn('            BootView()', app)
        self.assertIn('Image("StartupLogoV2")', app)
        self.assertNotIn('ProgressView("Préparation des cartes…")', app)
        self.assertIn('                ConnectionStatusView()', app)

    def test_map_renderers_are_persistent_but_lazy(self):
        code = (ROOT / 'KoveMirror/WebCockpitSession.swift').read_text()
        for name in ('tracks', 'roads', 'osmand'):
            self.assertIn(f'lazy var {name} = IntegratedNavigationPanel', code)

    def test_heavy_startup_deferred_and_cancelled(self):
        code = (ROOT / 'KoveMirror/WebCockpitView.swift').read_text()
        self.assertIn('startupToken == token', code)
        self.assertIn('startupToken = UUID() // Ignore', code)
        self.assertIn('session.beginLocation()', code)
        self.assertIn('bleController.resumeAutomaticConnection()', code)

if __name__ == '__main__':
    unittest.main()
