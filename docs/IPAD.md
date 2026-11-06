# Aurora sur iPad

Aurora existe aussi en version iPad, construite à partir du même code que l'app Apple TV :
mêmes écrans, même compte Stremio, mêmes addons, même lecteur (AetherEngine).

## Ce qui change par rapport à l'Apple TV

- **Interface de la télévision, réduite à l'écran de l'iPad**, en **paysage uniquement**.
  Tout se fait au doigt : un appui ouvre une fiche, lance une source, etc.
- **Lecteur tactile** :
  - un appui sur la vidéo affiche ou masque les commandes ;
  - **✕** en haut à droite ferme le lecteur, la bulle ouvre **Audio et sous-titres**
    (panneau fermé par son bouton ✕) ;
  - au centre : **−10 s**, **lecture / pause**, **+10 s** ;
  - **faire glisser le doigt sur la barre de progression** pour se déplacer, relâcher pour y aller ;
  - « Passer l'intro » : toucher le bouton ;
  - pendant le fondu du minuteur (« Bonne nuit »), un appui annule l'arrêt.
- **Pas de carrousel Top Shelf** (il n'existe que sur l'Apple TV).
- Les zones qui suivent le focus de la télécommande (bandeau de l'accueil qui suit
  l'affiche sélectionnée, panneau de détails de Films / Séries) restent sur le premier
  élément : il suffit de toucher une affiche pour ouvrir sa fiche.

État : compilée et vérifiée par la CI depuis le build 60 (IPA, captures du simulateur en mode
démo de l'accueil, d'une fiche et des sources, publiées dans la Release
[« apercus-ipad »](https://github.com/popolski/aurora-tv/releases/tag/apercus-ipad)) ; le lecteur tactile n'apparaît pas sur ces captures ; **validée sur un
iPad réel** (build 60, installation avec Sideloadly) (voir [STATUS.md](STATUS.md)).

## Ce qu'il faut

- Un **iPad sous iPadOS 18 ou plus récent**.
- Un **PC Windows** (ou un Mac) et un **câble USB** pour la première installation.
- Un **compte Apple** (gratuit suffit). Conseil : utilisez **un autre compte Apple que
  celui d'atvloadly** ; avec un compte gratuit, une nouvelle signature peut révoquer le
  certificat utilisé par l'autre outil, et Aurora ne s'ouvrirait plus sur l'Apple TV
  avant la prochaine re-signature.

## Installation avec Sideloadly (Windows)

1. **Télécharger l'IPA iPad** : page
   [Releases](https://github.com/popolski/aurora-tv/releases), dernier `build-NN`, fichier
   **`Aurora-iPad-…-unsigned.ipa`** (et non `Aurora-…` sans « iPad », qui est pour l'Apple TV).
2. **Installer iTunes et iCloud pour Windows** depuis le site d'Apple (versions « hors
   Microsoft Store », indiquées sur le site de Sideloadly) : Sideloadly en a besoin pour
   communiquer avec l'iPad.
3. **Installer Sideloadly** depuis son site officiel, `sideloadly.io`.
4. **Brancher l'iPad** au PC en USB, le déverrouiller et répondre **« Se fier »** à
   « Se fier à cet ordinateur ? ».
5. Dans Sideloadly :
   - glisser le fichier `Aurora-iPad-…-unsigned.ipa` dans la fenêtre ;
   - choisir l'iPad dans la liste des appareils ;
   - saisir l'adresse du compte Apple, puis **Start** ; le mot de passe et, le cas échéant,
     le code de validation en deux étapes sont demandés par Sideloadly.
6. **Sur l'iPad, autoriser l'app** :
   - *Réglages › Confidentialité et sécurité › Mode développeur* : activer, redémarrer
     l'iPad, puis confirmer « Activer » au redémarrage (une seule fois) ;
   - *Réglages › Général › VPN et gestion de l'appareil* : toucher le compte Apple utilisé
     et **« Faire confiance »**.
7. **Ouvrir Aurora** :
   - accepter l'accès au **réseau local** (nécessaire pour le NAS : bandes-annonces,
     addons hébergés chez vous) ;
   - Réglages › Compte : connexion par **code QR** ou e-mail, comme sur l'Apple TV ;
     les addons, la bibliothèque et la progression se synchronisent ;
   - Réglages › Bandes-annonces : `http://192.168.1.120:8787`.

### Renouvellement tous les 7 jours (compte Apple gratuit)

Avec un compte gratuit, la signature expire au bout de 7 jours : l'app ne s'ouvre plus
tant qu'elle n'est pas re-signée. Les données (connexion, réglages, bibliothèque) sont
conservées.

- **Le plus simple** : rebrancher l'iPad et relancer l'installation dans Sideloadly.
- **Automatique** : dans Sideloadly, activer le rafraîchissement automatique (option
  « Automatic refresh », avec le Wi-Fi et l'appareil reconnus par iTunes) ; le PC doit
  être allumé et sur le même réseau que l'iPad.
- Un compte développeur payant (99 €/an) porte la durée à un an.

### Mettre à jour Aurora

Installer le nouvel IPA iPad par-dessus, de la même façon : les réglages et la connexion
sont conservés (même identifiant d'app).

## Autres outils possibles

- **AltStore** (Windows ou Mac) : AltServer sur le PC, l'app AltStore sur l'iPad ;
  installation de l'IPA depuis AltStore (« My Apps › + ») et renouvellement en Wi-Fi tant
  qu'AltServer tourne sur le PC.
- **SideStore** : renouvellement depuis l'iPad seul, sans PC, mais mise en place plus
  technique (fichier d'appairage et application VPN locale).

## Dépannage

| Problème | Solution |
|---|---|
| « Développeur non approuvé » à l'ouverture | Réglages › Général › VPN et gestion de l'appareil › faire confiance au compte |
| L'app ne s'ouvre plus après une semaine | signature expirée : réinstaller avec Sideloadly (données conservées) |
| Sideloadly ne voit pas l'iPad | versions iTunes / iCloud du site d'Apple (pas celles du Microsoft Store), câble de données, iPad déverrouillé et « Se fier » |
| Erreur de certificat dans Sideloadly | trop de certificats sur le compte gratuit : utiliser un compte Apple dédié à l'iPad |
| Pas de bande-annonce ni d'addon du NAS | iPad sur le même réseau que le NAS ; Réglages de l'iPad › Aurora › Réseau local activé |
