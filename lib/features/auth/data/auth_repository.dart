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
      throw _mapAuthFailure(e);
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
      // V1 hardening (Pass 7 A7) : suppress account enumeration.
      //
      // Before this fix, `requestSigninOtp` for an unknown email
      // threw an `AuthFailure(code: 'user_not_found')`, while a
      // known email returned silently. An attacker could spray the
      // signin form with candidate emails and read the differential
      // response to learn which addresses are registered DateNow
      // users — a textbook user-enumeration oracle.
      //
      // The fix is to swallow `user_not_found` and pretend success.
      // The UI then routes to the OTP entry screen as if a code had
      // been sent ; `verifyOtp` will fail with a generic
      // 'otp_invalid' for any code the attacker types, which is
      // indistinguishable from a legitimate user mistyping their
      // code. The attacker can still infer email validity by waiting
      // for an email to actually arrive, but that requires controlling
      // a mailbox — i.e. social engineering, not an enumeration oracle.
      //
      // We DO still throw rate-limit / OTP-disabled / other errors
      // so the UX surfaces real outages.
      final failure = _mapAuthFailure(e);
      if (failure.code == 'user_not_found') {
        _log.info(
          'requestSigninOtp: user_not_found suppressed (anti-enum)',
        );
        return;
      }
      _log.error(
        'requestSigninOtp error: code=${e.code} message="${e.message}"',
        e,
        st,
      );
      throw failure;
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
      await _ensureProfileExists();
      _log.info('verifyOtp success — user=${user.id}');
      return user;
    } on sb.AuthException catch (e, st) {
      _log.error(
        'verifyOtp error: code=${e.code} message="${e.message}"',
        e,
        st,
      );
      throw _mapAuthFailure(e);
    }
  }

  /// Calls the `ensure_profile_exists` SECURITY DEFINER RPC. Idempotent
  /// top-up that re-creates any of profiles / user_preferences /
  /// user_settings / subscriptions that the `handle_new_user` trigger
  /// might have silently dropped (see migration
  /// 20260527130000_handle_new_user_hardening.sql for the why). Never
  /// throws — a missing row is a UX inconvenience at worst, not an
  /// auth failure, so we log and move on.
  Future<void> _ensureProfileExists() async {
    try {
      await _client.rpc('ensure_profile_exists');
    } catch (e, st) {
      _log.warn('ensure_profile_exists RPC failed (non-fatal): $e\n$st');
    }
  }

  @override
  Future<AuthUser> signInWithApple() async {
    // ──────────────────────────────────────────────────────────────
    // TEMP — numbered [APPLE N] logs so we can pinpoint the exact
    // step that breaks during diagnostic. Tag each branch (cancel,
    // no_id_token, audience, nonce, …) with its own [APPLE ERR …]
    // so the Mac console / Xcode console shows the cause as the
    // very next line after the last successful step. Remove the
    // [APPLE …] tags once both OAuth flows are stable in TestFlight.
    // ──────────────────────────────────────────────────────────────
    _log.info('[APPLE 1] entry — generating per-request nonce');
    final rawNonce = _generateRawNonce();
    final hashedNonce = _sha256Hex(rawNonce);
    _log.info(
      '[APPLE 2] nonce ready — rawNonce_len=${rawNonce.length} '
      'hashedNonce_len=${hashedNonce.length}',
    );

    final AuthorizationCredentialAppleID credential;
    try {
      _log.info('[APPLE 3] calling SignInWithApple.getAppleIDCredential — '
          'this is where the iOS native sheet + Face ID happens');
      credential = await SignInWithApple.getAppleIDCredential(
        scopes: const [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: hashedNonce,
      );
      _log.info('[APPLE 4] Apple credential returned by native SDK');
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) {
        _log.info('[APPLE ERR cancel] user dismissed the Apple sheet');
        throw const OAuthCancelledFailure();
      }
      _log.warn(
        '[APPLE ERR native] AuthorizationErrorCode=${e.code} '
        'message="${e.message}"',
      );
      throw AuthFailure(
        e.message,
        code: 'apple_${e.code.name}',
        originalMessage: e.message,
      );
    }

    final idToken = credential.identityToken;
    if (idToken == null) {
      _log.error(
        '[APPLE ERR no_id_token] credential.identityToken is null — '
        'Apple did not return an id_token. Usually means the request '
        'scopes were missing the email scope or the entitlement is off.',
      );
      throw const AuthFailure(
        'Apple did not return an identity token.',
        code: 'apple_no_id_token',
      );
    }

    _log.info(
      '[APPLE 5] credential parsed — userId=${credential.userIdentifier} '
      'has_name=${credential.givenName != null} '
      'has_email=${credential.email != null} '
      'idToken_len=${idToken.length}',
    );
    // [APPLE 6] decodes and logs the id_token payload (iss/aud/sub/
    // nonce/azp/exp/email) for cross-check vs Supabase Apple provider.
    _logJwtPayload(
      provider: 'apple',
      idToken: idToken,
      extraContext: 'rawNonce_len=${rawNonce.length} '
          'hashedNonce=$hashedNonce',
    );

    try {
      _log.info('[APPLE 7] calling Supabase signInWithIdToken — '
          'provider=apple nonce_len=${rawNonce.length}');
      final res = await _client.auth.signInWithIdToken(
        provider: sb.OAuthProvider.apple,
        idToken: idToken,
        nonce: rawNonce,
      );
      _log.info('[APPLE 8] Supabase exchange OK — session opened, '
          'user_id=${res.user?.id}');
      final user = _mapUser(res.user);
      if (user == null) {
        _log.error('[APPLE ERR no_user] Supabase returned a response with '
            'no user — should never happen if exchange succeeded');
        throw const AuthFailure(
          'No user returned from Apple sign in.',
          code: 'apple_no_user',
        );
      }
      _log.info('[APPLE 9] calling ensure_profile_exists RPC');
      await _ensureProfileExists();
      _log.info('[APPLE 10] ensure_profile_exists returned');
      // Apple sends a `givenName` only on the very first sign-in. If
      // we got it, push it into raw_user_meta_data so the profile-
      // setup flow can pre-fill the field. The trigger has already
      // run by now (relaxed migration 20260527100000) — this is a
      // post-creation enrichment, not a gate.
      if (credential.givenName != null &&
          credential.givenName!.trim().isNotEmpty) {
        try {
          _log.info('[APPLE 11] pushing givenName="${credential.givenName}" '
              'to user metadata');
          await _client.auth.updateUser(
            sb.UserAttributes(
              data: <String, dynamic>{
                'first_name': credential.givenName!.trim(),
                'display_name': credential.givenName!.trim(),
              },
            ),
          );
          _log.info(
            '[APPLE 12] givenName pushed OK',
          );
        } catch (e) {
          _log.warn('updateUser(givenName) failed (non-fatal): $e');
        }
      }
      _log.info('[APPLE 13] success — user=${user.id} — returning');
      return user;
    } on sb.AuthException catch (e, st) {
      _log.error(
        '[APPLE ERR supabase] AuthException at signInWithIdToken — '
        'code=${e.code} message="${e.message}"',
        e,
        st,
      );
      throw _mapAuthFailure(e, provider: 'apple');
    }
  }

  @override
  Future<AuthUser> signInWithGoogle() async {
    _log.info('[GOOGLE 1] entry — reading Env.googleWebClientId');
    // `serverClientId` MUST be the Web OAuth client ID (the same value
    // Supabase Auth → Providers → Google is configured with). Without
    // it, Google issues an id_token whose `aud` claim is the iOS
    // client and Supabase rejects the exchange with "Unacceptable
    // audience in id_token". The iOS client is still implicitly used
    // to identify the app to Google (via GoogleService-Info.plist /
    // Info.plist URL scheme); only the audience switches.
    final webClientId = Env.googleWebClientId;
    if (webClientId.isEmpty) {
      _log.warn(
        '[GOOGLE 2 WARN] GOOGLE_WEB_CLIENT_ID is empty — Google will '
        'issue an id_token with the iOS client as audience, which '
        'Supabase rejects unless its "Authorized Client IDs" includes '
        'the iOS client.',
      );
    } else {
      _log.info('[GOOGLE 2] webClientId set (len=${webClientId.length})');
    }
    final googleSignIn = GoogleSignIn(
      serverClientId: webClientId.isEmpty ? null : webClientId,
      scopes: const ['email', 'profile'],
    );
    final GoogleSignInAccount? account;
    try {
      _log.info('[GOOGLE 3] calling googleSignIn.signIn() — opens native '
          'iOS sheet');
      account = await googleSignIn.signIn();
      _log.info('[GOOGLE 4] googleSignIn.signIn() returned');
    } catch (e, st) {
      _log.warn('[GOOGLE ERR native] googleSignIn.signIn() threw: $e\n$st');
      throw AuthFailure(
        'Google sign in failed: $e',
        code: 'google_failed',
        originalMessage: e.toString(),
      );
    }
    if (account == null) {
      _log.info('[GOOGLE ERR cancel] account is null — user dismissed sheet');
      throw const OAuthCancelledFailure();
    }
    _log.info('[GOOGLE 5] account received — email=${account.email}');
    final auth = await account.authentication;
    final idToken = auth.idToken;
    final accessToken = auth.accessToken;
    if (idToken == null) {
      _log.error(
        '[GOOGLE ERR no_id_token] auth.idToken is null — '
        'check GoogleService-Info.plist CLIENT_ID + scopes',
      );
      throw const AuthFailure(
        'Google did not return an identity token.',
        code: 'google_no_id_token',
      );
    }
    _log.info(
      '[GOOGLE 6] credential parsed — email=${account.email} '
      'has_displayName=${account.displayName != null} '
      'has_access=${accessToken != null} idToken_len=${idToken.length}',
    );
    // [GOOGLE 7] decodes and logs the id_token payload (iss/aud/sub/
    // nonce/azp/exp/email) for cross-check vs Supabase Google provider.
    _logJwtPayload(
      provider: 'google',
      idToken: idToken,
      extraContext: 'serverClientId_set=${webClientId.isNotEmpty}',
    );
    try {
      _log.info('[GOOGLE 8] calling Supabase signInWithIdToken');
      final res = await _client.auth.signInWithIdToken(
        provider: sb.OAuthProvider.google,
        idToken: idToken,
        accessToken: accessToken,
      );
      _log.info('[GOOGLE 9] Supabase exchange OK — session opened, '
          'user_id=${res.user?.id}');
      final user = _mapUser(res.user);
      if (user == null) {
        _log.error('[GOOGLE ERR no_user] Supabase exchange returned no user');
        throw const AuthFailure(
          'No user returned from Google sign in.',
          code: 'google_no_user',
        );
      }
      _log.info('[GOOGLE 10] calling ensure_profile_exists RPC');
      await _ensureProfileExists();
      _log.info('[GOOGLE 11] ensure_profile_exists returned');
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
          _log.info('[GOOGLE 12] displayName "$name" pushed to metadata');
        } catch (e) {
          _log.warn(
            '[GOOGLE 12 WARN] updateUser(displayName) failed (non-fatal): $e',
          );
        }
      }
      _log.info('[GOOGLE 13] success — user=${user.id} — returning');
      return user;
    } on sb.AuthException catch (e, st) {
      _log.error(
        '[GOOGLE ERR supabase] AuthException at signInWithIdToken — '
        'code=${e.code} message="${e.message}"',
        e,
        st,
      );
      throw _mapAuthFailure(e, provider: 'google');
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
      throw _mapAuthFailure(e);
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

  /// Maps Supabase's `AuthException` onto our domain `AuthFailure`
  /// with a stable `code` the UI switches on to pick a humane FR
  /// string. The raw Supabase message stays on the `Failure` instance
  /// (preserved in `originalMessage`) so debug logs and crash reports
  /// keep the technical detail; only the user-facing string is
  /// rewritten by the UI layer.
  ///
  /// [provider] is an optional hint — when an OAuth flow fails, an
  /// "unknown" error falls back to a provider-specific generic
  /// message ("Connexion Google impossible…") instead of the raw
  /// Supabase string.
  AuthFailure _mapAuthFailure(sb.AuthException e, {String? provider}) {
    final code = (e.code ?? '').toLowerCase();
    final msg = e.message.toLowerCase();

    // Rate limit (Supabase "for security purposes" wording).
    if (code.contains('rate_limit') ||
        msg.contains('for security purposes') ||
        msg.contains('only request this after')) {
      return AuthFailure('Rate limited',
          code: 'rate_limited', originalMessage: e.message);
    }
    // User-not-found on a `shouldCreateUser: false` request.
    if (msg.contains('not found') ||
        msg.contains('no user found') ||
        code == 'otp_disabled') {
      return AuthFailure(
        'No DateNow account is linked to that email.',
        code: 'user_not_found',
        originalMessage: e.message,
      );
    }
    if (msg.contains('token has expired') ||
        msg.contains('expired') ||
        code == 'otp_expired') {
      return AuthFailure('OTP code expired',
          code: 'otp_expired', originalMessage: e.message);
    }
    if (msg.contains('invalid token') ||
        msg.contains('invalid otp') ||
        code == 'otp_invalid' ||
        code == 'invalid_otp') {
      return AuthFailure('OTP code invalid',
          code: 'otp_invalid', originalMessage: e.message);
    }
    // Audience mismatch — the id_token's `aud` claim doesn't match
    // any of Supabase's configured Client IDs for this provider.
    //
    //   Google → `Env.googleWebClientId` (serverClientId) or iOS
    //            CLIENT_ID must match Supabase Google Provider's
    //            "Client ID (for OAuth)" + "Authorized Client IDs".
    //   Apple  → bundle id (com.datenow.app) must be in Supabase
    //            Apple Provider's "Client IDs" comma-list alongside
    //            the Services ID (com.datenow.app.auth).
    //
    // CRITICAL: tag the code with the actual provider so the UI maps
    // to the right humane string. Earlier this used a single
    // `oauth_audience_mismatch` code that always mapped to the
    // Google message — a real Apple failure was shown as "Connexion
    // Google impossible", confusing the user about which provider
    // actually broke.
    if (msg.contains('unacceptable audience') ||
        (msg.contains('audience') && msg.contains('id_token'))) {
      final mappedCode = provider == 'apple'
          ? 'apple_audience_mismatch'
          : provider == 'google'
              ? 'google_audience_mismatch'
              : 'oauth_audience_mismatch';
      return AuthFailure(
        'id_token audience mismatch ($provider)',
        code: mappedCode,
        originalMessage: e.message,
      );
    }
    // Apple-specific: nonce present on one side but not the other.
    // Usually fires when the iOS native SDK didn't forward our
    // hashedNonce to AuthenticationServices, so Apple returned a
    // token with no nonce claim while we still send the rawNonce to
    // Supabase (or vice versa). Different from the audience case.
    if (msg.contains('nonce') &&
        (msg.contains('both exist') || msg.contains('should either'))) {
      return AuthFailure(
        'Apple nonce mismatch',
        code: 'apple_nonce_mismatch',
        originalMessage: e.message,
      );
    }
    // Generic DB-side trigger failure (handle_new_user). Now mostly
    // mitigated by the hardened trigger + ensure_profile_exists RPC,
    // but we still map the code so the UI shows a humane message if
    // it ever resurfaces (e.g. a brand-new column with NOT NULL).
    if (code == 'unexpected_failure' ||
        msg.contains('database error saving new user') ||
        msg.contains('database error')) {
      return AuthFailure(
        'Database error during signup',
        code: 'db_signup_error',
        originalMessage: e.message,
      );
    }
    // Provider-specific generic fallback so we never bubble a
    // technical Supabase string into a snack.
    if (provider == 'google') {
      return AuthFailure('Google sign in failed',
          code: 'google_failed', originalMessage: e.message);
    }
    if (provider == 'apple') {
      return AuthFailure('Apple sign in failed',
          code: 'apple_failed', originalMessage: e.message);
    }
    return AuthFailure(e.message,
        code: e.code, originalMessage: e.message);
  }

  /// TEMP — diagnostic helper. Decodes the un-verified JWT payload of
  /// an id_token to log the key claims (`aud`, `iss`, `sub`, `nonce`,
  /// `azp`, `exp`) so we can see EXACTLY what the OAuth provider sent
  /// before we hand it to Supabase. Pure inspection, NO verification
  /// (gotrue does the cryptographic check on its side). Safe to ship
  /// — never logs the signature, never logs the full token.
  ///
  /// Remove this helper + its 2 call sites once the OAuth flows are
  /// stable and we no longer need the visibility.
  void _logJwtPayload({
    required String provider,
    required String idToken,
    String? extraContext,
  }) {
    try {
      final parts = idToken.split('.');
      if (parts.length != 3) {
        _log.warn('[$provider id_token] malformed JWT (parts=${parts.length})');
        return;
      }
      var payload = parts[1];
      // base64Url with optional padding
      switch (payload.length % 4) {
        case 2: payload += '=='; break;
        case 3: payload += '=';  break;
      }
      final decoded = utf8.decode(base64Url.decode(payload));
      final m = jsonDecode(decoded) as Map<String, dynamic>;
      final aud = m['aud'];
      final iss = m['iss'];
      final sub = m['sub'];
      final nonce = m['nonce'];
      final azp = m['azp'];
      final exp = m['exp'];
      final email = m['email'];
      _log.info(
        '[$provider id_token] '
        'iss=$iss '
        'aud=$aud '
        'azp=$azp '
        'sub=$sub '
        'nonce=${nonce ?? "<absent>"} '
        'exp=$exp '
        'email=$email'
        '${extraContext == null ? '' : ' $extraContext'}',
      );
    } catch (e, st) {
      _log.warn('[$provider id_token] decode failed: $e\n$st');
    }
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
