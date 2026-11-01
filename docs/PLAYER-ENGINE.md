# Moteur de lecture : comparaison et décision

> Statut : décision d'architecture prise sur la base des documentations et du code source des
> projets (lus le 1er novembre 2026). **Aucune des affirmations de performance ou de compatibilité
> des tiers ci-dessous n'a été vérifiée sur une Apple TV par Lanterne.** La qualification réelle se
> fait avec `docs/QA-DEVICE-CHECKLIST.md`.

## Le vrai problème

Les sources Stremio courantes (services de débridage, serveur de streaming) sont en majorité des
fichiers **MKV** contenant du **HEVC** (souvent 10 bits, HDR10 ou Dolby Vision), de l'audio
**E-AC-3/Atmos, DTS, DTS-HD MA ou TrueHD**, et des sous-titres **SRT, ASS ou PGS**.

- AVPlayer (AVFoundation) ne lit **ni MKV, ni DTS, ni TrueHD**, ni sous-titres hors WebVTT/HLS.
- Un moteur FFmpeg « classique » (VLC, mpv) décode tout, mais doit **présenter** lui-même les
  images : sur tvOS, cela signifie OpenGL ES (déprécié) ou Vulkan via MoltenVK, sans le chemin
  natif de bascule HDR/Dolby Vision de l'Apple TV. C'est la cause typique de « le décodeur
  produit des images mais rien ne s'affiche » ou d'un HDR délavé.

Il faut donc séparer **décoder** et **présenter**, et ne considérer une lecture comme réussie que
si la couche de présentation d'Apple signale une image prête et que l'horloge progresse.

## Options étudiées

| Critère | AVPlayer seul | VLCKit 3.x (TVVLCKit) | libmpv (MPVKit et forks) | KSPlayer | **AetherEngine** |
|---|---|---|---|---|---|
| MKV / AVI / TS | ❌ / ❌ / ✅ (HLS) | ✅ | ✅ | ✅ | ✅ (démux FFmpeg) |
| HEVC matériel | ✅ | ✅ | ✅ | ✅ | ✅ (VideoToolbox) |
| Présentation HDR10 / Dolby Vision | ✅ natif (bascule d'écran) | ❌ rendu SDR historiquement (non revérifié : hôtes VideoLAN inaccessibles depuis l'environnement de travail) | MoltenVK : complexe ; fork streamyfin : sortie `AVSampleBufferDisplayLayer` annoncée HDR/DV | annoncé ; métadonnées DV dynamiques réservées à la version payante | ✅ annoncé : remux local vers AVPlayer (chemin natif Apple), DV P5/P7→8.1/P8 |
| DTS / DTS-HD / TrueHD | ❌ | ✅ décodage | ✅ décodage | ✅ décodage | ✅ décodage en PCM multicanal ; objets Atmos TrueHD/DTS:X via options de compilation désactivées par défaut |
| E-AC-3 Atmos (bitstream) | ✅ | ? | ❌ (PCM) | version payante | ✅ copie du flux (annoncé) |
| Sous-titres ASS / PGS | ❌ | ✅ libass, PGS | ✅ libass, PGS | ✅ | texte stylé simplifié (pas libass complet) + images PGS/DVB |
| Signal « image prête à l'affichage » | ✅ `isReadyForDisplay` | ❌ pas de signal fiable de présentation | ❌ | ? | ✅ `hasFirstFrameReadyForDisplay` (issu d'AVPlayerLayer / AVSampleBufferDisplayLayer) |
| Licence | Apple | LGPL 2.1 | LGPL ou GPL selon la variante | GPL ou licence payante | LGPL 3 + exception App Store |
| Distribution | système | xcframework VideoLAN | SPM (binaires) | SPM (branche `main`) | SPM, version exacte |
| Maintenance | Apple | VideoLAN, stable (v4 longtemps en bêta) | amont « pour apprendre », forks actifs | un développeur, modèle payant | un développeur, cadence très élevée |

## Décision

**Architecture hybride derrière une abstraction `PlaybackEngine` :**

1. **AetherEngine (moteur par défaut)** — FFmpeg ne sert qu'au démultiplexage et au décodage
   logiciel de secours ; la présentation reste celle d'Apple (AVPlayer via un serveur HLS local, ou
   `AVSampleBufferDisplayLayer`). On récupère ainsi la bascule HDR/Dolby Vision, l'adaptation de la
   fréquence d'images et le passage Atmos gérés par tvOS, et surtout un **signal fiable de première
   image prête**, indispensable au critère « la vidéo est réellement visible ».
