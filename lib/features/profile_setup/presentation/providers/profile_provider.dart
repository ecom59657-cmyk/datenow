import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../auth/presentation/providers/auth_provider.dart';
import '../../data/profile_repository.dart';
import '../../domain/user_profile.dart';

/// Streams the currently signed-in user's profile (or `null`). Driven by both
/// [currentUserProvider] (rebuilds when the user changes) and the repo's
/// reactive `watchProfile` stream.
final currentProfileProvider = StreamProvider<UserProfile?>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) {
    return Stream<UserProfile?>.value(null);
  }
  return ref.watch(profileRepositoryProvider).watchProfile(user.id);
});

/// Convenience boolean used by the router redirect.
///
/// Returns `false` while the profile stream is loading so we don't briefly
/// flash the home screen on cold start. Once the stream resolves, the value
/// reflects `UserProfile.isComplete` (or `false` when no profile exists).
final profileSetupCompletedProvider = Provider<bool>((ref) {
  final state = ref.watch(currentProfileProvider);
  return state.maybeWhen(
    data: (p) => p?.isComplete ?? false,
    orElse: () => false,
  );
});
