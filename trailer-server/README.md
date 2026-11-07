# aurora-trailers

Petit service à installer sur le NAS : il fournit à l'app Aurora les bandes-annonces
lues en fond, sans le son, sur les fiches et dans le bandeau de l'accueil, ou en plein écran avec le son à la demande.

Les addons Stremio ne donnent que des identifiants YouTube, que l'Apple TV ne sait pas
lire directement. Le service télécharge la piste vidéo de la bande-annonce avec
[yt-dlp](https://github.com/yt-dlp/yt-dlp) (H.264 et AAC, 1080p au plus), la garde
en cache et la sert à l'Apple TV. La première demande d'une bande-annonce prend quelques
secondes ; ensuite elle part immédiatement.

Il compose aussi les images du carrousel Top Shelf avec le titre du film incrusté
(`/topshelf/<id>.jpg`) : l'Apple TV n'a pas assez de mémoire pour le faire elle-même. Seules
des images HTTPS d'hôtes connus (metahub, TMDB, IMDb, TheTVDB, fanart.tv) sont téléchargées
(variable `TOPSHELF_IMAGE_HOSTS`). Police : Manrope (SIL Open Font License, `fonts/`).

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

## Bandes-annonces en français

Les addons (Cinemeta) ne donnent en général que la bande-annonce originale. Avec une clé
[TMDB](https://www.themoviedb.org/settings/api) (gratuite), le service choisit pour chaque
fiche la bande-annonce **VF**, sinon **VOSTFR**, sinon la **VO** de l'addon. Il s'appuie
sur la langue et le titre des vidéos répertoriées par TMDB (« Bande-annonce VF »,
« … VOSTFR ») ; le choix est gardé 7 jours en cache. Sans clé, rien ne change.

La clé est un secret : elle va dans un fichier `.env` sur le NAS, à côté de
`compose.yaml`, jamais dans le dépôt ni dans `compose.yaml`. En SSH, dans le dossier du
service (la saisie reste invisible) :

```bash
sudo bash -c 'read -rs -p "Clé TMDB : " K; echo; printf "TMDB_API_KEY=%s\n" "$K" > .env; chmod 600 .env'
```

puis `sudo docker compose up -d --build`. La clé v3 (« Clé d'API ») et le jeton de
lecture v4 (« Jeton d'accès en lecture », commence par `eyJ`) conviennent. Elle n'apparaît
jamais dans les journaux du service. Vérification : `http://<ip-du-nas>:8787/health`
indique `"localized": true`, et
`http://<ip-du-nas>:8787/resolve/tt0111161.json?type=movie` donne la langue choisie pour
« Les Évadés ».

## Découverte (TMDB)

Avec la même clé TMDB, le service fournit aussi à Aurora :

- `GET /tmdb/recommendations/<fiche>.json?type=movie|series` : titres proches (« Parce que
  vous avez regardé… ») ;
- `GET /tmdb/collection/<fiche>.json` : saga d'un film selon TMDB, quand Wikidata n'en connaît pas.

Chaque titre TMDB est converti en identifiant IMDb (`/external_ids`, correspondance gardée) ;
réponses gardées 3 jours dans `/cache/discovery.json`. Sans clé : erreur 503, Aurora n'affiche
simplement pas ces rangées.

## Sauvegarde des réglages d'Aurora

Réglages › Sauvegarde, dans l'app, dépose une copie des réglages sur ce service
(`POST /backup`) et la restaure (`GET /backup/latest.json`). Les 10 dernières sont gardées
dans le volume du cache (`/cache/backups`). Uniquement des réglages : ni compte, ni addons,
ni bibliothèque. Liste : `http://<ip-du-nas>:8787/backup/list.json`.

## Mise à jour de yt-dlp

YouTube change régulièrement ; si les bandes-annonces ne se chargent plus, il faut la
dernière version de yt-dlp :

1. Dans `compose.yaml`, changer la date de `YTDLP_REFRESH` (par exemple la date du jour).
2. Reconstruire : Container Manager › Projet › aurora-trailers › *Action › Construire*,
   ou en SSH : `sudo docker compose up -d --build`.

Seule l'étape yt-dlp est refaite (environ une minute). Éviter `--no-cache` : cela referait
aussi l'installation de ffmpeg, qui a pris près de 30 minutes sur un DS224+ lors de la
première installation (téléchargements Debian lents depuis le NAS).

## Réglages (variables d'environnement)

| Variable | Défaut | Rôle |
|---|---|---|
| `CACHE_MAX_MB` | `4000` | Taille maximale du cache ; les bandes-annonces les moins vues sont supprimées |
| `MAX_HEIGHT` | `1080` | Hauteur maximale de la vidéo |
| `MAX_PARALLEL` | `2` | Téléchargements simultanés |
| `WAIT_SECONDS` | `120` | Attente maximale d'une demande pendant le premier téléchargement |
| `PREVIEW_START` | `5` | Début de l'extrait du carrousel (s), après les logos des studios |
| `PREVIEW_SECONDS` | `30` | Durée de l'extrait du carrousel Top Shelf (s) |
| `FAILURE_TTL` | `21600` | Durée (s) pendant laquelle une bande-annonce introuvable n'est pas redemandée |
| `TMDB_API_KEY` | vide | Clé TMDB pour les bandes-annonces en français (fichier `.env`, voir plus haut) |

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
python3 -m unittest -v test_server test_topshelf test_localize test_discovery
```

Les tests remplacent yt-dlp et TMDB par des imitations : ils ne vérifient pas l'accès réel à
YouTube ni à TMDB, qui ne peut être constaté que sur le NAS (`/health`, `/resolve/…`, puis
une fiche dans l'app).
