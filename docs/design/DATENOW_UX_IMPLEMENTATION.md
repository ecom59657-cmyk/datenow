# DateNow — Plan d'implémentation UX, point par point

> Document d'exécution. Chaque section suit le même format :
> **État actuel** (ce que fait vraiment le code) → **Décision** (le choix produit adapté à
> DateNow, pas à Hinge) → **Code** (Dart + SQL) → **Vérification** → **Prompt Claude Code**.
>
> Rien ici n'est théorique : les noms de tables, de colonnes, de classes et de providers
> correspondent au code existant de `~/datenow`.
>
> **Relecture du 19 août 2026** — chaque « État actuel » du Lot A a été confronté au code
> de la branche `feat/redesign-voile` (build `0.1.0+70`). Cinq écarts trouvés et corrigés
> ci-dessous ; ils sont signalés par un bloc **⚠️ Correction**. Les « État actuel » des
> lots B, C et D n'ont **pas** encore été revérifiés — à faire avant d'attaquer chaque lot.

---

## Conventions du projet à respecter

Relevées dans le code existant — Claude Code doit s'y tenir :

- **Riverpod** avec des providers en fin de fichier : `final xxxRepositoryProvider = Provider<X>((ref) {...})`.
- **Pattern repository** : classe abstraite → `MockXxxRepository` + `SupabaseXxxRepository`,
  le provider choisit selon `ref.watch(supabaseAvailableProvider)`.
- **Logs** : `static const _log = AppLogger('Tag');` puis `_log.info/warn/error`.
- **Freezed** pour les modèles de domaine (`part 'x.freezed.dart'`), régénérer avec
  `dart run build_runner build --delete-conflicting-outputs`.
- **Aucune chaîne en dur** : tout passe par `AppLocalizations` (`lib/l10n/app_fr.arb` +
  `app_en.arb`), puis `flutter gen-l10n`.
- **Aucune couleur en dur** : tout passe par `AppColors` (palette ivoire/bordeaux, cf.
  `docs/design/DATENOW_UI_MOCKUP.html` et `lib/app/theme/app_colors.dart`).
- **Enums ↔ SQL** : `Gender.nonBinary` → `'non_binary'`, tous les autres enums utilisent
  `.name` verbatim. Toute nouvelle valeur d'enum doit être ajoutée **des deux côtés**
  (Dart + `CHECK` SQL) sinon l'insert est rejeté.
- **Migrations** : un fichier par sujet dans `supabase/migrations/`, horodaté
  `YYYYMMDDHHMMSS_sujet.sql`, idempotent (`IF NOT EXISTS`, `CREATE OR REPLACE`).

---

## Ordre d'exécution recommandé

| Lot | Points | Pourquoi dans cet ordre |
|---|---|---|
| **A — Fondations** | 4, 3a, 7, 8, 13c | Rien ne sert de peaufiner tant que l'état ne survit pas à un redémarrage et que deux pièges détruisent des matchs |
| **B — Matière** | 1, 10, 2, 12 | Les prompts conditionnent le like ciblé et l'amorce de conversation |
| **C — Confiance** | 5, 9, 11, 13a/b | Onboarding, permissions, rareté expliquée |
| **D — Rétention** | 6, 3b, 3c | Notifications et vraie géolocalisation |

Un commit par point. `flutter analyze` doit rester vert après chacun.

---

# LOT A — FONDATIONS

## Point 4 — Persister les suggestions et les matchs

### État actuel

`lib/features/discover/data/discover_repository.dart` :
- `SupabaseDiscoverRepository` existe mais **ses 7 méthodes lèvent `UnimplementedError`**.
- `discoverRepositoryProvider` retourne **toujours** `MockDiscoverRepository`, même quand
  Supabase est disponible — seul le *pool* de candidats vient de Supabase via
  `candidateSource`.
- Les **suggestions** vivent dans une `Map` en mémoire. Commentaire du fichier :
  « Resets on app restart ».

> **⚠️ Correction (19/08)** — les **matchs sont déjà persistés**. Le provider
> (`discover_repository.dart:506-518`) injecte un `_SupabaseMutualMatchesSource` qui lit
> la table `matches` directement, précisément pour que « phone B sees the row phone A's
> reveal repo upserted ». Le commentaire du fichier le dit : « Weekly-suggestion cards
> stay in RAM for now — out of scope ».
>
> **Le périmètre réel de ce point, c'est donc les suggestions hebdo uniquement.** Le code
> ci-dessous implémente aussi les matchs : cette partie est à écrire pour compléter
> `SupabaseDiscoverRepository`, mais elle ne corrige aucun bug — elle remplace un câblage
> qui marche déjà. À traiter en second, et à vérifier sur deux appareils avant de basculer
> le provider, sous peine de casser le seul chemin de matchs qui fonctionne aujourd'hui.

**Bonne nouvelle** : le schéma SQL est déjà complet. `public.weekly_suggestions`
(avec `UNIQUE(user_id, suggested_user_id, week_start_date)` et le `CHECK` de statut) et
`public.matches` (avec `user_a_id < user_b_id` et `UNIQUE`) existent depuis la migration
initiale. Il n'y a **rien à créer** — juste à câbler.

### Décision

Implémenter `SupabaseDiscoverRepository` contre les tables existantes et basculer le
provider. Le mock reste, il sert au mode démo et aux tests.

Deux subtilités du schéma à respecter :
- `weekly_suggestions` ne stocke **pas** la distance ni le profil du candidat → il faut
  joindre `profiles` et recalculer la distance à la lecture.
- `matches` impose l'ordre canonique `user_a_id < user_b_id`.

### Code

```dart
// lib/features/discover/data/discover_repository.dart
// Remplace intégralement la classe SupabaseDiscoverRepository.

class SupabaseDiscoverRepository implements DiscoverRepository {
  SupabaseDiscoverRepository(this._client, this._service, this._profiles);

  final sb.SupabaseClient _client;
  final WeeklySuggestionsService _service;
  final ProfileRepository _profiles;

  static const _log = AppLogger('SupabaseDiscover');

  String _weekKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  // ------------------------------------------------------------------
  // Lectures
  // ------------------------------------------------------------------

  @override
  Stream<List<WeeklySuggestion>> watchSuggestions(String userId) {
    return _client
        .from('weekly_suggestions')
        .stream(primaryKey: ['id'])
        .eq('user_id', userId)
        .asyncMap(_hydrateSuggestions);
  }

  /// `weekly_suggestions` ne porte que l'id du candidat : on hydrate le
  /// profil complet + la distance pour chaque ligne visible.
  Future<List<WeeklySuggestion>> _hydrateSuggestions(
    List<Map<String, dynamic>> rows,
  ) async {
    final week = _weekKey(WeeklySuggestionsService.startOfWeek(DateTime.now()));
    final visible = rows.where((r) =>
        r['status'] != 'dismissed' && r['week_start_date'] == week);

    final out = <WeeklySuggestion>[];
    for (final r in visible) {
      final peerId = r['suggested_user_id'] as String;
      final peer = await _profiles.getProfile(peerId);
      if (peer == null) continue;
      out.add(WeeklySuggestion(
        id: r['id'] as String,
        candidate: peer,
        compatibilityScore: (r['compatibility_score'] as num).toInt(),
        distanceKm: (r['distance_km'] as num?)?.toInt() ?? 0,
        weekStartDate: DateTime.parse(r['week_start_date'] as String),
        status: SuggestionStatus.values.byName(
          _statusFromDb(r['status'] as String),
        ),
      ));
    }
    return out;
  }

  /// SQL `call_started` ↔ Dart `callStarted`.
  String _statusFromDb(String v) => switch (v) {
        'call_started' => 'callStarted',
        _ => v,
      };

  String _statusToDb(SuggestionStatus s) => switch (s) {
        SuggestionStatus.callStarted => 'call_started',
        _ => s.name,
      };

  // ------------------------------------------------------------------
  // Génération du lot hebdomadaire
  // ------------------------------------------------------------------

  @override
  Future<void> ensureWeeklyBatch(UserProfile self) async {
    final weekStart = WeeklySuggestionsService.startOfWeek(DateTime.now());
    final week = _weekKey(weekStart);

    final current = await _client
        .from('weekly_suggestions')
        .select('id')
        .eq('user_id', self.userId)
        .eq('week_start_date', week)
        .neq('status', 'dismissed');

    final missing = WeeklySuggestionsService.weeklySlots - current.length;
    if (missing <= 0) {
      _log.info('lot de la semaine déjà complet (${current.length})');
      return;
    }

    // Ne jamais re-proposer quelqu'un : toutes semaines confondues,
    // tous statuts confondus, + les matchs existants + les blocages.
    final seen = await _client
        .from('weekly_suggestions')
        .select('suggested_user_id')
        .eq('user_id', self.userId);
    final matched = await _client
        .from('matches')
        .select('user_a_id, user_b_id')
        .or('user_a_id.eq.${self.userId},user_b_id.eq.${self.userId}');
    final blocked = await _client
        .from('blocked_users')
        .select('blocked_user_id')
        .eq('user_id', self.userId);

    final excluded = <String>{
      self.userId,
      ...seen.map((r) => r['suggested_user_id'] as String),
      ...matched.expand((r) => [r['user_a_id'] as String, r['user_b_id'] as String]),
      ...blocked.map((r) => r['blocked_user_id'] as String),
    };

    // Pool réel + distance réelle (cf. point 3c). Tant que la géo n'est
    // pas déployée, `nearbyCandidates` retombe sur fetchPotentialCandidates
    // avec distanceKm = 0 — jamais sur un tirage aléatoire.
    final pool = await _profiles.nearbyCandidates(
      selfUserId: self.userId,
      maxDistanceKm: self.maxDistanceKm,
    );

    final ranked = _service.selectFor(
      self: self,
      pool: pool,
      excludedUserIds: excluded,
    );

    for (final r in ranked.take(missing)) {
      await _client.from('weekly_suggestions').upsert({
        'user_id': self.userId,
        'suggested_user_id': r.candidate.userId,
        'compatibility_score': r.score.percentage,
        'distance_km': r.distanceKm,
        'week_start_date': week,
        'status': 'pending',
      }, onConflict: 'user_id,suggested_user_id,week_start_date');
    }
    _log.info('lot hebdo: ${ranked.take(missing).length} suggestion(s) écrites');
  }

  // ------------------------------------------------------------------
  // Mutations
  // ------------------------------------------------------------------

  @override
  Future<void> dismissSuggestion(String id) =>
      _updateStatus(id, SuggestionStatus.dismissed);

  @override
  Future<void> markSuggestionCallStarted(String id) =>
      _updateStatus(id, SuggestionStatus.callStarted);

  @override
  Future<void> markSuggestionMatched(String id) =>
      _updateStatus(id, SuggestionStatus.matched);

  Future<void> _updateStatus(String id, SuggestionStatus s) async {
    await _client
        .from('weekly_suggestions')
        .update({'status': _statusToDb(s)})
        .eq('id', id);
  }

  @override
  Stream<List<MutualMatch>> watchMatches(String userId) {
    return _client
        .from('matches')
        .stream(primaryKey: ['id'])
        .asyncMap((rows) async {
          final mine = rows.where((r) =>
              r['user_a_id'] == userId || r['user_b_id'] == userId);
          final out = <MutualMatch>[];
          for (final r in mine) {
            final peerId = r['user_a_id'] == userId
                ? r['user_b_id'] as String
                : r['user_a_id'] as String;
            final peer = await _profiles.getProfile(peerId);
            if (peer == null) continue;
            out.add(MutualMatch(
              id: r['id'] as String,
              peer: peer,
              compatibilityScore: (r['compatibility_score'] as num).toInt(),
              matchedAt: DateTime.parse(r['matched_at'] as String),
              status: MatchStatus.values.byName(
                r['status'] == 'conversation_open' ? 'conversationOpen'
                : r['status'] == 'new' ? 'newMatch' : 'archived',
              ),
            ));
          }
          return out;
        });
  }

  /// Le match permanent est déjà écrit par [RevealRepository.createMatch]
  /// (upsert idempotent sur `matches`). Ici on ne fait donc rien —
  /// l'appel reste dans l'interface pour le mock.
  @override
  Future<void> recordMutualMatch({
    required UserProfile self,
    required UserProfile candidate,
    required int score,
  }) async {
    _log.info('recordMutualMatch — no-op côté Supabase (voir RevealRepository)');
  }
}
```

