#!/bin/bash
set -euo pipefail
task_source_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$task_source_dir"
if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "Ce script demande Xcode sur ton Mac."
    exit 1
fi
mkdir -p Captures_iOS
task_capture_dir="$(mktemp -d "$task_source_dir/Captures_iOS/serie-XXXXXXXX")"
python3 scripts/prepare-screenshot-scheme.py
task_simulator_id="$(xcrun simctl list devices available -j | python3 -c '
import json, re, sys
candidates = []
for runtime, devices in json.load(sys.stdin)["devices"].items():
    match = re.search(r"\.iOS-(\d+(?:-\d+)*)$", runtime)
    if not match:
        continue
    version = tuple(int(part) for part in match[1].split("-"))
    if version < (26,):
        continue
    for device in devices:
        if device.get("isAvailable") and device["name"].startswith("iPhone"):
            candidates.append((device["state"] == "Booted", version, device["udid"]))
print(max(candidates)[2] if candidates else "")')"
if [[ -z "$task_simulator_id" ]]; then
    echo "Installe un simulateur iPhone iOS 26 ou ultérieur dans Xcode, puis relance ce script."
    exit 1
fi
xcodebuild -project NicoMirror.xcodeproj -scheme DoubleInterfaceCaptures \
    -configuration Debug -destination "platform=iOS Simulator,id=$task_simulator_id" \
    -derivedDataPath "$task_capture_dir/DerivedData" \
    -resultBundlePath "$task_capture_dir/Ecrans.xcresult" \
    -only-testing:KoveMirrorUITests/KoveMirrorUITests/testCaptureMapSettingsInPortraitAndLandscape \
    CODE_SIGNING_ALLOWED=NO test
mkdir -p "$task_capture_dir/Images"
xcrun xcresulttool export attachments --path "$task_capture_dir/Ecrans.xcresult" --output-path "$task_capture_dir/Images"
open "$task_capture_dir/Images"
echo "Captures natives : $task_capture_dir/Images"
