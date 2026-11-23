#!/bin/bash
# Batterie de vérifications non destructives de Double Interface.
# Usage : bash scripts/lancer-batterie-tests.sh [--xcode]
set -u
cd "$(dirname "$0")/.." || exit 1
full_build=0
if [ "${1:-}" = '--xcode' ]; then full_build=1; fi
mkdir -p Resultats_tests || exit 1
report_dir="$(mktemp -d "Resultats_tests/$(date '+%Y%m%d_%H%M%S')-XXXXXXXX")" || exit 1
summary="$report_dir/resume.txt"
: > "$summary"
passed=0
failed=0
skipped=0
printf '%s\n' 'DOUBLE INTERFACE — BATTERIE DE TESTS' "Dossier de résultats : $report_dir" | tee -a "$summary"
run() {
  label="$1";shift
  logfile="$report_dir/$label.log"
  printf '\n[%s] ...\n' "$label" | tee -a "$summary"
  if "$@" > "$logfile" 2>&1; then
    printf '[OK] %s\n' "$label" | tee -a "$summary"
    passed=$((passed+1))
  else
    printf '[ECHEC] %s (voir %s)\n' "$label" "$logfile" | tee -a "$summary"
    failed=$((failed+1))
  fi
}
skip() { printf '[NON EXECUTE] %s\n' "$1" | tee -a "$summary";skipped=$((skipped+1)); }

if command -v swift >/dev/null 2>&1; then
  run 'swift_unitaires' swift test --parallel
  # Parse syntax only. This is NOT an Xcode/iOS compilation.
  swift_files=()
  while IFS= read -r -d '' file; do swift_files+=("$file"); done < <(find KoveMirror KoveMirrorTests KoveMirrorUITests 'Kove broadcast extension' 'Kove broadcast extensionSetupUI' Tests -name '*.swift' -print0)
  run 'swift_syntaxe' swiftc -frontend -parse "${swift_files[@]}"
else
  skip 'Swift non disponible'
  skip 'Syntaxe Swift non vérifiée'
fi
if command -v python3 >/dev/null 2>&1; then
  run 'python_projet' python3 -B -m unittest discover -s scripts/tests -v
  run 'manifeste_et_plist' python3 -c '
import json, hashlib, pathlib, plistlib
root=pathlib.Path(".")
data=json.loads((root/"MISE_A_JOUR.json").read_text())
for item in data["files"]:
 p=root/item["path"]
 assert p.is_file(), "Fichier absent : "+str(p)
 assert hashlib.sha256(p.read_bytes()).hexdigest()==item["sha256"], "Empreinte incorrecte : "+str(p)
for folder in ("KoveMirror", "Kove broadcast extension", "Kove broadcast extensionSetupUI"):
 for p in (root/folder).rglob("*"):
  if p.suffix in {".plist", ".entitlements", ".xcprivacy"}: plistlib.loads(p.read_bytes())
  if p.suffix in {".json", ".xcstrings"}: json.loads(p.read_text())
print("Manifeste, plists et JSON valides.")'
else
  skip 'Python 3 non disponible'
  skip 'Manifeste non contrôlé'
fi
if [ "$full_build" -eq 1 ]; then
  if [ "$(uname -s)" = 'Darwin' ] && command -v xcodebuild >/dev/null 2>&1; then
    run 'xcode_compile_simulateur' xcodebuild -project NicoMirror.xcodeproj -scheme NicoMirror -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
  else
    skip 'Compilation Xcode : nécessite macOS + Xcode'
  fi
else
  skip 'Compilation Xcode facultative (relancer avec --xcode)'
fi
printf '\nBILAN : %s OK, %s ECHEC(S), %s NON EXECUTE(S).\n' "$passed" "$failed" "$skipped" | tee -a "$summary"
printf 'Cela ne remplace pas la validation sur iPhone et TFT Kove.\n' | tee -a "$summary"
if [ "$failed" -gt 0 ]; then exit 1; fi
exit 0
