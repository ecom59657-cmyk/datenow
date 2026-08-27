import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../../../core/services/supabase_service.dart';
import '../../../core/utils/logger.dart';
import '../domain/settings_models.dart';

/// Stores account-level toggles + the user's block list. The same surface
/// covers all three concerns so we have a single source of truth and one
/// repository to swap when Supabase comes online.
abstract class SettingsRepository {
  Stream<NotificationPrefs> watchNotificationPrefs(String userId);
  Future<void> updateNotificationPrefs(String userId, NotificationPrefs prefs);

  Stream<PrivacyPrefs> watchPrivacyPrefs(String userId);
  Future<void> updatePrivacyPrefs(String userId, PrivacyPrefs prefs);

  Stream<List<BlockedUser>> watchBlockedUsers(String userId);
  Future<void> unblockUser(String userId, String blockedUserId);
}

// ---------------------------------------------------------------------------
// Mock — in-memory state per user. Seeds the block list with one entry so
// the dedicated screen can demonstrate the unblock action out of the box.
// ---------------------------------------------------------------------------

class MockSettingsRepository implements SettingsRepository {
  static const _log = AppLogger('MockSettings');

  final Map<String, NotificationPrefs> _notifByUser = {};
  final Map<String, PrivacyPrefs> _privacyByUser = {};
  final Map<String, List<BlockedUser>> _blockedByUser = {};

  final Map<String, StreamController<NotificationPrefs>> _notifStreams = {};
  final Map<String, StreamController<PrivacyPrefs>> _privacyStreams = {};
  final Map<String, StreamController<List<BlockedUser>>> _blockedStreams = {};

  StreamController<T> _stream<T>(Map<String, StreamController<T>> map, String key) {
    return map.putIfAbsent(key, () => StreamController<T>.broadcast());
  }

  NotificationPrefs _notif(String userId) =>
      _notifByUser.putIfAbsent(userId, () => const NotificationPrefs());

  PrivacyPrefs _privacy(String userId) =>
      _privacyByUser.putIfAbsent(userId, () => const PrivacyPrefs());

  List<BlockedUser> _blocked(String userId) {
    return _blockedByUser.putIfAbsent(userId, () {
      // Seed one blocked user so the screen has something to show on first
      // open. Removed when the user taps unblock.
      return [
        BlockedUser(
          id: 'mock-blocked-1',
          displayName: 'Hidden Profile',
          blockedAt: DateTime.now().subtract(const Duration(days: 12)),
        ),
      ];
    });
  }

  @override
  Stream<NotificationPrefs> watchNotificationPrefs(String userId) async* {
    yield _notif(userId);
    yield* _stream(_notifStreams, userId).stream;
  }

  @override
  Future<void> updateNotificationPrefs(
    String userId,
    NotificationPrefs prefs,
  ) async {
    _notifByUser[userId] = prefs;
    _stream(_notifStreams, userId).add(prefs);
    _log.info('notif prefs updated for $userId');
  }

  @override
  Stream<PrivacyPrefs> watchPrivacyPrefs(String userId) async* {
    yield _privacy(userId);
    yield* _stream(_privacyStreams, userId).stream;
  }

  @override
  Future<void> updatePrivacyPrefs(String userId, PrivacyPrefs prefs) async {
    _privacyByUser[userId] = prefs;
    _stream(_privacyStreams, userId).add(prefs);
    _log.info('privacy prefs updated for $userId');
  }

  @override
  Stream<List<BlockedUser>> watchBlockedUsers(String userId) async* {
    yield _blocked(userId);
    yield* _stream(_blockedStreams, userId).stream;
  }

  @override
  Future<void> unblockUser(String userId, String blockedUserId) async {
    final current = _blocked(userId);
    _blockedByUser[userId] = current.where((u) => u.id != blockedUserId).toList();
    _stream(_blockedStreams, userId).add(_blockedByUser[userId]!);
    _log.info('$userId unblocked $blockedUserId');
  }
}

// ---------------------------------------------------------------------------
// Supabase — the real thing
// ---------------------------------------------------------------------------

class SupabaseSettingsRepository implements SettingsRepository {
  SupabaseSettingsRepository(this._client);

  final sb.SupabaseClient _client;

  static const _log = AppLogger('SupabaseSettings');

  /// `handle_new_user` inserts a `user_settings` row at sign-up, so this is
  /// normally a single row. It is still written defensively: accounts created
  /// before that trigger existed have no row, and a missing row means
  /// "defaults", not "error".
  static const _table = 'user_settings';

  // -------------------------------------------------------------------
  // Notifications
  // -------------------------------------------------------------------

  @override
  Stream<NotificationPrefs> watchNotificationPrefs(String userId) {
    return _client
        .from(_table)
        .stream(primaryKey: ['user_id'])
        .eq('user_id', userId)
        .map(_notificationsFrom)
        .handleError((Object e, StackTrace st) {
      _log.error('notification prefs stream failed: $e', e, st);
    });
  }