Migration pour la colonne de distance manquante :

```sql
-- supabase/migrations/20260820090000_suggestions_distance.sql
ALTER TABLE public.weekly_suggestions
  ADD COLUMN IF NOT EXISTS distance_km SMALLINT
    CHECK (distance_km IS NULL OR distance_km >= 0);

COMMENT ON COLUMN public.weekly_suggestions.distance_km IS
  'Distance au moment de la génération du lot. Figée : on ne veut pas '
  'qu''une carte change de distance entre deux ouvertures de l''app.';
```

Et le provider :

```dart
final discoverRepositoryProvider = Provider<DiscoverRepository>((ref) {
  final service = ref.watch(weeklySuggestionsServiceProvider);
  if (!ref.watch(supabaseAvailableProvider)) {
    return MockDiscoverRepository(service);
  }
  return SupabaseDiscoverRepository(
    ref.watch(supabaseClientProvider),
    service,
    ref.watch(profileRepositoryProvider),
  );
});
```

### Vérification

- [ ] Générer un lot, tuer l'app, la rouvrir : les 3 suggestions sont toujours là.
- [ ] Rappeler `ensureWeeklyBatch` deux fois de suite : aucune ligne dupliquée
      (le `UNIQUE(user_id, suggested_user_id, week_start_date)` doit tenir).
- [ ] Un utilisateur bloqué ne réapparaît jamais dans un lot.
- [ ] Le lundi suivant, un nouveau lot est généré sans écraser l'historique.

### Prompt Claude Code

```
Point 4 du plan docs/design/DATENOW_UX_IMPLEMENTATION.md : implémente
SupabaseDiscoverRepository contre les tables weekly_suggestions et matches qui
existent déjà, ajoute la migration distance_km, et bascule
discoverRepositoryProvider. Ne touche pas au MockDiscoverRepository.
Montre-moi le diff avant de continuer.
```

---

## Point 3a — Arrêter d'afficher un pourcentage qu'on ne sait pas calculer

### État actuel

`lib/features/matching/data/matching_service.dart` répartit 100 points :

```
_wIntentions 25 · _wInterests 25 · _wDistance 15 · _wOrientation 15
_wAvailability 10 · _wAge 10
```

Trois défauts :
1. `_scoreOrientation` renvoie **15 points en bloc dès que les deux orientations sont
   non-nulles**, quelles qu'elles soient. Commentaire du code : « For MVP we don't model
   orientation compatibility deeply ». Ces 15 points ne discriminent rien.
2. `_scoreDistance` (15 points) s'appuie sur une distance **synthétisée** par
   `_factory.distanceFor(self)` — y compris pour les candidats réels.
3. Aucune porte dure sur les intentions : `serious` peut rencontrer `casual`.

Résultat : 30 points sur 100 sont du bruit, et `CompatibilityBadge` affiche « 87 % ».

### Décision

Trois changements, du moins risqué au plus structurant :

1. **Afficher la bande, pas le nombre.** `MatchBand` existe déjà avec ses seuils
   (≥90 veryHigh, ≥70 high, ≥50 medium). On affiche « Très compatible » au lieu de
   « 87 % ». C'est honnête, et le jour où la géo sera réelle on pourra revenir au chiffre
   sans avoir menti entre-temps.
2. **Porte dure sur les intentions**, mais uniquement sur l'opposition franche —
   bloquer trop large viderait le pool.
3. **Supprimer l'axe orientation** et redistribuer ses 15 points.

> **⚠️ Correction (19/08)** — deux effets de bord à anticiper :
> - la redistribution change **tous** les scores ; `test/matching_service_test.dart` est à
>   reprendre dans le même commit, sinon la suite casse ;
> - le plancher de sélection est `minScore = 50` (`matching_driver.dart:68`), pas 75.
>   Une porte dure sur les intentions **plus** des poids redistribués peut vider le pool au
>   volume de lancement. Mesurer avant/après sur des profils réels, pas seulement en test.

Nouvelle répartition :

| Axe | Avant | Après | Raison |
|---|---|---|---|
| Intentions | 25 | **30** | C'est le meilleur prédicteur d'un bon appel |
| Intérêts | 25 | **25** | inchangé — c'est la matière de conversation |
| Distance | 15 | **20** | reprend du poids une fois la géo réelle |
| Âge | 10 | **15** | |
| Disponibilité | 10 | **10** | inchangé |
| Orientation | 15 | **0** | supprimé : la réciprocité de genre fait déjà le travail |

### Code

```dart
// lib/features/matching/data/matching_service.dart

// --- Poids (doivent sommer à 100) ---
static const int _wIntentions   = 30;
static const int _wInterests    = 25;
static const int _wDistance     = 20;
static const int _wAge          = 15;
static const int _wAvailability = 10;
// _wOrientation supprimé : la réciprocité de genre gère déjà « qui est
// attiré par qui ». Accorder des points à la simple présence de la donnée
// gonflait tous les scores de 15 points sans rien discriminer.

/// Opposition franche d'intentions. On ne bloque que le cas où l'un cherche
/// exclusivement une relation sérieuse et l'autre exclusivement du casual :
/// tous les autres croisements restent possibles, la pondération douce
/// suffit à les départager. Bloquer plus large viderait le pool.
static bool _intentionsCompatible(Set<Intention> a, Set<Intention> b) {
  if (a.isEmpty || b.isEmpty) return true;
  if (a.intersection(b).isNotEmpty) return true;
  bool onlySerious(Set<Intention> s) =>
      s.length == 1 && s.first == Intention.serious;
  bool onlyCasual(Set<Intention> s) =>
      s.length == 1 && s.first == Intention.casual;
  return !((onlySerious(a) && onlyCasual(b)) ||
           (onlyCasual(a) && onlySerious(b)));
}
```

Dans `_hardGatesPass`, après la porte de distance :

```dart
  // 6. Opposition d'intentions — cinq minutes de visio en direct coûtent
  //    trop cher pour risquer un serious/casual frontal.
  if (!_intentionsCompatible(a.intentions, b.intentions)) return false;
```

Le badge :

```dart
// lib/features/matching/presentation/widgets/compatibility_badge.dart

/// Tant que la distance n'est pas réelle (cf. point 3c), 20 des 100 points
/// reposent sur une valeur approchée : on affiche la bande, pas le chiffre.
/// Repasser à `true` le jour où `profiles.location` est renseignée.
const bool kShowExactCompatibility = false;

// dans build() :
final label = kShowExactCompatibility
    ? l10n.compatibilityPercent(score.percentage)
    : score.band.label(l10n);
```

`MatchBand.label` existe déjà (`l.compatibilityBandVeryHigh` etc.) — vérifier que les
quatre clés sont bien présentes dans les deux `.arb`, sinon les ajouter :

```json
"compatibilityBandVeryHigh": "Très compatibles",
"compatibilityBandHigh":     "Compatibles",
"compatibilityBandMedium":   "Quelques points communs",
"compatibilityBandLow":      "Peu de points communs"
```

### Vérification

