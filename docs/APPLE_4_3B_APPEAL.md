# Dossier d'appel — App Store Guideline 4.3(b) « Design Spam »

**App :** DateNow (`0.1.0+70`) — dating app live-matching
**Date :** 9 juin 2026 — *références code revérifiées le 19 août 2026 sur `feat/redesign-voile`*
**Objet :** réponse argumentée au rejet 4.3(b) + plan de mise en conformité métadonnées/marketing
**Concurrents de référence cités par Apple (catégorie saturée) :** Tinder, Bumble, Hinge, Fruitz, Happn

> **Toutes les affirmations de ce dossier sont vérifiées dans le binaire** (références `fichier:ligne` ci-dessous). C'est le point décisif : un appel 4.3(b) ne se gagne pas avec du discours marketing — il se gagne en prouvant que la *mécanique de produit* est structurellement différente et **démontrable à l'écran** par le reviewer.

---

## 0. Comprendre le rejet 4.3(b)

4.3(b) ne dit pas « votre app est mauvaise ». Il dit : *« dans une catégorie saturée (dating), votre app ressemble à une énième variation du même concept ; apportez une différenciation substantielle ou elle n'a pas sa place sur le Store. »*

Deux leviers, à actionner **ensemble** :

1. **Prouver la différenciation fonctionnelle** — la boucle de produit (le « core loop ») doit être structurellement différente des 5 apps citées, pas une reskin. → Sections 1 à 4.
2. **Aligner les métadonnées** — fiche App Store, captures, mots-clés et sous-titre ne doivent **pas** ressembler à du dating générique (« Rencontre, chat, swipe… »). Une fiche générique confirme le verdict du reviewer même si l'app est différente. → Sections 5 à 7.

Atout dont on dispose déjà : un **compte démo Apple Review + login OTP scopé** (commits `7773911`, `297f485`). On peut donc faire vivre au reviewer le core loop complet. C'est notre meilleure arme.

---

## 1. Le core loop de DateNow (ce qui n'existe chez aucun des 5)

> **Disponible maintenant → match temps réel → date vidéo de 5 min caméra floutée → révélation progressive → décision → seulement alors, le chat s'ouvre.**

Aucune des 5 apps citées n'a cette boucle. Toutes les 5 sont **photo-first** : on voit le visage *avant* tout contact, on like/swipe sur une photo, puis on chatte par texte. La vidéo, quand elle existe (Tinder, Bumble), est **optionnelle et postérieure au match texte**. DateNow inverse l'ordre entier de la rencontre.

| Étape | Tinder | Bumble | Hinge | Fruitz | Happn | **DateNow** |
|---|---|---|---|---|---|---|
| Premier signal | Swipe sur photo | Swipe sur photo | Like/commentaire sur profil | Swipe + fruit d'intention | Like sur profil croisé | **Présence « dispo maintenant »** |
| Visage visible d'emblée | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ **Flouté** |
| Premier contact | Chat texte | Chat texte (femme initie) | Chat texte | Chat texte | Chat texte | **Date vidéo live 5 min** |
| Chat texte | Immédiat post-match | Immédiat post-match | Immédiat post-match | Immédiat post-match | Immédiat post-match | **Verrouillé jusqu'après la vidéo + reveal mutuel** |
| Pile à parcourir | Swipe infini | Swipe infini | File de profils | Swipe infini | Profils croisés | **Aucune pile — 1 match auto à la fois** |
| Révélation du visage | Jamais cachée | Jamais cachée | Jamais cachée | Jamais cachée | Jamais cachée | **Progressive, en fin de date** |

La colonne DateNow ne partage **aucune** case avec les 5 autres. C'est l'argument 4.3(b) le plus fort : ce n'est pas un degré de différence, c'est une boucle différente.

---

## 2. Les 6 piliers — preuves dans le code

