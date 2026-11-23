# Correction de latence TFT — 23 novembre 2026

Projet conservé depuis **Double_Interface_CORRIGE_23NOV.zip**.

## Changements

- Le rendu de la carte TFT écran verrouillé ne déplace plus la caméra `MKMapView` à chaque nouvelle position GPS ; la capture reste recentrée sur les coordonnées du GPS.
- Le calcul MapKit `map.convert` servant à mesurer l’échelle n’est plus refait en arrière-plan pour chaque image ; l’échelle de la carte existante est réutilisée.
- Si un rendu prend trop longtemps et qu’une position nettement plus récente est disponible, une seule image obsolète peut être abandonnée **avant** son entrée dans l’encodeur H.264. La prochaine image prend la position la plus récente. Limitation à un abandon consécutif pour ne pas bloquer une carte hors ligne lente.
- Le transport TCP, les noms RIVADVENTURE/RIVROUTE/RIVMONDE, les cartes, le logo et les réglages restent inchangés.

## Tests effectués ici

- Vérifications de régression de code source (voir `scripts/tests/test_locked_gps_latency.py`).
- Analyse syntaxique Swift disponible sans les SDK Apple ; test de compilation et validation de latence sur TFT réel **à effectuer sur Mac/iPhone/moto**.

## Test pratique

1. Ouvrir `NicoMirror.xcodeproj`, sélectionner le schéma `NicoMirror` puis compiler sur l’iPhone.
2. Brancher TFT et lancer la carte TFT en trajet réel.
3. Comparer le délai en laissant l’écran allumé, puis en verrouillant l’iPhone au moins 2 minutes.
4. Dans les paramètres iOS, autoriser la localisation permanente et précise pour Double Interface.
5. Exporter les diagnostics de Double Interface après le trajet pour comparer `mean_gps_to_send_seconds` et `longest_gap_seconds`.

**Attention :** iOS peut toujours suspendre le rendu vidéo ou les connexions pendant un verrouillage prolongé. Aucun seuil « sous une seconde » n’est garanti par cette correction ; le résultat doit être mesuré sur l’appareil réel.