- [ ] `MatchingService` : les poids somment toujours à 100 (ajouter un test).
- [ ] Un profil `{serious}` et un profil `{casual}` ne sont jamais proposés l'un à l'autre.
- [ ] Un profil `{serious, feeling}` et un `{casual, feeling}` le sont toujours (intersection non vide).
- [ ] Aucun écran n'affiche plus de pourcentage : `rg 'percentage' lib/features/*/presentation`.
- [ ] `WeeklySuggestionsService.minCompatibility = 75` doit être **revu à la baisse** :
      sans les 15 points gratuits d'orientation, les scores chutent mécaniquement.
      Passer à **65** et observer le log `selectFor ... belowFloor=`.

### Prompt Claude Code

```
Point 3a : dans matching_service.dart, supprime l'axe orientation, redistribue
les poids (intentions 30, intérêts 25, distance 20, âge 15, dispo 10), ajoute la
porte dure _intentionsCompatible, et abaisse minCompatibility à 65 dans
weekly_suggestions_service.dart. Puis dans compatibility_badge.dart, affiche
score.band.label() au lieu du pourcentage derrière la constante
kShowExactCompatibility = false. Ajoute un test unitaire qui vérifie que les
poids somment à 100 et que serious/casual est bloqué.
```

---

## Point 7 — Le piège de l'écran d'attente

### État actuel

`lib/features/post_call/presentation/post_call_screen.dart`, `_Stage.waiting` :

- `_revealTimeout = Duration(seconds: 30)` ; au bout de 30 s, `_revealTimedOut = true`.

> **⚠️ Correction (19/08)** — le doc annonçait 2 minutes ; le code
> (`post_call_screen.dart:70`) dit **30 secondes**, avec une justification explicite :
> au-delà, l'écran « reads as broken / ghosted ». Toute la temporisation de ce point est
> donc à relire à cette échelle — voir la limite de réarmement plus bas.
- Deux boutons apparaissent :
  - « Continuer à attendre » → `_keepWaiting()` réarme **une fenêtre complète, sans
    limite de réarmement** ;
  - « Passer » → appelle `_pass()`, donc `submitReveal(revealed: false)`.

Le second est le piège : l'utilisateur croit **quitter un écran**, il **décline
définitivement**. Si le pair acceptait 30 secondes plus tard, le match est perdu et
personne ne saura pourquoi.

Ces quatre chaînes sont en plus **codées en dur en français**.

### Décision

Séparer trois intentions qui sont aujourd'hui confondues dans un seul bouton :

| Intention | Action | Effet sur `reveals` |
|---|---|---|
| « je reste » | Continuer à attendre | aucun |
| « je pars mais je reste intéressé » | **Me prévenir** (nouveau) | aucun — la ligne `revealed: true` reste |
| « ça ne m'intéresse pas » | Ne pas donner suite | `revealed: false` + confirmation |

Le bouton « Me prévenir » devient l'action principale après le timeout : c'est ce que
l'utilisateur veut faire dans 90 % des cas. Il exige la notification du point 6 —
en attendant, une notification locale suffit tant que l'app tourne.

Limiter aussi le réarmement : après 3 tours, on n'affiche plus « Continuer à attendre ».
À 30 s par tour cela fait **90 secondes**, pas 6 minutes — ce qui est court. Soit on
allonge `_revealTimeout` (au risque de l'effet « ghosté » que le commentaire du code
cherchait justement à éviter), soit on autorise davantage de tours. À trancher en
implémentant, avec le comportement réel sous les yeux.

### Code

```dart
// post_call_screen.dart

int _waitRearmCount = 0;
static const _maxRearms = 3;

void _keepWaiting() {
  if (_waitRearmCount >= _maxRearms) return;
  _waitRearmCount++;
  setState(() => _revealTimedOut = false);
  _startRevealTimeout();
}

/// Quitte l'écran **sans décliner**. La ligne `reveals` de l'utilisateur
/// reste à `revealed: true` : si le pair accepte plus tard, le match se
/// fait et la notification arrive. C'est la différence avec [_pass].
Future<void> _notifyMeLater() async {
  _revealSub?.cancel();
  _revealTimeoutTimer?.cancel();
  await ref.read(pendingRevealsProvider.notifier).track(
        callId: ref.read(activeCallIdProvider)!,
        peerFirstName: ref.read(activeMatchProvider)?.candidate.firstName,
      );
  if (!mounted) return;
  context.goNamed(AppRoute.home.name);
}

/// Refus explicite — désormais confirmé, parce qu'il est irréversible.
Future<void> _declineExplicitly() async {
  final ok = await showDestructiveDialog(
    context,
    title: l10n.postCallDeclineConfirmTitle,
    body: l10n.postCallDeclineConfirmBody,   // « Cette personne ne pourra plus vous recontacter. »
    confirmLabel: l10n.postCallDeclineConfirmCta,
  );
  if (ok == true) await _pass();
}
```

Et dans `_WaitingView`, quand `timedOut` :

```dart
AppButton(
  label: l10n.postCallNotifyMe,            // « Me prévenir »
  icon: Icons.notifications_active_outlined,
  onPressed: onNotifyMe,
),
if (canRearm) ...[
  const SizedBox(height: AppSpacing.sm),
  AppButton(
    label: l10n.postCallKeepWaiting,       // « Continuer à attendre »
    variant: AppButtonVariant.secondary,
    onPressed: onKeepWaiting,
  ),
],
const SizedBox(height: AppSpacing.sm),
AppButton(
  label: l10n.postCallDecline,             // « Ne pas donner suite »
  variant: AppButtonVariant.tertiary,
  onPressed: onDecline,
),
```

Le suivi des reveals en attente, pour que le retour à l'accueil ne perde pas le fil :

```dart
// lib/features/post_call/presentation/providers/pending_reveals_provider.dart
/// Reveals en attente de décision du pair. Persistés dans shared_preferences
/// pour survivre à une fermeture de l'app : au prochain lancement on
/// re-souscrit et on notifie si le pair a accepté entre-temps.
class PendingReveals extends StateNotifier<List<PendingReveal>> { ... }
```

`showDestructiveDialog` existe déjà dans
`lib/features/settings/presentation/widgets/destructive_dialog.dart` — vérifier sa
signature et l'adapter plutôt que d'en créer un second.

### Vérification

- [ ] Depuis l'écran d'attente, « Me prévenir » → retour à l'accueil, et la ligne
      `reveals` de l'utilisateur est toujours `revealed = true` (vérifier en base).
- [ ] Le pair accepte ensuite → le match se crée et l'utilisateur est notifié.
- [ ] « Ne pas donner suite » demande confirmation avant d'écrire `revealed = false`.
- [ ] Après 3 réarmements, « Continuer à attendre » disparaît.

### Prompt Claude Code

```
Point 7 : dans post_call_screen.dart, dissocie les trois actions de l'écran
d'attente (Me prévenir / Continuer à attendre / Ne pas donner suite). « Me
prévenir » ne doit PAS appeler submitReveal(false) — il quitte l'écran en
laissant la ligne reveals à true. Ajoute la confirmation sur le refus explicite,
limite les réarmements à 3, et sors toutes les chaînes en dur vers les .arb.
```

---

## Point 8 — Bloquer et se dématcher

### État actuel

Ce qui existe déjà et qui est bon :
- `ReportRepository.blockUser({reportedUserId})` → RPC `block_user(p_user_id)`,
  `SECURITY DEFINER`, déjà déployée (migration `20260524120000_app_store_compliance.sql`).
- Table `blocked_users` avec clé primaire `(user_id, blocked_user_id)`.
- `report_sheet.dart` accessible depuis le post-appel et la conversation.

Ce qui manque :
- Le menu `PopupMenuButton` de `conversation_screen.dart:292-310` contient **deux
  entrées** : « Signaler » et « Supprimer la conversation ». Pas de blocage, pas d'unmatch.
- **Signaler ne bloque pas.** Chez Hinge, signaler bloque automatiquement.
- Aucun moyen de défaire un match.

> **⚠️ Correction (19/08)** — le doc annonçait une seule entrée et l'absence de suppression
> de conversation. `_confirmDeleteConversation` existe déjà et est câblée sur l'entrée
> `delete`. Le menu passe donc de **2 à 4** entrées, pas de 1 à 3.

### Décision

- Le menu passe à trois entrées : **Signaler · Bloquer · Ne plus être en contact**.
- Dans `report_sheet`, une case **cochée par défaut** : « Bloquer aussi cette personne ».
  Décochable — quelqu'un peut vouloir signaler un faux profil sans bloquer.
