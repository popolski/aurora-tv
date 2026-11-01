# Compatibilité Stremio

Deux interfaces très différentes :

1. **Le protocole des addons** — public, documenté (`Stremio/stremio-addon-sdk`), stable. Lanterne
   l'implémente sans dépendre d'aucun service Stremio.
2. **L'API de compte** (`api.strem.io`) — **non officielle, non documentée**. Lanterne l'utilise
   comme les applications officielles, d'après le code source de `Stremio/stremio-core`
   (branche `development`, commit du 28/10/2026). Elle peut changer sans préavis.

> ⚠️ L'environnement de développement de cette session n'avait **pas accès réseau** à
> `strem.io` : aucune requête réelle n'a été faite vers l'API de compte ni vers les addons
> officiels. Les tests utilisent des réponses simulées conformes aux types de `stremio-core`.
> L'intégration de compte est donc **implémentée mais non testée** contre le vrai serveur.

## Protocole addon (implémenté)

| Élément | Détail | Fichier |
|---|---|---|
| Manifeste | `id`, `version`, `name`, `types`, `resources` (forme courte/complète), `idPrefixes`, `catalogs` (forme `extra` et forme historique `extraRequired`/`extraSupported`), `behaviorHints` | `Addons/Manifest.swift` |
| URL de ressource | `<base>/<resource>/<type>/<id>[/<extra>].json`, encodage identique à `encodeURIComponent` (comme `AddonHTTPTransport` de stremio-core) | `Addons/AddonDescriptor.swift` |
| Catalogues | pagination `skip`, filtre `genre` (y compris obligatoire), recherche `search` | `Addons/AddonAggregator.swift` |
| Métadonnées | aperçu + fiche, `videos` dédupliquées et triées (saison 0 en dernier à l'affichage), `links` (Genres/Cast/Directors), note IMDb, bandes-annonces | `Addons/Meta.swift` |
| Flux | `url`, `ytId`, `infoHash`/`fileIdx`/`sources`, magnet, `externalUrl`, `playerFrameUrl`, archives ; `behaviorHints` (`proxyHeaders`, `bingeGroup`, `filename`, `videoSize`, `videoHash`, `notWebReady`) | `Addons/Stream.swift` |
| Sous-titres | ressource `subtitles` avec extras `videoHash`, `videoSize`, `filename` ; sous-titres embarqués dans les flux | `Addons/Stream.swift` |
| Plusieurs addons | requêtes concurrentes, délai par addon, résultats au fil de l'eau, annulation, cache LRU avec `cacheMaxAge` | `Addons/AddonClient.swift` |

Sécurité : réponses limitées en taille (1 à 8 Mo selon la ressource), délai global, décodage
tolérant (un élément invalide est ignoré), URL `http(s)` uniquement, HTTPS obligatoire hors réseau
local, en-têtes `proxyHeaders` filtrés (pas de `Host`, pas d'injection CR/LF).

## API de compte (implémentée, non testée en conditions réelles)

Toutes les méthodes : `POST https://api.strem.io/api/<méthode>`, corps JSON, réponse
`{"result": …}` ou `{"error": {"message", "code"}}`.

| Usage | Méthode | Corps | Réponse |
|---|---|---|---|
| Connexion | `login` | `{"type":"Login","email","password","facebook":false}` | `{"authKey","user"}` |
| Utilisateur | `getUser` | `{"type":"GetUser","authKey"}` | `User` |
| Déconnexion | `logout` | `{"type":"Logout","authKey"}` | — |
| Addons du compte | `addonCollectionGet` | `{"type":"AddonCollectionGet","authKey","update":true}` | `{"addons":[{"transportUrl","manifest","flags"}],"lastModified"}` |
| Index bibliothèque | `datastoreMeta` | `{"authKey","collection":"libraryItem"}` | `[[id, mtime_ms], …]` |
| Lecture bibliothèque | `datastoreGet` | `{"authKey","collection":"libraryItem","ids":[…],"all":bool}` | `[libraryItem, …]` |
| Écriture bibliothèque | `datastorePut` | `{"authKey","collection":"libraryItem","changes":[libraryItem, …]}` | `{"success":true}` |

**Connexion par code** (comme les applications TV officielles) :
`GET https://link.stremio.com/api/v2/create?type=Create` → `{"code","link","qrcode"}`, puis
interrogation de `GET …/api/v2/read?type=Read&code=…` jusqu'à obtenir `{"authKey"}`. La
réponse « pas encore validé » n'est pas documentée : Lanterne traite toute erreur d'API comme
« en attente » et abandonne après 5 minutes.

### `libraryItem`

Champs gérés : `_id`, `name`, `type`, `poster`, `posterShape`, `removed`, `temp`, `_ctime`,
`_mtime`, `state.{lastWatched, timeWatched, timeOffset, overallTimeWatched, timesWatched,
flaggedWatched, duration, video_id, watched, noNotif}` (durées en millisecondes).
**Tout champ inconnu est conservé et renvoyé à l'identique** lors d'un envoi.

Règles reprises de stremio-core : « vu » au-delà de 70 % de temps réellement regardé, générique à
90 %, « Continuer » si `(!removed || temp) && timeOffset > 0`, épisode suivant avec
`timeOffset = 1`, synchronisation des éléments non supprimés ou supprimés depuis moins d'un an.

Le champ `state.watched` (épisodes vus) est un bitfield compressé
(`{idAncre}:{longueur}:{base64(zlib)}`) ; Lanterne l'implémente d'après la bibliothèque JavaScript
de référence, avec un vecteur de test produit par cette bibliothèque. La compatibilité avec des
données réelles de compte reste **à valider**.

### Synchronisation

- Tirage incrémental (`datastoreMeta` puis `datastoreGet` des seuls éléments plus récents), repli
  sur un tirage complet.
- Le plus récent `_mtime` gagne ; une modification locale plus récente reste à envoyer.
- Envoi par lots de 50 après chaque lecture et à chaque synchronisation ; hors connexion, les
  modifications restent en attente (persistées) et partent à la synchronisation suivante.
- Les addons du compte remplacent ceux par défaut ; **Lanterne n'écrit jamais la collection
  d'addons du compte** (`addonCollectionSet` non utilisé) pour ne pas l'altérer par erreur ; les
  ajouts faits sur l'Apple TV restent locaux.

### Ce qui n'est pas repris

Notifications de nouveaux épisodes, statistiques de visionnage (`events`, `seekLog`), intégration
Trakt, profils multiples — non nécessaires au périmètre et/ou trop dépendants d'API non publiques.

## Sources torrent

tvOS ne sait pas lire un torrent et Lanterne n'embarque **aucun moteur torrent**. Un flux
`infoHash` n'est lisible que si l'utilisateur renseigne l'adresse d'un **serveur de streaming
Stremio** qu'il héberge (ex. conteneur Docker sur le NAS) ; l'URL est construite comme dans
stremio-core : `<serveur>/<infoHash>/<fileIdx | -1>?tr=…&f=…`. Sans serveur, ces sources sont
affichées « non lisibles » avec la raison.
