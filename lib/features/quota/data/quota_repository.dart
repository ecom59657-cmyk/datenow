import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

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
  SupabaseQuotaRepository(this._client, this._service);

  // ignore: unused_field
  final sb.SupabaseClient _client;
  // ignore: unused_field
  final QuotaService _service;

  @override
  Future<QuotaStatus> currentStatus(
    UserProfile self, {
    required bool isPremium,
  }) {
    // TODO(datenow): call a Postgres function that counts today's matches
    // for `self.userId` using server-side `now()` so the day boundary is
    // consistent across devices.
    throw UnimplementedError('SupabaseQuotaRepository.currentStatus');
  }

  @override
  Future<void> recordMatch(UserProfile self) {
    // TODO(datenow): insert into a `match_consumptions` table with a
    // `consumed_at` timestamp; the daily count is derived server-side.
    throw UnimplementedError('SupabaseQuotaRepository.recordMatch');
  }

  @override
  Future<void> grantBonusDate(UserProfile self) {
    // TODO(datenow): insert into a `quota_bonuses` table. Verify the grant
    // server-side against an AdMob SSV callback before trusting it — a
    // client-only grant is trivially forged by a repackaged APK.
    throw UnimplementedError('SupabaseQuotaRepository.grantBonusDate');
  }
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

final quotaServiceProvider = Provider<QuotaService>((_) => const QuotaService());

final quotaRepositoryProvider = Provider<QuotaRepository>((ref) {
  // TODO(datenow): the Supabase quota backend (a Postgres function +
  // table counting matches per day) hasn't been deployed yet. Until it
  // is, we use the in-memory mock even when the rest of the app talks
  // to Supabase. This keeps "Find a date" working end-to-end instead of
  // dying on an UnimplementedError when the user taps the CTA.
  return MockQuotaRepository(ref.watch(quotaServiceProvider));
});
