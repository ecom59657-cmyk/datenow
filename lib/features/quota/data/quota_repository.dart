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

  /// Grants one extra date for today, earned by watching a rewarded ad.
  ///
  /// Callers must only invoke this after Google has confirmed the reward.
  /// Granting on dismissal would hand out free dates for closing a video.
  Future<void> grantBonusDate(UserProfile self);
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
  Future<void> grantBonusDate(UserProfile self) async {
    final k = _key(self.userId);
    final next = (_bonusByKey[k] ?? 0) + 1;
    _bonusByKey[k] = next;
    _log.info('bonus dates today for ${self.userId}: $next');
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

  /// Claims one extra date after a rewarded video.
  ///
  /// The server refuses past three a day, so a repackaged client that skips
  /// the video buys a bounded number of dates rather than an endless supply.
  /// Making it unforgeable needs AdMob server-side verification, which will
  /// write these rows with a signed transaction id instead.
  @override
  Future<void> grantBonusDate(UserProfile self) async {
    final row =
        await _client.rpc('grant_quota_bonus') as Map<String, dynamic>;
    if (row['granted'] == true) {
      _log.info('bonus granted — bonus_today=${row['bonus_today']}');
    } else {
      _log.warn('bonus refused: ${row['reason']}');
    }
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
