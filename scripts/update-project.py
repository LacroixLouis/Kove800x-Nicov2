#!/usr/bin/env python3
"""Update an already signed local Xcode project without replacing its signing files."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import tempfile
from datetime import datetime


def safe_path(base, relative):
    name = Path(relative)
    if name.is_absolute() or not name.parts or ".." in name.parts:
        raise ValueError("Chemin de mise à jour invalide.")
    path = base / name
    if not path.resolve().is_relative_to(base.resolve()):
        raise ValueError("Un lien symbolique sort du dossier du projet.")
    return path


HOTSPOT = "com.apple.developer.networking.HotspotConfiguration"


def update_project(source, target, wifi_mode="keep"):
    source, target = Path(source).resolve(), Path(target).resolve()
    if source == target:
        raise ValueError("Ce dossier contient déjà la nouvelle version. Ouvre son projet dans Xcode.")
    project = target / "NicoMirror.xcodeproj/project.pbxproj"
    if not project.is_file() or not (target / "KoveMirror/Connection/BleController.swift").is_file():
        raise ValueError("Choisis le dossier de ton projet existant, celui qui contient NicoMirror.xcodeproj.")
    project_text = project.read_text()
    if "PBXFileSystemSynchronizedRootGroup" not in project_text:
        raise ValueError("La structure de ce projet ne permet pas l’ajout automatique des nouveaux fichiers.")
    manifest = json.loads((source / "MISE_A_JOUR.json").read_text())
    if wifi_mode not in ("keep", "qr", "manual"):
        raise ValueError("Mode Wi-Fi inconnu.")
    # Read the installation's own entitlement. Never import its team or App Groups
    # from the template. Older manifests retain their original migration behavior.
    wifi_auto = None
    if any(e.get("mode") == "configure_hotspot" for e in manifest["files"]):
        rights = plistlib.loads(safe_path(target, "KoveMirror/KoveMirror.entitlements").read_bytes())
        wifi_auto = (rights.get(HOTSPOT) is True) if wifi_mode == "keep" else (wifi_mode == "qr")
    plans, seen, planned_modes = [], set(), {}
    for entry in manifest["files"]:
        relative = entry["path"]
        if relative in seen:
            raise ValueError("Fichier dupliqué dans la mise à jour.")
        seen.add(relative)
        mode = entry.get("mode", "copy")
        hotspot_merge = relative == "KoveMirror/KoveMirror.entitlements" and mode in ("disable_hotspot", "configure_hotspot")
        project_branding = relative == "NicoMirror.xcodeproj/project.pbxproj" and mode in (
            "merge_project_display_name", "merge_project_resources")
        if (".xcodeproj" in relative and not project_branding) or (relative.endswith(".entitlements") and not hotspot_merge):
            raise ValueError("La mise à jour ne doit pas modifier les identifiants de signature.")
        src, dst = safe_path(source, relative), safe_path(target, relative)
        executable = entry.get("executable", False)
        if not isinstance(executable, bool) or (executable and not relative.endswith((".command", ".sh"))):
            raise ValueError("Le droit d’exécution est réservé aux scripts de lancement.")
        permissions = (dst.stat().st_mode & 0o777) if dst.exists() else 0o644
        planned_modes[relative] = permissions | 0o111 if executable else permissions
        data = src.read_bytes()
        if hashlib.sha256(data).hexdigest() != entry["sha256"]:
            raise ValueError("Le fichier de mise à jour a changé : " + relative)
        if mode == "preserve_service_settings":
            services = {"KoveMirror/TomTomTraffic.plist": ("APIKey",),
                        "KoveMirror/WizeCommunity.plist": ("URL", "PublishableKey")}
            if relative not in services:
                raise ValueError("Fichier de configuration de service inconnu.")
            if dst.exists():
                existing = plistlib.loads(dst.read_bytes())
                incoming = plistlib.loads(data)
                fields = services[relative]
                # A project URL and its publishable key belong together.
                if all(not existing.get(k) or existing[k] == incoming.get(k) for k in fields):
                    for k in fields:
                        if not existing.get(k) and k in incoming:
                            existing[k] = incoming[k]
                data = plistlib.dumps(existing, sort_keys=False)
        elif mode in ("merge_queries", "merge_app_settings", "merge_app_branding"):
            existing = plistlib.loads(dst.read_bytes())
            incoming = plistlib.loads(data)
            existing["LSApplicationQueriesSchemes"] = sorted(set(existing.get("LSApplicationQueriesSchemes", []))
                | set(incoming.get("LSApplicationQueriesSchemes", [])))
            if mode in ("merge_app_settings", "merge_app_branding"):
                if "DoubleInterfaceAutomaticWiFiJoinEnabled" in incoming:
                    existing["DoubleInterfaceAutomaticWiFiJoinEnabled"] = (
                        incoming["DoubleInterfaceAutomaticWiFiJoinEnabled"] if wifi_auto is None else wifi_auto)
                existing["UIRequiresPersistentWiFi"] = True
                existing["UIBackgroundModes"] = sorted(set(existing.get("UIBackgroundModes", []))
                    | {"location", "bluetooth-central"})
                for key in ("NSLocationAlwaysAndWhenInUseUsageDescription", "NSLocationWhenInUseUsageDescription"):
                    if key in incoming:
                        existing[key] = incoming[key]
            if mode == "merge_app_branding":
                existing["CFBundleDisplayName"] = incoming["CFBundleDisplayName"]
                if "UILaunchStoryboardName" in incoming:
                    existing["UILaunchStoryboardName"] = incoming["UILaunchStoryboardName"]
                # Register GPX opening without replacing the signed app's other
                # document handlers, custom schemes, identifiers or permissions.
                for key, identity in (("CFBundleDocumentTypes", "CFBundleTypeName"),
                                      ("UTImportedTypeDeclarations", "UTTypeIdentifier")):
                    if key in incoming:
                        merged = list(existing.get(key, []))
                        for declaration in incoming[key]:
                            merged = [item for item in merged if item.get(identity) != declaration.get(identity)]
                            merged.append(declaration)
                        existing[key] = merged
                if "LSSupportsOpeningDocumentsInPlace" in incoming:
                    existing["LSSupportsOpeningDocumentsInPlace"] = incoming["LSSupportsOpeningDocumentsInPlace"]
                for key in ("NSBluetoothAlwaysUsageDescription", "NSBluetoothPeripheralUsageDescription",
                            "NSCameraUsageDescription", "NSLocalNetworkUsageDescription"):
                    if key in incoming:
                        existing[key] = incoming[key]
            data = plistlib.dumps(existing, sort_keys=False)
        elif project_branding:
            pattern = re.compile(r'(?m)^(\s*INFOPLIST_KEY_CFBundleDisplayName\s*=\s*)("(?:[^"\\]|\\.)*"|[^;\n]+)(;)')
            names = {match.group(2).strip() for match in pattern.finditer(data.decode("utf-8"))}
            if len(names) != 1:
                raise ValueError("Le nom de l’application doit être unique dans cette mise à jour.")
            name = json.loads(names.pop())
            if not isinstance(name, str) or not name.strip():
                raise ValueError("Le nom de l’application est invalide.")
            quoted_name = json.dumps(name, ensure_ascii=False)
            project_text = pattern.sub(lambda match: match.group(1) + quoted_name + match.group(3), project_text)
            if mode == "merge_project_resources":
                # Retire only the README build file from the original project.
                # The distinct file reference keeps the guide in the navigator.
                project_text = re.sub(
                    r'(?m)^[ \t]*302F1C6E300F506900E78C3F /\* README\.md in Resources \*/'
                    r'(?:,| = \{isa = PBXBuildFile; fileRef = 302F1C6C300F506900E78C3F /\* README\.md \*/; \};)[ \t]*\r?\n',
                    '', project_text)
                project_text = re.sub(r'(\bINFOPLIST_KEY_UILaunchStoryboardName\s*=\s*)"?LaunchScreen"?(\s*;)',
                                      r'\g<1>LaunchScreenDoubleInterface\2', project_text)
            data = project_text.encode("utf-8")
        elif mode in ("disable_hotspot", "configure_hotspot"):
            if not hotspot_merge:
                raise ValueError("La capacité Wi-Fi ne doit modifier que les droits de l’application principale.")
            existing = plistlib.loads(dst.read_bytes())
            if mode == "disable_hotspot" and HOTSPOT in plistlib.loads(data):
                raise ValueError("La mise à jour ne doit pas demander la capacité Hotspot.")
            if mode == "configure_hotspot" and wifi_auto:
                existing[HOTSPOT] = True
            else:
                existing.pop(HOTSPOT, None)
            data = plistlib.dumps(existing, sort_keys=False)
        elif mode in ("merge_extension_icons", "merge_extension_branding"):
            incoming = plistlib.loads(data)
            existing = plistlib.loads(dst.read_bytes()) if dst.exists() else incoming.copy()
            for key in ("CFBundleIcons", "CFBundleIcons~ipad"):
                existing[key] = incoming[key]
            if mode == "merge_extension_branding":
                existing["CFBundleDisplayName"] = incoming["CFBundleDisplayName"]
            data = plistlib.dumps(existing, sort_keys=False)
        elif mode == "merge_display_name":
            existing = plistlib.loads(dst.read_bytes())
            existing["CFBundleDisplayName"] = plistlib.loads(data)["CFBundleDisplayName"]
            data = plistlib.dumps(existing, sort_keys=False)
        elif mode == "merge_gitignore":
            if relative != ".gitignore":
                raise ValueError("La fusion des exclusions Git est réservée à .gitignore.")
            lines = dst.read_text().splitlines() if dst.exists() else []
            for line in data.decode("utf-8").splitlines():
                if line and line not in lines:
                    lines.append(line)
            data = ("\n".join(lines) + "\n").encode("utf-8")
        elif mode != "copy":
            raise ValueError("Type de mise à jour inconnu.")
        # The installed settings may differ from the distribution (signing,
        # configured services or permissions). Its manifest must describe
        # the bytes actually installed, including when this run changes nothing.
        entry["sha256"] = hashlib.sha256(data).hexdigest()
        if not dst.exists() or dst.read_bytes() != data or planned_modes[relative] != permissions:
            plans.append((relative, dst, data))

    if "version" in manifest:
        relative = "MISE_A_JOUR.json"
        if relative in seen:
            raise ValueError("Le manifeste ne peut pas se référencer lui-même.")
        seen.add(relative)
        dst = safe_path(target, relative)
        data = (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode()
        if not dst.exists() or dst.read_bytes() != data:
            plans.append((relative, dst, data))
            planned_modes[relative] = (dst.stat().st_mode & 0o777) if dst.exists() else 0o644

    for relative in manifest.get("removed_files", []):
        if relative in seen:
            raise ValueError("Suppression dupliquée ou en conflit avec un fichier à copier.")
        seen.add(relative)
        # Only obsolete source/test files may be removed. Signing, project
        # configuration, user documents and data are never deletion targets.
        if not isinstance(relative, str) or not relative.endswith(".swift") or not relative.startswith(
                ("KoveMirror/", "KoveMirrorTests/", "Tests/Connection/")) and relative not in {
                    "KoveMirrorUploadExtension/SampleHandler.swift",
                    "KoveMirrorUploadExtension/H264Encoder.swift",
                    "KoveMirrorUploadExtension/TcpServerManager.swift"}:
            raise ValueError("Suppression réservée aux anciens fichiers source.")
        dst = safe_path(target, relative)
        if dst.exists():
            if not dst.is_file():
                raise ValueError("Une suppression ne doit pas viser un dossier.")
            plans.append((relative, dst, None))

    for entry in manifest.get("removed_support_files", []):
        relative, digest = entry["path"], entry["sha256"]
        if relative in seen:
            raise ValueError("Suppression de support dupliquée ou en conflit avec une copie.")
        seen.add(relative)
        name = Path(relative)
        legacy_document = (len(name.parts) == 1 and name.suffix in (".md", ".txt")
                           and relative not in {"README.md", "PRIVACY_POLICY.md", "UPSTREAM_README.md"})
        legacy_preview = name.parts[0] in {"Apercus", "References_Design", "PromotionIcons"}
        legacy_icon = (
            name.parent.as_posix() in {"Kove broadcast extension", "Kove broadcast extensionSetupUI"}
            and name.name in {"RivetIcon60x60@2x.png", "RivetIcon60x60@3x.png",
                              "RivetIcon76x76.png", "RivetIcon76x76@2x.png", "RivetIcon83.5x83.5@2x.png"}
        )
        legacy_tool = relative in {"scripts/create-mockups.py", "Recuperer_code_source_OsmAnd.command",
                                  "Double_Interface_OsmAnd.xcworkspace/contents.xcworkspacedata",
                                  "KoveMirrorUploadExtension/Info.plist", "VERIFICATION_WIZE_22NOV.json",
                                  "UPSTREAM_README.md", "VERIFICATION.json", "VERIFICATION_OFFLINE_21NOV.json",
                                  "KoveMirror/LaunchScreen.storyboard"}
        if not (legacy_document or legacy_preview or legacy_tool or legacy_icon) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ValueError("Suppression de support non autorisée.")
        dst = safe_path(target, relative)
        if dst.exists():
            if relative == "KoveMirror/LaunchScreen.storyboard" and re.search(r"\bLaunchScreen\b", project_text):
                continue
            if not dst.is_file():
                raise ValueError("Une suppression de support ne doit pas viser un dossier.")
            # Remove only an unchanged copy of a known old deliverable. A user's
            # edited document is retained, and every removal is backed up below.
            if hashlib.sha256(dst.read_bytes()).hexdigest() == digest:
                plans.append((relative, dst, None))

    if not plans:
        return {"updated_files": 0, "removed_files": 0, "backup": None, "project": str(project.parent)}
    backup = Path(tempfile.mkdtemp(prefix="Sauvegarde_Double_Interface_" + datetime.now().strftime("%Y%m%d_%H%M%S_"),
                                  dir=target.parent))
    prior = {}
    for relative, dst, _ in plans:
        if dst.exists():
            saved = safe_path(backup, relative)
            saved.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(dst, saved)
            prior[relative] = saved
        else:
            prior[relative] = None
    written = []
    try:
        for relative, dst, data in plans:
            if data is None:
                dst.unlink()
                written.append((relative, dst))
                continue
            dst.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(dir=dst.parent, delete=False) as stream:
                stage = Path(stream.name)
                stream.write(data)
            try:
                os.chmod(stage, planned_modes[relative])
                os.replace(stage, dst)
                written.append((relative, dst))
            finally:
                stage.unlink(missing_ok=True)
    except Exception:
        for relative, dst in reversed(written):
            saved = prior[relative]
            if saved is None:
                dst.unlink(missing_ok=True)
            else:
                shutil.copy2(saved, dst)
        raise
    return {"updated_files": sum(data is not None for _, _, data in plans),
            "removed_files": sum(data is None for _, _, data in plans),
            "backup": str(backup), "project": str(project.parent)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("target", type=Path)
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--wifi-mode", choices=("keep", "qr", "manual"), default="keep")
    args = parser.parse_args()
    try:
        result = update_project(args.source, args.target, wifi_mode=args.wifi_mode)
    except Exception as error:
        parser.exit(1, "Mise à jour arrêtée : " + str(error) + "\n")
    print("Mise à jour appliquée : " + str(result["updated_files"]) + " fichiers.")
    print("Anciens fichiers retirés : " + str(result["removed_files"]) + ".")
    if result["backup"]:
        print("Sauvegarde des fichiers modifiés : " + result["backup"])
    else:
        print("Ce projet est déjà à jour.")
    print("Les identifiants, l’équipe Apple et les groupes partagés ont été conservés.")
    wifi_rights = plistlib.loads((args.target / "KoveMirror/KoveMirror.entitlements").read_bytes())
    print("Wi-Fi par QR activé." if wifi_rights.get(HOTSPOT) else "Installation pour connexion Wi-Fi manuelle.")
    print("Dans Xcode, garde ton iPhone comme destination puis fais Commande + R.")


if __name__ == "__main__":
    main()
