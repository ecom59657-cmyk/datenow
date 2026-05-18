import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/services/supabase_service.dart';
import '../../../core/utils/logger.dart';
import '../domain/presence_status.dart';

/// A presence row snapshot — the *effective* [status] already accounts
/// for staleness (see [PresenceStatus.fromRow]).
class PresenceRow {
  const PresenceRow({
    required this.userId,
    required this.status,
    required this.updatedAt,
  });

  final String userId;
  final PresenceStatus status;
  final DateTime updatedAt;

  factory PresenceRow.fromJson(Map<String, dynamic> json) {
    final updated = DateTime.parse(json['updated_at'] as String).toUtc();
    return PresenceRow(
      userId: json['user_id'] as String,
      status: PresenceStatus.fromRow(json['status'] as String?, updated),
      updatedAt: updated,
    );
  }
}

/// Real-time presence backed by `public.user_presence`.
///
/// Writes go through the `set_presence` RPC (server clock); reads use a
/// Realtime stream so the call screen reacts the instant a peer's status
/// changes. Every method is best-effort — presence is a UX nicety and
/// must never throw into a user-facing flow.
class PresenceRepository {
  PresenceRepository(this._client);

  final SupabaseClient _client;
  static const _log = AppLogger('Presence');
  static const _table = 'user_presence';

  /// Upserts the caller's presence. Swallows errors (e.g. signed out)
  /// so it can be called freely from lifecycle hooks.
  Future<void> setStatus(PresenceStatus status) async {
    try {
      await _client.rpc<dynamic>(
        'set_presence',
        params: {'p_status': status.wire},
      );
    } catch (e) {
      _log.warn('set_presence(${status.wire}) failed: $e');
    }
  }

  /// Approximate count of reachable peers (online/searching, fresh).
  /// Returns null when the count can't be fetched.
  Future<int?> activeProfilesCount() async {
    try {
      final res = await _client.rpc<dynamic>('active_profiles_count');
      if (res is int) return res;
      if (res is num) return res.toInt();
      return null;
    } catch (e) {
      _log.warn('active_profiles_count failed: $e');
      return null;
    }
  }

  /// One-shot read of a user's presence row (used by Debug).
  Future<PresenceRow?> fetchPresence(String userId) async {
    try {
      final row = await _client
          .from(_table)
          .select()
          .eq('user_id', userId)
          .maybeSingle();
      return row == null ? null : PresenceRow.fromJson(row);
    } catch (e) {
      _log.warn('fetchPresence($userId) failed: $e');
      return null;
    }
  }

  /// Streams a single user's presence via Realtime. Yields null until a
  /// row exists. The effective status still ages out client-side, so
  /// subscribers should also re-evaluate staleness on a timer if they
  /// need it to flip to offline without a row change.
  Stream<PresenceRow?> watchPresence(String userId) {
    return _client
        .from(_table)
        .stream(primaryKey: ['user_id'])
        .eq('user_id', userId)
        .map((rows) => rows.isEmpty ? null : PresenceRow.fromJson(rows.first));
  }
}

final presenceRepositoryProvider = Provider<PresenceRepository?>((ref) {
  if (!ref.watch(supabaseAvailableProvider)) return null;
  return PresenceRepository(ref.watch(supabaseClientProvider));
});
