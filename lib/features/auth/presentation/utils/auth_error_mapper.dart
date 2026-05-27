import '../../../../core/errors/failures.dart';
import '../../../../l10n/app_localizations.dart';

/// Picks the humane FR/EN string for any `Failure` produced by the
/// auth layer. We never display [Failure.message] directly — that's
/// the domain message, mostly English, sometimes a raw Supabase
/// string. The UI always switches on [Failure.code] (set by
/// `_mapAuthFailure` in the repository) and falls back to a generic
/// retry hint instead of leaking technical detail.
///
/// [fallbackKey] picks WHICH generic message to show when the code
/// doesn't match anything specific — sign-in / sign-up / OTP-verify
/// each have a slightly different default tone.
String humaneAuthError(
  Object? err,
  AppLocalizations l10n, {
  required AuthFallback fallback,
}) {
  if (err is Failure) {
    switch (err.code) {
      case 'rate_limited':
        return l10n.signupRateLimited;
      case 'minor_sign_up':
        return l10n.validatorBirthDateMinor;
      case 'user_not_found':
        return l10n.signInUserNotFound;
      case 'otp_invalid':
        return l10n.otpInvalidCode;
      case 'otp_expired':
        return l10n.otpExpiredCode;
      case 'oauth_cancelled':
        // User-cancelled — caller should usually skip showing a snack.
        // We still return a string in case the call site shows it
        // anyway.
        return l10n.authGenericRetry;
      case 'oauth_audience_mismatch':
        return l10n.authGoogleAudienceMismatch;
      case 'google_failed':
      case 'google_no_id_token':
        return l10n.authGoogleFailed;
      case 'apple_failed':
      case 'apple_no_id_token':
        return l10n.authAppleFailed;
      case 'db_signup_error':
      case 'unexpected_failure':
        return l10n.authDbSignupError;
      case 'no_user':
      case 'link_failed':
      case 'identity_already_exists':
      case 'delete_failed':
        // These already have a sensible domain message we can show.
        // Most carry an English string today; treat as a generic
        // retry until we get dedicated l10n strings for them.
        return l10n.authGenericRetry;
    }
  }
  switch (fallback) {
    case AuthFallback.signIn:
      return l10n.couldNotSignIn;
    case AuthFallback.signUp:
      return l10n.couldNotSignUp;
    case AuthFallback.otpVerify:
      return l10n.otpVerifyFailed;
    case AuthFallback.oauthApple:
      return l10n.authAppleFailed;
    case AuthFallback.oauthGoogle:
      return l10n.authGoogleFailed;
    case AuthFallback.generic:
      return l10n.authGenericRetry;
  }
}

enum AuthFallback {
  signIn,
  signUp,
  otpVerify,
  oauthApple,
  oauthGoogle,
  generic,
}
