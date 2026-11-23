# Confidentialité de Double Interface

Document de travail mis à jour le 23 novembre 2026. L’éditeur doit compléter son identité, son contact et les modalités de conservation avant publication.

## iPhone et compteur Kove

- La caméra lit le QR de connexion du compteur. L’app conserve le nom du réseau dans les préférences et les identifiants Wi-Fi dans le trousseau local de l’iPhone. Avec la capacité de connexion Wi-Fi, l’app transmet ces identifiants à iOS pour rejoindre le réseau. En mode manuel, le bouton de copie place le mot de passe dans le presse-papiers local pendant deux minutes.
- Le Bluetooth et le réseau local servent aux commandes, à la télémétrie et à l’envoi des images au TFT. Lors d’une diffusion complète autorisée avec ReplayKit, le contenu visible à l’écran peut inclure des notifications ou des données d’autres apps.
- Le GPS fournit la position, la vitesse et l’altitude utiles au guidage. Le mode trajet utilise la localisation lorsque l’iPhone est verrouillé. Les cartes choisies et la disposition de l’écran sont mémorisées dans les préférences.
- Les fichiers GPX importés ou enregistrés, leurs favoris et les cartes MBTiles importées sont conservés localement. Une trace peut contenir des coordonnées, des horaires, des altitudes, des noms de lieux et des extensions ajoutées par son auteur.

## Cartes en ligne

Les cartes, recherches d’adresse et itinéraires utilisent Apple MapKit. Rivmonde peut demander des tuiles topographiques à OpenTopoMap, qui reçoit les références des tuiles de la zone affichée et les informations réseau de la requête. Ces tuiles peuvent être mises en cache sur l’iPhone.

## Parcours dans Rivadventure

Une publication envoie à Supabase le GPX original, son titre, son activité, son point de départ et ses statistiques. Les utilisateurs authentifiés du service peuvent consulter et télécharger le parcours. Son auteur peut le retirer du partage. Supprimer uniquement la copie locale laisse la publication disponible. Le partage par fichier passe par la destination choisie dans la feuille de partage iOS.

## Diagnostic

Le diagnostic exporté à ta demande contient les états de connexion, les événements techniques et les mesures de réception GPS et d’envoi des images. Un ancien réglage d’enregistrement du journal peut aussi conserver localement des messages techniques sur les périphériques et la navigation.

## Trafic et signalements dans Rivroute

- TomTom reçoit les requêtes de tuiles et une zone autour de la position GPS pour fournir trafic et incidents. La zone demandée permet de déduire une position précise ; les informations réseau habituelles, dont l’adresse IP, sont aussi transmises. Les tuiles de trafic sont conservées brièvement en mémoire.
- Le partage Rivroute est facultatif. Son activation crée une session pseudonyme Supabase conservée dans le trousseau de l’iPhone. Les requêtes de réception concernent des secteurs régionaux. Aucun trajet ni suivi continu de position n’est diffusé aux autres utilisateurs.
- Publier un accident, un bouchon, des travaux ou un danger partage l’emplacement GPS de l’incident après confirmation dans l’app. Publier une zone de vigilance partage seulement une zone approximative. Le type, l’emplacement, la date, les votes et l’échéance du signalement sont visibles par les utilisateurs authentifiés de Rivroute. Les signalements expirent après une ou deux heures.
- L’identifiant pseudonyme de l’auteur et les votes individuels restent dans des tables privées, non diffusées par Realtime. Ces liens servent à limiter les doublons, les confirmations abusives et le rythme de publication.
- Les notifications sont locales sur l’iPhone et nécessitent son autorisation. Le son respecte le réglage des alertes et le mode Muet du guidage. iOS peut suspendre les connexions réseau en arrière-plan. Aucune réception d’alerte n’est promise après une fermeture forcée de l’app.
- Les zones de vigilance intégrées sont des informations dérivées du jeu de données public du Ministère de l’intérieur, mis à jour le 30 décembre 2025 (Licence Ouverte 2.0). Elles sont approximatives et ne constituent pas un relevé en direct des contrôles mobiles.

## Garage et journal d’entretien

Le garage conserve localement les fiches moto, les coordonnées facultatives du propriétaire et du concessionnaire, les entretiens, les photos et les factures importées. Les coordonnées du propriétaire figurent sur le PDF d’une intervention lorsque l’utilisateur choisit de le partager. L’application ne les transmet pas automatiquement à un serveur ou au concessionnaire.
