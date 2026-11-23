"""Static regression checks for the 22 November visual refresh.

These are NOT iOS UI tests or TFT connection tests. Xcode runs those on a Mac.
"""
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]


class VisualRedesignTests(unittest.TestCase):
    def test_real_map_renderer_not_static_image(self):
        source = (ROOT / 'KoveMirror/WebCockpitView.swift').read_text()
        self.assertIn('DualMapRendererHost(', source)
        self.assertIn('session.renderer(session.layout.tft)', source)
        self.assertIn('session.exchange()', source)
        self.assertIn('onMove: { x, y in session.moveMini(x: x, y: y) }', source)
        self.assertNotIn('Image("Maquette_Navigation_BLEU_TFT_ORANGE_REFERENCE")', source)

    def test_navigation_actions_keep_their_semantics(self):
        source = (ROOT / 'KoveMirror/WebCockpitView.swift').read_text()
        self.assertIn('private var navigationQuickActions: some View', source)
        self.assertIn('nav.isAudioMuted.toggle()', source)
        self.assertIn('nav.stopNavigation()', source)
        self.assertIn('nav.stopFollowingGPX()', source)
        self.assertIn('maps.stopGuidance', source)
        self.assertIn('maps.toggleGuidanceAudio', source)
        self.assertIn('private let controlsIdleTimeout: TimeInterval = 4', source)

    def test_launch_art_and_icon_actual_assets(self):
        for rel in ('AppIcon.appiconset/icon_1024.png', 'StartupLogoV2.imageset/startup_logo_v2.png'):
            path = ROOT / 'KoveMirror/Assets.xcassets' / rel
            data = path.read_bytes()
            self.assertEqual(data[:8], b'\x89PNG\r\n\x1a\n')
            width, height = struct.unpack('>II', data[16:24])
            self.assertEqual((width, height), (1024, 1024))
        doc = ET.parse(ROOT / 'KoveMirror/LaunchScreenDoubleInterface.storyboard')
        views = [v.attrib for v in doc.iter('imageView')]
        self.assertTrue(any(v.get('image') == 'StartupLogoV2' for v in views))

    def test_keep_background_map_projection(self):
        source = (ROOT / 'KoveMirror/WebCockpitView.swift').read_text()
        self.assertIn('bleController.beginWebPanelProjection()', source)
        self.assertIn('bleController.selectMiniature()', source)
        self.assertIn('bleController.resumeAutomaticConnection()', source)
        session = (ROOT / 'KoveMirror/WebCockpitSession.swift').read_text()
        self.assertIn('func snapshotTFT(', session)
        self.assertIn('lockedTFTOnly', session)

    def test_both_broadcast_extensions_install_the_current_icon_family(self):
        manifest = json.loads((ROOT / 'MISE_A_JOUR.json').read_text())
        files = {item['path']: item for item in manifest['files']}
        retired = {item['sha256'] for item in manifest['removed_support_files']}
        variants = {'60x60@2x': 120, '60x60@3x': 180, '76x76': 76,
                    '76x76@2x': 152, '83.5x83.5@2x': 167}
        artwork = {}
        for folder in ('Kove broadcast extension', 'Kove broadcast extensionSetupUI'):
            with self.subTest(extension=folder):
                plist_path = folder + '/Info.plist'
                self.assertEqual(files[plist_path]['mode'], 'merge_extension_icons')
                info = plistlib.loads((ROOT / plist_path).read_bytes())
                for key, stems in [('CFBundleIcons', ['60x60']),
                                   ('CFBundleIcons~ipad', ['60x60', '76x76', '83.5x83.5'])]:
                    self.assertEqual(info[key]['CFBundlePrimaryIcon']['CFBundleIconFiles'],
                                     ['DoubleInterfaceIcon' + stem for stem in stems])
                expected = {'DoubleInterfaceIcon' + v + '.png' for v in variants}
                self.assertEqual({p.name for p in (ROOT / folder).glob('*.png')}, expected)
                for variant, side in variants.items():
                    path = folder + '/DoubleInterfaceIcon' + variant + '.png'
                    data = (ROOT / path).read_bytes()
                    digest = hashlib.sha256(data).hexdigest()
                    self.assertEqual(struct.unpack('>II', data[16:24]), (side, side))
                    self.assertEqual(files[path]['sha256'], digest)
                    self.assertNotIn(digest, retired)
                    self.assertEqual(artwork.setdefault(variant, digest), digest)

if __name__ == '__main__':
    unittest.main()
