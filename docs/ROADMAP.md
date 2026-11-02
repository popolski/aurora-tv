# Feuille de route et risques

## Phases

| Phase | Contenu | État |
|---|---|---|
| 1. Recherche et conception | tvOS, API Stremio (code de stremio-core), moteurs vidéo, runners GitHub, atvloadly, architecture | ✅ fait (docs/) |
| 2. Fondations | dépôt, XcodeGen, CI (tests, IPA, vérification), interface, navigation, réglages, journaux | ✅ écrit — ⏳ première compilation CI |
| 3. Stremio | addons, catalogues, recherche, fiches, sources, compte, synchronisation | ✅ écrit — ⏳ compilation, ⏳ tests réels contre strem.io |
| 4. Lecture | AetherEngine + AVPlayer, jalons, chien de garde, clips de test | ✅ écrit — ⏳ compilation, ⏳ **qualification Apple TV** |
| 5. Expérience | bibliothèque, reprise, Smart Sources, sous-titres, préférences, épisode suivant | ✅ écrit — ⏳ qualification |
| 6. Stabilisation | corrections issues de la CI et de l'appareil, performances mesurées, documentation | à venir |

Ordre de travail recommandé après la première compilation verte :
1. Installer, exécuter la section B de la procédure (clips embarqués) → valide la chaîne
   moteur/affichage sans dépendre d'aucun addon.
2. Connexion au compte + section C avec les addons réels.
3. Sections D à F, puis corrections.

## Risques principaux

