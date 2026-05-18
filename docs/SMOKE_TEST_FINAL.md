# Smoke test final — DateNow

À ouvrir **avant chaque test réel sur 2 téléphones**. En ~10 minutes, dit
si DateNow est **prêt** ou **pas prêt**.

Deux niveaux :
- **Auto** — `bash scripts/smoke_check.sh` (statique, sans device ni réseau).
- **Manuel** — builds, Supabase, test 2 téléphones.

---

## 1. Checklist courte

| # | Vérification | Comment | Attendu |
|---|--------------|---------|---------|
| 1 | `flutter doctor` | `flutter doctor` | iOS ✓ ; Android ✓ *ou* SDK absent assumé |
| 2 | `flutter analyze` | script (auto) | aucune **erreur** (infos tolérées) |
| 3 | Build iOS debug | `flutter build ios --debug --no-codesign` | `✓ Built …Runner.app` |
| 4 | Build Android debug | `flutter build apk --debug` *(si SDK)* | `✓ Built …app-debug.apk` |
| 5 | Migrations Supabase appliquées | `supabase db push` | `Finished` / « up to date » |
| 6 | Edge Function `generate-agora-token` déployée | `supabase functions list` | présente |
| 7 | Secrets Agora présents | `supabase secrets list` | `AGORA_APP_ID` + `AGORA_APP_CERTIFICATE` |
| 8 | Routes debug absentes en release | script (auto) | routes sous `if (kDebugMode)` |
| 9 | Identifiants app corrects | script (auto) | `com.datenow.app`, plus de `com.example` |

> Items 2, 8, 9 (+ présence migrations / Edge Function en local) sont
> couverts par `scripts/smoke_check.sh`. Le reste est manuel.

---

## 2. Go / No Go

**No Go — un seul de ces points bloque le test :**

| Critère bloquant | Comment le détecter |
|------------------|---------------------|
| L'app ne compile pas | build iOS / Android échoue |
| Token Agora impossible | Debug → `token généré = non`, ou vidéo vide |
| Debug visible en release | tuile/route debug accessible dans un build release |
| Le matching ne crée pas de call | après match, aucune ligne `calls` (Debug → carte Call) |
| `channel_name` différent entre les 2 users | Debug → carte Call : valeurs non identiques sur A et B |
| Le reveal ne crée pas le match | double révélation → `match permanent créé = false` |

**Go** — aucune ligne ci-dessus déclenchée **et** checklist §1 verte.

```
┌─────────────────────────────────────────────┐
│  smoke_check.sh = 0 échec                   │
│  builds OK   +   Supabase OK   +   §3 OK     │
│  ──────────────────────────────────────────  │
│           → GO pour le test réel            │
└─────────────────────────────────────────────┘
```

---

## 3. Test réel minimum

Un seul scénario — le chemin nominal complet. S'il passe, le MVP tient.
(Cas d'échec détaillés : `docs/TEST_PROTOCOL_MVP.md`.)

**Prérequis :** 2 comptes, 2 téléphones (build debug), profils complétés,
comptes connus comme **compatibles ≥ 75 %**.

**Étapes :**
1. A lance la recherche, B lance la recherche dans les ~10 s.
2. Les deux sont appariés automatiquement (score ≥ 75 %).
3. Écran de connexion (« Nous avons trouvé quelqu'un » → « Connexion du
   date… »), puis l'appel vidéo se monte.
4. Vérifier : **même `channel_name`** sur A et B (Debug → carte Call).
5. Vérifier : vidéo **floutée** + timer **cohérent** entre A et B.
6. Laisser le timer aller au bout → les deux passent au RevealScreen.
7. A révèle, B révèle → **photo HD débloquée** des deux côtés.
8. Vérifier : **match permanent créé** + **conversation créée**
   (Debug → carte Reveal, ou onglet Messages).

**Résultat attendu :** chaque étape OK → DateNow est prêt pour les tests
élargis. Toute étape KO = No Go, voir le tableau §2.

---

## 4. Commandes utiles

```bash
# Vérification statique automatisée
bash scripts/smoke_check.sh

# Environnement
flutter doctor

# Nettoyage + dépendances
flutter clean
flutter pub get

# Analyse
flutter analyze

# Builds
flutter build ios --debug --no-codesign
flutter build apk --debug
flutter build appbundle --release

# Supabase (vérifs manuelles)
supabase db push
supabase functions list
supabase secrets list
```

---

## Verdict

> **DateNow est prêt** si : `smoke_check.sh` ne renvoie aucun échec, les
> builds passent, Supabase (migrations + Edge Function + secrets) est en
> place, et le scénario §3 se déroule sans accroc.
>
> Sinon : **pas prêt** — corriger le point bloquant avant de mobiliser
> deux testeurs.
