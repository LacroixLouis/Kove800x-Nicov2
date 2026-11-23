# Double Interface

Trois cartes : **Rivadventure** pour les parcours et les traces GPX, **Rivroute** pour la route, **Rivmonde** pour la topographie et les cartes raster MBTiles hors ligne.

## Couleurs des commandes — 23 novembre 2026

Le fond et le contour des bandeaux sont du même bleu foncé pour les trois cartes. Les boutons principaux et sélectionnés restent verts pour Rivadventure, bleus pour Rivroute et orange pour Rivmonde. Les boutons secondaires reprennent cette couleur en transparence. Les boutons du haut, les commandes de zoom et le panneau Outils utilisent le fond bleu foncé commun.

L’encadrement de la petite carte prend la couleur de la carte affichée à l’intérieur. Il se met à jour après un échange avec la grande carte ou un changement de carte TFT dans le menu.

Cette mise à jour porte sur l’apparence des commandes. Les vérifications réalisées ici portent sur les fichiers et les contrôles automatisés disponibles ; la compilation iOS et le rendu sur iPhone/TFT restent à vérifier dans Xcode et sur les appareils.

## Installer sur ton Mac

1. Fermer le projet dans Xcode.
2. Ouvrir **Mettre_a_jour_sur_Mac.command** dans ce dossier.
3. Sélectionner l’ancien dossier contenant **NicoMirror.xcodeproj**, puis **Compte gratuit** (Personal Team) ou **Compte payant** selon l’équipe choisie dans Xcode.
4. Dans Xcode, sélectionner l’iPhone et faire **Commande + R**. Si nécessaire : **Product → Clean Build Folder** (Maj + Commande + K).

Pour une installation directe avec une équipe Apple Developer inscrite, ouvrir **NicoMirror.xcodeproj**, schéma **NicoMirror**, puis choisir l’équipe Apple. Les nouvelles sources demandent la capacité **Hotspot Configuration** sur la cible principale. Avec une Personal Team, utiliser la mise à jour ci-dessus pour appliquer les réglages de la version gratuite.

## Connecter la moto

Allumer le compteur en mode navigation. Sur l’iPhone, ouvrir **… → Connexion Wi-Fi et Bluetooth → Scanner le QR du compteur**. Avec la signature Hotspot, le scan du QR Wi-Fi ou du lien d’association ThinkerRide lance la demande iOS. Toucher **Rejoindre** si l’iPhone le propose. L’app attend ensuite l’ouverture de la liaison vidéo.

Avec un compte gratuit, scanner le QR dans l’app pour récupérer les identifiants. Toucher **Copier le mot de passe**, sélectionner le réseau du compteur dans **Réglages → Wi-Fi**, coller le mot de passe et revenir dans l’app. Les mots de passe mémorisés restent dans le trousseau de cet iPhone.

Autoriser Bluetooth, Réseau local et la localisation lorsque l’iPhone le demande. L’écran Connexion distingue Bluetooth, commandes et vidéo TFT. L’état d’une connexion ne prouve pas que l’image est affichée : vérifier le compteur.

## Essayer le GPS écran verrouillé

1. À l’arrêt, ouvrir **Connexion**, activer **Mode trajet écran verrouillé** et attendre une première position ainsi que la carte sur le compteur.
2. Verrouiller l’iPhone avant de partir et parcourir une courte distance pendant deux minutes, avec un changement de direction. À l’arrivée, s’arrêter et vérifier que la position sur le TFT a avancé.
3. Déverrouiller l’iPhone et ouvrir **… → Connexion Wi-Fi et Bluetooth → Diagnostic pour le prochain essai**. **Dernier passage en arrière-plan** indique le nombre de positions GPS reçues, d’images envoyées et la plus longue pause entre les envois.

Pendant le trajet, l’app demande la précision de navigation maximale et chaque mouvement disponible. Dès qu’une position arrive, elle prépare son envoi au TFT. Si le Wi-Fi est occupé, la prochaine image utilise le point le plus récent. Après le trajet, **Délai GPS → envoi Wi-Fi** indique le temps moyen entre la mesure GPS et la fin de l’envoi par l’iPhone. Le décodage et l’affichage sur le compteur viennent ensuite.

Écran verrouillé, le TFT se met à jour sur les positions fournies par iOS. Rivmonde peut dessiner les tuiles locales disponibles autour de la position. Pour un fond Plans, l’app utilise la dernière image de la zone chargée. Hors de cette zone, le compteur affiche la position GPS et le tracé disponible avec la mention **Fond de carte indisponible**. La cadence mesurée correspond aux envois de l’iPhone. Vérifier l’affichage sur le compteur.

## Cartes et parcours

Toucher la petite carte pour l’échanger avec la grande, et la faire glisser pour la déplacer. Les réglages ouverts depuis le bandeau du bas suivent la carte affichée et restent ouverts jusqu’à fermeture avec la croix.

En portrait comme en paysage, faire défiler le panneau pour accéder à tous les réglages. La croix et le bandeau du bas restent accessibles.

Après avoir déplacé la carte, touche le triangle pour revenir à ta position. Si **GPS…** s’affiche, l’app garde ta demande et recentre la carte dès qu’elle reçoit une position récente. Les appuis suivants passent en **NORD** puis en **CAP**.

