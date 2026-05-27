import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../../../core/config/env.dart';
import '../../../core/errors/failures.dart';
import '../../../core/services/supabase_service.dart';
import '../../../core/utils/age.dart';
import '../../../core/utils/logger.dart';
import '../domain/auth_user.dart';

/// Abstract auth repository. Speaks the auth language of the rest of the
/// app while hiding which backend (Supabase, mock, …) is actually serving
/// it.
///
/// DateNow runs a **passwordless** email flow:
///   1. UI collects email (+ first_name + birth_date on first signup).
///   2. [requestSignupOtp] / [requestSigninOtp] triggers Supabase to send
///      a 6-digit OTP code by email.
///   3. UI shows the OTP screen.
///   4. [verifyOtp] consumes the code, returning the freshly-created
///      session (and a [AuthUser]).
///
/// For brand-new signups the first_name + birth_date are passed via the
/// Supabase `data` channel — they land in `auth.users.raw_user_meta_data`
/// and the `handle_new_user` trigger picks them up to create the
/// `profiles` / `user_preferences` / `user_settings` / `subscriptions`
/// rows transactionally.
abstract class AuthRepository {
  Stream<AuthUser?> authStateChanges();
  AuthUser? currentUser();

  /// Sends an OTP code for a new account. Includes the metadata the
  /// `handle_new_user` trigger needs (display_name, first_name,
  /// birth_date). Enforces the 18+ floor before any network call.
  Future<void> requestSignupOtp({
    required String email,
    required String firstName,
    required DateTime birthDate,
  });

  /// Sends an OTP code for an existing account. `shouldCreateUser:false`
  /// surfaces an explicit `user_not_found` failure when the email isn't
  /// registered, so the UI can suggest signing up instead.
  Future<void> requestSigninOtp({required String email});

  /// Consumes the 6-digit code. Returns the user when the code is valid
  /// and a session is opened. Throws an [AuthFailure] with a stable
  /// `code` for the UI to map onto a humane snack.
  Future<AuthUser> verifyOtp({
    required String email,
    required String token,
  });

  /// Opens the native iOS Sign in with Apple sheet and exchanges the
  /// resulting Apple ID token with Supabase. Returns the freshly-
  /// authenticated user. Apple never provides a date of birth and only
  /// provides the user's name on the FIRST sign-in — the app forces
  /// missing fields via the profile-setup flow.
  Future<AuthUser> signInWithApple();

  /// Opens the native iOS Google sign-in sheet and exchanges the
  /// returned ID token with Supabase. Same partial-profile semantics
  /// as [signInWithApple] — Google provides email + name (always) but
  /// no birth_date, so the profile-setup flow collects DOB after.
  Future<AuthUser> signInWithGoogle();

  /// Voluntarily links a third-party identity to the CURRENT user.
  /// Supabase opens the OAuth flow in a webview / system browser; on
  /// success the new identity is attached to the same `auth.users`
  /// row (no second profile created). Throws an [AuthFailure] with
  /// code `identity_already_exists` when the target email is already
  /// taken by another DateNow account — the UI surfaces a humane
  /// sheet in that case.
  Future<void> linkIdentity(sb.OAuthProvider provider);

  Future<void> signOut();

  /// Permanently deletes the current account. Implementations should
  /// also sign the user out — callers rely on the auth-state stream
  /// emitting `null` afterwards so the router can redirect.
  Future<void> deleteAccount();
}

/// Failure surfaced from every layer when a minor tries to sign up.
class MinorSignUpFailure extends AuthFailure {
  const MinorSignUpFailure()
      : super(
          'DateNow is reserved for people 18 and older.',
          code: 'minor_sign_up',
        );
}