- Nouvelle RPC `unmatch(p_peer_id)` : supprime le match et la conversation en une
  transaction, sans bloquer (c'est un geste plus doux que le blocage).

### Code

```sql
-- supabase/migrations/20260820100000_unmatch.sql
CREATE OR REPLACE FUNCTION public.unmatch(p_peer_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_self UUID := auth.uid();
  v_a UUID := LEAST(v_self, p_peer_id);
  v_b UUID := GREATEST(v_self, p_peer_id);
BEGIN
  IF v_self IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;
  IF v_self = p_peer_id THEN
    RAISE EXCEPTION 'cannot unmatch yourself';
  END IF;

  -- ON DELETE CASCADE sur messages.conversation_id fait le ménage.
  DELETE FROM public.conversations WHERE user_a_id = v_a AND user_b_id = v_b;
  DELETE FROM public.matches       WHERE user_a_id = v_a AND user_b_id = v_b;

  -- La suggestion d'origine repasse en 'dismissed' pour ne jamais
  -- être re-proposée.
  UPDATE public.weekly_suggestions
     SET status = 'dismissed'
   WHERE (user_id = v_self AND suggested_user_id = p_peer_id)
      OR (user_id = p_peer_id AND suggested_user_id = v_self);
END;
$$;

GRANT EXECUTE ON FUNCTION public.unmatch(UUID) TO authenticated;
```

```dart
// lib/features/messaging/data/messaging_repository.dart — ajouter à l'interface
/// Défait le match : supprime la conversation et la ligne `matches`.
/// Irréversible, mais moins violent qu'un blocage (le pair n'est pas
/// ajouté à `blocked_users`).
Future<void> unmatch({required String peerId});

// SupabaseMessagingRepository
@override
Future<void> unmatch({required String peerId}) async {
  _log.info('unmatch peer=$peerId');
  await _client.rpc<dynamic>('unmatch', params: {'p_peer_id': peerId});
}
```

Le menu de conversation :

```dart
PopupMenuButton<String>(
  itemBuilder: (_) => [
    PopupMenuItem(value: 'report',  child: Text(l10n.actionReport)),
    PopupMenuItem(value: 'block',   child: Text(l10n.actionBlock)),
    PopupMenuItem(
      value: 'unmatch',
      child: Text(l10n.actionUnmatch,
          style: const TextStyle(color: AppColors.error)),
    ),
  ],
  onSelected: (v) async {
    switch (v) {
      case 'report':
        await showReportSheet(context, reportedUserId: peerId!, ...);
      case 'block':
        if (await _confirmBlock(context) != true) return;
        await ref.read(reportRepositoryProvider).blockUser(reportedUserId: peerId!);
        if (context.mounted) context.goNamed(AppRoute.messages.name);
      case 'unmatch':
        if (await _confirmUnmatch(context) != true) return;
        await ref.read(messagingRepositoryProvider).unmatch(peerId: peerId!);
        if (context.mounted) context.goNamed(AppRoute.messages.name);
    }
  },
)
```

Et dans `report_sheet.dart`, au moment de la soumission :

```dart
bool _alsoBlock = true;   // coché par défaut

// ...
CheckboxListTile(
  value: _alsoBlock,
  onChanged: (v) => setState(() => _alsoBlock = v ?? true),
  title: Text(l10n.reportAlsoBlock),   // « Bloquer aussi cette personne »
  contentPadding: EdgeInsets.zero,
  controlAffinity: ListTileControlAffinity.leading,
),

// dans _submit(), après le submit du report :
if (_alsoBlock) {
  await repo.blockUser(reportedUserId: widget.reportedUserId);
}
```

**À vérifier aussi** : `call_screen.dart` doit permettre, pendant l'appel,
**raccrocher + signaler + bloquer en un geste**. Si le bouton « Signaler un problème »
de la maquette ouvre une feuille qui laisse l'appel actif, c'est un défaut de sécurité :
la RPC `block_user` doit couper l'appel (son commentaire annonce « Also force-ends any
live call between the two » — le vérifier réellement).

### Vérification

- [ ] Signaler avec la case cochée → la ligne apparaît dans `blocked_users`.
- [ ] L'utilisateur bloqué disparaît de la boîte de réception et des suggestions.
- [ ] Unmatch → la conversation et le match disparaissent des deux côtés.
- [ ] Un utilisateur bloqué ne peut plus insérer de message (vérifier la RLS).
- [ ] Pendant un appel, bloquer met fin à l'appel immédiatement.

### Prompt Claude Code

```
Point 8 : ajoute la RPC unmatch (migration + méthode repository), passe le menu
de conversation_screen.dart à trois entrées Signaler/Bloquer/Ne plus être en
contact avec confirmations, et ajoute la case « Bloquer aussi cette personne »
cochée par défaut dans report_sheet.dart. Vérifie ensuite que block_user coupe
bien un appel en cours et dis-moi ce que tu trouves.
```

---

## Point 13c — Fermer les routes

### État actuel

`app_router.dart` : la seule garde après « profil complet » est… rien. `/call`,
`/post-call`, `/matching` et `/messages/:id` sont atteignables directement, sans
vérification de match actif ni d'appartenance à la conversation.

