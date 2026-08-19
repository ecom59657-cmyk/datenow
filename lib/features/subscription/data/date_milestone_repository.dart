import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../../../core/services/preferences_service.dart';
import '../../../core/services/supabase_service.dart';
import '../../../core/utils/logger.dart';
import '../../auth/presentation/providers/auth_provider.dart';

/// How many live dates the user has actually been through.
///
/// Counted from `calls` rows that reached `ended`, which is the only record
/// that survives the session: a date the user launched but never connected
/// stays `waiting` and does not count. The RLS on `calls` already limits
/// the rows to the ones the caller participates in, so this is a plain
/// count and needs no RPC.
class DateMilestoneRepository {
  const DateMilestoneRepository(this._client);

  final sb.SupabaseClient _client;
  static const _log = AppLogger('DateMilestone');

  /// Dates after which the Premium pitch is worth making. Before that the
  /// user has nothing to compare it to; the argument for paying is the
  /// experience of the free tier running out, not a promise.
  static const int pitchAfter = 3;

  Future<int> completedDates(String userId) async {
    try {
      final rows = await _client
          .from('calls')
          .select('id')
          .eq('status', 'ended')
          .or('caller_id.eq.$userId,callee_id.eq.$userId');
      return rows.length;
    } catch (e) {
      // Never block a screen on a counter: an unknown count simply means
      // no pitch this time.
      _log.warn('completedDates failed for $userId: $e');
      return 0;
    }
  }
}

final dateMilestoneRepositoryProvider =
    Provider<DateMilestoneRepository?>((ref) {
  if (!SupabaseService.isInitialized) return null;
  return DateMilestoneRepository(ref.watch(supabaseClientProvider));
});

/// Number of dates the signed-in user has completed.
final completedDatesProvider = FutureProvider<int>((ref) async {
  final repo = ref.watch(dateMilestoneRepositoryProvider);
  final user = ref.watch(currentUserProvider);
  if (repo == null || user == null) return 0;
  return repo.completedDates(user.id);
});

/// Whether the Premium pitch has already been made to this user.
///
/// Persisted, and deliberately once-only: a paywall that reappears on every
/// launch is how an app teaches people to dismiss it without reading.
class PremiumPitchSeen {
  const PremiumPitchSeen._();

  static const String key = 'premium_pitch_seen_v1';

  static bool read(SharedPreferences prefs) => prefs.getBool(key) ?? false;

  static Future<void> mark(SharedPreferences prefs) =>
      prefs.setBool(key, true);
}

/// True when the user has earned the pitch and has not seen it yet.
final shouldPitchPremiumProvider = FutureProvider<bool>((ref) async {
  final prefs = await ref.watch(sharedPreferencesProvider.future);
  if (PremiumPitchSeen.read(prefs)) return false;
  final done = await ref.watch(completedDatesProvider.future);
  return done >= DateMilestoneRepository.pitchAfter;
});
