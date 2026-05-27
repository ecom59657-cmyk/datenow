import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/errors/failures.dart';
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

/// Synchronously exposes the current user (may be stale by a frame
/// compared to the stream — fine for routing decisions).
final currentUserProvider = Provider<AuthUser?>((ref) {
  final state = ref.watch(authStateProvider);
  return state.asData?.value;
});

final isAuthenticatedProvider = Provider<bool>(
  (ref) => ref.watch(currentUserProvider) != null,
);

/// Result of the OTP request step. Lets the screen decide where to go
/// next without inspecting the controller state.
enum OtpRequestOutcome {
  /// OTP was successfully requested — the screen should navigate to the
  /// OTP entry screen so the user can type the 6-digit code.
  sent,

  /// The call was rejected (rate limit, unknown user, validation, …).
  /// The controller's `state.error` carries the [AuthFailure].
  failed,

  /// A previous request is still in flight — call dropped.
  alreadyInFlight,
}

/// Drives the passwordless auth flow (signup + signin + verify). Holds
/// loading + error state so views stay dumb. Every public method that
/// hits the network guards against re-entry by checking
/// `state.isLoading`.
class AuthController extends StateNotifier<AsyncValue<void>> {
  AuthController(this._ref) : super(const AsyncValue.data(null));

  final Ref _ref;
  static const _log = AppLogger('AuthController');

  /// Step 1 of signup — sends OTP to a new email, carrying first_name
  /// + birth_date so the `handle_new_user` trigger can hydrate the
  /// profile + preferences rows.
  Future<OtpRequestOutcome> requestSignupOtp({
    required String email,
    required String firstName,
    required DateTime birthDate,
  }) async {
    if (state.isLoading) {
      _log.warn('requestSignupOtp ignored — another call is in flight.');
      return OtpRequestOutcome.alreadyInFlight;
    }
    _log.info('requestSignupOtp called for $email');
    // Controller-level age check — fast-fails before the network
    // round-trip when the form was somehow bypassed.
    if (!isOfMinimumAge(birthDate)) {
      state = AsyncValue.error(
        const MinorSignUpFailure(),
        StackTrace.current,
      );
      return OtpRequestOutcome.failed;
    }
    state = const AsyncValue.loading();
    try {
      await _ref.read(authRepositoryProvider).requestSignupOtp(
            email: email,
            firstName: firstName,
            birthDate: birthDate,
          );
      state = const AsyncValue.data(null);
      return OtpRequestOutcome.sent;
    } catch (e, st) {
      _log.error('requestSignupOtp failed: $e', e, st);
      state = AsyncValue.error(e, st);
      return OtpRequestOutcome.failed;
    }
  }

  /// Step 1 of signin — sends OTP to a known email.
  Future<OtpRequestOutcome> requestSigninOtp({required String email}) async {
    if (state.isLoading) {
      _log.warn('requestSigninOtp ignored — another call is in flight.');
      return OtpRequestOutcome.alreadyInFlight;
    }
    _log.info('requestSigninOtp called for $email');
    state = const AsyncValue.loading();
    try {
      await _ref.read(authRepositoryProvider).requestSigninOtp(email: email);
      state = const AsyncValue.data(null);
      return OtpRequestOutcome.sent;
    } catch (e, st) {
      _log.error('requestSigninOtp failed: $e', e, st);
      state = AsyncValue.error(e, st);
      return OtpRequestOutcome.failed;
    }
  }

  /// Step 2 — consumes the 6-digit token. Returns true when the
  /// session was opened (auth-state stream will then redirect the
  /// router). False means the controller's `state.error` is set.
  Future<bool> verifyOtp({
    required String email,
    required String token,
  }) async {
    if (state.isLoading) {
      _log.warn('verifyOtp ignored — another call is in flight.');
      return false;
    }
    _log.info('verifyOtp called for $email');
    state = const AsyncValue.loading();
    try {
      await _ref.read(authRepositoryProvider).verifyOtp(
            email: email,
            token: token,
          );
      state = const AsyncValue.data(null);
      return true;
    } catch (e, st) {
      _log.error('verifyOtp failed: $e', e, st);
      state = AsyncValue.error(e, st);
      return false;
    }
  }

  Future<void> signOut() async {
    await _ref.read(authRepositoryProvider).signOut();
  }

  Future<void> deleteAccount() async {
    await _ref.read(authRepositoryProvider).deleteAccount();
  }
}

final authControllerProvider =
    StateNotifierProvider<AuthController, AsyncValue<void>>(
  AuthController.new,
);