> **⚠️ Correction (19/08)** — le code proposé plus bas ne peut pas s'insérer là où le doc
> l'indique. La garde `profileComplete` vit dans `decideRedirect()`
> (`app_router.dart:382`), une fonction **pure**, marquée `@visibleForTesting`, et
> `test/router_redirect_test.dart` en dépend précisément parce qu'elle est testable
> « without mounting providers ». Y appeler `ref.read(...)` casse ce contrat.
>
> Deux ajustements obligatoires :
>
> 1. **Passer les gardes en paramètres.** `decideRedirect` reçoit deux arguments de plus —
>    `bool hasActiveMatch` et `bool Function(String id) canOpenConversation` (ou une liste
>    d'ids) — alimentés par `_RouterNotifier.redirect` (`:334`), qui a `_ref`. Les
>    nouveaux cas se testent alors dans `router_redirect_test.dart` comme les autres.
> 2. **Écouter les nouveaux providers.** `_RouterNotifier` (`:320-330`) n'écoute que
>    `onboardingCompletedProvider`, `authStateProvider`, `currentProfileProvider` et
>    `splashGateProvider`. Une garde qui dépend de `activeMatchProvider` ou
>    `inboxProvider` sans `_ref.listen` correspondant ne re-déclenche pas le redirect
>    quand ces états changent : l'utilisateur reste coincé, ou se fait éjecter au mauvais
>    moment. C'est le même piège que le bug de démarrage à froid documenté en tête de
>    `router_redirect_test.dart`.

### Décision

Trois gardes ciblées dans le `redirect` existant, après le bloc profil.

### Code

```dart
// app_router.dart, dans redirect(), après la garde profileComplete :

// Un appel ou un post-appel n'a de sens qu'avec un match actif en mémoire.
const liveOnly = {'/call', '/post-call'};
if (liveOnly.contains(location) && ref.read(activeMatchProvider) == null) {
  return AppRoute.home.path;
}

// Une conversation n'est ouvrable que si l'utilisateur en est participant.
// La RLS bloque déjà les données côté serveur ; cette garde évite juste
// un écran vide et un log d'erreur.
if (location.startsWith('/messages/')) {
  final id = location.split('/').last;
  final inbox = ref.read(inboxProvider).valueOrNull;
  if (inbox != null && !inbox.any((c) => c.id == id)) {
    return AppRoute.messages.path;
  }
}
```

Ajouter aussi un `errorBuilder` au `GoRouter` — aujourd'hui une URL inconnue produit
l'écran d'erreur brut de go_router.

---

# LOT B — MATIÈRE

## Point 1 — Des prompts, pas une bio

### État actuel

`UserProfile` a 13 champs et **aucun texte libre** hors `firstName`. Les 16 valeurs de
`Interest` (`music, films, sports, fitness, foodie, travel, books, gaming, dance, nature,
photography, art, fashion, wellness, cooking, animals`) sont le seul contenu.

La maquette affiche déjà un encart « UN DIMANCHE PARFAIT » sur la carte Découvrir —
il est purement décoratif, aucun champ n'existe derrière.

### Décision

**Des prompts, jamais une bio libre.** Une bio produit des paragraphes creux et une
charge de modération ; une banque de questions fermée produit des réponses courtes et
concrètes — c'est ce qui fait la qualité des profils Hinge.

Paramètres retenus, adaptés à DateNow :

| Paramètre | Valeur | Pourquoi |
|---|---|---|
| Nombre affiché | **3 max** | comme Hinge |
| Nombre **requis** | **2** | Hinge en exige 3, mais notre onboarding a déjà 4 étapes — en exiger 3 tuerait la conversion |
| Longueur | **140 caractères** | ce sont des amorces d'appel, pas des biographies |
| Banque | **16 questions** | assez pour varier, assez peu pour rester curable |

**La différence avec Hinge** : chez DateNow, les prompts ne servent pas seulement à
décider — ils sont **affichés pendant l'appel**, en bas d'écran, repliés. C'est le filet
de sécurité des cinq minutes. Aucune app à photos ne peut faire ça.

### Code

```dart
// lib/features/profile_setup/domain/prompt.dart
import '../../../l10n/app_localizations.dart';

/// Banque fermée de questions de profil. Fermée volontairement : un champ
/// libre produit des paragraphes creux et une charge de modération, une
/// question précise produit une amorce de conversation.
///
/// Toute nouvelle valeur doit être ajoutée au CHECK de `user_prompts.question`
/// dans la migration, sinon l'insert est rejeté.
enum PromptQuestion {
  perfectSunday,        // Un dimanche parfait…
  cantShutUpAbout,      // Je peux en parler pendant des heures…
  makeMeLaugh,          // Ce qui me fait rire à tous les coups…
  learningRightNow,     // Ce que j'apprends en ce moment…
  unpopularOpinion,     // Mon avis impopulaire…
  bestMealEver,         // Le meilleur repas de ma vie…
  weekendPlan,          // Mon week-end idéal ressemble à…
  proudOf,              // Ce dont je suis le plus fier·e…
  neverAgain,           // Ce que je ne referai jamais…
  firstThingNotice,     // La première chose que je remarque…
  simplePleasure,       // Mon plaisir le plus simple…
  wouldTravelTo,        // Là où je repartirais demain…
  badAt,                // Ce à quoi je suis vraiment mauvais·e…
  changedMyMind,        // Ce qui m'a fait changer d'avis récemment…
  soundtrack,           // La musique qui me suit partout…
  askMeAbout,           // Demandez-moi de vous parler de…
}

extension PromptQuestionX on PromptQuestion {
  String label(AppLocalizations l) => switch (this) {
        PromptQuestion.perfectSunday => l.promptPerfectSunday,
        // … une clé l10n par valeur
      };

  /// Exemple grisé dans le champ. Hinge s'appuie beaucoup là-dessus : sans
  /// exemple, on obtient « bien » et « sympa ».
  String hint(AppLocalizations l) => switch (this) {
        PromptQuestion.perfectSunday => l.promptPerfectSundayHint,
        // …
      };
}
```

```dart
// lib/features/profile_setup/domain/prompt_answer.dart
import 'package:freezed_annotation/freezed_annotation.dart';
import 'prompt.dart';

part 'prompt_answer.freezed.dart';

@freezed
class PromptAnswer with _$PromptAnswer {
  const factory PromptAnswer({
    required PromptQuestion question,
    required String answer,
  }) = _PromptAnswer;

  const PromptAnswer._();

  /// Longueur maximale — miroir du CHECK SQL.
  static const int maxLength = 140;

  bool get isFilled => answer.trim().isNotEmpty;
}
```

Dans `UserProfile` :

```dart
    /// Réponses aux prompts, ordonnées (position 0..2). Deux réponses
    /// remplies sont exigées par [isComplete] : ce sont elles qui alimentent
    /// l'appel, et un appel sans matière est un appel raté.
    @Default(<PromptAnswer>[]) List<PromptAnswer> prompts,

  static const int maxPrompts = 3;
  static const int requiredPrompts = 2;

  List<PromptAnswer> get filledPrompts =>
      prompts.where((p) => p.isFilled).toList(growable: false);

  // dans isComplete, ajouter :
  //   && filledPrompts.length >= requiredPrompts
```

Migration :

```sql
-- supabase/migrations/20260820110000_user_prompts.sql
-- Miroir de PromptQuestion (lib/features/profile_setup/domain/prompt.dart).
-- Toute nouvelle valeur d'enum doit être ajoutée ici AUSSI.
CREATE TABLE IF NOT EXISTS public.user_prompts (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  position   SMALLINT NOT NULL CHECK (position >= 0 AND position < 3),
  question   TEXT NOT NULL CHECK (question IN (
               'perfectSunday','cantShutUpAbout','makeMeLaugh','learningRightNow',
               'unpopularOpinion','bestMealEver','weekendPlan','proudOf',
               'neverAgain','firstThingNotice','simplePleasure','wouldTravelTo',
               'badAt','changedMyMind','soundtrack','askMeAbout')),
  answer     TEXT NOT NULL CHECK (
               length(trim(answer)) BETWEEN 1 AND 140),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

  UNIQUE (user_id, position),
  -- Une même question ne peut pas être répondue deux fois.
  UNIQUE (user_id, question)
);

CREATE INDEX IF NOT EXISTS user_prompts_user_idx ON public.user_prompts(user_id);

ALTER TABLE public.user_prompts ENABLE ROW LEVEL SECURITY;

-- Les prompts sont le SEUL contenu visible avant l'appel : lisibles par
-- tout utilisateur authentifié non banni, contrairement aux photos.
CREATE POLICY "user_prompts_select_authenticated"
  ON public.user_prompts FOR SELECT TO authenticated
  USING (true);

CREATE POLICY "user_prompts_modify_own"
  ON public.user_prompts FOR ALL TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

CREATE TRIGGER trg_user_prompts_updated_at
  BEFORE UPDATE ON public.user_prompts
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
```

Lecture/écriture dans `SupabaseProfileRepository` — même schéma que `user_photos` :

```dart
// getProfile() — ajouter :
final promptRows = await _client
    .from('user_prompts')
    .select()
    .eq('user_id', userId)
    .order('position');

// saveProfile() — après user_preferences :
await _client.from('user_prompts').delete().eq('user_id', profile.userId);
if (profile.filledPrompts.isNotEmpty) {
  await _client.from('user_prompts').insert([
    for (var i = 0; i < profile.filledPrompts.length; i++)
      {
        'user_id': profile.userId,
        'position': i,
        'question': profile.filledPrompts[i].question.name,
        'answer': profile.filledPrompts[i].answer.trim(),
      },
  ]);
}
```

> Le `delete` puis `insert` est volontairement brutal : trois lignes maximum, et ça
> évite toute la gymnastique de réconciliation de positions. À faire dans une RPC
> transactionnelle si on veut être rigoureux.

**Nouvelle étape de setup** — le flux passe de 4 à 5 étapes. La placer **en position 4**,
juste avant `FinalizeStep` : l'utilisateur a déjà investi, il abandonne moins.

```dart
// profile_setup_screen.dart
static const _stepCount = 5;
// children : IdentityStep, SeekingStep, VibeStep, PromptsStep, FinalizeStep

bool _validForStep(int i, ProfileDraft d) => switch (i) {
      0 => d.isStep1Valid, 1 => d.isStep2Valid, 2 => d.isStep3Valid,
      3 => d.isStep4Valid,          // prompts
      4 => d.isStep5Valid,          // availability
      _ => false,
    };
```

```dart
// ProfileDraft
@Default(<PromptAnswer>[]) ... // même champ
bool get isStep4Valid =>
    prompts.where((p) => p.isFilled).length >= UserProfile.requiredPrompts;
bool get isStep5Valid => availability != null;
```

**Affichage pendant l'appel** — le point qui justifie tout le reste :

```dart
// lib/features/call/presentation/widgets/prompt_lifeline.dart
/// Bandeau replié en bas de l'écran d'appel. Se déplie d'un tap et montre
/// les réponses du pair. C'est le filet de sécurité des cinq minutes :
/// quand le silence tombe, on a quelque chose à demander.
///
/// Volontairement discret : opacité 0.5 au repos, aucune animation
/// d'apparition, jamais de badge ni de pastille. On ne veut pas voler
/// l'attention pendant que quelqu'un parle.
class PromptLifeline extends StatefulWidget { ... }
```

### Vérification

- [ ] Un profil avec 1 seule réponse ne peut pas terminer le setup.
- [ ] Une réponse de 141 caractères est refusée côté client **et** côté SQL.
- [ ] Deux fois la même question est impossible (`UNIQUE(user_id, question)`).
- [ ] Les prompts du pair sont lisibles avant l'appel (RLS `select_authenticated`).
- [ ] Le bandeau d'appel n'apparaît que replié et ne masque aucun contrôle.
- [ ] `EditProfileScreen` permet de changer ses prompts après coup.

### Prompt Claude Code

```
Point 1 : ajoute les prompts. Crée domain/prompt.dart (enum 16 questions) et
domain/prompt_answer.dart (freezed, 140 car max), ajoute le champ prompts à
UserProfile avec requiredPrompts = 2, la migration user_prompts, la
lecture/écriture dans SupabaseProfileRepository, une 5e étape PromptsStep dans
le profile setup, et les clés l10n FR + EN pour les 16 questions et leurs
exemples. N'implémente PAS encore l'affichage pendant l'appel — on le fera
juste après. Régénère freezed et l10n.
```

---

## Point 10 — Le like porte sur une réponse, pas sur la personne

### État actuel

`suggestion_card.dart` : deux boutons, ✕ et ♥ « Proposer un appel ». Binaire, sans contexte.

### Décision

Une fois les prompts en place : « Proposer un appel » **depuis une réponse précise**.
La réponse choisie devient l'amorce affichée aux deux personnes au début de l'appel :

> *Alexandre a réagi à « Un dimanche parfait »*

C'est la traduction DateNow du mécanisme de Hinge — sauf qu'ici l'amorce ne sert pas à
ouvrir un chat, elle sert à ouvrir **les dix premières secondes d'une visio**, qui sont
le vrai point de rupture.

### Code

```sql
-- supabase/migrations/20260820120000_call_opening.sql
ALTER TABLE public.calls
  ADD COLUMN IF NOT EXISTS opening_prompt_id UUID
    REFERENCES public.user_prompts(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.calls.opening_prompt_id IS
  'Réponse de prompt qui a déclenché la proposition d''appel. Affichée aux '
  'deux participants au démarrage.';
```

```dart
// suggestion_card.dart — chaque prompt devient tappable
for (final p in suggestion.candidate.filledPrompts)
  _PromptTile(
    prompt: p,
    onPropose: () => onProposeCall(promptId: p.id),
  ),

// Le bouton global reste, sans amorce — pour ceux qui ne veulent pas choisir.
AppButton(label: l10n.discoverProposeCall, onPressed: () => onProposeCall());
```

### Vérification

- [ ] Proposer depuis un prompt → `calls.opening_prompt_id` renseigné.
- [ ] L'amorce s'affiche 8 secondes au début de l'appel puis se replie dans le bandeau.
- [ ] Proposer sans choisir de prompt reste possible.

---

## Point 2 — Une question après l'appel

### État actuel

`post_call_screen.dart` : `_Stage.decide` → révéler → match/pass. **Aucune question sur
l'appel.** Le système ne sait pas si les cinq minutes se sont bien passées.

### Décision

Une question, trois réponses, **posée avant la révélation de la photo**.

C'est le point où DateNow peut faire mieux que Hinge, pas seulement aussi bien. Hinge
demande « ça s'est bien passé ? » plusieurs jours après un rendez-vous hors app, quand
le souvenir est reconstruit. DateNow a l'événement à l'intérieur de l'app et peut
demander **dix secondes après**, et surtout **avant que la photo n'influence la réponse**.
Poser la question après la révélation biaiserait tout : on note la tête, pas la
conversation.

```
Comment s'est passé l'appel ?
😊 Bien        😐 Moyen        😖 Mal à l'aise
Anonyme. Jamais partagé avec cette personne.
```

- « Mal à l'aise » → ouvre `report_sheet` pré-rempli, **et court-circuite la révélation**
  (on passe directement à `_Stage.passed`). Personne ne devrait avoir à regarder la photo
  de quelqu'un qui l'a mise mal à l'aise pour pouvoir partir.
- Les deux autres → `_Stage.decide` normalement.
- Jamais bloquant : un bouton « Passer » discret.

### Code

```dart
// lib/features/post_call/domain/call_vibe.dart
/// Ressenti déclaré juste après l'appel, avant toute révélation de photo.
/// Confidentiel : jamais exposé au pair, ni maintenant ni plus tard.
enum CallVibe { good, neutral, uncomfortable }
```

```sql
-- supabase/migrations/20260820130000_call_feedback.sql
CREATE TABLE IF NOT EXISTS public.call_feedback (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  call_id        UUID NOT NULL REFERENCES public.calls(id) ON DELETE CASCADE,
  rater_id       UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  rated_user_id  UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  vibe           TEXT NOT NULL CHECK (vibe IN ('good','neutral','uncomfortable')),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),

  UNIQUE (call_id, rater_id),
  CONSTRAINT call_feedback_no_self CHECK (rater_id <> rated_user_id)
);

CREATE INDEX IF NOT EXISTS call_feedback_rated_idx
  ON public.call_feedback(rated_user_id, created_at DESC);

ALTER TABLE public.call_feedback ENABLE ROW LEVEL SECURITY;

-- Écriture seule. PERSONNE ne peut lire, pas même l'auteur : la promesse
-- « anonyme, jamais partagé » doit être vraie au niveau de la base, pas
-- seulement dans la copie de l'écran. Les agrégats sont calculés par des
-- fonctions SECURITY DEFINER.
CREATE POLICY "call_feedback_insert_self"
  ON public.call_feedback FOR INSERT TO authenticated
  WITH CHECK (rater_id = auth.uid());

-- Signal de modération : un utilisateur qui accumule les 'uncomfortable'
-- est remonté aux modérateurs, sans jamais exposer qui a répondu quoi.
CREATE OR REPLACE VIEW public.moderation_vibe_flags AS
  SELECT rated_user_id,
         COUNT(*) FILTER (WHERE vibe = 'uncomfortable') AS uncomfortable_count,
         COUNT(*) AS total_count,
         MAX(created_at) AS last_at
    FROM public.call_feedback
   GROUP BY rated_user_id
  HAVING COUNT(*) FILTER (WHERE vibe = 'uncomfortable') >= 3;

REVOKE ALL ON public.moderation_vibe_flags FROM authenticated, anon;
```

```dart
// post_call_screen.dart
enum _Stage { vibe, decide, waiting, matched, noMatch, passed }
//            ^^^^ nouvel état initial

Future<void> _submitVibe(CallVibe vibe) async {
  final callId = ref.read(activeCallIdProvider);
  final peer = ref.read(activeMatchProvider)?.candidate;
  if (callId != null && peer != null) {
    // Non bloquant : un échec réseau ne doit pas retenir l'utilisateur
    // sur cet écran.
    unawaited(
      ref.read(callFeedbackRepositoryProvider)?.submit(
            callId: callId,
            raterId: ref.read(currentUserProvider)!.id,
            ratedUserId: peer.userId,
            vibe: vibe,
          ).catchError((Object e) => _log.warn('vibe non enregistré: $e')),
    );
  }

  if (vibe == CallVibe.uncomfortable) {
    // On ne montre pas la photo de quelqu'un qui vous a mis mal à l'aise
    // pour vous laisser partir.
    if (mounted) {
      await showReportSheet(context,
          reportedUserId: peer!.userId,
          reportedDisplayName: peer.firstName);
    }
    await _pass();
    return;
  }
  setState(() => _stage = _Stage.decide);
}
```

### Vérification

- [ ] L'écran apparaît avant la révélation, jamais après.
- [ ] « Mal à l'aise » ouvre le signalement et n'affiche jamais la photo.
- [ ] Un `SELECT` sur `call_feedback` avec une clé anon/authenticated échoue.
- [ ] Passer sans répondre est possible en un tap.
- [ ] Une seule réponse par (appel, auteur) — le `UNIQUE` doit tenir.

### Prompt Claude Code

```
Point 2 : ajoute l'étape de feedback post-appel. Crée domain/call_vibe.dart, la
migration call_feedback (RLS insert-only, aucune lecture) + la vue de
modération, un CallFeedbackRepository sur le modèle de RevealRepository, et
insère _Stage.vibe AVANT _Stage.decide dans post_call_screen.dart. « Mal à
l'aise » doit ouvrir le report sheet et sauter la révélation. Textes dans les
.arb.
```

---

## Point 12 — Ouvrir la conversation avec l'appel

### État actuel

`messages` n'a que `body TEXT`. La conversation s'ouvre sur un champ vide alors que les
deux personnes viennent de se parler cinq minutes en visio.

`MatchScore.breakdown` contient déjà les intérêts communs calculés par
`_weightedJaccard` — ils ne sont **jamais affichés nulle part**.

### Décision

Deux ajouts, aucun média (pas de photo ni de vocal : ce serait contradictoire avec le
produit, la photo vient d'être révélée et l'audio, c'était l'appel).

1. **Un message système** non effaçable en tête de conversation :
   *« Vous vous êtes parlé 5 minutes le 19 août. »*
2. **Trois amorces** proposées au-dessus du champ de saisie, tirées des intérêts communs
   réels — pas d'un catalogue générique.

### Code

```sql
-- supabase/migrations/20260820140000_system_messages.sql
ALTER TABLE public.messages
  ADD COLUMN IF NOT EXISTS kind TEXT NOT NULL DEFAULT 'user'
    CHECK (kind IN ('user', 'system'));

-- Un message système n'a pas d'auteur humain : on relâche la contrainte
-- d'insertion pour les lignes écrites par la fonction d'ouverture.
COMMENT ON COLUMN public.messages.kind IS
  'user = écrit par un participant. system = carte de contexte insérée à '
  'l''ouverture de la conversation (durée de l''appel, date). Non effaçable.';
```

```dart
// messaging_repository.dart — dans ensureConversation, après la création
if (created) {
  await _client.from('messages').insert({
    'conversation_id': conversation.id,
    'sender_id': currentUserId,
    'kind': 'system',
    'body': 'call_recap:${callDate.toIso8601String()}:$durationSeconds',
  });
}
```

> Le corps est un **code**, pas une phrase : la conversation peut être lue en français
> par l'un et en anglais par l'autre. `MessageBubble` décode le préfixe `call_recap:` et
> rend la phrase via `l10n`. Ne jamais stocker de texte localisé en base.

```dart
// message_bubble.dart
if (message.kind == MessageKind.system) {
  return _SystemCard(text: _decodeSystem(message.body, l10n));
}
```

```dart
// message_input.dart — amorces
/// Trois amorces tirées des intérêts réellement communs (MatchScore.breakdown).
/// Affichées uniquement tant que la conversation ne contient aucun message
/// utilisateur — après, elles disparaissent définitivement.
class IcebreakerRow extends ConsumerWidget { ... }
```

### Vérification

- [ ] Une nouvelle conversation contient exactement un message système.
- [ ] Le message système s'affiche en français ou en anglais selon la locale du lecteur.
- [ ] Les amorces disparaissent dès le premier vrai message.
- [ ] Les amorces citent des intérêts que les deux profils ont réellement en commun.

---

# LOT C — CONFIANCE

## Point 5 — Préparer l'appel avant d'en avoir besoin

### État actuel

`onboarding_screen.dart` : 3 pages statiques, puis l'auth. **Aucune permission demandée,
aucune acceptation de CGU, aucun test technique.** `permission_handler: ^11.3.1` est déjà
dans le `pubspec.yaml` mais n'est pas utilisé sur ce chemin.

Scénario d'échec actuel : l'utilisateur appuie sur « Trouver quelqu'un », le matching
aboutit, et c'est **à ce moment-là**, avec un inconnu qui attend, qu'iOS demande l'accès
à la caméra.

### Décision

Un écran `CallReadinessScreen` obligatoire **une seule fois**, avant le premier matching.
Trois blocs :

1. **Amorce interne** avant la demande système. Si l'utilisateur refuse la boîte de
   dialogue iOS, elle ne se rouvre jamais — il faut donc ne la déclencher qu'une fois
   l'intention établie.
2. **Aperçu de soi** : sa propre caméra + un niveau de micro qui bouge. C'est aussi utile
   pour le cadrage et la lumière que pour la permission — et ça détend.
3. **Deux règles** en une phrase, pas une charte de dix points.

Utiliser `startPreview()` d'`agora_rtc_engine` (déjà en dépendance) plutôt que d'ajouter
le paquet `camera`.

### Code

```dart
// lib/app/router/app_routes.dart
callReadiness('/call/ready'),

// lib/core/constants/storage_keys.dart
static const callReadinessDone = 'call_readiness_done_v1';
```

```dart
// lib/features/call/presentation/call_readiness_screen.dart
/// Préparation avant le premier appel. Trois raisons d'exister :
///
/// 1. Demander caméra + micro AVANT qu'un inconnu attende en face. iOS ne
///    montre sa boîte de dialogue qu'une fois : la déclencher pendant un
///    matching, c'est risquer de tuer l'appel et l'inscription d'un coup.
/// 2. Laisser l'utilisateur se voir. Le cadrage et la lumière se corrigent
///    en dix secondes ici, jamais en direct.
/// 3. Poser les deux règles.
///
/// Franchi une seule fois (`StorageKeys.callReadinessDone`), rejouable
/// depuis Réglages.
class CallReadinessScreen extends ConsumerStatefulWidget { ... }

Future<bool> _requestPermissions() async {
  final statuses = await [Permission.camera, Permission.microphone].request();
  return statuses.values.every((s) => s.isGranted);
}
```

Garde dans `matching_screen.dart` (et non dans le routeur, pour garder un message
explicite) :

```dart
Future<void> _startMatching() async {
  final prefs = ref.read(preferencesServiceProvider);
  if (!(prefs.getBool(StorageKeys.callReadinessDone) ?? false)) {
    context.pushNamed(AppRoute.callReadiness.name);
    return;
  }
  // …
}
```

Amorce des notifications, à la fin de l'onboarding et non au lancement :

```dart
// onboarding_screen.dart, dernière page — avant _skip()
// On explique avant de demander. Une demande système refusée est définitive ;
// une amorce interne refusée peut être reproposée plus tard.
final wants = await showNotificationPrimer(context);
if (wants) await Permission.notification.request();
```

### Vérification

- [ ] Sur une installation neuve, aucune boîte de dialogue système avant l'écran de préparation.
- [ ] Refuser la caméra affiche un message clair + un bouton vers les Réglages iOS.
- [ ] L'aperçu s'affiche et se coupe proprement à la sortie (`stopPreview()` dans `dispose`).
- [ ] Le second matching ne repasse pas par l'écran.
- [ ] Un lien « Refaire le test » existe dans Réglages.

### Prompt Claude Code

```
Point 5 : crée CallReadinessScreen (permissions caméra + micro via
permission_handler, aperçu local via agora_rtc_engine startPreview, deux règles
de conduite), la route callReadiness, la clé StorageKeys.callReadinessDone, la
garde dans matching_screen, et l'amorce de notification en fin d'onboarding.
Attention à stopPreview() dans dispose.
```

---

## Point 9 — Ne plus perdre le travail de l'utilisateur

### État actuel

`ProfileSetupController` garde le `ProfileDraft` **en mémoire uniquement**.
`shared_preferences` est dans le `pubspec.yaml` mais n'est pas utilisé ici. Si l'app est
tuée à l'étape 3, tout est à refaire.

Par ailleurs `isStep3Valid` exige `interests.length >= 3` mais **rien ne le dit à
l'écran** : le bouton est simplement grisé.

Et `AppTextField` pour le prénom n'a ni `maxLength` ni `inputFormatters`, alors que le
`CHECK` SQL impose `length(trim(first_name)) BETWEEN 1 AND 60`.

### Décision

Trois correctifs peu coûteux, gros impact sur la conversion.

### Code

**a) Brouillon persisté.** Sérialiser à chaque changement d'étape (pas à chaque
frappe — inutile et coûteux). `photoBytes` est volontairement exclu : on ne met pas
une image en base64 dans les préférences.

