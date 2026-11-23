"""Static checks for the transparent name on BOTH iPhone and encoded TFT."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]
class MapNameOverlayTests(unittest.TestCase):
    def text(self, p): return (ROOT / p).read_text()
    def test_names_correct_and_no_capsule(self):
        profile = self.text('KoveMirror/SetupViews/WebPanelLayout.swift')
        self.assertIn('case .explorer: return "Rivadventure"', profile)
        self.assertIn('case .wize: return "Rivroute"', profile)
        self.assertIn('case .osmand: return "Rivmonde"', profile)
        self.assertIn('var overlayTitle: String { title.uppercased() }', profile)
        colors = self.text('KoveMirror/WebCockpitSession.swift')
        for rgb in ['100/255, green: 237/255, blue: 84/255',
                    '57/255, green: 139/255, blue: 255/255',
                    '255/255, green: 159/255, blue: 51/255']:
            self.assertIn(rgb, colors)
    def test_iphone_and_miniature_keep_label_transparent(self):
        src = self.text('KoveMirror/Navigation/IntegratedNavigationPanel.swift')
        self.assertIn('mapNameLabel.backgroundColor = .clear', src)
        self.assertIn('mapNameLabel.isUserInteractionEnabled = false', src)
        self.assertIn('mapNameLabel.text = mapProfile.overlayTitle', src)
        self.assertIn('view.addSubview(mapNameLabel)', src)
        self.assertIn('mapNameTopConstraint?.constant = isTFT ? 22', src)
        host = self.text('KoveMirror/WebCockpitView.swift')
        self.assertIn('incomingTFT.view.removeFromSuperview()', host)
        self.assertIn('miniContent.addSubview(incomingTFT.view)', host)
    def test_tft_video_draws_same_name_for_both_snapshot_paths(self):
        src = self.text('KoveMirror/Connection/WebPanelStream.swift')
        self.assertIn('let nameProfile = session.profile(id)', src)
        self.assertIn('self.pixelBuffer(image, outputSize: size, nameProfile: nameProfile)', src)
        self.assertIn('(nameProfile.overlayTitle as NSString).draw(', src)
        self.assertIn('.foregroundColor: nameProfile.overlayColor', src)
        self.assertIn('image.draw(in: rect)', src)
        self.assertRegex(src, r'server\.streamVideoFrame\(data: data, source: \.screen,\s*capturedAt:')
if __name__ == '__main__': unittest.main()
