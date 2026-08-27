import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../../../core/services/supabase_service.dart';
import '../../../core/utils/logger.dart';
import '../../profile_setup/domain/user_profile.dart';
import '../domain/quota_status.dart';
import 'quota_service.dart';

/// Tracks how many matches each user has consumed today and decides whether
/// they can start another live date.
abstract class QuotaRepository {
  /// Today's snapshot. [isPremium] is passed in rather than looked up:
  /// the cap depends on the subscription, and a repository that reached
  /// for a provider to find out would be untestable and would couple the
  /// data layer to Riverpod.
  Future<QuotaStatus> currentStatus(
    UserProfile self, {
    required bool isPremium,
  });

  /// Bumps the daily counter by one. Safe to call even for unlimited users
  /// — the counter is harmless there.
  Future<void> recordMatch(UserProfile self);

  /// Settles the extra date a finished video earns, and reports whether it
  /// is actually available now.
  ///
  /// Not "grant": with AdMob server-side verification the grant happens in
  /// Postgres, driven by a signed callback from Google that this process
  /// never sees. All the app can do is wait for it and say whether it
  /// arrived. [knownBonusToday] is the count read *before* the video, so a
  /// callback that lands early is not mistaken for one that never came.
  ///
  /// False means "not yet", never "denied" — the date may still appear a
  /// moment later.
  Future<bool> awaitRewardedBonus(
    UserProfile self, {
    required int knownBonusToday,
  });
}

// ---------------------------------------------------------------------------
// Mock — in-memory, keyed by (userId, day). Resets at local midnight naturally.
// ---------------------------------------------------------------------------

class MockQuotaRepository implements QuotaRepository {
  MockQuotaRepository(this._service);

  final QuotaService _service;
  final Map<String, int> _countsByKey = {};
  final Map<String, int> _bonusByKey = {};

  static const _log = AppLogger('MockQuota');

  String _key(String userId, [DateTime? now]) =>
      _service.dayKey(userId, now);

  @override
  Future<QuotaStatus> currentStatus(
    UserProfile self, {
    required bool isPremium,
  }) async {
    final cap = _service.capFor(self.gender, isPremium: isPremium);
    final key = _key(self.userId);
    final used = _countsByKey[key] ?? 0;
    return QuotaStatus(
      usedToday: used,
      cap: cap,
      checkedAt: DateTime.now(),
      bonusToday: _bonusByKey[key] ?? 0,
      // Recomputed on every read, never stored: it is a pure function of
      // (user, day), so there is nothing to keep in sync.
      boostToday: _service.boostFor(self.userId, hasCap: cap != null),
    );
  }

  @override
  Future<void> recordMatch(UserProfile self) async {
    final k = _key(self.userId);
    final next = (_countsByKey[k] ?? 0) + 1;
    _countsByKey[k] = next;
    _log.info('matches today for ${self.userId}: $next');
  }

  @override
  Future<bool> awaitRewardedBonus(
    UserProfile self, {
    required int knownBonusToday,
  }) async {
    // No server, no signature, nothing to wait for: the mock is the whole
    // world here, so it grants directly.
    final k = _key(self.userId);
    final next = (_bonusByKey[k] ?? 0) + 1;
    _bonusByKey[k] = next;
    _log.info('bonus dates today for ${self.userId}: $next');
    return true;
  }
}

// ---------------------------------------------------------------------------
// Supabase — stub kept honest with [UnimplementedError]
// ---------------------------------------------------------------------------

class SupabaseQuotaRepository implements QuotaRepository {
  SupabaseQuotaRepository(this._client);

  final sb.SupabaseClient _client;

  // No QuotaService here on purpose. Every number this class returns is the
  // server's; keeping a local copy of the policy would invite someone to
  // "fall back" to it and quietly re-open the cap during an outage.
  static const _log = AppLogger('SupabaseQuota');

  /// Reads today's allowance from `quota_status()`.
  ///
  /// [isPremium] is accepted for interface parity but deliberately ignored:
  /// the server reads `subscriptions` itself. A client that could name its
  /// own tier could name the wrong one.
  @override
  Future<QuotaStatus> currentStatus(
    UserProfile self, {
    required bool isPremium,
  }) async {
    final row = await _client.rpc('quota_status') as Map<String, dynamic>;
    _log.info(
      'quota_status → used=${row['used_today']} cap=${row['cap'] ?? "∞"} '
      'bonus=${row['bonus_today']} boost=${row['boost_today']} '
      'premium=${row['is_premium']} day=${row['day']}',
    );
    return QuotaStatus(
      usedToday: (row['used_today'] as num).toInt(),
      cap: (row['cap'] as num?)?.toInt(),
      checkedAt: DateTime.now(),
      bonusToday: (row['bonus_today'] as num).toInt(),
      boostToday: (row['boost_today'] as num).toInt(),
    );
  }

  /// Nothing to write. Consumption is derived from `public.calls`, which the
  /// matching RPCs already insert into — so a date counts the moment it
  /// actually happens, on whichever path started it.
  ///
  /// This is also the fix for a live bug: the Home "Lancer un date" button
  /// never called this method, so only Discover-initiated dates were ever
  /// charged. Deriving the count removes the possibility of forgetting.
  @override
  Future<void> recordMatch(UserProfile self) async {}

  /// Waits for AdMob's signed callback to be settled in Postgres.
  ///
  /// This app has no way to grant itself anything any more — that is the
  /// point of SSV, and grant_quota_bonus() is revoked from `authenticated`.
  /// Google posts to the admob-ssv Edge Function directly, so the only thing
  /// left to do here is ask again until the row shows up.
  ///
  /// Polling rather than a realtime subscription: it runs once, for a few
  /// seconds, on a sheet the user is already looking at. A subscription
  /// would cost a socket and a lifecycle for the same six seconds.
  @override
  Future<bool> awaitRewardedBonus(
    UserProfile self, {
    required int knownBonusToday,
  }) async {
    const backoff = [300, 500, 800, 1200, 1500, 1700]; // ~6 s in total
    for (final ms in backoff) {
      await Future<void>.delayed(Duration(milliseconds: ms));
      try {
        final status = await currentStatus(self, isPremium: false);
        if (status.bonusToday > knownBonusToday) {
          _log.info('bonus settled — bonus_today=${status.bonusToday}');
          return true;
        }
      } catch (e) {
        // A blip mid-poll is not a refusal; keep asking.
        _log.warn('bonus poll failed ($e)');
      }
    }
    _log.warn('bonus did not settle within the window — it may still land');
    return false;
  }
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

final quotaServiceProvider = Provider<QuotaService>((_) => const QuotaService());

final quotaRepositoryProvider = Provider<QuotaRepository>((ref) {
  final service = ref.watch(quotaServiceProvider);
  // The mock survives only where there is no server to ask: widget tests,
  // and a build with no Supabase credentials. Everywhere else the cap is
  // decided in Postgres, where killing the app does not reset it.
  if (ref.watch(supabaseAvailableProvider)) {
    return SupabaseQuotaRepository(ref.watch(supabaseClientProvider));
  }
  return MockQuotaRepository(service);
});
