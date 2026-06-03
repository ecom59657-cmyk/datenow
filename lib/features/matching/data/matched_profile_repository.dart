import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/services/supabase_service.dart';
import '../../../core/utils/logger.dart';
import '../domain/matched_profile.dart';

/// Raised when the matched profile can't be shown — no active match between
/// the two users (server-side gate raised `no_match`), or the backend is
/// unreachable. The screen turns this into a calm "Profil indisponible".
class MatchedProfileUnavailable implements Exception {
  const MatchedProfileUnavailable();
}

/// Calls the secure `get_matched_profile` RPC. The match is enforced
/// SERVER-SIDE on auth.uid(); this client never decides access — it only
/// renders what the RPC is willing to return.
class MatchedProfileRepository {
  const MatchedProfileRepository(this._client);

  final SupabaseClient _client;
  static const _log = AppLogger('MatchedProfile');

  Future<MatchedProfile> fetch(String userId) async {
    try {
      final res = await _client.rpc<dynamic>(
        'get_matched_profile',
        params: {'p_user_id': userId},
      );
      // `returns table` surfaces as a List of rows; a single row is expected.
      final row = res is List && res.isNotEmpty ? res.first : res;
      if (row is Map<String, dynamic>) {
        return MatchedProfile.fromRpc(row);
      }
      _log.warn('get_matched_profile returned no row for $userId');
      throw const MatchedProfileUnavailable();
    } on MatchedProfileUnavailable {
      rethrow;
    } catch (e, st) {
      // A no_match / unauthenticated raise lands here too — every failure
      // maps to the same calm "unavailable" UX; the real reason stays in
      // the logs and is never surfaced to the user.
      _log.warn('get_matched_profile failed for $userId: $e\n$st');
      throw const MatchedProfileUnavailable();
    }
  }
}

/// Null when Supabase is unavailable (mock/dev path) — callers gate on it.
final matchedProfileRepositoryProvider =
    Provider<MatchedProfileRepository?>((ref) {
  if (!SupabaseService.isInitialized) return null;
  return MatchedProfileRepository(ref.watch(supabaseClientProvider));
});

/// Loads the matched profile for [userId]. AutoDispose + family so each
/// screen instance fetches once and frees when popped.
final matchedProfileProvider = FutureProvider.autoDispose
    .family<MatchedProfile, String>((ref, userId) async {
  final repo = ref.watch(matchedProfileRepositoryProvider);
  if (repo == null) throw const MatchedProfileUnavailable();
  return repo.fetch(userId);
});
