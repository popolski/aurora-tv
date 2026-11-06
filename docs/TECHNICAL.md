# Pile technique et choix de conception

Ce document explique **avec quoi** Aurora est construite, **comment** les morceaux s'emboîtent
et **pourquoi** chaque choix a été fait — y compris les pistes abandonnées et les problèmes
constatés sur l'Apple TV qui ont conduit à les changer. Pour le moteur de lecture en détail,
voir [PLAYER-ENGINE.md](PLAYER-ENGINE.md) ; pour l'organisation du code,
[ARCHITECTURE.md](ARCHITECTURE.md).

## En un coup d'œil

| Domaine | Technologie | Rôle |
|---|---|---|
| Langage | **Swift 6** (concurrence stricte) | toute l'application et sa logique |
| Interface | **SwiftUI** (tvOS 18+) | écrans, rangées, focus de la Siri Remote |
| Lecteur | **UIKit** + **AetherEngine 7.53.1** (FFmpeg) + **AVFoundation** | lecture MKV/HEVC/HDR/DTS…, télécommande |
| Logique métier | **LanterneCore** (paquet SwiftPM, sans interface) | protocole Stremio, compte, bibliothèque, tri des sources, réglages |
| Carrousel d'accueil | **TVServices** (extension Top Shelf) | dernières sorties, bandes-annonces |
| Reconnaissance de texte | **Vision** | détection des logos de titre illisibles |
| Projet Xcode | **XcodeGen** (`project.yml`) | projet reproductible, aucun `.pbxproj` versionné |
| Compilation | **GitHub Actions**, image `xcode-27` (Xcode 27.1, SDK tvOS 27) | tests, IPA, captures d'écran — sans Mac |
| Installation | **atvloadly** (sur le NAS) | signature avec un Apple ID gratuit et installation sur l'Apple TV |
| Service NAS | **Python 3.12** + **yt-dlp** + **ffmpeg** + **Pillow**, **Docker** | bandes-annonces, extraits, images du carrousel |
| Données libres | **Cinemeta**, **Wikidata**, **TheIntroDB**, **AniSkip** | catalogues, notes critiques, titres lisibles, génériques |

Environ 15 000 lignes de Swift, 147 tests unitaires du cœur, 4 tests d'interface sur simulateur,
14 tests Python pour le service NAS.

## Architecture générale

```
┌──────────────────────────────── Apple TV « Chambre » ───────────────────────────────┐
│                                                                                     │
│  Aurora (app tvOS)                                     Extension Top Shelf          │
│  ┌──────────────────────────────────────────────┐      ┌─────────────────────────┐  │
│  │ SwiftUI : Accueil · Films · Séries · Ma liste │      │ ContentProvider         │  │
│  │           Recherche · Réglages · Fiche ·      │      │ (TVServices)            │  │
│  │           Sources                             │      │ dernières sorties,      │  │
│  │ UIKit : lecteur (PlayerViewController)        │◀────▶│ extraits, images titrées│  │
│  │ AppModel (@Observable, MainActor)             │ groupe└─────────────────────────┘  │
│  │ LanterneCore (actors, logique testée)         │ d'apps                             │
│  │ AetherEngine ─ FFmpeg ─ AVPlayer / AVSBDL     │                                    │
│  └──────────────────────────────────────────────┘                                    │
└─────────┬───────────────────────┬───────────────────────────┬───────────────────────┘
          │ HTTPS                 │ HTTPS                     │ HTTP (réseau local)
          ▼                       ▼                           ▼
  Addons Stremio            Services libres            NAS (Synology DS224+)
  (catalogues, fiches,      Wikidata · TheIntroDB      ┌──────────────────────────┐
   sources, sous-titres)    AniSkip · Cinemeta         │ aurora-trailers (Docker) │
  API de compte Stremio                                │ yt-dlp · ffmpeg · Pillow │
                                                       │ atvloadly (installation) │
                                                       │ serveur de streaming     │
                                                       └──────────────────────────┘
```