### Pilier 1 — Disponibilité immédiate (real-time, pas une file statique)
**Vérifié ✅**
- `lib/features/presence/domain/presence_status.dart:10-13` — enum de présence `online / searching / inCall / offline`.
- `lib/features/presence/data/presence_repository.dart:46` — `setStatus()` écrit l'état temps réel dans `user_presence`.
- `lib/features/presence/data/presence_repository.dart:59` — `activeProfilesCount()` : compteur de personnes joignables, servi par une RPC `SECURITY DEFINER` à horloge serveur (fenêtre de fraîcheur 60 s).
- `lib/features/presence/data/presence_repository.dart:76` — `availableDateProposalsToday()` ne compte que les pairs à présence **fraîche** (non offline / non banni / pas déjà en call).
- `lib/features/matching/data/matching_driver.dart:34-44` — `joinQueue / leaveQueue / heartbeat` maintiennent la dispo vivante.

→ On ne matche pas sur un catalogue de profils dormants, mais sur **qui est joignable à l'instant T**.

### Pilier 2 — Date vidéo AVANT le chat
**Vérifié ✅**
- `lib/features/matching/presentation/matching_screen.dart:34-37` — après match, court reveal du score **(aucune photo)**, puis push direct vers le call.
- `lib/features/call/presentation/call_screen.dart:81` — la durée de l'appel est bornée par `AppConfig.maxCallDuration` (5 min) : ce call live est le **premier** contact.
- `lib/features/post_call/presentation/post_call_screen.dart:36` — « Real photos surface **only** here » : la photo n'apparaît qu'après l'appel.
- `lib/features/messaging/presentation/conversation_screen.dart:423-434` — le chat est verrouillé tant qu'il n'y a pas de reveal mutuel.

### Pilier 3 — Caméra floutée
**Vérifié ✅**
- `lib/features/call/presentation/agora_call_view.dart:768-775` — `BackdropFilter(ImageFilter.blur(sigmaX:15, sigmaY:15))` plein écran sur le flux distant.
- `lib/features/call/presentation/agora_call_view.dart:986-989` — même flou sigma-15 sur l'auto-vue PIP (« never show a sharp camera, self-view included »).
- `lib/features/call/presentation/agora_call_view.dart:1036` — `_BlurCaption`, la mention permanente affichée pendant tout l'appel.
- `lib/features/call/presentation/call_screen.dart:881` — « Caméra floutée — la révélation, c'est pour la fin ».

> Le flou de l'appel est **fixe et non désactivable** : un seul sigma, appliqué aux deux surfaces (flux distant et auto-vue), du début à la fin de la date. Aucun palier, aucun réglage, aucun déblocage payant.

### Pilier 4 — Révélation progressive
**Vérifié ✅**
- `lib/features/post_call/data/reveal_repository.dart:79-95` — machine à états `PostCallStage` : `selfDecideReveal → waitingForPeerReveal → mutual → matched`.
- `lib/shared/widgets/veil.dart:12-25` — le **Voile**, composant unique à quatre niveaux : sigma 26 (Découvrir) → 16 (match trouvé) → 7 (fin de date) → 0 (après décision mutuelle **des deux** personnes).
- `lib/shared/widgets/veil.dart:142-151` — le flou utilise `TileMode.decal` précisément pour que les pixels de bord ne trahissent pas la silhouette du visage.
- `lib/features/post_call/presentation/post_call_screen.dart:874-889` — la chorégraphie de la révélation : 400 ms d'immobilité, puis le flou tombe sur 1 s, et les boutons de décision n'apparaissent qu'à 1600 ms.
- `lib/features/matching/presentation/matching_screen.dart:36` — score révélé d'abord, photo bien plus tard.

→ Séquence : score seul → vidéo floutée → photo animée → décision mutuelle → chat. Le visage se mérite.

### Pilier 5 — Suppression du swipe infini
**Vérifié ✅ (absence confirmée)**
- Aucune occurrence de `swipe`, `CardStack`, `Dismissible` ou deck à gestes dans `lib/` — vérifiable par simple recherche.
- `lib/features/discover/data/weekly_suggestions_service.dart:34` — `static const int weeklySlots = 3` : le plafond hebdomadaire est une constante du service, pas une limite d'affichage.
- `lib/features/discover/presentation/discover_screen.dart:46` — l'écran ne consomme que ces suggestions et les matchs confirmés.
- `lib/features/matching/data/matching_driver.dart:55-69` — un seul meilleur candidat par recherche, pas une file à balayer.
- `lib/features/quota/data/quota_service.dart:16` — `static const int maleDailyCap = 5` : plafond quotidien côté serveur.

