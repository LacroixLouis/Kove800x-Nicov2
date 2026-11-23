#!/bin/bash
# Nettoyage Xcode pour Double Interface - macOS. Aucune suppression sans confirmation.
set -u

printf '\n=======================================================\n'
printf '  NETTOYAGE DU MAC - XCODE / DOUBLE INTERFACE\n'
printf '=======================================================\n\n'
if [ "$(uname -s)" != 'Darwin' ]; then
    printf 'Ce fichier doit etre execute sur un Mac.\n'
    exit 1
fi

if pgrep -x Xcode >/dev/null 2>&1 || pgrep -x xcodebuild >/dev/null 2>&1; then
    printf 'Ferme Xcode et attends la fin de toute compilation avant le nettoyage.\n'
    printf 'Rien n\047a ete efface.\n'
    read -r -p 'Appuie sur Entree pour quitter... ' answer
    exit 1
fi

show_usage() {
    target="$1"
    if [ -e "$target" ] && [ ! -L "$target" ]; then
        du -sh "$target" 2>/dev/null || true
    fi
}

# Ne supprime que des repertoires caches/recreables connus et valides.
empty_cache() {
    target="$1"
    case "$target" in
        "$HOME/Library/Developer/Xcode/DerivedData"|\
        "$HOME/Library/Caches/com.apple.dt.Xcode"|\
        "$HOME/Library/Developer/Xcode/ModuleCache.noindex"|\
        "$HOME/Library/Developer/Xcode/SDKStatCaches.noindex") ;;
        *) printf 'Dossier non autorise : %s\n' "$target"; return 1 ;;
    esac
    if [ -d "$target" ] && [ ! -L "$target" ]; then
        find "$target" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    fi
}

printf 'Espace libre AVANT :\n'
df -h "$HOME" | tail -n 1
printf '\nDossiers systeme Xcode a nettoyer (uniquement caches) :\n'
show_usage "$HOME/Library/Developer/Xcode/DerivedData"
show_usage "$HOME/Library/Caches/com.apple.dt.Xcode"
show_usage "$HOME/Library/Developer/Xcode/ModuleCache.noindex"
show_usage "$HOME/Library/Developer/Xcode/SDKStatCaches.noindex"

# Cherche les copies de projets Double Interface uniquement dans les emplacements courants.
projects_file="$(mktemp "${TMPDIR:-/tmp}/double-interface-projects.XXXXXX")" || exit 1
trap 'rm -f "$projects_file"' EXIT
for root in "$HOME/Desktop" "$HOME/Documents" "$HOME/Downloads" "$HOME/Developer" "$HOME/Projects"; do
    if [ -d "$root" ]; then
        find "$root" -maxdepth 6 -type d -name 'NicoMirror.xcodeproj' -print -prune 2>/dev/null | while IFS= read -r proj; do
            dirname "$proj"
        done >> "$projects_file"
    fi
done
sort -u "$projects_file" -o "$projects_file"

printf '\nFichiers temporaires dans les projets Double Interface trouves :\n'
if [ ! -s "$projects_file" ]; then
    printf 'Aucun projet detecte dans Bureau/Documents/Telechargements/Developer/Projects.\n'
else
    while IFS= read -r project; do
        [ -d "$project/NicoMirror.xcodeproj" ] || continue
        printf '\nProjet : %s\n' "$project"
        show_usage "$project/.build"
        show_usage "$project/build/DerivedData"
        show_usage "$project/build/SwiftPM"
        find "$project" -mindepth 1 -maxdepth 1 -type d \( -name 'build-signed-*' -o -name '.tmp-build-signed-*' \) -print 2>/dev/null | while IFS= read -r folder; do
            show_usage "$folder"
        done
    done < "$projects_file"
fi

printf '\nNE SONT PAS SUPPRIMES : projets, code, photos, ZIP, cartes, IPA,\n'
printf 'archives Xcode, simulateurs, sauvegardes et corbeille.\n'
printf 'Les caches se recreent au prochain Build (c\047est normal).\n\n'
printf 'Pour confirmer, ecris exactement NETTOYER puis Entree : '
IFS= read -r confirmation
if [ "$confirmation" != 'NETTOYER' ]; then
    printf 'Annule : aucun fichier supprime.\n'
    read -r -p 'Appuie sur Entree pour fermer... ' answer
    exit 0
fi

printf '\nNettoyage des caches Xcode...\n'
empty_cache "$HOME/Library/Developer/Xcode/DerivedData"
empty_cache "$HOME/Library/Caches/com.apple.dt.Xcode"
empty_cache "$HOME/Library/Developer/Xcode/ModuleCache.noindex"
empty_cache "$HOME/Library/Developer/Xcode/SDKStatCaches.noindex"

if [ -s "$projects_file" ]; then
    printf 'Nettoyage des builds temporaires Double Interface...\n'
    while IFS= read -r project; do
        [ -d "$project/NicoMirror.xcodeproj" ] || continue
        # Suppression limitee a des dossiers reconstruisibles du projet verifie.
        for folder in "$project/.build" "$project/build/DerivedData" "$project/build/SwiftPM"; do
            if [ -d "$folder" ] && [ ! -L "$folder" ]; then
                rm -rf -- "$folder"
            fi
        done
        find "$project" -mindepth 1 -maxdepth 1 -type d \( -name 'build-signed-*' -o -name '.tmp-build-signed-*' \) -print 2>/dev/null | while IFS= read -r folder; do
            # Les dossiers sont des resultats de l'ancien script, pas du code source.
            if [ -d "$folder" ] && [ ! -L "$folder" ]; then
                rm -rf -- "$folder"
            fi
        done
    done < "$projects_file"
fi

printf '\nEspace libre APRES :\n'
df -h "$HOME" | tail -n 1
printf '\nNettoyage termine. Ne vide pas la corbeille sans controler son contenu.\n'
printf 'Si le disque se remplit encore, il faudra mesurer les dossiers apres Build.\n'
read -r -p 'Appuie sur Entree pour fermer la fenetre... ' answer