/// Surfaced when the user cancels the native Apple Sign In sheet.
/// Distinct from an actual error so the UI can stay silent instead of
/// showing a snack.
class OAuthCancelledFailure extends AuthFailure {
  const OAuthCancelledFailure()
      : super('Cancelled by user', code: 'oauth_cancelled');
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
  Future<void> requestSignupOtp({
    required String email,
    required String firstName,
    required DateTime birthDate,
  }) async {
    // Layer 2 of the age gate (UI being layer 1; trigger + CHECK in the
    // DB are layers 3 and 4). Never relies on caller validation alone.
    if (!isOfMinimumAge(birthDate)) {
      throw const MinorSignUpFailure();
    }
    _log.info(
      'requestSignupOtp email=$email first_name=$firstName '
      'birth_date=${_formatDate(birthDate)}',
    );
    try {
      await _client.auth.signInWithOtp(
        email: email,
        // We DO want to create the user if it doesn't exist — that's the
        // whole point of signup. The trigger will then pick up the
        // metadata.
        shouldCreateUser: true,
        data: <String, dynamic>{
          'display_name': firstName,
          'first_name': firstName,
          'birth_date': _formatDate(birthDate),
        },
      );
    } on sb.AuthException catch (e, st) {
      _log.error(
        'requestSignupOtp error: code=${e.code} message="${e.message}"',
        e,
        st,
      );
      throw _mapOtpFailure(e);
    }
  }

  @override
  Future<void> requestSigninOtp({required String email}) async {
    _log.info('requestSigninOtp email=$email');
    try {
      await _client.auth.signInWithOtp(
        email: email,
        shouldCreateUser: false,
      );
    } on sb.AuthException catch (e, st) {
      _log.error(
        'requestSigninOtp error: code=${e.code} message="${e.message}"',
        e,
        st,
      );
      throw _mapOtpFailure(e);
    }
  }

  @override
  Future<AuthUser> verifyOtp({
    required String email,
    required String token,
  }) async {
    _log.info('verifyOtp email=$email token_len=${token.length}');
    try {
      final res = await _client.auth.verifyOTP(
        email: email,
        token: token,
        type: sb.OtpType.email,
      );
      final user = _mapUser(res.user);
      if (user == null) {
        throw const AuthFailure(
          'No user returned from OTP verification.',
          code: 'no_user',
        );
      }
      _log.info('verifyOtp success — user=${user.id}');
      return user;
    } on sb.AuthException catch (e, st) {
      _log.error(
        'verifyOtp error: code=${e.code} message="${e.message}"',
        e,
        st,
      );
      throw _mapOtpFailure(e);
    }
  }

  @override
  Future<AuthUser> signInWithApple() async {
    // Generate a per-request nonce. We send a SHA-256 hash of it to
    // Apple (`nonce:` field) so Apple binds the returned ID token to
    // this specific request; we then hand the RAW nonce to Supabase
    // (`signInWithIdToken nonce:`) which re-derives the hash and
    // verifies it matches the token's `nonce` claim. Without this the
    // ID token is replay-able by anyone who intercepts it.
    final rawNonce = _generateRawNonce();
    final hashedNonce = _sha256Hex(rawNonce);
    _log.info('signInWithApple — opening Apple sheet');

    final AuthorizationCredentialAppleID credential;
    try {
      credential = await SignInWithApple.getAppleIDCredential(
        scopes: const [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: hashedNonce,
      );
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) {
        _log.info('Apple sheet cancelled by user');
        throw const OAuthCancelledFailure();
      }
      _log.warn(
        'Apple authorization error: code=${e.code} message=${e.message}',
      );
      throw AuthFailure(e.message, code: 'apple_${e.code.name}');
    }

    final idToken = credential.identityToken;
    if (idToken == null) {
      _log.error('Apple credential returned without an identity token');
      throw const AuthFailure(
        'Apple did not return an identity token.',
        code: 'apple_no_id_token',
      );
    }

    _log.info(
      'Apple credential — userId=${credential.userIdentifier} '
      'has_name=${credential.givenName != null} '
      'has_email=${credential.email != null}',
    );

    try {
      final res = await _client.auth.signInWithIdToken(
        provider: sb.OAuthProvider.apple,
        idToken: idToken,
        nonce: rawNonce,
      );
      final user = _mapUser(res.user);
      if (user == null) {
        throw const AuthFailure(
          'No user returned from Apple sign in.',
          code: 'no_user',
        );
      }
      // Apple sends a `givenName` only on the very first sign-in. If
      // we got it, push it into raw_user_meta_data so the profile-
      // setup flow can pre-fill the field. The trigger has already
      // run by now (relaxed migration 20260527100000) — this is a
      // post-creation enrichment, not a gate.
      if (credential.givenName != null &&
          credential.givenName!.trim().isNotEmpty) {
        try {
          await _client.auth.updateUser(
            sb.UserAttributes(
              data: <String, dynamic>{
                'first_name': credential.givenName!.trim(),
                'display_name': credential.givenName!.trim(),
              },
            ),
          );
          _log.info(
            'Apple givenName "${credential.givenName}" pushed to user metadata',
          );
        } catch (e) {
          _log.warn('updateUser(givenName) failed (non-fatal): $e');
        }
      }
      _log.info('signInWithApple success — user=${user.id}');
      return user;
    } on sb.AuthException catch (e, st) {
      _log.error(
        'signInWithApple Supabase error: code=${e.code} '
        'message="${e.message}"',
        e,
        st,
      );
      throw _mapOtpFailure(e);
    }
  }

