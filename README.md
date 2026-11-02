# Aurora

Client Stremio natif pour Apple TV (tvOS 18+, conçu pour l'Apple TV 4K sous tvOS 27).
Nom affiché : **Aurora** (anciennement « Lanterne », nom conservé pour le dépôt, le module
et l'identifiant `io.github.popolski.lanterne`, qui ne doit pas changer pour que les mises à
jour conservent les données). Interface SwiftUI « Aurore » teintée par l'image du contenu, navigation pensée pour la Siri Remote, addons Stremio,
compte et bibliothèque synchronisés, lecteur AetherEngine (MKV, HEVC, HDR10/Dolby Vision,
DTS/TrueHD, sous-titres texte et image) avec repli AVPlayer.

Lanterne n'héberge, ne fournit ni ne recommande aucun contenu : il affiche ce que renvoient les
addons installés par l'utilisateur. Il n'embarque aucun moteur torrent.

## État honnête du projet

| Élément | Implémenté | Compilé | Testé automatiquement | Validé sur Apple TV |
|---|---|---|---|---|
| Protocole addon (manifestes, catalogues, fiches, flux, sous-titres) | ✅ | ✅ | ✅ tests unitaires (réponses simulées) | ⏳ |
| Compte Stremio (e-mail, code QR), synchro addons/bibliothèque | ✅ | ✅ | ✅ simulé (84 tests du cœur) | 🟡 connexion + synchro OK sur « Chambre » (build 6, 01/11/2026) ; bibliothèque à vérifier |
| Smart Sources (analyse, tri, lisibilité) | ✅ | ✅ | ✅ | ⏳ |
| Bibliothèque, progression, reprise, épisode suivant | ✅ | ✅ | ✅ | 🟡 reprise, synchro et proposition d'épisode suivant OK sur un vrai contenu (build 8) ; encart pendant le générique à confirmer |
| Lecteur (AetherEngine + AVPlayer), jalons, chien de garde | ✅ | ✅ | ⏳ tests d'interface sur simulateur (indicatifs) | 🟡 clips de test embarqués signalés fonctionnels (build 6) ; télécommande, changement de piste audio et sous-titres intégrés OK sur les clips (build 8) ; lecture d'un vrai film OK (build 8) ; avance/retour rapide maintenu et accéléré OK sur la Siri Remote (build 18) ; touches ⏪/⏩ d'une télécommande de TV non vérifiées ; sources réelles à qualifier plus largement |
| Interface « Aurore » (accueil, barre d'onglets en haut, nom Aurora, icône) | ✅ | ✅ | 🟡 3 tests d'interface sur 4 (simulateur) | 🟡 accueil fluide, menu en haut et icône OK (build 17) ; menus déroulants Films/Séries à confirmer (build 18) |
| Bandes-annonces muettes (fiches, accueil) via le service NAS `trailer-server/` | ✅ | ✅ | ✅ service testé avec yt-dlp simulé ; YouTube non joignable depuis l'environnement de développement | 🟡 service installé sur le DS224+ (Docker, `/health` OK) ; bande-annonce affichée sur une fiche et dans le bandeau de l'accueil (build 19) ; bande-annonce à la demande avec le son OK (build 21) |
| Carrousel Top Shelf (10 dernières sorties, titre incrusté par le NAS, extrait de 30 s) | ✅ | ✅ | ✅ cœur et service NAS (téléchargements simulés) | ✅ carrousel, titres, bandes-annonces et défilement OK (build 30, NAS DS224+) |
| Passer l'intro (TheIntroDB), note IMDb, heure de fin, bandeau qui défile | ✅ | ✅ | ✅ client TheIntroDB testé avec réponses simulées | ✅ validé par l'utilisateur (build 31) |
| Notes critiques (Wikidata), fiche série en deux colonnes, « Cette semaine », nouvel épisode, titres vus, AniSkip | ✅ | ✅ | ✅ clients testés avec réponses simulées ; 4/4 tests d'interface (simulateur) | ✅ validé par l'utilisateur (build 34) |
| Explorer avec panneau de détails, filtres de sources, finitions de fiche et de bandeau, titres et logos lisibles (Wikidata, Vision) | ✅ | ✅ | ✅ cœur testé (réponses simulées) ; 4/4 tests d'interface | ✅ validé par l'utilisateur (build 42) |
| CI GitHub Actions → IPA non signée + vérification | ✅ | ✅ | — | ✅ installée via atvloadly (builds 6, 8, 17 et 18) |

⏳ = pas encore exécuté ; 🟡 = validé partiellement sur l'appareil, d'après le retour de
l'utilisateur. Rien n'est déclaré « fonctionnel » sans exécution réelle.

Remarque atvloadly : la page d'installation peut rester bloquée à 100 % alors que l'installation a
abouti (vérifier la version dans Réglages › À propos). **Avant une mise à jour, ouvrir une autre
app sur l'Apple TV** : si le carrousel Top Shelf d'Aurora est affiché, l'installation bloque
(voir docs/DEPLOYMENT.md).

## Démarrage rapide

```bash
brew install xcodegen
xcodegen generate
open Lanterne.xcodeproj   # facultatif : la CI suffit
```

```bash
cd Packages/LanterneCore && swift test
```

Compilation et IPA : voir [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) (GitHub Actions, runner
`xcode-27`, installation via atvloadly).

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — modules, focus, cycle de vie du lecteur, persistance
- [docs/PLAYER-ENGINE.md](docs/PLAYER-ENGINE.md) — comparaison des moteurs, décision, jalons, formats
- [docs/STREMIO-API.md](docs/STREMIO-API.md) — protocole addon, API de compte non officielle, risques
- [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) — CI, IPA, atvloadly, mises à jour sans perte
- [docs/SECURITY.md](docs/SECURITY.md) — secrets, journaux, ATS, données non fiables
- [docs/QA-DEVICE-CHECKLIST.md](docs/QA-DEVICE-CHECKLIST.md) — qualification sur l'Apple TV
- [docs/ROADMAP.md](docs/ROADMAP.md) — phases et risques

## Structure

```
App/                  application tvOS (SwiftUI + lecteur UIKit)
  Sources/            App, Design, Home, Discover, Search, Detail, Sources, Library, Settings, Player, Platform
  Resources/          Assets.xcassets (icônes en couches), TestMedia (clips de test générés)
  UITests/            tests d'interface (focus, retour, cycle du lecteur)
Packages/LanterneCore logique métier testable (SwiftPM, sans UI)
scripts/              IPA (empaquetage, vérification, signature optionnelle), icônes, récepteur de journaux
project.yml           projet XcodeGen
.github/workflows/    CI
```

## Licences tierces

AetherEngine (LGPL-3.0 + exception App Store) et ses dépendances FFmpeg (LGPL), liés
dynamiquement. Clips de test : mires générées avec FFmpeg (`testsrc2`, `sine`).