### Pilier 6 — Interaction temps réel
**Vérifié ✅**
- `lib/features/presence/data/presence_repository.dart:108` — `watchPresence()` via Supabase Realtime `.stream(primaryKey:['user_id'])`.
- `lib/features/matching/data/matchmaking_repository.dart:210` — `watchMyActiveCall()` stream sur `calls`.
- `lib/features/post_call/presentation/post_call_screen.dart:162` — `watchReveals()` = source de vérité unique, convergence des 2 clients.

---

## 3. Différenciateurs classés par force d'argument (pour Apple)

À mettre en avant **dans cet ordre** — du plus structurel/incontestable au plus secondaire :

1. **La date vidéo live floutée AVANT tout chat ou photo (Piliers 2+3+4 combinés).** C'est LE différenciateur. Aucune des 5 apps ne cache le visage ni n'impose la vidéo comme premier contact. Mécaniquement vérifiable en 90 secondes par le reviewer. **C'est l'argument principal.**
2. **Matching sur disponibilité temps réel, pas sur un catalogue (Pilier 1+6).** « Qui est dispo maintenant » vs « parcours un stock de profils ». Change la nature même de l'usage (sessions courtes intentionnelles vs scroll infini).
3. **Zéro swipe infini, interactions plafonnées (Pilier 5).** Anti-pattern explicite du modèle Tinder/Bumble/Fruitz/Happn. Argument « anti-addiction / qualité > quantité » qui plaît aussi à Apple sur l'angle bien-être.
4. **Révélation progressive comme récompense de l'interaction réelle (Pilier 4).** Renverse la logique « photo d'abord, conversation peut-être ».

> Conseil de cadrage : présenter 1+2+3 comme **un seul système cohérent** (« une app de rencontre par la voix/vidéo en temps réel, pas par le catalogue photo »), pas comme 4 features juxtaposées. Le reviewer doit retenir UNE phrase.

**Phrase-pivot (à réutiliser partout, fiche + appel) :**
> *« DateNow is the only dating app where you meet someone on a live, blurred 5-minute video date before you ever see their photo or send a message — matched in real time on who is available right now, with no swipe deck. »*

---

## 4. Écrans à mettre en avant (au reviewer & en captures)

| # | Écran | Fichier | Ce qu'il prouve |
|---|---|---|---|
| 1 | Home « dispo maintenant » + CTA « Trouver un date » | `home_screen.dart` | Pilier 1 — entrée par la disponibilité, pas par une pile |
| 2 | Matching live (score, **sans photo**) | `matching_screen.dart` | Piliers 2+6 — match temps réel, visage caché |
| 3 | Appel vidéo **caméra floutée** + caption | `agora_call_view.dart:768` / `call_screen.dart:881` | Piliers 2+3 — LE différenciateur, plein écran |
| 4 | Post-call : **révélation progressive** de la photo | `post_call_screen.dart:874` + `veil.dart` | Pilier 4 — la photo se mérite |
| 5 | Discover : 3 suggestions/sem (**pas de deck**) | `discover_screen.dart` / `weekly_suggestions_service.dart:34` | Pilier 5 — anti swipe infini |
| 6 | Quota atteint (plafond quotidien) | `quota_limit_sheet.dart` | Pilier 5 — interactions bornées |

---

## 5. Captures App Store à modifier (priorité élevée)

Le problème typique : des captures « génériques dating » (un profil, un bouton like, un chat) → le reviewer voit Tinder. **Il faut que les captures racontent le core loop dans l'ordre, avec un overlay texte par écran.**

