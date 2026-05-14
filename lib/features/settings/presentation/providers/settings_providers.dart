import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../profile_setup/presentation/providers/profile_provider.dart';
import '../../data/settings_repository.dart';
import '../../domain/settings_models.dart';

/// Streams the current user's notification prefs. Emits the defaults when
/// no user is signed in so screens don't have to handle a `null` profile.
final notificationPrefsProvider = StreamProvider<NotificationPrefs>((ref) {
  final profile = ref.watch(currentProfileProvider).asData?.value;
  if (profile == null) {
    return Stream<NotificationPrefs>.value(const NotificationPrefs());
  }
  return ref
      .watch(settingsRepositoryProvider)
      .watchNotificationPrefs(profile.userId);
});

final privacyPrefsProvider = StreamProvider<PrivacyPrefs>((ref) {
  final profile = ref.watch(currentProfileProvider).asData?.value;
  if (profile == null) {
    return Stream<PrivacyPrefs>.value(const PrivacyPrefs());
  }
  return ref
      .watch(settingsRepositoryProvider)
      .watchPrivacyPrefs(profile.userId);
});

final blockedUsersProvider = StreamProvider<List<BlockedUser>>((ref) {
  final profile = ref.watch(currentProfileProvider).asData?.value;
  if (profile == null) {
    return Stream<List<BlockedUser>>.value(const <BlockedUser>[]);
  }
  return ref
      .watch(settingsRepositoryProvider)
      .watchBlockedUsers(profile.userId);
});