2. **AVPlayer seul (moteur « système »)** — implémenté en interne (≈ 200 lignes), sert de repli,
   de référence de diagnostic, et de bouton « Réessayer avec AVPlayer » dans l'écran d'erreur.

Je n'ai **pas** compilé moi-même FFmpeg/mpv/VLC : AetherEngine fournit des binaires XCFramework
FFmpeg (LGPL, dynamiques) via SwiftPM et l'abstraction permet d'ajouter un autre moteur (VLCKit,
mpv) plus tard si la qualification sur l'appareil le justifie.

### Risques identifiés et parades

| Risque | Parade |
|---|---|
| Projet à mainteneur unique, publications quasi quotidiennes : régressions possibles | Version **exacte** dans `project.yml` (`7.53.1`) ; montée de version = décision explicite + re-qualification |
| Exige Xcode 27 / Swift 6.4 (Xcode 26.3 « au mieux ») | CI sur l'image GitHub `xcode-27` (Xcode 27.1, SDK tvOS 27.0) |
| ASS : rendu simplifié (pas de karaoké, pas de positionnement libre complet) | Documenté ; texte, gras/italique et haut/bas pris en charge |
| Dolby Vision profil 8.1 sur téléviseur HDR10 seul : blocage signalé par le projet (issue #4) | Option « Mon téléviseur affiche le Dolby Vision » désactivée par défaut ; à qualifier |
| Le moteur expose beaucoup d'options avancées | Lanterne n'en utilise qu'un sous-ensemble documenté (en-têtes, critères d'affichage, langues) |

## Jalons de démarrage (critère fondamental)

Implémentés dans `PlaybackMilestoneTracker` (LanterneCore, testé) et affichés dans le lecteur :

| # | Jalon | Signal utilisé |
|---|---|---|
| 1 | Source ouverte | appel de chargement accepté |
| 2 | Données reçues | durée, pistes ou conteneur connus |
| 3 | Décodage démarré | le moteur annonce un état de lecture **et** des données reçues |
| 4 | Première image prête à l'affichage | `hasFirstFrameReadyForDisplay` / `AVPlayerLayer.isReadyForDisplay` |
| 5 | Lecture effective | jalon 4 atteint **et** horloge qui progresse en lecture |
| 6 | Lecture stable | progression continue pendant 10 s |

- Une lecture n'est déclarée réussie qu'au jalon 5 ; la source n'est mémorisée comme « déjà
  utilisée » qu'à ce moment.
- **Chien de garde** : si l'horloge avance depuis plus de 3 s, 20 s après l'ouverture, sans
  image signalée, l'écran « Aucune image affichée » apparaît (au lieu d'un faux succès).
- Le jalon 4 est le signal le plus fort exposé par la plateforme ; seule une observation sur le
  téléviseur prouve que l'image est réellement visible (procédure de qualification).

## Formats : attendu vs. vérifié

« Attendu » = d'après la documentation du moteur et d'Apple ; rien n'est « validé » tant que la
procédure n'a pas été exécutée sur l'Apple TV « Chambre ».

| Format | Attendu | Validé sur Apple TV |
|---|---|---|
| H.264, HEVC 8/10 bits (MP4, MKV) | ✅ décodage matériel | ⏳ |
| HDR10 / HLG | ✅ bascule d'écran | ⏳ |
| Dolby Vision P5 / P8 | ✅ selon téléviseur | ⏳ |
| AV1 | Logiciel (dav1d) sauf puce avec décodeur AV1 matériel ; l'Apple TV 4K 3e génération (A15) n'en a pas → 4K AV1 probablement trop lourd | ⏳ |
| HLS | ✅ (AVPlayer direct) | ⏳ |
| MPEG-DASH | Partiel : manifestes statiques seulement (moteur ≥ 7.48) | ⏳ |
| AAC, AC-3, E-AC-3 (+Atmos) | ✅ copie du flux | ⏳ |
| DTS, DTS-HD MA, TrueHD | ✅ décodés en PCM (tvOS n'accepte pas le DTS en bitstream) | ⏳ |
| SRT, WebVTT, ASS (simplifié), PGS | ✅ surcouche Lanterne | ⏳ |
| Torrent / magnet | ❌ en natif — uniquement via un serveur de streaming Stremio externe | ⏳ |
| YouTube, liens externes, archives | ❌ affichés comme non lisibles | — |

Les trois clips embarqués (Réglages › Diagnostics › Tester le lecteur) couvrent H.264/AAC en MP4,
HEVC 10 bits + E-AC-3/AAC + SRT/ASS en MKV, et H.264 + DTS en MKV.
