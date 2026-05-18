# Protocole de test MVP — DateNow

Test de bout en bout du flow réel **recherche → match → call Agora → révélation**,
avec **2 téléphones physiques** et **2 comptes distincts**. Couvre le chemin nominal
ET les cas d'échec (abandon, call fantôme, refus, timeout).

---

## Prérequis généraux (à valider une seule fois avant la session)

| # | Prérequis | OK ? |
|---|-----------|------|
| G1 | Build **debug** installé sur les 2 téléphones (l'écran Debug est gated `kDebugMode`) | ☐ |
| G2 | 2 comptes créés, profils complétés (photo principale, âge, préférences) | ☐ |
| G3 | Permissions caméra + micro accordées sur les 2 téléphones | ☐ |
| G4 | Supabase joignable — migrations à jour (`matchmaking_queue.heartbeat_at`, `reveals`, `calls.started_at`) | ☐ |
| G5 | Edge Function `generate-agora-token` déployée + secrets `AGORA_APP_ID` / `AGORA_APP_CERTIFICATE` configurés | ☐ |
| G6 | Les 2 téléphones sur un réseau stable (la qualité vidéo n'est pas l'objet du test) | ☐ |
| G7 | Écran **Debug · DateNow** accessible depuis Réglages sur les 2 téléphones | ☐ |

**Convention :** *A* et *B* désignent les deux téléphones/comptes. « Debug »
renvoie à l'écran Debug · DateNow ; pensez à **Rafraîchir** pour lire l'état
serveur réel.

---

## Scénario 1 — Matching normal (chemin nominal)

- **Prérequis :** comptes A et B **compatibles** (score attendu ≥ 75 % — vérifier au préalable dans Debug → carte Matching → ligne du peer).
- **Étapes :**
  1. A : lancer la recherche (écran Matching).
  2. B : lancer la recherche dans les ~10 s qui suivent.
  3. Attendre l'appariement automatique.
  4. Sur chaque téléphone : ouvrir Debug → carte Call.
- **Résultat attendu :**
  - Les deux basculent dans le **même call Agora**.
  - `channel_name` **identique** sur A et B (Debug → carte Call, ou « Copier channel_name »).
  - Vidéo distante **floutée** (blur sigma 15) + légende « Caméra floutée jusqu'à la fin du date ».
  - Timer affiché **cohérent** entre A et B (écart ≤ 2 s — il dérive de `started_at` serveur).
  - Debug → carte Call : `status = live`, `started_at` renseigné, `temps restant (serveur)` cohérent avec le HUD.
- **Résultat obtenu :** _____________________________
- **Bug éventuel :** _____________________________
- **Priorité :** 🔴 Bloquant

---

## Scénario 2 — Pas de match (score < 75 %)

- **Prérequis :** comptes A et B **incompatibles** (score attendu < 75 %).
- **Étapes :**
  1. A : lancer la recherche.
  2. B : lancer la recherche.
  3. Laisser tourner ~30 s.
  4. Sur A et B : ouvrir Debug → carte Matching.
- **Résultat attendu :**
  - **Aucun call créé** (Debug → carte Call = « active call : aucun » sur les deux).
  - Les deux restent en phase « recherche ».
  - Debug → carte Matching explique le rejet : la ligne du peer affiche `<75 ✗` ou `HARD GATE FAIL`, et « meilleur peer ≥75% » = `—`.
- **Résultat obtenu :** _____________________________
- **Bug éventuel :** _____________________________
- **Priorité :** 🟠 Majeur

---

## Scénario 3 — Abandon de recherche (heartbeat périmé)

- **Prérequis :** comptes A et B compatibles.
- **Étapes :**
  1. A : lancer la recherche.
  2. A : **fermer complètement l'app** (swipe out — pas juste en arrière-plan).
  3. Attendre **> 30 s** (expiration du heartbeat).
  4. B : lancer la recherche.
  5. Laisser tourner ~30 s.
- **Résultat attendu :**
  - B **ne matche pas** avec A : le heartbeat de A est périmé, `active_queue_peers()` l'exclut.
  - Debug B → carte Matching : la ligne de A apparaît `(périmé)` avec `hb > 30s`, et n'est pas comptée dans « peers frais ».
  - Aucun call créé.
- **Résultat obtenu :** _____________________________
- **Bug éventuel :** _____________________________
- **Priorité :** 🟠 Majeur

---

## Scénario 4 — Call fantôme (peer absent après le match)

- **Prérequis :** comptes A et B compatibles.
- **Étapes :**
  1. A et B : lancer la recherche → laisser le match se créer.
  2. B : **fermer l'app immédiatement** avant que la vidéo Agora ne s'établisse.
  3. A : rester sur l'écran de call.
  4. Observer A jusqu'à la fin du compte à rebours.
- **Résultat attendu :**
  - A **n'est jamais bloqué** : le call se termine proprement à l'expiration du timer serveur (auto-end), A est redirigé vers le post-call.
  - Le bandeau de statut Agora reste sur « En attente » côté A (le pair distant n'a jamais publié) mais l'app reste réactive.
  - Debug → carte Call : `status` passe à `ended` après l'auto-end.
- **Résultat obtenu :** _____________________________
- **Bug éventuel :** _____________________________
- **Priorité :** 🔴 Bloquant

---

## Scénario 5 — Fin normale (timer jusqu'au bout)

- **Prérequis :** scénario 1 réussi (A et B dans le même call).
- **Étapes :**
  1. A et B : laisser le call se dérouler **jusqu'à 0:00** sans toucher « Terminer le date ».
  2. Observer la transition sur les deux téléphones.
- **Résultat attendu :**
  - Le call se termine **automatiquement** des deux côtés à l'expiration.
  - Sortie Agora **propre** (pas de crash, caméra/micro libérés — `client.release()`).
  - Les deux passent sur le **RevealScreen** (post-call).
  - Debug → carte Call : `status = ended`.
- **Résultat obtenu :** _____________________________
- **Bug éventuel :** _____________________________
- **Priorité :** 🔴 Bloquant

---

## Scénario 6 — Révélation mutuelle

- **Prérequis :** scénario 5 réussi (A et B sur le RevealScreen).
- **Étapes :**
  1. A : taper « Révéler ».
  2. B : taper « Révéler ».
  3. Observer les deux téléphones.
  4. Vérifier la liste des conversations / matches.
- **Résultat attendu :**
  - **Photo HD débloquée** des deux côtés (le flou disparaît uniquement après double révélation).
  - Écran « C'est un match » affiché sur A et B.
  - **Match permanent créé** : Debug → carte Reveal → `match permanent créé = true`, `outcome = mutual`.
  - **Conversation créée** : Debug → carte Reveal → `conversation créée = oui`, conversation visible dans Messages.
- **Résultat obtenu :** _____________________________
- **Bug éventuel :** _____________________________
- **Priorité :** 🔴 Bloquant

---

## Scénario 7 — Refus (un des deux passe)

- **Prérequis :** A et B sur le RevealScreen (refaire un call si besoin).
- **Étapes :**
  1. A : taper « Révéler ».
  2. B : taper « Passer ».
  3. Observer A.
- **Résultat attendu :**
  - **Aucun match permanent** créé (Debug → carte Reveal → `outcome = declined`, `match permanent créé = false`).
  - Aucune conversation créée.
  - A voit **immédiatement** le refus (écran « Pas de match ») dès que B a passé — pas d'attente bloquée.
  - Aucune photo HD débloquée.
- **Résultat obtenu :** _____________________________
- **Bug éventuel :** _____________________________
- **Priorité :** 🟠 Majeur

---

## Scénario 8 — Timeout de révélation (peer silencieux)

- **Prérequis :** A et B sur le RevealScreen.
- **Étapes :**
  1. A : taper « Révéler ».
  2. B : **ne rien faire** (laisser le RevealScreen ouvert sans décider).
  3. A : attendre **2 minutes**.
  4. A : tester d'abord « Continuer à attendre », puis re-attendre 2 min et tester « Passer ».
- **Résultat attendu :**
  - Après 2 min, A voit l'écran d'attente proposer **« Continuer à attendre »** et **« Passer »** (plus de spinner infini).
  - « Continuer à attendre » → réarme un nouveau cycle de 2 min, A reste en attente.
  - « Passer » → A sort du flow (écran « passé »), reveal `false` enregistré pour A.
  - Aucun match permanent.
- **Résultat obtenu :** _____________________________
- **Bug éventuel :** _____________________________
- **Priorité :** 🟠 Majeur

---

## Scénario 9 — Token Agora (sécurité)

- **Prérequis :** un call actif (pendant le scénario 1 ou 5).
- **Étapes :**
  1. Pendant le call, sur A et B : ouvrir Debug → carte Agora Token.
  2. Comparer les `uid` entre les deux téléphones.
  3. Inspecter les logs (`[DateNow][...]`) côté A et B.
- **Résultat attendu :**
  - `token généré = oui` sur les deux.
  - `uid utilisé` renseigné sur chaque téléphone (chacun a son propre uid, dérivé de son `userId`) — **stable** d'un rafraîchissement à l'autre.
  - `expiration approx.` renseignée (TTL ~15 min).
  - **Aucun token complet** affiché dans Debug ni dans les logs (la chaîne du token ne doit jamais apparaître).
  - `AGORA_APP_CERTIFICATE` jamais présent côté client.
- **Résultat obtenu :** _____________________________
- **Bug éventuel :** _____________________________
- **Priorité :** 🔴 Bloquant

---

## Tableau de synthèse

| # | Scénario | Priorité | Statut | Bug |
|---|----------|----------|--------|-----|
| 1 | Matching normal | 🔴 Bloquant | ☐ Pass / ☐ Fail | |
| 2 | Pas de match | 🟠 Majeur | ☐ Pass / ☐ Fail | |
| 3 | Abandon recherche | 🟠 Majeur | ☐ Pass / ☐ Fail | |
| 4 | Call fantôme | 🔴 Bloquant | ☐ Pass / ☐ Fail | |
| 5 | Fin normale | 🔴 Bloquant | ☐ Pass / ☐ Fail | |
| 6 | Révélation mutuelle | 🔴 Bloquant | ☐ Pass / ☐ Fail | |
| 7 | Refus | 🟠 Majeur | ☐ Pass / ☐ Fail | |
| 8 | Timeout reveal | 🟠 Majeur | ☐ Pass / ☐ Fail | |
| 9 | Token Agora | 🔴 Bloquant | ☐ Pass / ☐ Fail | |

**Verdict MVP :** tous les 🔴 doivent être *Pass* pour valider une démo.
Les 🟠 ouvrent un bug à corriger mais ne bloquent pas une démo contrôlée.

---

## Outils de debug rapides (écran Debug · DateNow)

- **Force leaveQueue** — sort A ou B de la file (utile pour réinitialiser entre deux scénarios).
- **Reset ma décision** — supprime sa propre ligne `reveals` pour rejouer une révélation.
- **Forcer fin call** — passe le call à `ended` (simule une fin).
- **Rejoindre ce call** — rebascule sur le call actif (utile après scénario 4).
- **Copier channel_name / call_id** — pour comparer entre les 2 téléphones.
- **Rafraîchir** — recharge l'état serveur (à faire systématiquement avant de lire une carte).
