import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/supabase_service.dart';
import '../../data/auth_repository.dart';
import '../../domain/auth_user.dart';

/// Streams the current authenticated user.
///
/// When Supabase isn't configured (no .env), we emit a constant `null` so the
/// router can still resolve and the UI lands on the auth landing screen
/// without crashing in dev.
final authStateProvider = StreamProvider<AuthUser?>((ref) {
  final available = ref.watch(supabaseAvailableProvider);
  if (!available) {
    return Stream<AuthUser?>.value(null);
  }
  final repo = ref.watch(authRepositoryProvider);
  return repo.authStateChanges();
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

/// Drives the sign-in / sign-up screens. Holds loading + error state so views
/// stay dumb.
class AuthController extends StateNotifier<AsyncValue<void>> {
  AuthController(this._ref) : super(const AsyncValue.data(null));

  final Ref _ref;

  Future<bool> signIn({required String email, required String password}) {
    return _run(
      () => _ref.read(authRepositoryProvider).signInWithPassword(
            email: email,
            password: password,
          ),
    );
  }

  Future<bool> signUp({required String email, required String password}) {
    return _run(
      () => _ref.read(authRepositoryProvider).signUpWithPassword(
            email: email,
            password: password,
          ),
    );
  }

  Future<void> signOut() async {
    await _ref.read(authRepositoryProvider).signOut();
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
