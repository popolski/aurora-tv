# Sécurité

## Secrets

| Secret | Où | Jamais |
|---|---|---|
| Jeton de session Stremio (`authKey`) | Trousseau (`kSecAttrAccessibleAfterFirstUnlock`) | journalisé, stocké en clair, envoyé ailleurs qu'à `api.strem.io` |
| Mot de passe Stremio | nulle part (envoyé une fois à `login`) | conservé |
| URL d'addons configurés (peuvent contenir des clés de services tiers) | Trousseau | journalisées en clair (expurgées : chemins longs masqués) |
| Certificats/profils (signature optionnelle) | Secrets GitHub chiffrés, trousseau temporaire détruit en fin de job | dans le dépôt ou les artefacts |

## Journaux

Toute ligne passe par `Redactor` avant stockage : valeurs `authKey/password/token/apikey…`,
en-têtes `Bearer`, segments d'URL longs ou encodés, valeurs de requête. Les journaux du moteur
de lecture passent aussi par ce filtre.

## Données externes non fiables

Réponses d'addons et de l'API : taille plafonnée (lecture en flux, arrêt au-delà de la limite),
délai global par requête, décodage tolérant, URL d'images/flux limitées à `http(s)`, en-têtes
fournis par les addons filtrés (`Host`, `Content-Length`, `Connection`… interdits ; CR/LF refusés),
identifiants de torrent validés (40 hex).

## App Transport Security

`NSAllowsArbitraryLoads = true` dans l'Info.plist, **justifié** : les addons sont choisis par
l'utilisateur et une partie des médias (serveur de streaming local, certains hébergeurs) est servie
en HTTP ; AetherEngine télécharge les médias via `URLSession`, donc l'exception « médias seuls »
d'AVFoundation ne suffit pas.

Ce réglage **ne désactive pas la validation TLS** : toute connexion HTTPS reste vérifiée
normalement. En complément, le code impose HTTPS pour les manifestes et ressources d'addons et pour
l'API Stremio, sauf adresses de réseau local (IP privées, `.local`, `.lan`, Tailscale/CGNAT).

## Ce qui n'est pas protégé

- atvloadly n'a pas d'authentification : ne pas l'exposer hors du réseau local.
- Le récepteur de journaux (`scripts/log-receiver.py`) n'a pas d'authentification : réseau local
  uniquement, journaux déjà expurgés.

## Services tiers contactés par l'app

| Service | Quand | Données envoyées |
|---|---|---|
| Addons Stremio choisis par l'utilisateur | navigation, lecture | identifiants de contenu (IMDb…), filtres |
| API de compte Stremio | connexion, synchronisation | identifiants de connexion, jeton de session (Trousseau) |
| TheIntroDB (`api.theintrodb.org`, API v4, sans clé) | début de lecture, si « Passer l'intro » est activé | identifiant IMDb/TMDB, saison, épisode, durée — aucune donnée de compte |
| Wikidata (`query.wikidata.org`, sans clé) | fiche (notes de la critique) ; catalogues contenant des titres non latins ; filmographie d'une personne (à la demande) | identifiants IMDb et Wikidata seulement — les noms ne sont jamais insérés dans les requêtes |
| TMDB (`api.themoviedb.org`), **depuis le service du NAS uniquement**, clé de l'utilisateur dans `.env` sur le NAS | première demande de bande-annonce d'une fiche (choix VF / VOSTFR / VO, gardé 7 jours) | identifiant IMDb ou TMDB de la fiche — la clé n'est jamais journalisée ni versionnée |
| Cinemeta (`v3-cinemeta.strem.io`) | rafraîchissement du Top Shelf | aucune (catalogue public) |
| Service aurora-trailers (NAS, réseau local) | bandes-annonces, images du Top Shelf | identifiants YouTube, adresses d'images publiques |

Les réponses de TheIntroDB sont traitées comme non fiables : seuls des nombres sont lus,
et un minutage aberrant ne peut que déplacer la lecture dans la vidéo en cours.

## Sauvegarde des réglages sur le NAS

Le service du NAS n'a pas d'authentification (réseau local uniquement). Aurora n'y dépose donc
que ses réglages (`AppSettings`) : jamais la session du compte Stremio (trousseau), ni les
adresses d'addons (qui peuvent contenir des clés de débrideur), ni la bibliothèque. Le service
refuse ce qui n'est pas une sauvegarde d'Aurora, limite la taille à 256 Ko et garde les 10
dernières. À la restauration, l'adresse du NAS actuelle est conservée.