| Risque | Impact | Probabilité | Parade |
|---|---|---|---|
| Erreurs de compilation au premier passage (code écrit sans compilateur Swift disponible dans l'environnement de travail) | retard | **élevée** | itérations CI rapides ; erreurs résumées dans la page d'exécution |
| Régression ou changement d'API d'AetherEngine | lecture | moyenne | version exacte ; abstraction `PlaybackEngine` ; moteur AVPlayer de repli |
| API de compte Stremio non officielle modifiée | connexion/synchro | faible à moyenne | erreurs explicites ; app utilisable sans compte |
| Format réel de `state.watched` différent de l'implémentation de référence | épisodes vus | faible | vecteur de test JS ; champ conservé intact s'il ne se décode pas |
| Signature Apple ID gratuite (7 jours, 3 apps) | disponibilité | moyenne | rafraîchissement atvloadly ; compte payant possible |
| Purge du cache par tvOS | bibliothèque locale | faible | copie de secours `UserDefaults` + synchro Stremio |
| Dolby Vision sur téléviseur non compatible | image | selon matériel | option d'assertion désactivée par défaut, à qualifier |

## Demandes notées (01/11/2026) — bandes-annonces et Top Shelf

Demande : bandes-annonces lues en fond, sans le son, sur les fiches ; carrousel des dernières
sorties sur l'écran d'accueil de l'Apple TV, titre dans la typographie du film, bande-annonce
lancée après quelques secondes, sans le son.

### Faisabilité

| Élément | Faisable ? | Détail |
|---|---|---|
| Lecture muette en boucle sur la fiche (et le bandeau d'accueil) | ✅ techniquement simple | `AVPlayer` muet en couche de fond, démarrage après ~3 s de focus, arrêt dès qu'on quitte ; fondu depuis l'image de fond |
| Carrousel sur l'écran d'accueil tvOS (Top Shelf) | ✅ | extension `TVTopShelfContentProvider`, style `TVTopShelfCarouselContent` : image plein écran, titre, résumé, durée, genres, boutons Lire/Fiche (liens profonds), et `previewVideoURL` que **tvOS lance lui-même, sans le son, après quelques secondes** |
| Titre « dans la typo du film » sur le Top Shelf | 🟡 partiel | le système affiche le titre avec sa propre police ; possibilité : incruster le logo du film (fourni par les addons de métadonnées) directement dans l'image du carrousel, à vérifier visuellement |
| **Source des bandes-annonces** | ⚠️ **point bloquant** | Cinemeta et TMDB ne fournissent que des identifiants **YouTube**. Aucune API officielle ne donne de flux vidéo direct (MP4/HLS) pour YouTube ; extraire le flux contourne les conditions d'utilisation de YouTube et casse régulièrement. Les bandes-annonces Apple (trailers.apple.com) n'existent plus. |

### Options pour la source (à décider)

1. Service d'extraction auto-hébergé sur le NAS (du type yt-dlp → URL directe) appelé par
   Lanterne : fonctionne techniquement, fragile, contraire aux conditions de YouTube — à décider
   par l'utilisateur, non activé par défaut.
2. N'utiliser que les bandes-annonces disponibles en vidéo directe (rares : certains addons ou
   Vimeo) — couverture faible.
3. Sans vidéo : Top Shelf avec images et logos seulement (aucune dépendance douteuse).

### Décision (01/11/2026) : option 1

L'utilisateur a choisi le service auto-hébergé sur le NAS. État :

- **Étape 1, faite (build 19)** : service `trailer-server/` (yt-dlp, cache, plages HTTP,
  Docker) ; bande-annonce muette en fond sur les fiches et dans le bandeau de l'accueil,
  après un délai réglable ; préparation anticipée des bandes-annonces probables ; réglages
  *Réglages › Bandes-annonces*. Testé : service avec yt-dlp simulé (tests Python), conversion
  ffmpeg d'un MP4 fragmenté. Validé sur l'appareil : service installé sur le NAS (DS224+), téléchargement
  réel depuis YouTube et bandes-annonces affichées sur une fiche et dans le bandeau de
  l'accueil (build 19).
- **Étape 2 (builds 23 à 27)** — constaté sur l'appareil : carrousel affiché après
  redémarrage (build 26) ; atvloadly attribue un groupe d'apps renommé (suffixe d'équipe,
  en double côté app), d'où le choix du groupe commun aux deux profils. Titre incrusté :
  composé par l'extension (builds 27-29) → carrousel vide (mémoire), puis aucun titre ;
  depuis le build 30, image composée par le service du NAS (`/topshelf/<id>.jpg`, Pillow,
  hôtes d'images autorisés seulement). Extrait de 30 s pour accélérer le défilement.
  **Validé sur l'appareil (build 30)** : carrousel avec titres, bandes-annonces et
  passage automatique au film suivant. Le défilement automatique du carrousel est géré par tvOS (aucune API
  de réglage). Détail initial : : extension Top Shelf `AuroraTopShelf` : carrousel des
  10 dernières sorties de films (Cinemeta, année en cours puis précédente), image plein
  écran, titre, résumé, genres, durée, réalisation, distribution, boutons Lire / Plus d'infos
  (liens `aurora://`), bande-annonce muette lancée par tvOS (`previewVideoURL` vers le NAS).
  L'adresse du NAS passe par un groupe d'apps dont le nom réel est lu dans le profil de
  provisionnement (atvloadly peut le renommer) ; sans groupe utilisable, carrousel en images
  seules. Pseudo-signature ad hoc (`scripts/fakesign.sh`) pour inscrire les droits avant
  la re-signature par atvloadly. À valider sur l'appareil : installation par atvloadly avec
  un Apple ID gratuit, affichage du carrousel, bandes-annonces.

### Contraintes de distribution

- Une extension Top Shelf est un second exécutable signé : un identifiant d'application de plus
  sur l'Apple ID (limite des comptes gratuits : 10 identifiants par semaine). atvloadly conserve
  les extensions par défaut ; à vérifier sur l'appareil.
- Partager des données entre l'app et l'extension demande un groupe d'applications (App Group),
  capacité pas toujours disponible en signature gratuite ; alternative : l'extension interroge
  elle-même le catalogue (Cinemeta « dernières sorties »).
- Le Top Shelf n'apparaît que si Lanterne est dans la rangée du haut de l'écran d'accueil.

## Améliorations envisagées (non commencées)

Image de fond animée sur la fiche, « Now Playing » système (Siri, autres
télécommandes), rendu libass complet (si nécessaire), profils multiples, mise à jour OTA via
source atvloadly, Top Shelf dynamique.

## Idées en attente (proposées le 02/11/2026)

Ordre recommandé : 1, 2, 3, puis 4 et 6, puis le reste.

1. ✅ Minuteur de mise en veille (fin de l'épisode ou du film, 15 à 90 min, fondu « Bonne
   nuit » annulable par n'importe quelle touche) — implémenté (build 48), à valider sur
   l'appareil.
2. ✅ « Êtes-vous toujours là ? » après N épisodes enchaînés sans interaction (3 par défaut,
   réglable, 0 = jamais) — implémenté (build 48), à valider sur l'appareil.
3. ✅ Synchroniser les sous-titres en choisissant la réplique entendue (lecture en pause,
   répliques à ±30 s, AetherEngine et sous-titres texte) — implémenté (build 48), à valider
   sur l'appareil.
4. Épisode suivant préparé pendant le générique (sources cherchées à l'avance).
5. Infos techniques du flux (résolution, codec, HDR, débit, images perdues, pairs).
6. Filmographie depuis les puces « Avec » / « Réalisation » (Wikidata).
7. Sagas sur la fiche (Wikidata, ordre, déjà vus).
8. « Je ne sais pas quoi regarder » (tirage dans Ma liste, filtre de durée).
9. Top Shelf au choix : nouveautés ou « Continuer à regarder ».
10. Sauvegarde des réglages d'Aurora sur le NAS (restauration en un clic).

Écarté : vignettes d'aperçu dans la barre de progression (non fournies par le moteur).
