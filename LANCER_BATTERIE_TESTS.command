#!/bin/bash
cd "$(dirname "$0")" || exit 1
printf '\nDOUBLE INTERFACE — VERIFICATION AUTOMATIQUE\n\n'
bash scripts/lancer-batterie-tests.sh --xcode
status=$?
printf '\nLes rapports sont dans le dossier Resultats_tests.\n'
printf 'Appuie sur Entrée pour fermer cette fenêtre.\n'
read -r _
exit "$status"
