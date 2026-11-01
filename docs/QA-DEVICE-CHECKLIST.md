# Qualification sur l'Apple TV « Chambre »

Les tests automatisés (unitaires sur macOS, interface sur simulateur) ne prouvent pas qu'une
vidéo s'affiche sur une vraie Apple TV. Cette procédure doit être exécutée sur l'appareil pour
chaque version candidate. Noter pour chaque ligne : ✅ / ❌ / remarque, la version (Réglages ›
À propos) et le modèle de téléviseur/ampli.

Avant de commencer : Réglages › Diagnostics › renseigner l'adresse du récepteur de journaux
(`scripts/log-receiver.py`) pour pouvoir envoyer les journaux après chaque série.

## A. Installation

| # | Vérification | Résultat |
|---|---|---|
| A1 | Installation via atvloadly sans erreur ; version tvOS de l'appareil notée | |
| A2 | L'icône (parallaxe) et le nom « Lanterne » apparaissent | |
| A3 | Mise à jour par-dessus la version précédente : réglages, connexion et progression conservés | |

## B. Lecteur — clips embarqués (Réglages › Diagnostics › Tester le lecteur)

Pour chaque clip : l'horodatage en haut à gauche défile, la mire bouge, le carré blanc en haut à
droite clignote **en même temps** que le bip.

| # | Clip | Image visible et qui progresse | Son | Synchro A/V | Jalon « Lecture stable » (▼ › Informations) |
|---|---|---|---|---|---|
| B1 | MP4 · H.264 · AAC | | | | |
| B2 | MKV · HEVC 10 bits · E-AC-3 + AAC | | | | |
| B3 | MKV · H.264 · DTS | | | | |

| # | Fonction (sur B2) | Résultat |
|---|---|---|
| B4 | ▼ › Audio : passer de « Français (440 Hz) » à « English (660 Hz) » — la tonalité change, la coche suit | |
| B5 | Sous-titres SRT français : texte visible, accents corrects ; italique en 6–10 s | |
| B6 | Sous-titres ASS anglais : ligne jaune en haut (3–9 s) + ligne en bas | |
| B7 | « Désactivés » masque les sous-titres | |
| B8 | Décalage +0,25 s / −0,25 s appliqué | |
| B9 | B1 : sous-titre externe « Français (externe) » disponible et affiché | |
| B10 | Clic gauche/droite : −10 s / +10 s, l'horodatage le confirme | |
| B11 | Balayage horizontal : prévisualisation de position, clic = déplacement, Menu = annulation | |
| B12 | Lecture/Pause (clic central et touche ⏯) | |
| B13 | Menu ×2 : retour à l'écran précédent, focus intact, navigation possible immédiatement | |
| B14 | Enchaîner B1 → B2 → B3 → B1 (×3) sans relancer l'app : aucune lecture ne reste noire, pas de son résiduel | |

## C. Sources réelles (addons de l'utilisateur, médias autorisés)

| # | Type de source | Moteur/chemin (Informations) | Image | Son | HDR/DV basculé | Remarque |
|---|---|---|---|---|---|---|
| C1 | HLS (HTTPS) | | | | | |
| C2 | MP4 H.264/AAC | | | | | |
| C3 | MKV HEVC SDR + E-AC-3 | | | | | |
| C4 | MKV HEVC HDR10 | | | | | |
| C5 | MKV Dolby Vision (P8 ou P5) | | | | | |
| C6 | MKV avec DTS-HD ou TrueHD | | | | | |
| C7 | Sous-titres PGS intégrés | | | | | |
| C8 | Source nécessitant des en-têtes (`proxyHeaders`) | | | | | |
| C9 | Torrent via serveur de streaming du NAS (si configuré) | | | | | |
| C10 | Source invalide/expirée : écran d'erreur explicite, « Autre source… » fonctionne | | | | | |

Pour chaque ligne, comparer « Annoncé » et « Détecté » dans Informations.

## D. Reprise et bibliothèque

| # | Vérification | Résultat |
|---|---|---|
| D1 | Regarder 3 min d'un film, fermer : il apparaît dans « Continuer à regarder » avec la bonne progression | |
| D2 | Fiche : « Reprendre · mm:ss » reprend à la bonne position ; « Depuis le début » repart à 0 | |
| D3 | Couper le réseau pendant la lecture puis fermer : la progression est conservée après redémarrage | |
| D4 | Série : finir un épisode → écran « Épisode suivant » + compte à rebours → lecture du suivant avec une source du même groupe | |
| D5 | Marquer un épisode vu (appui long) : coche affichée ; reprise proposée sur le suivant | |
| D6 | Connecté : la progression apparaît dans l'application Stremio officielle (autre appareil) | |
| D7 | Connecté : un épisode marqué vu dans Stremio officiel apparaît coché dans Lanterne | |

## E. Navigation

| # | Vérification | Résultat |
|---|---|---|
| E1 | Accueil : passage fluide entre rangées, aucun élément inatteignable | |
| E2 | Retour depuis une fiche : focus sur l'affiche d'origine | |
| E3 | Retour après lecture : focus sur la source puis sur l'épisode | |
| E4 | Recherche (clavier tvOS) : résultats par catalogue | |
| E5 | Réglages : toutes les options atteignables et modifiables | |
| E6 | Connexion par code QR depuis un téléphone | |

## F. Stabilité

| # | Vérification | Résultat |
|---|---|---|
| F1 | 10 lectures successives de sources différentes sans redémarrer l'app | |
| F2 | Lecture d'un film complet (> 90 min) sans blocage | |
| F3 | Mise en arrière-plan (bouton TV) pendant la lecture puis retour | |
| F4 | Journaux envoyés au récepteur après la série et joints au compte rendu | |
