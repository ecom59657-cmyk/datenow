import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../../../core/config/env.dart';
import '../../../core/errors/failures.dart';
import '../../../core/services/supabase_service.dart';
import '../../../core/utils/age.dart';
import '../../../core/utils/logger.dart';
import '../domain/auth_user.dart';

/// Abstract auth repository. Speaks the auth language of the rest of the app
/// while hiding which backend (Supabase, mock, …) is actually serving it.
abstract class AuthRepository {
  Stream<AuthUser?> authStateChanges();
  AuthUser? currentUser();

  Future<AuthUser> signInWithPassword({
    required String email,
    required String password,
  });

  /// Creates a new account. [birthDate] is required and the implementation
  /// MUST reject anyone under [kMinAgeYears] — the frontend validation is
  /// not enough on its own (form bypass, deeplinks, etc.).
  Future<SignUpResult> signUpWithPassword({
    required String firstName,
    required String email,
    required String password,
    required DateTime birthDate,
  });

  Future<void> signOut();

  /// Permanently deletes the current account. Implementations should also
  /// sign the user out — callers rely on the auth-state stream emitting
  /// `null` afterwards so the router can redirect to the auth landing.
  Future<void> deleteAccount();
}

/// Failure surfaced from every layer when a minor tries to sign up.
/// Lives here so the controller + UI + tests can switch on the code.
class MinorSignUpFailure extends AuthFailure {
  const MinorSignUpFailure()
      : super(
          'DateNow is reserved for people 18 and older.',
          code: 'minor_sign_up',
        );
}

/// Result of a successful sign-up call.
///
/// [hasSession] is `true` when Supabase returned an active session (email
/// confirmation disabled at the project level, or the email was already
/// confirmed). When `false` the user must verify their email before they
/// can sign in — UI navigates to the verify-email screen in that case.
class SignUpResult {
  const SignUpResult({required this.user, required this.hasSession});

  final AuthUser user;
  final bool hasSession;
}

// ---------------------------------------------------------------------------
// Supabase implementation
// ---------------------------------------------------------------------------

class SupabaseAuthRepository implements AuthRepository {
  SupabaseAuthRepository(this._client);

  final sb.SupabaseClient _client;
  static const _log = AppLogger('SupabaseAuth');

  @override
  Stream<AuthUser?> authStateChanges() {
    return _client.auth.onAuthStateChange.map((event) {
      return _mapUser(event.session?.user);
    });
  }

  @override
  AuthUser? currentUser() => _mapUser(_client.auth.currentUser);

  @override
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

  @override
  Future<SignUpResult> signUpWithPassword({
    required String firstName,
    required String email,
    required String password,
    required DateTime birthDate,
  }) async {
    // Layer 2 of the age gate (UI being layer 1; trigger + CHECK in the DB
    // are layers 3 and 4). Never relies on caller validation alone.
    if (!isOfMinimumAge(birthDate)) {
      throw const MinorSignUpFailure();
    }

    _log.info(
      'Signup sent to Supabase Auth — email=$email '
      'first_name=$firstName birth_date=${_formatDate(birthDate)}',
    );

    try {
      final res = await _client.auth.signUp(
        email: email,
        password: password,
        data: {
          'display_name': firstName,
          'first_name': firstName,
          'birth_date': _formatDate(birthDate),
        },
      );
      final user = _mapUser(res.user);
      if (user == null) {
        const msg =
            'Supabase signUp returned no user — likely a server-side '
            'trigger rejected the row (check the profiles CHECK + '
            'handle_new_user RAISE in Supabase logs).';
        _log.error('Signup error: $msg');
        throw const AuthFailure('No user returned from sign up.');
      }
      // No session means email confirmation is enabled at the project
      // level and the user must click the link before they can sign in.
      final hasSession = res.session != null;
      _log.info(
        'Signup success user id: ${user.id} '
        '(session_created=$hasSession)',
      );
      return SignUpResult(user: user, hasSession: hasSession);
    } on sb.AuthException catch (e, st) {
      _log.error(
        'Signup error: code=${e.code} message="${e.message}"',
        e,
        st,
      );
      // Rate-limit (Supabase's "For security purposes, you can only
      // request this after N seconds") gets its own code so the UI can
      // show a friendly localized message instead of leaking the raw
      // message to the user.
      final lower = e.message.toLowerCase();
      final isRateLimit = (e.code ?? '').contains('rate_limit') ||
          lower.contains('for security purposes') ||
          lower.contains('only request this after');
      if (isRateLimit) {
        throw const AuthFailure(
          'Sign up rate-limited',
          code: 'rate_limited',
        );
      }
      throw AuthFailure(e.message, code: e.code);
    } catch (e, st) {
      _log.error('Signup error: unexpected $e', e, st);
      rethrow;
    }
  }

