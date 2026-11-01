# aurora-trailers

Petit service à installer sur le NAS : il fournit à l'app Aurora les bandes-annonces
lues en fond, sans le son, sur les fiches et dans le bandeau de l'accueil.

Les addons Stremio ne donnent que des identifiants YouTube, que l'Apple TV ne sait pas
lire directement. Le service télécharge la piste vidéo de la bande-annonce avec
[yt-dlp](https://github.com/yt-dlp/yt-dlp) (H.264, 1080p au plus, sans le son), la garde
en cache et la sert à l'Apple TV. La première demande d'une bande-annonce prend quelques
secondes ; ensuite elle part immédiatement.

## Installation (Docker)

1. Copier ce dossier `trailer-server` sur le NAS (par exemple `/volume1/docker/aurora-trailers`).
2. Dans ce dossier :

   ```bash
   docker compose up -d --build
   ```

   Sur Synology, l'équivalent dans Container Manager : *Projet › Créer*, choisir ce
   dossier ; le fichier `compose.yaml` est repris tel quel.
3. Vérifier depuis un ordinateur du réseau : `http://<ip-du-nas>:8787/health` doit
   répondre `"ok": true` et indiquer une version de yt-dlp.
4. Sur l'Apple TV : *Réglages › Bandes-annonces*, saisir `http://<ip-du-nas>:8787`.

## Mise à jour de yt-dlp

YouTube change régulièrement ; si les bandes-annonces ne se chargent plus, reconstruire
l'image pour prendre la dernière version de yt-dlp :

```bash
docker compose build --pull --no-cache && docker compose up -d
```

## Réglages (variables d'environnement)

| Variable | Défaut | Rôle |
|---|---|---|
| `CACHE_MAX_MB` | `4000` | Taille maximale du cache ; les bandes-annonces les moins vues sont supprimées |
| `MAX_HEIGHT` | `1080` | Hauteur maximale de la vidéo |
| `MAX_PARALLEL` | `2` | Téléchargements simultanés |
| `WAIT_SECONDS` | `120` | Attente maximale d'une demande pendant le premier téléchargement |
| `FAILURE_TTL` | `21600` | Durée (s) pendant laquelle une bande-annonce introuvable n'est pas redemandée |

## Sécurité et limites

- **Réseau local uniquement.** Le service n'a pas d'authentification : ne redirigez pas
  son port depuis Internet.
- Seuls des identifiants au format YouTube (11 caractères) sont acceptés ; yt-dlp est
  appelé sans shell, avec une taille de fichier maximale.
- Le conteneur tourne avec un utilisateur non administrateur.
- Le téléchargement de vidéos YouTube n'est pas prévu par les conditions d'utilisation de
  YouTube. Ce service se limite aux bandes-annonces, à usage personnel, sur votre réseau.

## Tests

```bash
python3 -m unittest -v test_server
```

Les tests remplacent yt-dlp par un faux programme : ils ne vérifient pas l'accès réel à
YouTube, qui ne peut être constaté que sur le NAS (`/health`, puis une fiche dans l'app).