**Storyboard recommandé (5–6 captures, dans l'ordre) :**

1. **« Personne en ligne, dispo maintenant »** — Home. Overlay : *« Pas de catalogue. Tu rencontres qui est là, maintenant. »*
2. **« Ta date commence en vidéo »** — écran matching/connexion. Overlay : *« Le premier contact, c'est un vrai date vidéo de 5 min. »*
3. **« Caméra floutée »** — écran d'appel flouté. Overlay : *« Pas de photo. Tu découvres la personne, pas son filtre. »* ← **capture héro, à mettre en 1ʳᵉ position dans certaines locales pour le punch.**
4. **« La révélation, en fin de date »** — post-call. Overlay : *« Si le courant passe, les visages se révèlent. »*
5. **« Zéro swipe »** — Discover (3 suggestions). Overlay : *« Pas de swipe infini. Des rencontres choisies. »*
6. *(optionnel)* **Sécurité** — vérif d'identité Didit + signalement. Overlay : *« Identités vérifiées, modération, 18+. »* (rassure aussi sur 1.2/safety).

**À bannir des captures :** toute carte de profil swipeable, toute grille de visages façon « stock », tout écran de chat texte mis en avant comme feature principale. Ce sont exactement les visuels qui ont déclenché le 4.3(b).

**Vidéo App Preview (fortement recommandée) :** 15–20 s montrant l'enchaînement match → call flouté → reveal. C'est ce qui fait *comprendre* la différence en mouvement. Apple pondère beaucoup l'App Preview pour lever un 4.3(b).

---

## 6. Texte d'appel à envoyer (Resolution Center, en anglais)

> À copier-coller dans la réponse au reviewer. Factuel, pointe des features démontrables, propose le compte démo et une vidéo.

```
Hello, and thank you for the review.

We'd like to respectfully clarify why DateNow is not a generic dating app
and does not fall under Guideline 4.3(b). DateNow's core interaction loop
is structurally different from every major dating app (Tinder, Bumble,
Hinge, Fruitz, Happn), all of which are photo-first, swipe/like-then-text
products. DateNow inverts that model:

1. NO PROFILE CATALOG / NO SWIPE DECK. There is no infinite swipe deck.
   Users are matched in real time based on who is AVAILABLE RIGHT NOW
   (live presence), and the app surfaces at most one match at a time, plus
   a small weekly set of curated suggestions (capped at 3).

2. THE FIRST CONTACT IS A LIVE VIDEO DATE — NOT TEXT. After a match, users
   are placed directly into a 5-minute live video date. Text messaging is
   LOCKED and unavailable until after that video date.

3. THE CAMERA IS BLURRED DURING THE DATE. Throughout the live date, both
   video feeds are intentionally blurred. Users get to know each other by
   conversation, not by appearance.

4. PROGRESSIVE REVEAL. The other person's photo is revealed only after the
   date, and only if both people choose to continue. Text chat unlocks
   only after this mutual reveal.

This "available-now → blurred live video → progressive reveal → then chat"
loop does not exist in any of the apps in this category. We believe it
constitutes the substantial, demonstrable differentiation 4.3 asks for.

To make this easy to verify, we've provided a demo account (credentials in
App Store Connect > App Review Information). The entire loop can be
experienced in under two minutes. We can also provide a short screen
recording on request.

We've also updated our App Store screenshots and subtitle to clearly
communicate this differentiated experience rather than generic dating
terminology.

Thank you for reconsidering. We're happy to answer any questions.
```

---

## 7. Modifications marketing / métadonnées (pour ne PAS retomber sur 4.3(b))

### 7.1 — ~~CORRECTIF BLOQUANT~~ : stats home codées en dur → **corrigé**

Au build 52, `home_screen.dart` affichait deux tuiles en dur : « 1.2k personnes en ligne » et « 38 s de temps de match moyen ». C'était un double risque — métadonnées trompeuses (2.3.1) **et** auto-sabotage du Pilier 1, un compteur « temps réel » figé décrédibilisant toute la thèse de la disponibilité.

**Fait.** Les deux tuiles sont branchées ou retirées :

- `lib/features/home/presentation/home_screen.dart:116` — la tuile « personnes en ligne » lit `activeProfilesCountProvider`, servi par la RPC `active_profiles_count()` (horloge serveur, fenêtre de fraîcheur 60 s).
- `lib/features/home/presentation/widgets/people_online_display.dart` — erreur, `null` et `0` affichent tous l'état vide, **jamais un nombre**. Testé FR + EN dans `test/people_online_format_test.dart`.
- `lib/features/home/presentation/home_screen.dart:133` — « 38 s » est remplacé par un fait produit vérifiable, la durée d'un date, tirée de `AppConfig.maxCallDuration`.
- `lib/features/home/presentation/home_screen.dart:149` — la troisième tuile lisait déjà `available_date_proposals_today()`.

Il ne reste **aucun chiffre d'audience inventé** dans l'interface.

### 7.2 — Sous-titre App Store (30 car.)
Bannir « Rencontre, Chat, Célibataires ». Proposer :
- *« Le date vidéo avant la photo »*
- *« Rencontre en live, pas en swipe »*

### 7.3 — Mots-clés
Réduire les génériques (« dating, chat, swipe, match, single ») qui rangent l'app dans le peloton 4.3(b). Pousser le positionnement : `live, vidéo, date vidéo, blur, temps réel, sans swipe, voix avant photo`.

### 7.4 — Description (1ʳᵉ ligne = la phrase-pivot section 3)
Ouvrir sur le différenciateur, pas sur « Bienvenue sur l'app de rencontre… ». La 1ʳᵉ phrase doit dire « date vidéo floutée avant le chat ». Idem sur le site `getdatenow.app` (déjà en place, commit `cfa0e95`) — vérifier que le H1 du site porte le même message (cohérence métadonnées ↔ site, qu'Apple peut consulter).