  @override
  Future<void> updateNotificationPrefs(
    String userId,
    NotificationPrefs prefs,
  ) async {
    // Upsert rather than update: an account older than the trigger has no row
    // to update, and silently writing nothing is how a preference appears to
    // save and comes back wrong on the next launch.
    await _client.from(_table).upsert({
      'user_id': userId,
      'push_new_match': prefs.pushNewMatch,
      'push_suggestions': prefs.pushSuggestions,
      'push_messages': prefs.pushMessages,
      'email_weekly_digest': prefs.emailWeeklyDigest,
      'email_marketing': prefs.emailMarketing,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
    _log.info('notification prefs saved for $userId');
  }

  // -------------------------------------------------------------------
  // Privacy
  // -------------------------------------------------------------------

  @override
  Stream<PrivacyPrefs> watchPrivacyPrefs(String userId) {
    return _client
        .from(_table)
        .stream(primaryKey: ['user_id'])
        .eq('user_id', userId)
        .map(_privacyFrom)
        .handleError((Object e, StackTrace st) {
      _log.error('privacy prefs stream failed: $e', e, st);
    });
  }

  @override
  Future<void> updatePrivacyPrefs(String userId, PrivacyPrefs prefs) async {
    await _client.from(_table).upsert({
      'user_id': userId,
      'show_online': prefs.showOnline,
      'block_screenshots': prefs.blockScreenshots,
      'share_usage_data': prefs.shareUsageData,
      'marketing_consent': prefs.marketingConsent,
      'two_factor_enabled': prefs.twoFactorEnabled,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
    _log.info('privacy prefs saved for $userId');
  }

  // -------------------------------------------------------------------
  // Blocked accounts
  // -------------------------------------------------------------------

  @override
  Stream<List<BlockedUser>> watchBlockedUsers(String userId) {
    // The list needs a name, which lives in `profiles`, and a realtime stream
    // cannot join. So the stream is used only as a change signal and the
    // actual list is refetched — the same shape discover_repository uses for
    // its suggestions.
    return _client
        .from('blocked_users')
        .stream(primaryKey: ['user_id', 'blocked_user_id'])
        .eq('user_id', userId)
        .asyncMap((_) => _fetchBlocked(userId))
        .handleError((Object e, StackTrace st) {
      _log.error('blocked users stream failed: $e', e, st);
    });
  }

  Future<List<BlockedUser>> _fetchBlocked(String userId) async {
    final rows = await _client
        .from('blocked_users')
        .select('blocked_user_id, blocked_at')
        .eq('user_id', userId)
        .order('blocked_at', ascending: false);

    final list = rows.cast<Map<String, dynamic>>();
    if (list.isEmpty) return const <BlockedUser>[];

    final ids = list.map((r) => r['blocked_user_id'] as String).toList();
    final names = <String, String>{};
    try {
      final profiles = await _client
          .from('profiles')
          .select('id, first_name')
          .inFilter('id', ids);
      for (final p in profiles.cast<Map<String, dynamic>>()) {
        names[p['id'] as String] = (p['first_name'] as String?) ?? '';
      }
    } catch (e) {
      // A blocked profile can be hidden from us by its own RLS, or deleted.
      // Losing the name must not lose the row — the point of this screen is
      // to be able to unblock, and that only needs the id.
      _log.warn('could not resolve blocked names ($e) — showing ids only');
    }

    return [
      for (final r in list)
        BlockedUser(
          id: r['blocked_user_id'] as String,
          displayName: (names[r['blocked_user_id']] ?? '').isEmpty
              ? '—'
              : names[r['blocked_user_id']]!,
          blockedAt:
              DateTime.tryParse(r['blocked_at'] as String? ?? '') ??
                  DateTime.now(),
        ),
    ];
  }

  @override
  Future<void> unblockUser(String userId, String blockedUserId) async {
    await _client
        .from('blocked_users')
        .delete()
        .eq('user_id', userId)
        .eq('blocked_user_id', blockedUserId);
    _log.info('unblocked $blockedUserId for $userId');
  }

  // -------------------------------------------------------------------
  // Row → model. A missing row is "defaults", never an error.
  // -------------------------------------------------------------------

  static bool _flag(Map<String, dynamic> row, String column, bool fallback) =>
      row[column] as bool? ?? fallback;

  static NotificationPrefs _notificationsFrom(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) return const NotificationPrefs();
    final r = rows.first;
    return NotificationPrefs(
      pushNewMatch: _flag(r, 'push_new_match', true),
      pushSuggestions: _flag(r, 'push_suggestions', true),
      pushMessages: _flag(r, 'push_messages', true),
      emailWeeklyDigest: _flag(r, 'email_weekly_digest', true),
      emailMarketing: _flag(r, 'email_marketing', false),
    );
  }

  static PrivacyPrefs _privacyFrom(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) return const PrivacyPrefs();
    final r = rows.first;
    return PrivacyPrefs(
      showOnline: _flag(r, 'show_online', true),
      blockScreenshots: _flag(r, 'block_screenshots', true),
      shareUsageData: _flag(r, 'share_usage_data', true),
      marketingConsent: _flag(r, 'marketing_consent', false),
      twoFactorEnabled: _flag(r, 'two_factor_enabled', false),
    );
  }
}

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  final available = ref.watch(supabaseAvailableProvider);
  if (available) {
    return SupabaseSettingsRepository(ref.watch(supabaseClientProvider));
  }
  return MockSettingsRepository();
});
