import '../../domain/prompt_answer.dart';
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

/// Convenience boolean — only meaningful AFTER the profile stream has
/// resolved. Returns `false` for both "loading" and "no profile / not
/// complete", so callers MUST gate on
/// `currentProfileProvider.isLoading` first or they will treat a
/// returning user as a brand-new one (bug fixed in app_router.dart's
/// redirect — it now checks `currentProfileProvider` directly).
final profileSetupCompletedProvider = Provider<bool>((ref) {
  final state = ref.watch(currentProfileProvider);
  return state.maybeWhen(
    data: (p) => p?.isComplete ?? false,
    orElse: () => false,
  );
});

/// Prompt answers of someone else — a suggested candidate, a match.
///
/// Separate from [currentProfileProvider] because the surfaces that need
/// them (the matched profile, built from the fixed-column
/// `get_matched_profile` RPC) do not carry a full [UserProfile]. AutoDispose
/// so a profile screen fetches once and frees on pop.
final peerPromptsProvider =
    FutureProvider.autoDispose.family<List<PromptAnswer>, String>(
  (ref, userId) => ref.watch(profileRepositoryProvider).fetchPrompts(userId),
);
