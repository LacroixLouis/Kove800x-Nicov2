#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "La compilation iPhone demande Xcode sur macOS." >&2
    exit 1
fi
python3 -m unittest discover -s scripts/tests -p 'test_*.py'
mkdir -p build
# Un espace de construction distinct permet le nettoyage, y compris en cas d'echec.
derived_data_dir="$PWD/build/DerivedData"
swiftpm_dir="$PWD/build/SwiftPM"
package_dir=""
cleanup_build_artifacts() {
    status=$?
    trap - EXIT
    set +e
    if [ -n "$package_dir" ]; then rm -rf -- "$package_dir"; fi
    rm -rf -- "$derived_data_dir" "$swiftpm_dir"
    echo "Caches temporaires de compilation supprimes."
    exit "$status"
}
trap cleanup_build_artifacts EXIT
swift test --scratch-path "$swiftpm_dir"
xcodebuild -project NicoMirror.xcodeproj -scheme NicoMirror -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
package_dir="$(mktemp -d "$PWD/build/package-XXXXXXXX")"
mkdir "$package_dir/Payload"
cp -R build/DerivedData/Build/Products/Release-iphoneos/KoveMirror.app "$package_dir/Payload/"
(cd "$package_dir" && zip -qry Double_Interface-non-signee.ipa Payload)
mv -f "$package_dir/Double_Interface-non-signee.ipa" build/Double_Interface-non-signee.ipa
echo "Produit : build/Double_Interface-non-signee.ipa — signature nécessaire pour installation."