### 7.5 — Catégorie / cohérence
Garder « Lifestyle » ou « Social Networking » selon le positionnement, mais s'assurer que **toute** la surface publique (fiche, captures, site, première phrase de la description) raconte la *même* histoire que le binaire. La cohérence est ce qui transforme « encore une app de dating » en « un nouveau format de rencontre ».

---

## 7.6 — La refonte visuelle (branche `feat/redesign-voile`)

Depuis le rejet, toute la direction artistique a changé : le fond quasi-noir et le dégradé rose→violet — soit exactement la palette de la catégorie — sont remplacés par un thème clair ivoire et bordeaux, une typographie serif éditoriale (Newsreader), des cartes papier séparées par des filets, et un seul écran resté sombre : l'appel vidéo.

Ça compte pour un 4.3(b), parce que la moitié du verdict se joue sur les visuels de la fiche : les anciennes captures montraient une app sombre à dégradé saturé, ce qui *ressemble* à la concurrence citée avant même qu'on lise un mot. Les nouvelles ne ressemblent à aucune des cinq.

Le Voile — `lib/shared/widgets/veil.dart` — est le composant qui matérialise le cœur du produit : un flou à quatre niveaux qui se lève au fil de la relation, jamais avant la décision mutuelle. C'est la mécanique du Pilier 4 rendue visible à l'écran.

## 8. Checklist avant resoumission

- [x] **7.1** Stats home en dur (`1.2k` / `38s`) branchées sur du réel ou retirées — *fait, commit `a13a455`*
- [ ] Captures App Store refaites selon le storyboard (section 5), capture « caméra floutée » incluse
- [ ] App Preview vidéo 15–20 s (match → call flouté → reveal)
- [ ] Sous-titre + mots-clés dégénérisés (7.2 / 7.3)
- [ ] 1ʳᵉ ligne de description = phrase-pivot ; cohérence avec `getdatenow.app`
- [ ] Compte démo Apple Review vérifié fonctionnel + parcours complet faisable (déjà en place, à re-tester **sur la nouvelle DA**)
- [ ] Texte d'appel (section 6) prêt dans Resolution Center
- [ ] (Recommandé) Screen recording du core loop attaché à la réponse

---

*Toutes les références code de ce dossier ont été revérifiées le 19 août 2026 sur la branche `feat/redesign-voile` au build `0.1.0+70`. Elles ont dérivé depuis la rédaction initiale (build 52) : la refonte a déplacé du code de présentation, sans jamais toucher aux six mécaniques ci-dessus. À revérifier avant tout envoi si d'autres commits s'intercalent.*
