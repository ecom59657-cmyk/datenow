import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../../../core/errors/failures.dart';
import '../../../core/services/supabase_service.dart';
import '../../../core/utils/logger.dart';
import '../domain/auth_user.dart';

/// Repository in charge of authentication flows. Speaks Supabase under the
/// hood but exposes a clean [AuthUser] domain type and converts SDK errors to
/// [AuthFailure].
class AuthRepository {
  AuthRepository(this._client);

  final sb.SupabaseClient _client;
  static const _log = AppLogger('AuthRepository');

  /// Emits the current user on every auth change. `null` when signed out.
  Stream<AuthUser?> authStateChanges() {
    return _client.auth.onAuthStateChange.map((event) {
      return _mapUser(event.session?.user);
    });
  }

  AuthUser? currentUser() => _mapUser(_client.auth.currentUser);

  Future<AuthUser> signInWithPassword({
    required String email,
    required String password,
  }) async {
    try {
      final res = await _client.auth.signInWithPassword(
        email: email,
        password: password,
      );
      final user = _mapUser(res.user);
      if (user == null) {
        throw const AuthFailure('No user returned from sign in.');
      }
      return user;
    } on sb.AuthException catch (e) {
      _log.warn('signIn failed: ${e.message}');
      throw AuthFailure(e.message, code: e.code);
    }
  }

  Future<AuthUser> signUpWithPassword({
    required String email,
    required String password,
  }) async {
    try {
      final res = await _client.auth.signUp(
        email: email,
        password: password,
      );
      final user = _mapUser(res.user);
      if (user == null) {
        throw const AuthFailure('No user returned from sign up.');
      }
      return user;
    } on sb.AuthException catch (e) {
      _log.warn('signUp failed: ${e.message}');
      throw AuthFailure(e.message, code: e.code);
    }
  }

  Future<void> signOut() => _client.auth.signOut();

  AuthUser? _mapUser(sb.User? user) {
    if (user == null) return null;
    return AuthUser(
      id: user.id,
      email: user.email ?? '',
      displayName: user.userMetadata?['display_name'] as String?,
      avatarUrl: user.userMetadata?['avatar_url'] as String?,
      createdAt: DateTime.tryParse(user.createdAt),
    );
  }
}

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return AuthRepository(client);
});