En **CAP**, la carte tourne pour placer le sens de déplacement en haut. En roulant, la direction vient du GPS. À l’arrêt, la boussole prend le relais si elle fournit un cap valide. La miniature et le TFT utilisent le mode choisi sur leur carte, y compris avec une carte Rivmonde hors ligne.

Dans les parcours, **Retirer de la carte** masque la trace sans supprimer son GPX ni ses favoris. **Rejoindre la trace** et **Aller au départ** permettent de préparer l’accès au parcours.

Rivmonde utilise le rendu de cartes et les fichiers raster MBTiles prévus dans ce projet. Le moteur natif OsmAnd et les fichiers vectoriels OBF ne sont pas intégrés. Les services en ligne demandent un accès Internet et ne constituent pas des cartes hors ligne.

### Relief mondial hors ligne intégré (aperçu)

Un fichier `Rivmonde_Monde_Relief_Apercu_v1.mbtiles` (19 Mo) est maintenant inclus dans l’app. À la première ouverture, il est copié dans la bibliothèque Rivmonde. Pour le voir : **Rivmonde → Réglages → Cartes hors ligne → Relief mondial (aperçu) → Utiliser**. Il apparaît sur l’iPhone et le TFT même sans réseau.

**Important :** cette carte issue du relief NOAA/NCEI ETOPO1 couvre le monde aux zooms 0–5, sans chemins, routes, altitude exploitable pour une navigation ni véritables courbes de niveau. **Elle ne doit pas être utilisée comme fond de carte pour conduire ou suivre une piste.** Pour naviguer hors réseau, importer en plus une carte topographique régionale **raster `.mbtiles`** dont la licence autorise l’utilisation hors ligne. Les fichiers `.obf`, MBTiles vectoriels PBF et PMTiles ne sont pas pris en charge. Une carte topo régionale détaillée n'est pas incluse dans cette version.

Source du relief : NOAA/NCEI, ETOPO1 Global Relief Model (2009), https://doi.org/10.7289/V5C8276M. Les données NOAA ne doivent pas être utilisées pour la navigation.

## Partage et services

Les migrations et tests SQL utiles au partage sont dans **Backend**. Les identifiants internes existants sont conservés pour retrouver les réglages, favoris, comptes communautaires et liens de partage. Les noms affichés changent uniquement.

## Vérifier le projet

**LANCER_BATTERIE_TESTS.command** exécute les contrôles disponibles sur le Mac. Les scripts de compilation et les tests automatisés restent fournis. La compilation iOS, la signature Apple et les essais sur l’iPhone et la moto doivent être confirmés avec Xcode et le matériel.

**Photos_des_ecrans.command** capture les réglages des trois cartes en portrait et en paysage sur un simulateur iPhone équipé d’iOS 26 ou ultérieur.

La mise à jour enregistre une sauvegarde des fichiers qu’elle doit modifier. Elle conserve les identifiants de signature et les réglages locaux de TomTom et du partage. Une deuxième exécution avec les mêmes options laisse le projet déjà à jour.

## Crédits

La base KoveMirror de MapaX est distribuée sous licence MIT dans **LICENSE**. Les attributions des cartes figurent dans **KoveMirror/ThirdPartyNotices.txt**. Le document **PRIVACY_POLICY.md** décrit les échanges de données de cette version.

## Mon garage et journal d’entretien — 23 novembre 2026

Ouvrir **… (en haut à gauche) → Mon garage · Journal d’entretien**. Le journal est indépendant des cartes et n'est pas projeté sur le TFT.

- **Ajouter une moto** : saisir librement sa marque, son type/modèle, éventuellement son année, immatriculation et VIN. Le titre utilise directement la marque et le modèle, jamais une valeur fixée dans le code.
- **Photo de la moto** : utiliser **Choisir ma photo** pour sélectionner une image dans la photothèque. Elle sera affichée en couverture de cette moto uniquement. La photo d'illustration de la maquette n'est pas ajoutée dans l'application.
- **Plusieurs motos** : utiliser le sélecteur « Moto active » pour passer d'une marque/modèle à un autre, chacun ayant sa photo, son historique et son concessionnaire.
- **Nouvelle fiche d’entretien** : date, kilométrage, opération, observations et jusqu'à six photos. Le kilométrage peut être repris du compteur pour une Kove connectée, lorsque la donnée Bluetooth est disponible. Sinon, saisie manuelle. Ce dispositif ne lit pas encore la température moteur, le régime moteur ni les codes de diagnostic.
- **Concessionnaire** : remplir la fiche contact spécifique à la moto (nom, e-mail, téléphone et adresse).
- **Partager** : ouvre l'application Mail iOS avec l'adresse du concessionnaire préremplie si Mail est configuré, sinon la feuille de partage iOS. Le document partagé est un PDF contenant les informations de la moto et les photos des opérations. Le partage est toujours volontaire, jamais automatique.

Les fiches sont enregistrées dans l'espace privé de l'application sur l'iPhone (`Application Support/DoubleInterfaceGarage`), sans serveur requis. **Attention : supprimer l'application peut effacer ce journal local** ; exporter régulièrement le journal PDF ou conserver une sauvegarde complète de l'iPhone. Les essais sur appareil et la compilation Xcode sont à effectuer sur Mac, car cette archive a été préparée hors d'un environnement macOS.
