# Correction ciblée — carte TFT lorsque l’iPhone est verrouillé

Problème signalé : affichage de la position sur le TFT avec environ 2–3 secondes de retard lorsque l’iPhone est verrouillé.

## Changement de cette version

Dans `KoveMirror/Connection/WebPanelStream.swift`, la logique de rejet d’une image déjà rendue dès qu’un GPS plus récent (>= 0,75 s) existe a été supprimée. Dans le mode verrouillé, si le rendu est lent, ce rejet pouvait provoquer **deux rendus successifs**, et réduire la fréquence des mises à jour. Une image terminée entre dans désormais l’encodeur ; la prochaine capture prend la dernière position GPS après la fin de l’envoi TCP. Cette modification privilégie la continuité de l’affichage plutôt qu’une tentative systématique de rattrapage qui pouvait aggraver les interruptions.

**Ce changement ne garantit pas une position instantanée.** La fréquence GPS d’iOS, le temps de rendu de la carte, le codage H.264, le Wi-Fi, et le délai du décodeur TFT restent des facteurs externes. Si les 2–3 secondes persistent, exporter un rapport après deux minutes de trajet verrouillé depuis l’application : `last_background_ride.mean_gps_to_send_seconds` compare GPS et fin d’envoi TCP. Le rapport ne mesure pas le délai interne du décodeur TFT.

## Vérifications hors Mac
- 73 tests Python statiques de régression : réussis.
- Analyse syntaxique de tous les fichiers Swift : à refaire sur Mac avec Xcode pour compiler et signer le projet iOS.
- ZIP : intégrité vérifiée.

## Pour tester
1. Remplacer le projet de test par ce ZIP et ouvrir `Double_Interface/NicoMirror.xcodeproj` dans Xcode.
2. Sur l’iPhone : `Réglages > Confidentialité et sécurité > Service de localisation > Double Interface` : autoriser `Toujours` si proposé et `Position exacte`.
3. Désactiver le mode économie d’énergie pendant le test. Lancer la connexion TFT avant de verrouiller le téléphone.
4. Tester au même endroit en roulant en sécurité, en comparant écran allumé et verrouillé pendant au moins deux minutes. Ne pas effectuer les manipulations en roulant.