## Les choix, un par un

### 1. Swift 6 et la concurrence stricte

- **Choix :** mode Swift 6 avec vérification complète de la concurrence ; l'app est isolée par
  défaut sur le `MainActor` (`SWIFT_DEFAULT_ACTOR_ISOLATION`) ; les services (bibliothèque,
  registre d'addons, compte, minutages, notes, titres) sont des `actor`.
- **Pourquoi :** une app de streaming fait beaucoup de choses en parallèle (catalogues, fiches,
  sources de dix addons, images, synchronisation). Le compilateur garantit l'absence de courses
  de données ; les tâches de chargement sont annulées dès qu'on quitte un écran.
- **Conséquence :** quelques contorsions documentées dans le code — par exemple la méthode de
  l'extension Top Shelf déclarée `nonisolated(nonsending)`, ou les gestionnaires de la
  télécommande système qui repassent explicitement sur le fil principal.

### 2. SwiftUI pour l'interface, UIKit pour le lecteur

- **SwiftUI** gère très bien le focus de la Siri Remote dans les grilles et les rangées
  (`focusSection`, `prefersDefaultFocus`, `defaultFocus`).
- **Le lecteur est en UIKit**, présenté par `PlayerPresenter` dans son propre contexte de focus.
  Première version en `fullScreenCover` SwiftUI : sur l'Apple TV, la télécommande n'atteignait
  plus le lecteur (impossible de changer de langue). UIKit donne accès aux appuis bruts
  (`pressesBegan/Ended`), indispensables pour distinguer un clic d'un appui long ou d'un
  balayage.
- **Navigation :** une barre d'onglets tvOS native en haut (après deux essais rejetés : menu
  latéral, puis capsule flottante en bas) ; une pile de navigation par onglet, qui restaure le
  focus au retour.

### 3. Un cœur métier séparé et testé (LanterneCore)

- Tout ce qui ne dépend pas de l'écran est dans un paquet SwiftPM sans UIKit ni AVFoundation :
  protocole des addons, API de compte, bibliothèque au format Stremio, champ « épisodes vus »
  compressé (`WatchedBitField`), analyse et tri des sources, filtres, sélection des pistes,
  jalons de lecture, minutages d'intro, notes, titres, calendrier des épisodes, Top Shelf.
- **Pourquoi :** ce code se compile et se teste sur macOS (`swift test`) en quelques secondes,
  avec des réponses réseau simulées. C'est là que se trouvent les règles délicates (tri des
  sources, progression, fusion des fiches), donc là qu'il faut le plus de tests.

### 4. Le lecteur : AetherEngine plutôt que VLC ou mpv

Résumé (le détail, avec le tableau comparatif, est dans [PLAYER-ENGINE.md](PLAYER-ENGINE.md)) :

- Les sources Stremio sont surtout des **MKV en HEVC 10 bits, HDR10 / Dolby Vision, avec du
  DTS, TrueHD ou E-AC-3 Atmos et des sous-titres SRT/ASS/PGS**. AVPlayer seul ne lit ni le MKV,
  ni le DTS, ni le TrueHD.
- VLC et mpv décodent tout, mais **affichent eux-mêmes** les images sur tvOS : on perd la bascule
  HDR/Dolby Vision native de l'Apple TV et il n'existe pas de signal fiable « l'image est
  réellement affichée ».
- **AetherEngine** utilise FFmpeg uniquement pour **démultiplexer** (et décoder en secours), puis
  rend la vidéo à **AVPlayer** via un petit serveur HLS local, ou à
  `AVSampleBufferDisplayLayer`. On garde donc le chemin d'affichage d'Apple : HDR, Dolby Vision,
  adaptation de la fréquence, Atmos — et un signal `hasFirstFrameReadyForDisplay`.
- **Version exacte figée** (7.53.1) : le projet publie presque chaque jour ; une montée de
  version est une décision explicite.
