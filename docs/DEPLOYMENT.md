# Compilation, signature et installation via atvloadly

## Chaîne complète

```
push GitHub ──► Actions (runner « xcode-27 », macOS ARM64, Xcode 27.1, SDK tvOS 27.0)
                 ├─ swift test (LanterneCore)
                 ├─ xcodegen → xcodebuild (Release, generic/platform=tvOS, arm64, non signé)
                 ├─ scripts/package-ipa.sh  → Lanterne-<version>-<build>-unsigned.ipa
                 ├─ scripts/verify-ipa.sh   → contrôle arm64/tvOS de chaque binaire, plist, ressources
                 ├─ (option) scripts/sign-ipa.sh si secrets de signature présents
                 └─ artefacts : IPA + SHA256SUMS, journaux, dSYM
                 └─ tests d'interface sur simulateur tvOS (indicatifs)
Téléchargement de l'IPA ──► atvloadly (NAS) ──► signature Apple ID ──► Apple TV « Chambre »
```

Aucun Mac n'est nécessaire. Le projet Xcode n'est pas versionné : il est généré par XcodeGen à
partir de `project.yml`.

## Pourquoi une IPA non signée

atvloadly (v0.8.2, moteur PlumeImpactor) **signe lui-même** l'IPA avec l'Apple ID configuré, crée
le profil pour l'Apple TV appairée et **rafraîchit automatiquement** l'application. La CI n'a donc
besoin d'**aucun** certificat ni mot de passe : rien de sensible dans le dépôt ni dans les
secrets GitHub.

Les binaires embarqués (FFmpeg et dépendances d'AetherEngine) sont des frameworks dynamiques ;
atvloadly les re-signe avec l'application.

## Installation (première fois)

1. GitHub › Actions › dernière exécution verte de « Build » › artefact
   `Lanterne-<version>-<build>` → télécharger et dézipper : on obtient
   `Lanterne-…-unsigned.ipa` (vérifier l'empreinte avec `SHA256SUMS.txt`).
2. Interface web d'atvloadly › Apple TV « Chambre » › sélectionner l'IPA › **Install**.
3. Lancer Lanterne sur l'Apple TV. Premier test conseillé : Réglages › Diagnostics › Tester le
   lecteur.

Alternative : publier une version (`git tag v0.1.0 && git push --tags`) crée une *Release* GitHub
contenant l'IPA. atvloadly sait suivre une source « GitHub releases » et proposer les mises à jour,
**si l'URL de l'IPA lui est accessible** (dépôt public, ou téléchargement manuel puis import).

## Mises à jour sans perte de données

Une mise à jour remplace l'application **sans effacer** ses données si et seulement si :

- l'identifiant de bundle final est identique : atvloadly en mode Apple ID **modifie**
  l'identifiant (FAQ du projet) — il faut donc toujours installer avec **le même atvloadly et le
  même Apple ID**, sans « identifiant personnalisé » différent ;
- l'équipe de signature (Team ID de l'Apple ID) est la même : sinon le trousseau (jeton Stremio,
  adresses d'addons) n'est plus accessible et l'app se comporte comme une nouvelle installation.

Ce qui est conservé et où :

| Donnée | Stockage | Survit à une mise à jour | Survit à une réinstallation |
|---|---|---|---|
| Jeton Stremio, adresses d'addons | Trousseau | ✅ (même équipe) | généralement ✅ |
| Réglages, progression récente (150 derniers éléments), modifications non envoyées | `UserDefaults` (persistant, ~500 Ko garantis sur tvOS) | ✅ | ❌ |
| Bibliothèque complète, manifestes, images | `Library/Caches` (purgeable par tvOS) | ✅ sauf purge | ❌ |

Si tvOS purge le cache, la bibliothèque est restaurée depuis la copie de secours puis complétée
par la synchronisation Stremio. Connecté à un compte, la bibliothèque est de toute façon
sauvegardée côté Stremio.

Le numéro de build (`CFBundleVersion`) est le numéro d'exécution GitHub : il croît à chaque
compilation, ce qu'exige tvOS pour une mise à jour.

## Limites des comptes Apple

- **Apple ID gratuit** : application valable 7 jours (atvloadly la rafraîchit automatiquement si
  l'Apple TV est joignable), 3 applications actives au maximum, quelques certificats partagés
  entre tous les outils de sideload. Aucune capacité payante (iCloud, etc.) — Lanterne n'en
  demande aucune.
- **Compte développeur payant** : profil d'un an. Option : fournir un certificat `.p12` et un
  profil tvOS listant l'UDID de l'Apple TV comme secrets GitHub (`SIGN_P12_BASE64`,
  `SIGN_P12_PASSWORD`, `SIGN_PROFILE_BASE64`) : la CI produira aussi une IPA signée, à importer
  dans atvloadly en mode « certificat » (non rafraîchie automatiquement). Ne jamais committer ces
  fichiers. Un profil expiré est refusé par le script.

## API d'atvloadly

atvloadly expose une API HTTP (`POST /api/install`, `/healthcheck`, serveur MCP `/mcp`) **sans
authentification**. Une installation automatisée depuis la CI supposerait d'exposer le NAS à
Internet : ce n'est **pas** fait ni recommandé. L'installation reste une action manuelle depuis
le réseau local.

## Journaux en cas d'échec

- Compilation : artefact `build-logs-<n>` (`build.log`, `resolve.log`, dSYM) + résumé des erreurs
  dans la page de l'exécution.
- Tests : artefacts `core-tests-log` et `ui-tests-<n>` (`.xcresult`).
- Sur l'Apple TV : Réglages › Diagnostics › journaux à l'écran, ou envoi vers
  `scripts/log-receiver.py` lancé sur le NAS (voir l'en-tête du script pour Docker).
