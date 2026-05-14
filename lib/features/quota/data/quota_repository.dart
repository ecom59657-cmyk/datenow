import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../../../core/utils/logger.dart';
import '../../profile_setup/domain/user_profile.dart';
import '../domain/quota_status.dart';
import 'quota_service.dart';

/// Tracks how many matches each user has consumed today and decides whether
/// they can start another live date.
abstract class QuotaRepository {
  Future<QuotaStatus> currentStatus(UserProfile self);

  /// Bumps the daily counter by one. Safe to call even for unlimited users
  /// — the counter is harmless there.
  Future<void> recordMatch(UserProfile self);
}

// ---------------------------------------------------------------------------
// Mock — in-memory, keyed by (userId, day). Resets at local midnight naturally.
// ---------------------------------------------------------------------------

class MockQuotaRepository implements QuotaRepository {
  MockQuotaRepository(this._service);

  final QuotaService _service;
  final Map<String, int> _countsByKey = {};

  static const _log = AppLogger('MockQuota');

  String _key(String userId, [DateTime? now]) {
    final d = now ?? DateTime.now();
    final yyyy = d.year.toString().padLeft(4, '0');
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '$userId:$yyyy-$mm-$dd';
  }

  @override
  Future<QuotaStatus> currentStatus(UserProfile self) async {
    final cap = _service.capFor(self.gender);
    final used = _countsByKey[_key(self.userId)] ?? 0;
    return QuotaStatus(
      usedToday: used,
      cap: cap,
      checkedAt: DateTime.now(),
    );
  }

  @override
  Future<void> recordMatch(UserProfile self) async {
    final k = _key(self.userId);
    final next = (_countsByKey[k] ?? 0) + 1;
    _countsByKey[k] = next;
    _log.info('matches today for ${self.userId}: $next');
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
  Future<QuotaStatus> currentStatus(UserProfile self) {
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
