# Double Interface — corrections du 23 novembre 2026

## Changements dans cette version

- Rivmonde hors ligne : un triangle GPS indépendant de l'annotation utilisateur MapKit est affiché à partir de la position CoreLocation récente de l'application. Cela évite de dépendre d'un marqueur MapKit potentiellement absent quand la couche MBTiles est active.
- Recentrage : la sélection d'une carte hors ligne demande un recentrage sur une position GPS récente ; si le GPS n'est pas encore disponible, la demande est conservée en attente.
- Zoom : l'affichage ne devient plus vide au-delà du zoom maximal fourni par la carte. Les tuiles sont agrandies visuellement. **Cet agrandissement ne crée aucune route ni aucun détail géographique supplémentaire.**
- Outils > Fermeture du menu : trois modes sont proposés, enregistrés d'un lancement à l'autre : **4 sec**, **Permanent** (avec bouton masquer et bouton réafficher), et **En roulant** (masquage à partir de 5 km/h, réaffichage automatique à l'arrêt).
- Carte et affichage TFT : la carte conserve son propre profil ; le menu est une surcouche iPhone et n'est pas incrusté dans le flux vidéo TFT.

## Limites importantes

- La carte intégrée « Rivmonde · Relief mondial (aperçu) » contient **seulement les niveaux 0 à 5** du relief NOAA. Elle n'a pas de routes, de pistes ni de courbes de niveau. Elle **n'est pas une carte de navigation moto**.
- Pour rouler en hors ligne avec de vrais détails, importer dans Rivmonde une **carte raster MBTiles** couvrant le pays ou la région souhaitée, avec des niveaux de zoom adaptés. Les cartes .obf ou .map ne sont pas lisibles directement par ce projet.
- La compilation Xcode sur macOS et le comportement avec un iPhone verrouillé, le TFT et la position GPS réelle **restent à tester**.

## Vérifications disponibles

- Tests Swift du paquet : 147 scénarios lancés, aucune erreur de commande.
- Tests Python du projet : 79 tests réussis.
- Syntaxe Swift, manifestes et plists : validés.
- Compilation iOS/Xcode : non exécutée car Xcode n'est pas disponible dans cet environnement.

## Test sur iPhone

1. Ouvrir la carte Rivmonde > carte hors ligne. Vérifier le triangle de position et la mise à jour quand on se déplace.
2. Tester le zoom +/− puis pincer pour agrandir ; vérifier que le relief reste visible, même s'il devient flou au zoom élevé.
3. Dans Outils, choisir successivement 4 sec, Permanent (bouton œil pour masquer/réafficher), puis En roulant. Tester le dernier mode **à l'arrêt / en sécurité**, sans manipuler l'écran en roulant.
4. Vérifier l'affichage TFT et la position écran iPhone verrouillé.
