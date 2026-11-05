# Architecture

## Vue d'ensemble

```
┌──────────────────────── App (tvOS, SwiftUI + UIKit) ─────────────────────────┐
│  RootView (barre d'onglets en haut) ─ NavigationStack par onglet ─ Route      │
│  Accueil · Films · Séries · Ma liste · Réglages · Recherche · Fiche · Sources │
│  AppModel (@Observable, MainActor) : état observé + accès aux services        │
│  Player : PlayerViewController (UIKit, télécommande) + PlayerSession          │
│           ├─ PlaybackEngine ── AetherPlaybackEngine | SystemPlaybackEngine    │
│           └─ RemoteCommands (touches ⏪/⏩, « À l'écran »)                     │
│  Platform : ImageLoader, LogoCheck (Vision), Trailers (NAS), TopShelfBridge,  │
│             journaux, clients HTTP de test et de démonstration                │
├──────────────── Extension Top Shelf (TVServices, AuroraTopShelf) ────────────┤
│  ContentProvider : dernières sorties Cinemeta, extraits et images du NAS      │
└───────────────────────────────┬──────────────────────────────────────────────┘
                                │ async/await, actors
┌───────────────────────── LanterneCore (SwiftPM, sans UI) ────────────────────┐
│  Addons : protocole, URL, AddonClient (cache, limites), Aggregator, Registry  │
│  Account : StremioAPI (non officielle), AccountService (session, synchro)     │
│  Library : LibraryItem (format Stremio), LibraryStore, WatchedBitField,       │
│            EpisodeCalendar (« Cette semaine », nouvel épisode)                │
│  Streams : StreamTraits, Playability, SourceRanker, SourceFilter              │
│  Playback : TrackSelector, PlaybackMilestoneTracker, SkipTimesClient          │
│  Reviews · Titles · People (filmographies) : Wikidata · Trailers (liens NAS)  │
│  TopShelf (groupe d'apps, configuration, flux, liens aurora://)               │
│  Settings, Persistence (UserDefaults/fichier/trousseau), Networking, Log      │
└──────────────────────────────────────────────────────────────────────────────┘
```

Pour les raisons de ces choix et l'historique des décisions, voir [TECHNICAL.md](TECHNICAL.md).

**Principe :** toute la logique testable (protocole, tri, bibliothèque, jalons, sélection de
pistes, réglages) est dans `LanterneCore`, compilée et testée sur macOS avec `swift test`. L'app
ne contient que la présentation, la navigation, l'intégration des moteurs et de la plateforme.

## Choix techniques

| Sujet | Choix | Raison |
|---|---|---|
| UI | SwiftUI (tvOS 18+), UIKit pour le lecteur | SwiftUI gère bien le focus des grilles/rangées ; le lecteur a besoin du contrôle fin des appuis (`pressesBegan/Ended`) et du geste de balayage |
| Concurrence | Swift 6, concurrence stricte ; app en isolation `MainActor` par défaut ; services en `actor` | absence de courses de données vérifiée à la compilation ; annulation structurée (tâches de chargement annulées à la sortie des écrans) |
| Navigation | une `NavigationStack` par onglet, destinations par valeur (`Route`) déclarées à la racine | évite les destinations ignorées dans les conteneurs paresseux ; la pile restaure le focus au retour |
| Lecteur | contrôleur UIKit présenté plein écran (`PlayerPresenter`) | contexte de focus propre (un `fullScreenCover` SwiftUI empêchait la télécommande d'atteindre le lecteur — constaté sur l'appareil, build 6) ; fermeture centralisée, libération du moteur |
| Projet | XcodeGen | projet reproductible, pas de `.pbxproj` en conflit |
| Dépendances | AetherEngine (version exacte) uniquement | rien d'autre n'est nécessaire |

## Focus et télécommande

- Rangées horizontales et sections marquées `focusSection()` : déplacement vertical prévisible
  entre rangées, horizontal dans une rangée.
- Fiche : `prefersDefaultFocus` sur « Lire/Reprendre ».
- Retour : la pile de navigation restaure le focus sur l'élément d'origine (vérifié par un test
  d'interface sur simulateur).
- Lecteur : une vue transparente focalisable, sœur des surcouches, reçoit les appuis ; quand un panneau ou un écran
  d'erreur/fin est ouvert, `preferredFocusEnvironments` bascule vers la surcouche SwiftUI et le
  geste de balayage est désactivé. Menu ferme d'abord le panneau, puis masque l'interface, puis
  ferme le lecteur. Appui long sur une affiche « Continuer » ou un épisode : menu contextuel
  (retirer, marquer vu/non vu).

## Cycle de vie du lecteur

1. `AppModel.play(context)` → `PlayerPresenter` présente un `PlayerViewController` (UIKit) avec
   une `PlayerSession`.
2. `viewDidAppear` → `session.start()` : création de la requête moteur, jalon « source ouverte »,
   chargement asynchrone, boucle d'observation à 4 Hz.
3. Pendant la lecture : jalons, chien de garde « pas d'image », pistes par défaut (préférences),
   sous-titres externes ajoutés sans retarder le démarrage, progression enregistrée toutes les
   15 s et à chaque pause (écritures regroupées par `LibraryStore`).
4. Fin : épisode suivant (même `bingeGroup` en priorité) avec compte à rebours, ou écran de fin.
5. Fermeture (Menu, bouton, disparition de la vue) : `session.close()` idempotent → progression
   finale, règle du générique, arrêt du moteur (critères d'affichage remis à zéro, session audio
   libérée), mise en veille réautorisée, puis envoi des modifications au compte.

## Persistance (contrainte tvOS)

tvOS ne garantit qu'environ 500 Ko de stockage local persistant (`UserDefaults`) ; tout fichier
peut être purgé. D'où : réglages + copie de secours compacte de la bibliothèque dans
`UserDefaults`, bibliothèque complète et caches en fichiers, secrets dans le trousseau. Décodage
tolérant champ par champ : une version future ne fait jamais perdre les réglages existants.

## Ce que l'interface affiche et n'affiche pas

- Jamais d'information inventée : champs absents masqués (année, durée, note…).
- Caractéristiques des sources : « annoncées » (contour) d'après le texte de l'addon ; les
  caractéristiques **détectées** par le moteur sont dans Informations pendant la lecture, à côté
  des annoncées.
- Note : uniquement la note IMDb fournie par l'addon de métadonnées, étiquetée « IMDb ».