- **Repli AVPlayer** (`SystemPlaybackEngine`) derrière la même abstraction `PlaybackEngine`,
  proposé dans l'écran d'erreur (« Réessayer avec AVPlayer »).
- **Une lecture n'est réussie qu'avec une image affichée et une horloge qui avance** : six
  jalons suivis, et un chien de garde qui affiche « Aucune image » au lieu d'un faux succès.

### 5. Le lecteur : choix d'ergonomie

| Fonction | Choix | Raison / historique |
|---|---|---|
| Télécommande | vue transparente focalisable, **sœur** des surcouches | une vue focalisable empêche ses enfants de recevoir le focus : le panneau Audio/Sous-titres serait inaccessible |
| Menu | ferme d'abord le panneau, puis masque l'interface, puis quitte | build 8 : Menu dans les réglages quittait le film |
| Appui court gauche/droite | saut (10 s par défaut, réglable) au **relâchement** | il faut attendre le relâchement pour savoir si la touche est maintenue |
| Gauche/droite maintenu | défilement accéléré ×8 → ×128, reprise au relâchement | demandé après le build 17 ; marche avec n'importe quel moteur (déplacement de la cible, pas de lecture accélérée) |
| Touches ⏪/⏩ d'une télécommande de TV ou de l'iPhone | `MPRemoteCommandCenter` (saut, appui maintenu, position) + infos « À l'écran » | ces touches n'arrivent pas comme des appuis UIKit |
| Épisode suivant | encart pendant le générique (délai réglable), compte à rebours, même groupe de sources (`bingeGroup`) | demandé au build 8 : ne pas attendre la toute fin du fichier |
| Passer l'intro | bouton « OK pour passer · Menu pour regarder », saut automatique en option | minutages TheIntroDB/AniSkip parfois décalés selon le fichier : le choix reste à l'utilisateur |
| Heure de fin | « −1:12:30 · Fin à 22:47 » | utile le soir |
| Pistes | audio français, puis anglais ; sous-titres français automatiques si l'audio n'est pas français | préférences par défaut pour un usage en France |
| Sous-titres | surcouche dessinée par Aurora (taille, position, fond, décalage) | rendu identique quels que soient le moteur et le format |

### 6. Les bandes-annonces : un service sur le NAS

- Les addons ne fournissent que des **identifiants YouTube**. tvOS n'a **pas de vue web** pour
  les apps : impossible d'intégrer le lecteur YouTube (c'est ce que fait dx.bi sur ordinateur et
  Android TV, voir l'analyse dans l'historique).
- **Solution :** `aurora-trailers`, un service Python en conteneur Docker sur le NAS, télécharge
  la bande-annonce avec **yt-dlp** (H.264 + AAC, 1080p au plus), la remet en forme avec
  **ffmpeg** (MP4 classique, index en tête), la garde en cache et la sert en HTTP avec les plages
  (`Range`) qu'attend AVPlayer. Il produit aussi les **extraits de 30 s** du carrousel et les
  **images titrées** du Top Shelf (Pillow).
- **Sécurité :** réseau local uniquement, identifiants YouTube validés (11 caractères), images
  téléchargées seulement depuis une liste d'hôtes connus, utilisateur non administrateur.
- Leçons apprises en installant sur le DS224+ : l'étape ffmpeg prend ~27 min la première fois
  (téléchargements Debian lents) → mise à jour de yt-dlp isolée dans sa propre couche Docker ;
  dossiers partagés Synology non inscriptibles par le conteneur → volume Docker nommé.

### 7. Le carrousel Top Shelf

- **Extension `AuroraTopShelf`** (style « détaillé ») : dix dernières sorties de Cinemeta,
  extrait de 30 s lancé par tvOS, boutons « Lire » et « Plus d'infos » via des liens
  `aurora://`.