```dart
// profile_setup_controller.dart
Map<String, dynamic> toJson() => {
      'firstName': firstName,
      'birthDate': birthDate?.toIso8601String(),
      'gender': gender?.name,
      'orientation': orientation?.name,
      'seekingGenders': seekingGenders.map((e) => e.name).toList(),
      'seekingAgeMin': seekingAgeMin,
      'seekingAgeMax': seekingAgeMax,
      'maxDistanceKm': maxDistanceKm,
      'intentions': intentions.map((e) => e.name).toList(),
      'interests': interests.map((e) => e.name).toList(),
      'prompts': prompts.map((p) => {'q': p.question.name, 'a': p.answer}).toList(),
      'availability': availability?.name,
      // photoBytes volontairement absent.
    };

/// Sauvegarde le brouillon. Appelé à chaque changement d'étape.
Future<void> persistDraft() async {
  await _ref.read(preferencesServiceProvider)
      .setString(StorageKeys.profileDraft, jsonEncode(state.toJson()));
}

/// Purge après un submit réussi — sinon un second compte sur le même
/// téléphone hériterait du brouillon du premier.
Future<void> clearDraft() async =>
    _ref.read(preferencesServiceProvider).remove(StorageKeys.profileDraft);
```

**b) Dire ce qui manque.** Sous le bouton, un texte qui explique le blocage :

