import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/utils/age.dart';
import '../../../../core/utils/logger.dart';
import '../../data/auth_repository.dart';
import '../../domain/auth_user.dart';

/// Streams the current authenticated user from whichever [AuthRepository]
/// is wired (Supabase in production, in-memory mock in dev when `.env` is
/// empty). The router watches this to drive its auth redirect.
final authStateProvider = StreamProvider<AuthUser?>((ref) {
  return ref.watch(authRepositoryProvider).authStateChanges();
});

/// Synchronously exposes the current user (may be stale by a frame compared
/// to the stream — fine for routing decisions).
final currentUserProvider = Provider<AuthUser?>((ref) {
  final state = ref.watch(authStateProvider);
  return state.asData?.value;
});

final isAuthenticatedProvider = Provider<bool>(
  (ref) => ref.watch(currentUserProvider) != null,
);

/// Three-valued result of [AuthController.signUp]. Lets the screen decide
/// where to navigate next without inspecting the controller state.
enum SignUpOutcome {
  /// Account created **and** a session is active — the router will redirect
  /// to the profile-setup flow as soon as `authStateProvider` emits.
  signedIn,

  /// Account created but Supabase requires email confirmation. The UI
  /// should push the verify-email screen.
  needsEmailConfirmation,

  /// The call was rejected (validation, network, rate-limit, …). The
  /// controller's `state.error` carries the [AuthFailure] for display.
  failed,

  /// A previous sign-up is still in flight; the call was a no-op. Use this
  /// to short-circuit double-taps without ever triggering a second
  /// `auth.signUp` round-trip.
  alreadyInFlight,
}

/// Drives the sign-in / sign-up screens. Holds loading + error state so
/// views stay dumb. Every public method that hits the network guards
/// against re-entry by checking `state.isLoading` first — that's the
/// canonical defence against double-tap signup races.
class AuthController extends StateNotifier<AsyncValue<void>> {
  AuthController(this._ref) : super(const AsyncValue.data(null));

  final Ref _ref;
  static const _log = AppLogger('AuthController');

  Future<bool> signIn({required String email, required String password}) {
    if (state.isLoading) {
      _log.warn('signIn ignored — another auth call is in flight.');
      return Future.value(false);
    }
    _log.info('signIn called for $email');
    return _run(
      () => _ref.read(authRepositoryProvider).signInWithPassword(
            email: email,
            password: password,
          ),
    );
  }

  Future<SignUpOutcome> signUp({
    required String firstName,
    required String email,
    required String password,
    required DateTime birthDate,
  }) async {
    // Re-entrancy guard: refuse a second call while the first hasn't
    // completed. This is the canonical defence against double-tap signup
    // races, regardless of how fast the UI rebuild propagates.
    if (state.isLoading) {
      _log.warn('signUp ignored — another auth call is in flight.');
      return SignUpOutcome.alreadyInFlight;
    }

    _log.info('signUp called for $email');

    // Controller-level age check — fast-fails before the network round-trip
    // when the form was somehow bypassed. The repository also re-validates.
    if (!isOfMinimumAge(birthDate)) {
      state = AsyncValue.error(
        const MinorSignUpFailure(),
        StackTrace.current,
      );
      return SignUpOutcome.failed;
    }

    state = const AsyncValue.loading();
    try {
      final result = await _ref.read(authRepositoryProvider).signUpWithPassword(
            firstName: firstName,
            email: email,
            password: password,
            birthDate: birthDate,
          );
      state = const AsyncValue.data(null);
      final outcome = result.hasSession
          ? SignUpOutcome.signedIn
          : SignUpOutcome.needsEmailConfirmation;
      _log.info('signUp outcome: $outcome');
      return outcome;
    } catch (e, st) {
      _log.error('signUp failed: $e', e, st);
      state = AsyncValue.error(e, st);
      return SignUpOutcome.failed;
    }
  }

  Future<void> signOut() async {
    await _ref.read(authRepositoryProvider).signOut();
  }

  Future<void> deleteAccount() async {
    await _ref.read(authRepositoryProvider).deleteAccount();
  }

  Future<bool> _run(Future<void> Function() action) async {
    state = const AsyncValue.loading();
    try {
      await action();
      state = const AsyncValue.data(null);
      return true;
    } catch (e, st) {
      state = AsyncValue.error(e, st);
      return false;
    }
  }
}

final authControllerProvider =
    StateNotifierProvider<AuthController, AsyncValue<void>>(
  AuthController.new,
);
