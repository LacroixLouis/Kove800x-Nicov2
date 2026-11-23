# Correctif Outils et fluidité – 23 novembre 2026

- Panneau Outils ouvert sans animation de layout du ScrollView sur la carte MapKit active.
- Suppression de la destruction/recréation du panneau Outils à chaque interaction.
- Le minuteur de 4 secondes ne masque plus le panneau de réglages tant qu’il est ouvert ; il reprend après fermeture.
- Suppression du symbole en double dans les boutons de réglages.
- Réglages de fermeture à 3 modes conservés et cartes Rivmonde hors ligne conservées.

Limites: tests statiques et unitaires seulement. Impossible de reproduire un plantage iPhone dans cet environnement ; il faut vérifier dans Xcode et sur iPhone, et recueillir le rapport de crash si le problème persiste.