  @override
  Future<AuthUser> signInWithGoogle() async {
    _log.info('signInWithGoogle — opening Google sheet');
    final googleSignIn = GoogleSignIn(
      scopes: const ['email', 'profile'],
    );
    final GoogleSignInAccount? account;
    try {
      account = await googleSignIn.signIn();
    } catch (e, st) {
      _log.warn('Google signIn() threw: $e\n$st');
      throw AuthFailure('Google sign in failed: $e', code: 'google_failed');
    }
    if (account == null) {
      _log.info('Google sheet cancelled by user');
      throw const OAuthCancelledFailure();
    }
    final auth = await account.authentication;
    final idToken = auth.idToken;
    final accessToken = auth.accessToken;
    if (idToken == null) {
      _log.error('Google credential returned without idToken');
      throw const AuthFailure(
        'Google did not return an identity token.',
        code: 'google_no_id_token',
      );
    }
    _log.info(
      'Google credential — email=${account.email} '
      'has_displayName=${account.displayName != null} '
      'has_access=${accessToken != null}',
    );
    try {
      final res = await _client.auth.signInWithIdToken(
        provider: sb.OAuthProvider.google,
        idToken: idToken,
        accessToken: accessToken,
      );
      final user = _mapUser(res.user);
      if (user == null) {
        throw const AuthFailure(
          'No user returned from Google sign in.',
          code: 'no_user',
        );
      }
      // Google reliably provides displayName / email on every sign-in.
      // Push first_name into metadata so profile-setup pre-fills the
      // form. Only on first signin (the trigger has already created a
      // partial profile by now if it's new).
      final name = account.displayName?.trim();
      if (name != null && name.isNotEmpty) {
        try {
          await _client.auth.updateUser(
            sb.UserAttributes(
              data: <String, dynamic>{
                'first_name': name.split(' ').first,
                'display_name': name,
              },
            ),
          );
          _log.info('Google displayName "$name" pushed to user metadata');
        } catch (e) {
          _log.warn('updateUser(displayName) failed (non-fatal): $e');
        }
      }
      _log.info('signInWithGoogle success — user=${user.id}');
      return user;
    } on sb.AuthException catch (e, st) {
      _log.error(
        'signInWithGoogle Supabase error: code=${e.code} '
        'message="${e.message}"',
        e,
        st,
      );
      throw _mapOtpFailure(e);
    }
  }