```dart
/// Ce qui manque pour valider l'étape courante. Un bouton grisé sans
/// explication est la première cause d'abandon d'un onboarding.
String? _missingHint(int step, ProfileDraft d, AppLocalizations l) =>
    switch (step) {
      0 when (d.firstName?.trim().isEmpty ?? true) => l.hintNeedFirstName,
      0 when d.gender == null => l.hintNeedGender,
      0 when d.orientation == null => l.hintNeedOrientation,
      1 when d.seekingGenders.isEmpty => l.hintNeedSeeking,
      2 when d.intentions.isEmpty => l.hintNeedIntention,
      2 when d.interests.length < 3 =>
        l.hintNeedInterests(3 - d.interests.length),   // « encore 2 centres d'intérêt »
      3 when d.prompts.where((p) => p.isFilled).length < 2 =>
        l.hintNeedPrompts(2 - d.prompts.where((p) => p.isFilled).length),
      4 when d.availability == null => l.hintNeedAvailability,
      _ => null,
    };
```

**c) Borner le prénom** — miroir du `CHECK` SQL :

```dart
AppTextField(
  maxLength: 40,                      // < 60 côté SQL, marge de sécurité
  inputFormatters: [
    FilteringTextInputFormatter.deny(RegExp(r'[\n\t]')),
  ],
  textCapitalization: TextCapitalization.words,
  // …
)
```

### Vérification

- [ ] Remplir 3 étapes, tuer l'app, la rouvrir : on reprend là où on en était.
- [ ] Après un submit réussi, le brouillon est purgé.
- [ ] Le texte sous le bouton indique précisément ce qui manque, à chaque étape.
- [ ] Un prénom de 41 caractères est impossible à saisir.
- [ ] Se déconnecter puis créer un autre compte n'hérite pas du brouillon précédent.

---

## Point 11 — Assumer la rareté

### État actuel

`quota_status.dart` : `cap == null` signifie illimité, et le commentaire précise
« women + non-binary users in this MVP ». Le plafond ne s'applique donc **qu'aux hommes**.
`quota_limit_sheet.dart` affiche `l10n.quotaLimitTitle` / `quotaLimitBody` sans jamais
donner de raison. Le `QuotaService.capFor(gender)` porte la valeur réelle (5 d'après le
commentaire de la feuille : « the daily 5-match cap »).

Deux problèmes distincts :
- **le pourquoi n'est jamais donné** ;
- **l'asymétrie homme/femme n'est expliquée nulle part.** Un utilisateur qui la découvre
  par recoupement la lira comme une injustice, pas comme un choix d'équilibre.

### Décision

- Ajouter une phrase de justification dans la feuille de limite, comme Hinge le fait
  pour ses 8 likes.
- **Rendre le compteur visible en permanence**, pas seulement au moment du blocage :
  une limite qu'on découvre en la heurtant est punitive, une limite qu'on voit venir est
  un cadre.
- Assumer l'asymétrie dans l'aide plutôt que la laisser se découvrir.

### Code

```json
// app_fr.arb
"quotaLimitTitle": "Vous avez fait vos {cap} appels",
"quotaLimitWhy": "Trois à cinq appels par jour, c'est la limite au-delà de laquelle les conversations se ressemblent. Ce n'est pas une contrainte technique, c'est un choix.",
"quotaRemaining": "{n, plural, =0{Plus d'appel aujourd'hui} =1{1 appel restant aujourd'hui} other{{n} appels restants aujourd'hui}}"
```

```dart
// home_hero_card.dart — sous le CTA
final quota = ref.watch(quotaStatusProvider).valueOrNull;
if (quota != null && !quota.isUnlimited)
  Text(l10n.quotaRemaining(quota.remaining ?? 0),
       style: AppTypography.caption);
```

Et dans `help_screen.dart`, une entrée explicite :
*« Pourquoi les hommes ont-ils une limite d'appels ? »* — avec la vraie raison
(équilibre de la file d'attente), pas une formule creuse.

> **À trancher côté produit** : une asymétrie de quota basée sur le genre déclaré est
> défendable sur l'équilibre de file, mais elle est aussi contestable et difficile à
> expliquer. Une alternative moins clivante : un plafond identique pour tous, plus élevé
> (5–8), et une **priorité de file** accordée au genre sous-représenté à l'instant T.
> Même effet sur l'équilibre, aucune règle visible différenciée.

---

## Point 13a/b — Finitions

**a) Chaînes en dur.** Dans `post_call_screen.dart` : « Votre date réfléchit… »,
« Cette personne n'a pas encore répondu. », « Continuer à attendre », « Passer »,
« C'est réciproque ✨ », « Pas cette fois », et le tooltip « Signaler » branché sur
`languageCode == 'fr'`. Idem dans `conversation_screen.dart` pour le menu.

Clés à ajouter dans les deux `.arb` :

```json
"postCallWaitingTitle": "Votre date réfléchit…",
"postCallWaitingBody": "Cette personne n'a pas encore répondu. On vous prévient dès qu'elle le fait.",
"postCallKeepWaiting": "Continuer à attendre",
"postCallNotifyMe": "Me prévenir",
"postCallDecline": "Ne pas donner suite",
"postCallDeclineConfirmTitle": "Ne pas donner suite ?",
"postCallDeclineConfirmBody": "Cette personne ne pourra plus vous recontacter, même si elle vous avait choisi.",
"postCallDeclineConfirmCta": "Confirmer",
"postCallMatchedTitle": "C'est réciproque",
"postCallNoMatchTitle": "Pas cette fois",
"actionReport": "Signaler",
"actionBlock": "Bloquer",
"actionUnmatch": "Ne plus être en contact",
"reportAlsoBlock": "Bloquer aussi cette personne"
```

Vérification : `rg "'[A-ZÀ-Ú][^']{12,}'" lib/features --type dart` ne doit plus rien
retourner d'affichable.

**b) Le match tiré au sort.** Dans `post_call_screen.dart`, le chemin de repli fait
`peerAccepts = Random().nextDouble() < 0.6` après 1600 ms. Il s'active **dès que Supabase
ou le `callId` est absent** — donc potentiellement pendant une démo client.

```dart
// À encadrer explicitement :
assert(() {
  _log.warn('MODE DÉMO — décision du pair simulée (60 %)');
  return true;
}());
if (!kDebugMode) {
  // En release, pas de match fictif : on affiche une erreur honnête.
  setState(() => _stage = _Stage.noMatch);
  return;
}
```

---

# LOT D — RÉTENTION

## Point 6 — Notifications

### État actuel

`notifications_screen.dart` n'est qu'un écran de **réglages** : il écrit dans
`user_settings` (`push_new_match`, `push_suggestions`, `push_messages`…). **Aucun envoi
n'existe** dans le code, et aucune dépendance push n'est déclarée.

Le cas le plus grave : quand le pair accepte après le départ de l'utilisateur, celui-ci
ne l'apprend **jamais** — il faudrait qu'il rouvre la conversation par hasard.

### Décision

