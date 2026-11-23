# Nettoyage macOS et Xcode — Double Interface, 23 novembre 2026

Pour liberer de la place : fermer Xcode puis ouvrir `NETTOYER_MAC_XCODE.command` (clic droit > Ouvrir). Lire les tailles affichees puis confirmer en saisissant `NETTOYER`. Les projets, donnees utilisateur, archives, cartes, ZIP et applications ne sont pas effaces.

Le nettoyeur cible les caches Xcode et les sous-dossiers de compilation connus des projets `NicoMirror.xcodeproj` identifies sur les emplacements usuels. Le nettoyage des caches Xcode est global et aura pour consequence de les regenerer lors du prochain build.

Deux scripts du projet ont egalement ete ajustes : `scripts/build-and-install.sh` conserve les journaux et efface les dossiers de compilation temporaires meme en cas d'echec ; `scripts/build-ios.sh` efface ses propres DerivedData et les fichiers temporaires SwiftPM apres execution. Le build lance manuellement dans l'interface Xcode peut toujours creer des caches dans la bibliotheque de l'utilisateur.

Ces scripts n'ont pas ete executes sur macOS et le nettoyage n'a pas ete execute sur le Mac de l'utilisateur.
