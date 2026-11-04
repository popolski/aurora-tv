# État du projet

Chaque fonction est évaluée sur quatre niveaux, distincts : **implémentée** (le code existe),
**compilée** (la CI produit l'IPA), **testée automatiquement** (tests unitaires ou d'interface),
**validée sur l'Apple TV** (constatée par l'utilisateur sur l'Apple TV « Chambre », Apple TV 4K
3e génération, tvOS 27.2). Rien n'est déclaré validé sans retour réel.

✅ fait · 🟡 partiel · ⏳ pas encore vérifié · — sans objet

Dernière mise à jour : 4 novembre 2026, build 50.

| Fonction | Implémentée | Compilée | Testée automatiquement | Validée sur l'Apple TV |
|---|---|---|---|---|
| Protocole des addons (manifestes, catalogues, fiches, sources, sous-titres) | ✅ | ✅ | ✅ tests unitaires (réponses simulées) | ✅ usage quotidien (catalogues, fiches, sources) ; addon auto-hébergé sur le NAS (HTTPS, lien de lecture redirigé vers le débrideur) lu sur l'appareil (build 50) |
| Compte Stremio (code QR, e-mail), synchronisation des addons et de la bibliothèque | ✅ | ✅ | ✅ simulé | ✅ connexion et synchro (build 6), bibliothèque et reprise |
| Sources : analyse, tri, lisibilité estimée, filtres à compteurs | ✅ | ✅ | ✅ | ✅ filtres (build 42) |
| Bibliothèque, progression, reprise, épisode suivant | ✅ | ✅ | ✅ | ✅ reprise et synchro (build 8) ; 🟡 encart au début du générique (dépend des minutages TheIntroDB) |
| Lecteur (AetherEngine + repli AVPlayer), jalons, chien de garde | ✅ | ✅ | ✅ tests d'interface sur simulateur | ✅ clips de test (build 6), pistes audio et sous-titres (build 8), films réels (build 8) ; ⏳ HDR10 / Dolby Vision / Atmos à qualifier |
| Télécommande : sauts, défilement accéléré, touches ⏪/⏩ | ✅ | ✅ | — | ✅ (builds 18 et 19) |
| Passer l'intro (TheIntroDB, AniSkip), heure de fin | ✅ | ✅ | ✅ réponses simulées | ✅ (build 31) |
| Interface « Aurore » : accueil, barre d'onglets en haut, nom et icône | ✅ | ✅ | ✅ 4/4 tests d'interface | ✅ (builds 17 à 34) |
| Accueil : bandeau qui défile, « Cette semaine », « Nouvel épisode », pastilles « Au cinéma » et IMDb | ✅ | ✅ | ✅ | ✅ (builds 22 à 34) |
| Films / Séries : trois catalogues, menus déroulants, panneau de détails | ✅ | ✅ | ✅ | ✅ (builds 18 et 42) |
| Fiches : notes critiques (Wikidata), groupes de puces, épisodes en panneau | ✅ | ✅ | ✅ réponses simulées | ✅ (builds 34 à 42) |
| Titres et logos lisibles (Wikidata, Vision) | ✅ | ✅ | ✅ réponses simulées | ✅ (build 42) |
| Bandes-annonces en français (VF > VOSTFR > VO, TMDB, clé sur le NAS) | ✅ | ✅ (build 52) | ✅ service testé avec TMDB simulé | 🟡 service du NAS : vraie réponse TMDB, VF trouvée pour « Les Évadés » ; ⏳ lecture dans Aurora |
| Bandes-annonces (fond muet, plein écran avec le son) via le service NAS | ✅ | ✅ | ✅ service testé avec yt-dlp simulé | ✅ (builds 19 et 21, NAS DS224+) |
| Carrousel Top Shelf (dernières sorties, titres, extraits) | ✅ | ✅ | ✅ cœur et service NAS | ✅ (build 30) |
| Minuteur de mise en veille, « Êtes-vous toujours là ? » | ✅ | ⏳ | ✅ logique (minuteur, compteur, réglage) | ⏳ |
| Synchronisation des sous-titres par réplique entendue | ✅ | ⏳ | ✅ calcul du décalage et choix des répliques | ⏳ |
| Films déjà vus estompés ou masqués | ✅ | ✅ | — | ✅ (build 34) |
| CI GitHub Actions → IPA non signée vérifiée, installation par atvloadly | ✅ | ✅ | — | ✅ (une quarantaine de builds installés) |
| Captures d'écran automatiques (mode démo) | ✅ | ✅ | ✅ simulateur | — |

## Limites connues

- **HDR10, Dolby Vision, Atmos, DTS-HD MA, TrueHD, PGS** : attendus d'après le moteur, pas
  encore qualifiés sur l'appareil ([QA-DEVICE-CHECKLIST.md](QA-DEVICE-CHECKLIST.md)).
- **Mode nuit et dialogues** : le moteur ne permet pas de traiter le son ; Aurora renvoie aux
  réglages natifs de l'Apple TV (« Réduire les sons forts », « Améliorer les dialogues »).
- **Installation** : ouvrir une autre app avant une mise à jour (sinon atvloadly reste bloqué à
  100 %) ; compte Apple gratuit = re-signature tous les 7 jours par atvloadly.
- **Torrents** : uniquement via un serveur de streaming Stremio externe (aucun moteur torrent
  intégré).
- **Logos** : un logo très stylisé d'un film dont l'addon n'indique pas l'origine peut rester
  affiché dans son écriture d'origine.
