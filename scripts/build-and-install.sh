#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 2 ]]; then
    echo "Usage : bash scripts/build-and-install.sh TEAM_ID UDID_IPHONE" >&2
    echo "L'équipe doit être configurée dans Xcode → Settings → Accounts." >&2
    exit 2
fi
signing_team="$1"
target_device="$2"
if [[ ! "$signing_team" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "TEAM_ID invalide : attendu 10 lettres majuscules ou chiffres." >&2
    exit 2
fi
if [[ ! "$target_device" =~ ^[A-Fa-f0-9-]{16,50}$ ]]; then
    echo "Identifiant iPhone invalide. Le copier depuis Xcode → Devices and Simulators." >&2
    exit 2
fi
if [[ "$(uname -s)" != Darwin ]] || ! command -v xcodebuild >/dev/null 2>&1; then
    echo "Ce script nécessite macOS avec Xcode complet." >&2
    exit 1
fi
run_dir="$(mktemp -d "$PWD/build-signed-XXXXXXXX")"
cleanup_build_artifacts() {
    status=$?
    trap - EXIT
    set +e
    logs_dir="$PWD/build/last-install-logs"
    mkdir -p "$logs_dir"
    for log in "$run_dir"/*.log; do
        [ -f "$log" ] && cp -f "$log" "$logs_dir/"
    done
    # Les journaux restent consultables, les artefacts volumineux sont recreables.
    rm -rf -- "$run_dir"
    echo "Fichiers temporaires supprimes. Journaux : $logs_dir"
    exit "$status"
}
trap cleanup_build_artifacts EXIT
echo "Le script utilisera la signature automatique de l'équipe indiquée."
echo "Xcode pourra créer ou mettre à jour ses profils de développement."
echo "Les mots de passe et codes Apple se saisissent uniquement dans Xcode."
echo "Dossier de résultats : $run_dir"
swift test --scratch-path "$run_dir/SwiftPM" 2>&1 | tee "$run_dir/tests.log"
xcodebuild \
    -project NicoMirror.xcodeproj \
    -scheme NicoMirror \
    -configuration Debug \
    -destination "id=$target_device" \
    -derivedDataPath "$run_dir/DerivedData" \
    -resultBundlePath "$run_dir/Compilation.xcresult" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    "DEVELOPMENT_TEAM=$signing_team" \
    CODE_SIGN_STYLE=Automatic \
    build 2>&1 | tee "$run_dir/build.log"
signed_app="$run_dir/DerivedData/Build/Products/Debug-iphoneos/KoveMirror.app"
if [[ ! -d "$signed_app" ]]; then
    echo "Le fichier .app attendu n'a pas été produit. Consulter build.log." >&2
    exit 1
fi
codesign --verify --deep --strict "$signed_app"
xcrun devicectl device install app --device "$target_device" "$signed_app" \
    2>&1 | tee "$run_dir/install.log"
echo "Installation terminée si devicectl a confirmé le succès. Ouvrir Double Interface sur l'iPhone."
echo "La compilation et l'installation ne valident pas le fonctionnement sur la Kove."