  @override
  Future<void> linkIdentity(sb.OAuthProvider provider) async {
    _log.info('linkIdentity provider=$provider');
    try {
      // Supabase opens the OAuth flow in an in-app webview (iOS) and
      // returns once the redirect callback fires. The new identity is
      // attached to the current session's user — no new auth.users row
      // unless the OAuth email collides with another account, in
      // which case Supabase returns `identity_already_exists`.
      await _client.auth.linkIdentity(provider);
      _log.info('linkIdentity returned successfully');
    } on sb.AuthException catch (e, st) {
      _log.error(
        'linkIdentity error: code=${e.code} message="${e.message}"',
        e,
        st,
      );
      final code = (e.code ?? '').toLowerCase();
      final msg = e.message.toLowerCase();
      if (code.contains('identity_already_exists') ||
          msg.contains('already exists') ||
          msg.contains('already linked')) {
        throw const AuthFailure(
          'This account is already linked to another DateNow profile.',
          code: 'identity_already_exists',
        );
      }
      throw _mapOtpFailure(e);
    } catch (e, st) {
      _log.error('linkIdentity unexpected: $e', e, st);
      throw AuthFailure('$e', code: 'link_failed');
    }
  }

  /// 32-byte URL-safe random nonce, base64-encoded.
  String _generateRawNonce({int length = 32}) {
    final random = Random.secure();
    final bytes = List<int>.generate(length, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  String _sha256Hex(String input) {
    return sha256.convert(utf8.encode(input)).toString();
  }

  @override
  Future<void> signOut() => _client.auth.signOut();

  @override
  Future<void> deleteAccount() async {
    // 1. Wipe data + delete the auth.users row via the `delete-account`
    //    Edge Function (it uses the service role, never shipped to the
    //    client). Sign out locally even if the function failed so a
    //    stale session can't reach a non-existent profile.
    try {
      final res = await _client.functions.invoke('delete-account');
      if (res.status != 200) {
        _log.error(
          'delete-account returned ${res.status} data=${res.data}',
        );
        throw AuthFailure(
          'Account deletion failed (server returned ${res.status}).',
          code: 'delete_failed',
        );
      }
    } on AuthFailure {
      rethrow;
    } catch (e, st) {
      _log.error('delete-account invocation failed', e, st);
      throw const AuthFailure(
        'Account deletion failed. Please try again or contact support.',
        code: 'delete_failed',
      );
    }
    // 2. Local sign-out so the auth-state stream emits null and the
    //    router redirects back to the auth landing.
    await _client.auth.signOut();
  }

  /// Maps Supabase's `AuthException` onto our domain `AuthFailure` with
  /// a stable `code` the UI can switch on. Rate-limits and unknown
  /// emails are the only signals we surface specifically — everything
  /// else falls back to the raw message.
  AuthFailure _mapOtpFailure(sb.AuthException e) {
    final code = (e.code ?? '').toLowerCase();
    final msg = e.message.toLowerCase();
    if (code.contains('rate_limit') ||
        msg.contains('for security purposes') ||
        msg.contains('only request this after')) {
      return const AuthFailure('Rate limited', code: 'rate_limited');
    }
    if (msg.contains('not found') ||
        msg.contains('no user found') ||
        code == 'otp_disabled') {
      return const AuthFailure(
        'No DateNow account is linked to that email.',
        code: 'user_not_found',
      );
    }
    if (msg.contains('token has expired') ||
        msg.contains('expired') ||
        code == 'otp_expired') {
      return const AuthFailure('OTP code expired', code: 'otp_expired');
    }
    if (msg.contains('invalid token') ||
        msg.contains('invalid otp') ||
        code == 'otp_invalid' ||
        code == 'invalid_otp') {
      return const AuthFailure('OTP code invalid', code: 'otp_invalid');
    }
    return AuthFailure(e.message, code: e.code);
  }

  AuthUser? _mapUser(sb.User? user) {
    if (user == null) return null;
    final meta = user.userMetadata;
    final birthDateRaw = meta?['birth_date'] as String?;
    return AuthUser(
      id: user.id,
      email: user.email ?? '',
      displayName:
          (meta?['display_name'] ?? meta?['first_name']) as String?,
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

/// In-memory passwordless OTP flow. Accepts any 6-digit code. Lets the
/// auth UI stay exercisable when `.env` is empty.
class MockAuthRepository implements AuthRepository {
  MockAuthRepository();

  static const _log = AppLogger('MockAuth');

  final StreamController<AuthUser?> _controller =
      StreamController<AuthUser?>.broadcast();
  AuthUser? _current;
  // email → metadata pending verification
  final Map<String, _PendingOtp> _pending = {};

  @override
  Stream<AuthUser?> authStateChanges() async* {
    yield _current;
    yield* _controller.stream;
  }

  @override
  AuthUser? currentUser() => _current;

  @override
  Future<void> requestSignupOtp({
    required String email,
    required String firstName,
    required DateTime birthDate,
  }) async {
    if (Env.supabaseConfigured) {
      _log.error(
        'Mock requestSignupOtp called while Supabase is configured.',
      );
      throw const AuthFailure(
        'Misconfiguration: Supabase env is set but the client never '
        'initialised. Restart the app or check the bootstrap logs.',
      );
    }
    if (!isOfMinimumAge(birthDate)) {
      throw const MinorSignUpFailure();
    }
    _log.info('mock requestSignupOtp $email — code=123456');
    _pending[email] = _PendingOtp(
      firstName: firstName,
      birthDate: birthDate,
      isSignup: true,
    );
  }

  @override
  Future<void> requestSigninOtp({required String email}) async {
    if (Env.supabaseConfigured) {
      throw const AuthFailure('Mock unavailable when Supabase is configured.');
    }
    _log.info('mock requestSigninOtp $email — code=123456');
    _pending.putIfAbsent(
      email,
      () => const _PendingOtp(isSignup: false),
    );
  }

  @override
  Future<AuthUser> verifyOtp({
    required String email,
    required String token,
  }) async {
    if (token.length != 6) {
      throw const AuthFailure('OTP code invalid', code: 'otp_invalid');
    }
    final pending = _pending.remove(email);
    final user = AuthUser(
      id: 'mock-${email.hashCode.abs()}',
      email: email,
      displayName: pending?.firstName,
      birthDate: pending?.birthDate,
      createdAt: DateTime.now(),
    );
    _current = user;
    _controller.add(user);
    return user;
  }

  @override
  Future<AuthUser> signInWithApple() async {
    if (Env.supabaseConfigured) {
      throw const AuthFailure('Mock unavailable when Supabase is configured.');
    }
    _log.info('mock signInWithApple — auto-completing');
    final user = AuthUser(
      id: 'mock-apple-${DateTime.now().millisecondsSinceEpoch}',
      email: 'apple-user@privaterelay.appleid.com',
      displayName: 'Apple User',
      createdAt: DateTime.now(),
    );
    _current = user;
    _controller.add(user);
    return user;
  }

  @override
  Future<AuthUser> signInWithGoogle() async {
    if (Env.supabaseConfigured) {
      throw const AuthFailure('Mock unavailable when Supabase is configured.');
    }
    _log.info('mock signInWithGoogle — auto-completing');
    final user = AuthUser(
      id: 'mock-google-${DateTime.now().millisecondsSinceEpoch}',
      email: 'google-user@gmail.com',
      displayName: 'Google User',
      createdAt: DateTime.now(),
    );
    _current = user;
    _controller.add(user);
    return user;
  }

  @override
  Future<void> linkIdentity(sb.OAuthProvider provider) async {
    if (Env.supabaseConfigured) {
      throw const AuthFailure('Mock unavailable when Supabase is configured.');
    }
    _log.info('mock linkIdentity provider=$provider — no-op');
  }

  @override
  Future<void> signOut() async {
    _current = null;
    _controller.add(null);
  }

  @override
  Future<void> deleteAccount() async {
    _current = null;
    _controller.add(null);
  }
}

class _PendingOtp {
  const _PendingOtp({
    this.firstName,
    this.birthDate,
    required this.isSignup,
  });

  final String? firstName;
  final DateTime? birthDate;
  final bool isSignup;
}

// ---------------------------------------------------------------------------
// Providers
// ---------------------------------------------------------------------------

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  final available = ref.watch(supabaseAvailableProvider);
  if (available) {
    return SupabaseAuthRepository(ref.watch(supabaseClientProvider));
  }
  return MockAuthRepository();
});
