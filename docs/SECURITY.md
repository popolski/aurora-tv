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
