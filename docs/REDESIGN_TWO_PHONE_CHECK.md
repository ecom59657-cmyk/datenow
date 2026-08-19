# Vérification à deux téléphones — ce que la refonte a touché

> Complément à `MATCHING_LIVE_TEST_AB.md`, qui couvre déjà le prérequis
> (comptes compatibles, réseau, monitoring des logs). **À faire avant toute
> resoumission.**
>
> Raison d'être : la branche `feat/redesign-voile` a modifié la couche de
> présentation de bout en bout — thème, widgets partagés, Voile, écrans —
> sans que **l'appel vidéo ni la révélation n'aient jamais été vus tourner**.
> Ce sont les deux seuls écrans du parcours qu'aucune capture n'a validés, et
> ce sont précisément ceux sur lesquels repose le Pilier 3 du dossier
> `APPLE_4_3B_APPEAL.md`.

## Pourquoi ces deux écrans et pas les autres

Le dossier d'appel affirme à Apple, références de lignes à l'appui, que la
caméra reste floutée pendant toute la date et que le visage n'apparaît qu'en
fin de parcours. Si la refonte a cassé l'une de ces deux choses, on
soumettrait un binaire qui contredit son propre dossier. C'est le seul risque
du lot qui ne soit pas rattrapable après coup.

## A — L'appel (Pilier 3)

| # | À vérifier | Attendu | Si ça échoue |
|---|---|---|---|
| A1 | Le flux **distant** est flouté dès la première frame | aucun instant de netteté, même bref | bloquant resoumission |
| A2 | L'**auto-vue** (PIP) est floutée aussi | même intensité que le plein écran | bloquant |
| A3 | La légende « Caméra floutée » est lisible | texte clair sur fond bordeaux | corriger avant captures |
| A4 | Le fond est **bordeauxDeep**, pas noir | `#451523`, pas `#000` | cosmétique |
| A5 | Les contrôles (micro, caméra, raccrocher) restent **nets** | le flou ne les touche pas | bloquant |
| A6 | Rotation / retour d'arrière-plan | le flou ne saute pas | bloquant |

Le flou de l'appel est un `BackdropFilter` sur une PlatformView iOS
(`agora_call_view.dart:768` et `:986`) : c'est le montage le plus fragile de
l'app, et un changement d'ordre dans le `Stack` suffit à le désactiver sans
qu'aucun test ne le voie.

## B — La révélation (Pilier 4)

| # | À vérifier | Attendu |
|---|---|---|
| B1 | À l'entrée : la photo est **floutée** (v2), pas nette | sigma 7 |
| B2 | **400 ms où rien ne bouge**, puis le flou tombe | la pause est délibérée |
| B3 | Trois retours haptiques : au départ, à 400 ms, à 1400 ms | léger / moyen / léger |
| B4 | Les boutons « On continue » / « Pas cette fois » n'apparaissent **qu'à 1600 ms** | jamais avant |
| B5 | Le grain reste visible **après** la révélation | v1 garde le grain |
| B6 | Le voile chaud tombe à 35 %, il ne disparaît pas | |
| B7 | Aucun liseré du visage aux bords de la carte | c'est ce que `TileMode.decal` empêche |

## C — Les deux écrans jamais atteints autrement

| # | Écran | Comment y arriver |
|---|---|---|
| C1 | Matching (score sans photo) | lancer un date des deux côtés en même temps |
| C2 | Quota atteint | 5 dates dans la journée sur le compte homme |

## Ce qu'on capture pendant qu'on y est

Les écrans 2, 3 et 4 du storyboard de `APPLE_4_3B_APPEAL.md` §5 ne peuvent
être capturés **que** pendant ce test. Prévoir l'enregistrement d'écran des
deux téléphones du début à la fin : il fournit à la fois l'App Preview de
15–20 s et le screen recording que le dossier propose de joindre à l'appel.
