import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("rivet_update", Path(__file__).resolve().parents[1] / "update-project.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ProjectUpdateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source, self.target = self.root / "nouvelle version", self.root / "mon projet signé"
        self.source.mkdir(); self.target.mkdir()
        self.project = self.target / "NicoMirror.xcodeproj/project.pbxproj"
        self.project.parent.mkdir()
        self.project.write_text("PBXFileSystemSynchronizedRootGroup; DEVELOPMENT_TEAM = KEEP_ME;")
        (self.target / "KoveMirror/Connection").mkdir(parents=True)
        (self.target / "KoveMirror/Connection/BleController.swift").write_text("old controller")
        (self.target / "KoveMirror/KoveMirror.entitlements").write_text("keep entitlements")
        self.entries = []
        self.removed = []
        self.removed_support = []

    def add(self, name, new, old=None, mode="copy"):
        src = self.source / name
        src.parent.mkdir(parents=True, exist_ok=True)
        src.write_bytes(new)
        if old is not None:
            dst = self.target / name
            dst.parent.mkdir(parents=True, exist_ok=True); dst.write_bytes(old)
        self.entries.append({"path": name, "sha256": hashlib.sha256(new).hexdigest(), "mode": mode})

    def run_update(self, wifi_mode="keep"):
        (self.source / "MISE_A_JOUR.json").write_text(json.dumps({"files": self.entries, "removed_files": self.removed,
                                                              "removed_support_files": self.removed_support}))
        return MODULE.update_project(self.source, self.target, wifi_mode=wifi_mode)

    def test_updates_files_and_backs_up_without_changing_signing(self):
        original_project = self.project.read_bytes()
        self.add("KoveMirror/Connection/BleController.swift", b"new controller", b"old controller")
        self.add("KoveMirror/NewView.swift", b"new view")
        result = self.run_update()
        self.assertEqual(self.project.read_bytes(), original_project)
        self.assertEqual((self.target / "KoveMirror/KoveMirror.entitlements").read_text(), "keep entitlements")
        self.assertEqual((self.target / "KoveMirror/NewView.swift").read_bytes(), b"new view")
        self.assertEqual((Path(result["backup"]) / "KoveMirror/Connection/BleController.swift").read_bytes(), b"old controller")

    def test_signed_manifest_records_merged_settings_and_repeat_creates_no_backup(self):
        name = "KoveMirror/Info.plist"
        self.add(name, plistlib.dumps({"CFBundleDisplayName": "Double Interface"}),
                 plistlib.dumps({"CFBundleIdentifier": "my.local.app", "CFBundleDisplayName": "Prototype"}),
                 "merge_app_branding")
        (self.source / "MISE_A_JOUR.json").write_text(json.dumps({"version": "test", "files": self.entries}))
        first = MODULE.update_project(self.source, self.target)
        self.assertTrue(Path(first["backup"]).exists())
        installed = json.loads((self.target / "MISE_A_JOUR.json").read_text())
        contents = (self.target / name).read_bytes()
        self.assertEqual(installed["files"][0]["sha256"], hashlib.sha256(contents).hexdigest())
        self.assertEqual(plistlib.loads(contents)["CFBundleIdentifier"], "my.local.app")
        second = MODULE.update_project(self.source, self.target)
        self.assertIsNone(second["backup"])
        self.assertEqual(second["updated_files"], 0)

    def test_service_settings_keep_local_account_and_initialize_an_empty_config(self):
        server = "KoveMirror/WizeCommunity.plist"
        traffic = "KoveMirror/TomTomTraffic.plist"
        self.add(server, plistlib.dumps({"URL": "https://template.example", "PublishableKey": "template"}),
                 plistlib.dumps({"URL": "https://local.example", "PublishableKey": "local", "Extra": 1}),
                 "preserve_service_settings")
        self.add(traffic, plistlib.dumps({"APIKey": "sample"}), plistlib.dumps({"APIKey": ""}),
                 "preserve_service_settings")
        self.run_update()
        self.assertEqual(plistlib.loads((self.target / server).read_bytes()),
                         {"URL": "https://local.example", "PublishableKey": "local", "Extra": 1})
        self.assertEqual(plistlib.loads((self.target / traffic).read_bytes())["APIKey"], "sample")

    def test_duplicate_storyboard_is_retained_while_an_old_target_references_it(self):
        name = "KoveMirror/LaunchScreen.storyboard"
        (self.target / name).write_bytes(b"known duplicate")
        self.removed_support = [{"path": name, "sha256": hashlib.sha256(b"known duplicate").hexdigest()}]
        original = self.project.read_text()
        self.project.write_text(original + "\nINFOPLIST_KEY_UILaunchStoryboardName = LaunchScreen;")
        self.run_update()
        self.assertTrue((self.target / name).is_file())
        self.project.write_text(original + "\nINFOPLIST_KEY_UILaunchStoryboardName = LaunchScreenDoubleInterface;")
        self.run_update()
        self.assertFalse((self.target / name).exists())

    def test_merges_query_schemes_and_preserves_existing_identifiers(self):
        before = {"CFBundleIdentifier": "my.actual.bundle", "CFBundleURLTypes": [{"CFBundleURLSchemes": ["mycallback"]}],
                  "LSApplicationQueriesSchemes": ["custom"], "NSCameraUsageDescription": "my text"}
        self.add("KoveMirror/Info.plist", plistlib.dumps({"LSApplicationQueriesSchemes": ["waze", "shortcuts"]}),
                 plistlib.dumps(before), "merge_queries")
        self.run_update()
        after = plistlib.loads((self.target / "KoveMirror/Info.plist").read_bytes())
        self.assertEqual(after["LSApplicationQueriesSchemes"], ["custom", "shortcuts", "waze"])
        for key in before:
            if key != "LSApplicationQueriesSchemes": self.assertEqual(before[key], after[key])

    def test_document_import_registration_preserves_signed_identity(self):
        before = {"CFBundleIdentifier": "my.signed.app", "CFBundleURLTypes": [{"CFBundleURLSchemes": ["mycallback"]}]}
        incoming = {"CFBundleDisplayName": "Double Interface", "CFBundleDocumentTypes": [{"CFBundleTypeRole": "Viewer", "LSItemContentTypes": ["com.doubleinterface.gpx"]}], "UTImportedTypeDeclarations": [{"UTTypeIdentifier": "com.doubleinterface.gpx"}]}
        self.add("KoveMirror/Info.plist", plistlib.dumps(incoming), plistlib.dumps(before), "merge_app_branding")
        self.run_update()
        after = plistlib.loads((self.target / "KoveMirror/Info.plist").read_bytes())
        self.assertEqual(after["CFBundleIdentifier"], before["CFBundleIdentifier"])
        self.assertEqual(after["CFBundleURLTypes"], before["CFBundleURLTypes"])
        self.assertEqual(after["CFBundleDocumentTypes"], incoming["CFBundleDocumentTypes"])
        self.assertEqual(after["UTImportedTypeDeclarations"], incoming["UTImportedTypeDeclarations"])

    def test_hash_failure_prevents_all_writes(self):
        self.add("KoveMirror/Connection/BleController.swift", b"new", b"old")
        (self.source / self.entries[0]["path"]).write_bytes(b"changed")
        with self.assertRaises(ValueError): self.run_update()
        self.assertEqual((self.target / self.entries[0]["path"]).read_bytes(), b"old")

    def test_app_settings_merge_keeps_identity_and_existing_background_modes(self):
        before = {"CFBundleDisplayName": "Mon nom", "CFBundleIdentifier": "my.signed.app",
                  "CFBundleURLTypes": [{"CFBundleURLSchemes": ["mycallback"]}],
                  "LSApplicationQueriesSchemes": ["custom"], "UIBackgroundModes": ["audio"],
                  "NSLocationWhenInUseUsageDescription": "Old explanation"}
        incoming = {"CFBundleDisplayName": "Template name", "CFBundleIdentifier": "must.not.copy",
                    "LSApplicationQueriesSchemes": ["waze"],
                    "NSLocationWhenInUseUsageDescription": "Share a position on request",
                    "NSLocationAlwaysAndWhenInUseUsageDescription": "Ride telemetry while locked"}
        self.add("KoveMirror/Info.plist", plistlib.dumps(incoming), plistlib.dumps(before), "merge_app_settings")
        self.run_update()
        after = plistlib.loads((self.target / "KoveMirror/Info.plist").read_bytes())
        for key in ("CFBundleDisplayName", "CFBundleIdentifier", "CFBundleURLTypes"):
            self.assertEqual(after[key], before[key])
        self.assertEqual(after["LSApplicationQueriesSchemes"], ["custom", "waze"])
        self.assertEqual(after["UIBackgroundModes"], ["audio", "bluetooth-central", "location"])
        self.assertTrue(after["UIRequiresPersistentWiFi"])
        self.assertEqual(after["NSLocationWhenInUseUsageDescription"], incoming["NSLocationWhenInUseUsageDescription"])

    def test_hotspot_removal_preserves_custom_groups_and_signing(self):
        before = {"com.apple.security.application-groups": ["group.my.actual.app"],
                  "application-identifier": "ABC123.my.actual.app",
                  "com.apple.developer.networking.HotspotConfiguration": True}
        source = {"com.apple.security.application-groups": ["group.template.must.not.copy"]}
        self.add("KoveMirror/KoveMirror.entitlements", plistlib.dumps(source),
                 plistlib.dumps(before), "disable_hotspot")
        original = self.project.read_bytes()
        result = self.run_update()
        after = plistlib.loads((self.target / "KoveMirror/KoveMirror.entitlements").read_bytes())
        expected = {key: value for key, value in before.items()
                    if key != "com.apple.developer.networking.HotspotConfiguration"}
        self.assertEqual(after, expected)
        self.assertEqual(self.project.read_bytes(), original)
        backup = Path(result["backup"]) / "KoveMirror/KoveMirror.entitlements"
        self.assertEqual(plistlib.loads(backup.read_bytes()), before)
        self.run_update()
        self.assertEqual(plistlib.loads((self.target / "KoveMirror/KoveMirror.entitlements").read_bytes()), expected)

    def test_wifi_signing_choice_matches_the_runtime_flag_and_preserves_identity(self):
        right = "com.apple.developer.networking.HotspotConfiguration"
        app_rights = "KoveMirror/KoveMirror.entitlements"
        info = "KoveMirror/Info.plist"
        personal = {"com.apple.security.application-groups": ["group.my.signed.app"]}
        self.add(app_rights, plistlib.dumps({right: True}), plistlib.dumps(personal), "configure_hotspot")
        self.add(info, plistlib.dumps({"CFBundleDisplayName": "Double Interface",
                 "DoubleInterfaceAutomaticWiFiJoinEnabled": True}),
                 plistlib.dumps({"CFBundleIdentifier": "my.signed.app"}), "merge_app_branding")
        original_project = self.project.read_bytes()
        for mode, enabled in [("keep", False), ("qr", True), ("keep", True), ("manual", False)]:
            with self.subTest(mode=mode):
                self.run_update(mode)
                actual_rights = plistlib.loads((self.target / app_rights).read_bytes())
                actual_info = plistlib.loads((self.target / info).read_bytes())
                self.assertEqual(actual_rights, {**personal, **({right: True} if enabled else {})})
                self.assertIs(actual_info["DoubleInterfaceAutomaticWiFiJoinEnabled"], enabled)
                self.assertEqual(actual_info["CFBundleIdentifier"], "my.signed.app")
                self.assertEqual(self.project.read_bytes(), original_project)

    def test_hotspot_removal_rejects_a_template_that_still_requests_hotspot(self):
        before = {"com.apple.security.application-groups": ["group.my.actual.app"]}
        self.add("KoveMirror/KoveMirror.entitlements",
                 plistlib.dumps({"com.apple.developer.networking.HotspotConfiguration": True}),
                 plistlib.dumps(before), "disable_hotspot")
        with self.assertRaises(ValueError):
            self.run_update()
        self.assertEqual(plistlib.loads((self.target / "KoveMirror/KoveMirror.entitlements").read_bytes()), before)

    def test_manual_wifi_setting_is_applied_to_an_existing_automatic_installation(self):
        before = {"CFBundleIdentifier": "my.signed.app", "DoubleInterfaceAutomaticWiFiJoinEnabled": True}
        incoming = {"CFBundleDisplayName": "Double Interface", "DoubleInterfaceAutomaticWiFiJoinEnabled": False}
        self.add("KoveMirror/Info.plist", plistlib.dumps(incoming), plistlib.dumps(before), "merge_app_branding")
        self.run_update()
        after = plistlib.loads((self.target / "KoveMirror/Info.plist").read_bytes())
        self.assertFalse(after["DoubleInterfaceAutomaticWiFiJoinEnabled"])
        self.assertEqual(after["CFBundleIdentifier"], before["CFBundleIdentifier"])

    def test_app_branding_updates_name_and_permission_text_without_changing_identity(self):
        before = {"CFBundleDisplayName": "My previous name", "CFBundleIdentifier": "my.signed.app",
                  "CFBundleURLTypes": [{"CFBundleURLSchemes": ["mycallback"]}],
                  "NSCameraUsageDescription": "Previous app uses the camera",
                  "UIBackgroundModes": ["audio"]}
        incoming = {"CFBundleDisplayName": "Double Interface", "CFBundleIdentifier": "must.not.copy",
                    "CFBundleURLTypes": [{"CFBundleURLSchemes": ["mustnotcopy"]}],
                    "NSCameraUsageDescription": "Double Interface reads the motorcycle QR code"}
        self.add("KoveMirror/Info.plist", plistlib.dumps(incoming), plistlib.dumps(before), "merge_app_branding")
        original = self.project.read_bytes()
        self.run_update()
        after = plistlib.loads((self.target / "KoveMirror/Info.plist").read_bytes())
        self.assertEqual(after["CFBundleDisplayName"], incoming["CFBundleDisplayName"])
        self.assertEqual(after["NSCameraUsageDescription"], incoming["NSCameraUsageDescription"])
        for key in ("CFBundleIdentifier", "CFBundleURLTypes"):
            self.assertEqual(after[key], before[key])
        self.assertIn("audio", after["UIBackgroundModes"])
        self.assertEqual(self.project.read_bytes(), original)

    def test_gpx_registration_preserves_existing_document_types_and_signed_identity(self):
        before = {"CFBundleIdentifier": "my.signed.app", "CFBundleURLTypes": [{"CFBundleURLSchemes": ["mycallback"]}],
                  "CFBundleDocumentTypes": [{"CFBundleTypeName": "My existing type", "LSItemContentTypes": ["my.type"]}],
                  "UTImportedTypeDeclarations": [{"UTTypeIdentifier": "my.type"}]}
        incoming = {"CFBundleDisplayName": "Double Interface", "LSSupportsOpeningDocumentsInPlace": True,
                    "CFBundleDocumentTypes": [{"CFBundleTypeName": "Trace GPX", "LSItemContentTypes": ["com.topografix.gpx"]}],
                    "UTImportedTypeDeclarations": [{"UTTypeIdentifier": "com.topografix.gpx", "UTTypeConformsTo": ["public.xml"]}]}
        self.add("KoveMirror/Info.plist", plistlib.dumps(incoming), plistlib.dumps(before), "merge_app_branding")
        self.run_update()
        after = plistlib.loads((self.target / "KoveMirror/Info.plist").read_bytes())
        self.assertEqual(after["CFBundleIdentifier"], before["CFBundleIdentifier"])
        self.assertEqual(after["CFBundleURLTypes"], before["CFBundleURLTypes"])
        self.assertEqual(after["CFBundleDocumentTypes"], before["CFBundleDocumentTypes"] + incoming["CFBundleDocumentTypes"])
        self.assertEqual(after["UTImportedTypeDeclarations"], before["UTImportedTypeDeclarations"] + incoming["UTImportedTypeDeclarations"])
        self.assertTrue(after["LSSupportsOpeningDocumentsInPlace"])

    def test_extension_icon_merge_preserves_name_and_extension_settings(self):
        before = {"CFBundleDisplayName": "My App — screen", "CFBundleIdentifier": "my.actual.extension",
                  "NSExtension": {"NSExtensionPointIdentifier": "com.apple.broadcast-services-upload"}}
        icons = {"CFBundleIcons": {"CFBundlePrimaryIcon": {"CFBundleIconFiles": ["RivetIcon60x60"]}},
                 "CFBundleIcons~ipad": {"CFBundlePrimaryIcon": {"CFBundleIconFiles": ["RivetIcon76x76"]}}}
        self.add("Kove broadcast extension/Info.plist", plistlib.dumps(icons),
                 plistlib.dumps(before), "merge_extension_icons")
        self.run_update()
        self.assertEqual(plistlib.loads((self.target / "Kove broadcast extension/Info.plist").read_bytes()), before | icons)

    def test_extension_branding_updates_name_and_icons_without_changing_extension_settings(self):
        before = {"CFBundleDisplayName": "My previous broadcast", "CFBundleIdentifier": "my.signed.extension",
                  "NSExtension": {"NSExtensionPointIdentifier": "com.apple.broadcast-services-upload"}}
        incoming = {"CFBundleDisplayName": "Double Interface", "CFBundleIdentifier": "must.not.copy",
                    "CFBundleIcons": {"CFBundlePrimaryIcon": {"CFBundleIconFiles": ["AppIcon60x60"]}},
                    "CFBundleIcons~ipad": {"CFBundlePrimaryIcon": {"CFBundleIconFiles": ["AppIcon76x76"]}}}
        self.add("Kove broadcast extension/Info.plist", plistlib.dumps(incoming),
                 plistlib.dumps(before), "merge_extension_branding")
        self.run_update()
        after = plistlib.loads((self.target / "Kove broadcast extension/Info.plist").read_bytes())
        self.assertEqual(after, before | {key: value for key, value in incoming.items() if key != "CFBundleIdentifier"})

    def test_project_branding_changes_only_display_names_in_signed_build_settings(self):
        before = ('PBXFileSystemSynchronizedRootGroup; DEVELOPMENT_TEAM = KEEP_ME;\n'
                  '    INFOPLIST_KEY_CFBundleDisplayName = "Old app";\n'
                  '    PRODUCT_BUNDLE_IDENTIFIER = my.signed.app;\n'
                  '    INFOPLIST_KEY_CFBundleDisplayName = "Old broadcast";\n')
        incoming = ('PBXFileSystemSynchronizedRootGroup; DEVELOPMENT_TEAM = MUST_NOT_COPY;\n'
                    '    INFOPLIST_KEY_CFBundleDisplayName = "Double Interface";\n'
                    '    PRODUCT_BUNDLE_IDENTIFIER = must.not.copy;\n')
        self.add("NicoMirror.xcodeproj/project.pbxproj", incoming.encode(), before.encode(), "merge_project_display_name")
        result = self.run_update()
        expected = before.replace('"Old app"', '"Double Interface"').replace('"Old broadcast"', '"Double Interface"')
        self.assertEqual(self.project.read_text(), expected)
        self.assertEqual((self.target / "KoveMirror/KoveMirror.entitlements").read_text(), "keep entitlements")
        self.assertEqual((Path(result["backup"]) / "NicoMirror.xcodeproj/project.pbxproj").read_text(), before)

    def test_inconsistent_project_branding_prevents_all_writes(self):
        original = self.project.read_bytes()
        self.add("KoveMirror/Connection/BleController.swift", b"new", b"old controller")
        incoming = ('INFOPLIST_KEY_CFBundleDisplayName = "One name";\n'
                    'INFOPLIST_KEY_CFBundleDisplayName = "Another name";\n')
        self.add("NicoMirror.xcodeproj/project.pbxproj", incoming.encode(), mode="merge_project_display_name")
        with self.assertRaises(ValueError):
            self.run_update()
        self.assertEqual(self.project.read_bytes(), original)
        self.assertEqual((self.target / "KoveMirror/Connection/BleController.swift").read_bytes(), b"old controller")

    def test_rejects_parent_paths_and_signing_file_replacements(self):
        for name in ["../outside.swift", "KoveMirror/KoveMirror.entitlements", "NicoMirror.xcodeproj/project.pbxproj"]:
            self.entries = [{"path": name, "sha256": "unused"}]
            with self.assertRaises((ValueError, FileNotFoundError)): self.run_update()
        self.assertFalse((self.root / "outside.swift").exists())

    def test_rejects_destination_symlink_outside_project(self):
        outside = self.root / "external"; outside.mkdir()
        (self.target / "linked").symlink_to(outside, target_is_directory=True)
        self.add("linked/new.swift", b"new")
        with self.assertRaises(ValueError): self.run_update()
        self.assertEqual(list(outside.iterdir()), [])

    def test_failed_replace_rolls_back_written_files(self):
        self.add("KoveMirror/Connection/BleController.swift", b"new", b"old")
        self.add("KoveMirror/NewView.swift", b"new view")
        self.add("KoveMirror/LastView.swift", b"last view")
        replace = MODULE.os.replace
        calls = [0]
        def failing_replace(src, dst):
            calls[0] += 1
            if calls[0] == 3: raise OSError("simulated full disk")
            return replace(src, dst)
        with patch.object(MODULE.os, "replace", side_effect=failing_replace):
            with self.assertRaises(OSError): self.run_update()
        self.assertEqual((self.target / "KoveMirror/Connection/BleController.swift").read_bytes(), b"old")
        self.assertFalse((self.target / "KoveMirror/NewView.swift").exists())

    def test_removes_obsolete_source_with_backup_and_preserves_signing(self):
        obsolete = self.target / "KoveMirror/OldLauncher.swift"
        obsolete.write_text("old app launcher")
        self.removed = ["KoveMirror/OldLauncher.swift", "KoveMirror/AlreadyRemoved.swift"]
        self.add("KoveMirror/NewPanel.swift", b"new panel")
        before = self.project.read_bytes()
        result = self.run_update()
        self.assertEqual(result["removed_files"], 1)
        self.assertEqual(result["updated_files"], 1)
        self.assertFalse(obsolete.exists())
        self.assertEqual((Path(result["backup"]) / self.removed[0]).read_text(), "old app launcher")
        self.assertEqual(self.project.read_bytes(), before)
        self.assertEqual((self.target / "KoveMirror/KoveMirror.entitlements").read_text(), "keep entitlements")

    def test_old_preview_is_removed_with_a_backup(self):
        p = self.target / "Apercus/old.png"
        p.parent.mkdir(); p.write_bytes(b"old preview")
        self.removed_support = [{"path": "Apercus/old.png", "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}]
        result = self.run_update()
        self.assertFalse(p.exists())
        self.assertEqual((Path(result["backup"]) / "Apercus/old.png").read_bytes(), b"old preview")

    def test_cleanup_preserves_a_document_edited_by_the_user(self):
        p = self.target / "CORRECTIF_ANCIEN.md"
        p.write_text("personal notes")
        self.removed_support = [{"path": p.name, "sha256": hashlib.sha256(b"original notice").hexdigest()}]
        self.run_update()
        self.assertEqual(p.read_text(), "personal notes")

    def test_cleanup_rejects_signing_personal_data_and_parent_paths(self):
        self.add("KoveMirror/NewPanel.swift", b"new")
        for name in ["README.md", "PRIVACY_POLICY.md", "KoveMirror/KoveMirror.entitlements",
                     "NicoMirror.xcodeproj/project.pbxproj", "user/ride.gpx", "Apercus/../../outside.png"]:
            with self.subTest(name=name):
                self.removed_support = [{"path": name, "sha256": hashlib.sha256(b"old").hexdigest()}]
                with self.assertRaises(ValueError): self.run_update()
                self.assertFalse((self.target / "KoveMirror/NewPanel.swift").exists())

    def test_exact_unused_upload_source_can_be_removed(self):
        p = self.target / "KoveMirrorUploadExtension/SampleHandler.swift"
        p.parent.mkdir(); p.write_text("unused duplicate")
        self.removed = ["KoveMirrorUploadExtension/SampleHandler.swift"]
        result = self.run_update()
        self.assertFalse(p.exists())
        self.assertEqual((Path(result["backup"]) / self.removed[0]).read_text(), "unused duplicate")

    def test_invalid_deletions_prevent_all_writes(self):
        self.add("KoveMirror/NewPanel.swift", b"new")
        for name in ["../outside.swift", "KoveMirror/../outside.swift",
                     "NicoMirror.xcodeproj/project.pbxproj", "KoveMirror/Info.plist",
                     "KoveMirror/KoveMirror.entitlements", "user/notes.swift"]:
            with self.subTest(name=name):
                self.removed = [name]
                with self.assertRaises(ValueError):
                    self.run_update()
                self.assertFalse((self.target / "KoveMirror/NewPanel.swift").exists())

    def test_failed_deletion_restores_removed_and_updated_files(self):
        first = self.target / "KoveMirror/FirstObsolete.swift"
        second = self.target / "KoveMirror/SecondObsolete.swift"
        first.write_text("first original")
        second.write_text("second original")
        self.removed = ["KoveMirror/FirstObsolete.swift", "KoveMirror/SecondObsolete.swift"]
        self.add("KoveMirror/Connection/BleController.swift", b"updated controller", b"old controller")
        unlink = Path.unlink
        def fail_second(path, *args, **kwargs):
            if path == second:
                raise OSError("simulated deletion failure")
            return unlink(path, *args, **kwargs)
        with patch.object(Path, "unlink", fail_second):
            with self.assertRaises(OSError):
                self.run_update()
        self.assertEqual(first.read_text(), "first original")
        self.assertEqual(second.read_text(), "second original")
        self.assertEqual((self.target / "KoveMirror/Connection/BleController.swift").read_text(), "old controller")

    def test_launcher_gets_execute_rights_for_existing_and_new_files(self):
        self.add("Mettre_a_jour_sur_Mac.command", b"#!/bin/bash\nexit 0\n", b"old launcher")
        self.entries[-1]["executable"] = True
        target = self.target / "Mettre_a_jour_sur_Mac.command"
        target.chmod(0o644)
        self.add("scripts/new.sh", b"#!/bin/bash\nexit 0\n")
        self.entries[-1]["executable"] = True
        self.run_update()
        self.assertEqual(target.stat().st_mode & 0o777, 0o755)
        self.assertEqual((self.target / "scripts/new.sh").stat().st_mode & 0o777, 0o755)

    def test_non_scripts_cannot_request_execute_rights(self):
        self.add("KoveMirror/NewPanel.swift", b"new panel")
        self.entries[-1]["executable"] = True
        with self.assertRaises(ValueError):
            self.run_update()
        self.assertFalse((self.target / "KoveMirror/NewPanel.swift").exists())

    def test_private_key_exclusion_preserves_user_gitignore(self):
        self.add(".gitignore", b"KoveMirror/TomTomTraffic.plist\n", b"my-private-notes/\n", mode="merge_gitignore")
        self.run_update()
        content = (self.target / ".gitignore").read_text()
        self.assertIn("my-private-notes/\n", content)
        self.assertIn("KoveMirror/TomTomTraffic.plist\n", content)

    def test_non_executable_files_preserve_their_permissions(self):
        self.add("KoveMirror/NewPanel.swift", b"new", b"old")
        target = self.target / "KoveMirror/NewPanel.swift"
        target.chmod(0o640)
        self.run_update()
        self.assertEqual(target.stat().st_mode & 0o777, 0o640)


if __name__ == "__main__":
    unittest.main()
