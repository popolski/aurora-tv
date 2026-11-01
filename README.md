# Lanterne

Client Stremio natif pour Apple TV (tvOS 18+, conçu pour l'Apple TV 4K sous tvOS 27).
Interface SwiftUI sombre et ambrée, navigation pensée pour la Siri Remote, addons Stremio,
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
| Bibliothèque, progression, reprise, épisode suivant | ✅ | ✅ | ✅ | ⏳ |
| Lecteur (AetherEngine + AVPlayer), jalons, chien de garde | ✅ | ✅ | ⏳ tests d'interface sur simulateur (indicatifs) | 🟡 clips de test embarqués signalés fonctionnels (build 6) ; sources réelles à qualifier |
| CI GitHub Actions → IPA non signée + vérification | ✅ | ✅ | — | ✅ installée via atvloadly (build 6) |

⏳ = pas encore exécuté ; 🟡 = validé partiellement sur l'appareil, d'après le retour de
l'utilisateur. Rien n'est déclaré « fonctionnel » sans exécution réelle.

Remarque atvloadly : la page d'installation peut rester bloquée à 100 % alors que l'installation a
abouti (vérifier la version dans Réglages › À propos).

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
