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
// Supabase — stub kept honest with [UnimplementedError]
// ---------------------------------------------------------------------------

class SupabaseSettingsRepository implements SettingsRepository {
  SupabaseSettingsRepository(this._client);

  // ignore: unused_field
  final sb.SupabaseClient _client;

  @override
  Stream<NotificationPrefs> watchNotificationPrefs(String userId) {
    throw UnimplementedError('SupabaseSettingsRepository.watchNotificationPrefs');
  }

  @override
  Future<void> updateNotificationPrefs(
    String userId,
    NotificationPrefs prefs,
  ) {
    throw UnimplementedError(
      'SupabaseSettingsRepository.updateNotificationPrefs',
    );
  }

  @override
  Stream<PrivacyPrefs> watchPrivacyPrefs(String userId) {
    throw UnimplementedError('SupabaseSettingsRepository.watchPrivacyPrefs');
  }

  @override
  Future<void> updatePrivacyPrefs(String userId, PrivacyPrefs prefs) {
    throw UnimplementedError('SupabaseSettingsRepository.updatePrivacyPrefs');
  }

  @override
  Stream<List<BlockedUser>> watchBlockedUsers(String userId) {
    throw UnimplementedError('SupabaseSettingsRepository.watchBlockedUsers');
  }

  @override
  Future<void> unblockUser(String userId, String blockedUserId) {
    throw UnimplementedError('SupabaseSettingsRepository.unblockUser');
  }
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  final available = ref.watch(supabaseAvailableProvider);
  if (available) {
    return SupabaseSettingsRepository(ref.watch(supabaseClientProvider));
  }
  return MockSettingsRepository();
});