Architecture minimale, sans surcouche :

```
app Flutter ──(token)──▶ table push_tokens
                              │
Postgres trigger ──▶ Edge Function `notify` ──▶ FCM / APNs
   sur reveals, messages, weekly_suggestions
```

Quatre déclencheurs, dans l'ordre d'importance :

| Déclencheur | Message | Réglage |
|---|---|---|
| Le pair a révélé et accepté | « Camille aussi. Votre conversation est ouverte. » | `push_new_match` |
| Message non lu depuis 24 h | « Camille attend votre réponse » | `push_messages` |
| Lot hebdo généré (lundi) | « Trois personnes pour vous cette semaine » | `push_suggestions` |
| Quota rechargé | « Vos appels sont de retour » | `push_suggestions` |

Le premier est le seul **indispensable** : sans lui, le point 7 (« Me prévenir ») ne
tient pas sa promesse. Les trois autres sont du confort.

**Repli immédiat** : `flutter_local_notifications` couvre le cas où l'app tourne encore
en arrière-plan, et se met en place en une heure. Ça débloque le point 7 pendant que le
push serveur se construit.

### Code

```sql
-- supabase/migrations/20260820150000_push_tokens.sql
CREATE TABLE IF NOT EXISTS public.push_tokens (
  user_id     UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  token       TEXT NOT NULL,
  platform    TEXT NOT NULL CHECK (platform IN ('ios','android')),
  locale      TEXT NOT NULL DEFAULT 'fr',
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, token)
);

ALTER TABLE public.push_tokens ENABLE ROW LEVEL SECURITY;
CREATE POLICY "push_tokens_own" ON public.push_tokens FOR ALL TO authenticated
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());
```

> `locale` est stockée avec le token : le serveur doit envoyer le texte dans la langue de
> l'utilisateur, pas dans celle du déclencheur.

```dart
// lib/core/services/push_service.dart
/// Enregistre le token FCM du device et le tient à jour. Le token change
/// à la réinstallation et parfois spontanément — d'où onTokenRefresh.
class PushService {
  Future<void> register(String userId) async { ... }
  Future<void> unregister(String userId) async { ... }  // à la déconnexion
}
```

### Vérification

- [ ] Utilisateur A part de l'écran d'attente, B accepte → A reçoit la notification.
- [ ] Désactiver `push_new_match` dans les réglages coupe réellement l'envoi.
- [ ] Un utilisateur anglophone reçoit une notification en anglais.
- [ ] Le token est supprimé à la déconnexion (sinon le device suivant reçoit les
      notifications du compte précédent).

---

## Point 3b/3c — Vraie géolocalisation

### État actuel

Aucun champ de localisation dans `profiles` ni dans `UserProfile`.
`MockCandidateFactory.distanceFor(self)` génère la distance, y compris pour les
candidats Supabase. `maxDistanceKm` n'est donc qu'une préférence sans effet.

### Décision

Précision volontairement grossière : **la ville et un point flouté**, pas la position
exacte. Sur une app de rencontre, stocker une position au mètre près est un risque
disproportionné — et personne n'a besoin de savoir qu'un match est à 1,2 km plutôt qu'à
« environ 2 km ».

- Capture à l'inscription et rafraîchissement à l'ouverture, jamais en continu.
- Arrondi à ~1 km avant écriture.
- Affichage par paliers : « à moins de 5 km », « à 10 km », « à 25 km ».

### Code

```sql
-- supabase/migrations/20260820160000_geo.sql
CREATE EXTENSION IF NOT EXISTS postgis;

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS location   GEOGRAPHY(POINT, 4326),
  ADD COLUMN IF NOT EXISTS city       TEXT,
  ADD COLUMN IF NOT EXISTS located_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS profiles_location_idx
  ON public.profiles USING GIST (location);

COMMENT ON COLUMN public.profiles.location IS
  'Position arrondie au kilomètre côté client. Ne JAMAIS exposer via une '
  'policy SELECT — seule la fonction candidates_within renvoie une distance '
  'dérivée, jamais les coordonnées.';

/// Candidats dans le rayon, avec leur distance. SECURITY DEFINER pour que
/// la position reste invisible : l'appelant reçoit des kilomètres, jamais
/// des coordonnées.
CREATE OR REPLACE FUNCTION public.candidates_within(p_max_km INTEGER)
RETURNS TABLE (candidate_id UUID, distance_km INTEGER)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT p.id,
         GREATEST(1, ROUND(ST_Distance(p.location, me.location) / 1000)::INT)
    FROM public.profiles p
    CROSS JOIN (SELECT location FROM public.profiles WHERE id = auth.uid()) me
   WHERE p.id <> auth.uid()
     AND p.location IS NOT NULL
     AND me.location IS NOT NULL
     AND NOT p.is_banned
     AND ST_DWithin(p.location, me.location, p_max_km * 1000)
     AND NOT EXISTS (
       SELECT 1 FROM public.blocked_users b
        WHERE (b.user_id = auth.uid() AND b.blocked_user_id = p.id)
           OR (b.user_id = p.id AND b.blocked_user_id = auth.uid())
     );
$$;

GRANT EXECUTE ON FUNCTION public.candidates_within(INTEGER) TO authenticated;
```

```dart
// profile_repository.dart — nouvelle méthode d'interface
/// Candidats dans le rayon, avec leur distance réelle. Remplace le couple
/// fetchPotentialCandidates + MockCandidateFactory.distanceFor.
Future<List<({UserProfile candidate, int distanceKm})>> nearbyCandidates({
  required String selfUserId,
  required int maxDistanceKm,
});
```

Une fois cette méthode branchée : supprimer `MockCandidateFactory.distanceFor` du chemin
Supabase, et repasser `kShowExactCompatibility` à `true` (point 3a).

### Vérification

- [ ] Aucune policy ne permet de lire `profiles.location`.
- [ ] `candidates_within` exclut les bloqués et les bannis dans les deux sens.
- [ ] Deux profils à 800 m affichent « à 1 km », jamais « à 0 km ».
- [ ] Refuser la géolocalisation reste possible : repli sur la ville déclarée.

---

# Tableau de bord

| Point | Fichiers principaux | Migration | Lot |
|---|---|---|---|
| 4 | `discover/data/discover_repository.dart` | `..._suggestions_distance.sql` | A |
| 3a | `matching/data/matching_service.dart`, `compatibility_badge.dart`, `weekly_suggestions_service.dart` | — | A |
| 7 | `post_call/presentation/post_call_screen.dart` | — | A |
| 8 | `messaging/.../conversation_screen.dart`, `safety/presentation/report_sheet.dart`, `messaging_repository.dart` | `..._unmatch.sql` | A |
| 13c | `app/router/app_router.dart` | — | A |
| 1 | `profile_setup/domain/*`, `steps/prompts_step.dart`, `profile_repository.dart`, `call/.../prompt_lifeline.dart` | `..._user_prompts.sql` | B |
| 10 | `discover/.../suggestion_card.dart`, `call_screen.dart` | `..._call_opening.sql` | B |
| 2 | `post_call/domain/call_vibe.dart`, `post_call_screen.dart` | `..._call_feedback.sql` | B |
| 12 | `messaging_repository.dart`, `message_bubble.dart`, `message_input.dart` | `..._system_messages.sql` | B |
| 5 | `call/presentation/call_readiness_screen.dart`, `matching_screen.dart`, `onboarding_screen.dart` | — | C |
| 9 | `profile_setup_controller.dart`, `profile_setup_screen.dart`, `identity_step.dart` | — | C |
| 11 | `quota_limit_sheet.dart`, `home_hero_card.dart`, `help_screen.dart` | — | C |
| 13a/b | `post_call_screen.dart`, `conversation_screen.dart`, `l10n/*.arb` | — | C |
| 6 | `core/services/push_service.dart`, Edge Function `notify` | `..._push_tokens.sql` | D |
| 3b/3c | `profile_repository.dart`, `discover_repository.dart` | `..._geo.sql` | D |

---

# Comment piloter Claude Code

Un point à la fois, dans l'ordre des lots. Le prompt d'ouverture de session :

```
Lis docs/design/DATENOW_UX_IMPLEMENTATION.md et docs/design/DATENOW_UI_MOCKUP.html.
On va exécuter le plan point par point, dans l'ordre des lots A → B → C → D.

Règles :
- Un point = un commit. Ne commence jamais le point suivant sans mon accord.
- Après chaque point, lance `flutter analyze` et `flutter test`, et montre-moi
  la checklist de vérification du point avec ce que tu as réellement pu tester.
- Si une décision du document te semble fausse au vu du code réel, dis-le
  AVANT d'implémenter — le document a été écrit sans lire les 100 % du repo.
- Les migrations Supabase ne sont jamais appliquées automatiquement : tu les
  écris, je les lance.

Commence par le point 4.
```

Et à la fin de chaque point :

```
Montre-moi le diff, puis la checklist de vérification du point N avec, pour
chaque ligne, si tu l'as vérifiée toi-même, si c'est à moi de la tester à la
main, ou si elle est bloquée.
```

---

## Ce qu'il ne faut pas faire

Trois tentations qui détruiraient le produit :

1. **Ajouter des photos avant l'appel.** La photo floutée est le seul vrai
   différenciateur, et le code la protège rigoureusement — le commentaire de
   `post_call_screen.dart` dit « the **only** place a real photo can surface », et c'est
   vrai. Tout ce document est écrit pour ajouter de la matière **sans** toucher à ça.
2. **Remplacer les prompts par une bio libre.** Plus simple à coder, beaucoup plus
   pauvre à lire, et une charge de modération que vous n'avez pas les moyens d'assumer.
3. **Rétablir le pourcentage de compatibilité avant d'avoir la géo.** Un chiffre à
   l'unité posé sur une distance tirée au sort, c'est une promesse qui ne tient pas au
   premier utilisateur qui compare deux cartes.
