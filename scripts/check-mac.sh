#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
    echo "Ce diagnostic demande macOS. Aucun réglage n'a été modifié." >&2
    exit 1
fi
sw_vers
if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "Installer Xcode complet, puis le lancer une première fois." >&2
    exit 1
fi
xcodebuild -version
if ! xcrun --find swift >/dev/null 2>&1; then
    echo "Le compilateur Swift de Xcode n'est pas disponible." >&2
    exit 1
fi
xcodebuild -checkFirstLaunchStatus
xcodebuild -showsdks
xcodebuild -project NicoMirror.xcodeproj -scheme NicoMirror -showdestinations
echo "Vérifier que l'iPhone apparaît et que sa version iOS est prise en charge."
echo "Ce diagnostic ne compile pas et ne signe pas l'application."