- **Partage de l'adresse du NAS :** par un groupe d'apps. atvloadly **renomme** le groupe à la
  signature (constaté : suffixe d'équipe, et même en double côté app) ; l'app et l'extension
  lisent donc les deux profils de provisionnement embarqués et retiennent le groupe commun.
- **Pseudo-signature** (`scripts/fakesign.sh`) : l'IPA porte une signature ad hoc avec les
  droits, pour qu'atvloadly sache qu'il faut un groupe d'apps.
- **Titre dans l'image :** tvOS n'affiche pas le titre dans ce style ; la composition de
  l'image sur l'Apple TV dépassait la mémoire accordée aux extensions (carrousel vide au
  build 28) → c'est le NAS qui compose les images.
- **Installation :** une mise à jour se bloque si le carrousel d'Aurora est affiché à l'écran ;
  il faut ouvrir une autre app avant d'installer.

### 8. Données libres plutôt que clés d'API

| Besoin | Source | Pourquoi |
|---|---|---|
| Catalogues, fiches, sources, sous-titres | addons Stremio de l'utilisateur | c'est le principe de Stremio |
| Compte, bibliothèque, progression | API de compte Stremio (non officielle, celle des apps officielles) | synchronisation avec les autres appareils |
| Notes Rotten Tomatoes / Metacritic | **Wikidata** (SPARQL) | gratuit, sans clé |
| Titres français pour les titres non latins | **Wikidata** (par IMDb ou TMDB) | idem ; une requête par page de catalogue |
| Passer l'intro | **TheIntroDB** (v4), **AniSkip** pour les animés Kitsu | communautaires, sans clé |
| Logos de titre illisibles | **Vision** (sur l'Apple TV) + pays d'origine | aucune donnée de langue fiable sur les logos |

Aucune clé d'API n'est nécessaire, et aucune n'est stockée dans le dépôt.

### 9. Persistance sur tvOS

tvOS ne garantit qu'environ 500 Ko de stockage persistant ; tout fichier de cache peut être
effacé par le système. D'où : réglages et copie compacte de la bibliothèque dans
`UserDefaults`, bibliothèque complète en fichier, secrets (jeton du compte) dans le trousseau,
caches d'images (150 Mo) purgeables. Le décodage des réglages est tolérant champ par champ : une
nouvelle version ne fait jamais perdre les réglages existants.

### 10. Compiler et distribuer sans Mac

- **GitHub Actions**, image `xcode-27` : tests du cœur, compilation Release pour l'appareil,
  IPA non signée, vérification (architectures, plateforme Mach-O, extension, version), tests
  d'interface sur simulateur, publication d'une release `build-NN` à chaque version.
- **Pas de certificat dans le dépôt :** l'IPA est signée à l'installation par atvloadly avec
  l'Apple ID de l'utilisateur (gratuit). Une signature par la CI reste possible
  (`scripts/sign-ipa.sh`) si des secrets sont configurés, ce qui n'est pas le cas.
- **Identifiant d'app figé** (`io.github.popolski.lanterne`) : le changer ferait perdre les
  données locales à la mise à jour. C'est pour cela que le dépôt et le module gardent le nom
  « Lanterne » alors que l'app s'appelle Aurora.
- **Captures d'écran automatiques :** un mode démo (films inventés, images générées) et un test
  d'interface dédié produisent les captures de la documentation sur le simulateur.

### 11. Sécurité et honnêteté

- Secrets : trousseau uniquement, jamais dans les journaux (expurgés), jamais dans le dépôt.
- TLS jamais désactivé globalement ; HTTP accepté pour les adresses du réseau local (NAS,
  serveur de streaming) et les addons choisis par l'utilisateur.
- Réponses des addons et services tiers traitées comme non fiables (décodage tolérant, tailles
  plafonnées, identifiants validés avant d'être insérés dans une requête).
- Aucun contenu fourni ni recommandé ; pas de moteur torrent intégré.
- Chaque fonction est marquée « implémentée / compilée / testée / validée sur l'appareil »
  séparément ([STATUS.md](STATUS.md)) ; rien n'est déclaré validé sans retour réel.

Détails : [SECURITY.md](SECURITY.md).
