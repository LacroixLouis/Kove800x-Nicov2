# Double Interface — bandeaux et cadre de la petite carte

Version : `23NOV-BANDEAUX-BLEU-FONCE-CADRE-MINIATURE-v5`.

Cette archive met à jour la version `23NOV-THEMES-MENUS-VERT-BLEU-ORANGE-v4` du projet `Double_Interface_THEMES_VERT_BLEU_ORANGE_23NOV.zip`.

## Modifications

- Fonds et contours des bandeaux en bleu foncé commun aux trois cartes.
- Boutons sélectionnés dans la couleur pleine de leur carte ; boutons secondaires dans la même couleur à 18 % d’opacité.
- Boutons du haut et du zoom sur fond bleu foncé ; suppression des halos colorés qui débordaient sur les bandeaux.
- Cadre de la petite carte lié au profil TFT réellement affiché à l’intérieur : vert Rivadventure, bleu Rivroute, orange Rivmonde.

## Vérifications effectuées

- 75 contrôles Python existants : réussis.
- Relecture indépendante des changements dans les quatre fichiers Swift.
- Empreintes du manifeste de mise à jour, ressources et intégrité ZIP vérifiées lors de la préparation de l’archive.
- Les moteurs de carte, le GPS, la transmission TFT, les actions et les règles de fermeture du menu ne sont pas modifiés.

## À vérifier dans Xcode et sur les appareils

La compilation iOS, la signature et le rendu sur iPhone/TFT ne sont pas validés ici : Swift et Xcode ne sont pas disponibles dans cet environnement. Passer entre les trois cartes puis échanger la grande et la petite carte pour contrôler les couleurs à l’écran.

Pour mettre à jour le projet déjà installé sur le Mac, suivre la rubrique d’installation du README et lancer `Mettre_a_jour_sur_Mac.command`.
