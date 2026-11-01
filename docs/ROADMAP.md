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

## Améliorations envisagées (non commencées)

Image de fond animée sur la fiche, bande-annonce, « Now Playing » système (Siri, autres
télécommandes), rendu libass complet (si nécessaire), profils multiples, mise à jour OTA via
source atvloadly, Top Shelf dynamique.