  @override
  Future<void> signOut() => _client.auth.signOut();

  @override
  Future<void> deleteAccount() async {
    // TODO(datenow): call a Postgres function `delete_my_account` that wipes
    // the user's profile, photos and linked rows server-side using the
    // service role. Then sign the client out.
    await _client.auth.signOut();
  }

  AuthUser? _mapUser(sb.User? user) {
    if (user == null) return null;
    final meta = user.userMetadata;
    final birthDateRaw = meta?['birth_date'] as String?;
    return AuthUser(
      id: user.id,
      email: user.email ?? '',
      displayName: (meta?['display_name'] ?? meta?['first_name']) as String?,
      birthDate:
          birthDateRaw == null ? null : DateTime.tryParse(birthDateRaw),
      avatarUrl: meta?['avatar_url'] as String?,
      createdAt: DateTime.tryParse(user.createdAt),
    );
  }

  static String _formatDate(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$y-$m-$day';
  }
}

// ---------------------------------------------------------------------------
// Mock implementation — used in dev when Supabase isn't configured
// ---------------------------------------------------------------------------

/// In-memory auth implementation so the UI flow stays exercisable when no
/// `.env` is set. Holds the "current user" in a broadcast stream so the rest
/// of the app reacts exactly as it would with a real backend.
class MockAuthRepository implements AuthRepository {
  MockAuthRepository();

  static const _log = AppLogger('MockAuth');

  final StreamController<AuthUser?> _controller =
      StreamController<AuthUser?>.broadcast();
  AuthUser? _current;

  @override
  Stream<AuthUser?> authStateChanges() async* {
    // Replay the current value to new listeners — mirrors Supabase behaviour.
    yield _current;
    yield* _controller.stream;
  }

  @override
  AuthUser? currentUser() => _current;

  @override
  Future<AuthUser> signInWithPassword({
    required String email,
    required String password,
  }) async {
    _log.info('mock signIn for $email');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final user = AuthUser(
      id: 'mock-${email.hashCode.abs()}',
      email: email,
      createdAt: DateTime.now(),
    );
    _current = user;
    _controller.add(user);
    return user;
  }

  @override
  Future<SignUpResult> signUpWithPassword({
    required String firstName,
    required String email,
    required String password,
    required DateTime birthDate,
  }) async {
    // Defence in depth: if .env actually contains Supabase credentials, the
    // app should never reach the mock for a write operation — that would
    // silently swallow a real signup. We refuse loudly instead of mocking.
    if (Env.supabaseConfigured) {
      _log.error(
        'Mock signUp called while Supabase is configured — refusing. '
        'Check that SupabaseService.init() succeeded at bootstrap.',
      );
      throw const AuthFailure(
        'Misconfiguration: Supabase env is set but the client never '
        'initialised. Restart the app or check the bootstrap logs.',
      );
    }

    // The mock enforces the 18+ rule too — never bypass.
    if (!isOfMinimumAge(birthDate)) {
      _log.warn('mock signUp rejected for $email — under 18');
      throw const MinorSignUpFailure();
    }
    _log.info(
      'mock signUp for $email ($firstName) — '
      'NO Supabase user is being created.',
    );
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final user = AuthUser(
      id: 'mock-${email.hashCode.abs()}',
      email: email,
      displayName: firstName,
      birthDate: birthDate,
      createdAt: DateTime.now(),
    );
    _current = user;
    _controller.add(user);
    return SignUpResult(user: user, hasSession: true);
  }

  @override
  Future<void> signOut() async {
    _log.info('mock signOut');
    _current = null;
    _controller.add(null);
  }

  @override
  Future<void> deleteAccount() async {
    _log.info('mock deleteAccount for ${_current?.id}');
    _current = null;
    _controller.add(null);
  }
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

/// Picks the right repo at runtime: real Supabase when configured, mock
/// otherwise. Either way, callers depend on the abstract [AuthRepository].
final authRepositoryProvider = Provider<AuthRepository>((ref) {
  final available = ref.watch(supabaseAvailableProvider);
  if (available) {
    return SupabaseAuthRepository(ref.watch(supabaseClientProvider));
  }
  return MockAuthRepository();
});
