import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/services/supabase_service.dart';
import '../../../core/utils/logger.dart';
import '../../auth/presentation/providers/auth_provider.dart';
import '../domain/identity_verification_status.dart';

/// Outcome of `IdentityRepository.createSession()`.
///
/// Three shapes :
///   * `IdentitySessionReady`    — Didit session created (or reused).
///                                  Carries the URL the WebView must
///                                  open.
///   * `IdentityAlreadyVerified` — server says this user is already
///                                  approved; no session needed.
///   * `IdentitySessionError`    — Edge Function failure (Didit
///                                  unreachable / API error / network).
///                                  Carries a pre-localised
///                                  [userMessage] ready for SnackBar.
sealed class IdentitySessionResult {
  const IdentitySessionResult();
}

class IdentitySessionReady extends IdentitySessionResult {
  const IdentitySessionReady({
    required this.sessionId,
    required this.sessionToken,
    required this.sessionUrl,
    required this.expiresAt,
    required this.reused,
  });

  final String sessionId;

  /// Short-lived (~30 min) token bound to ONE user's ONE verification
  /// session. Passed to `DiditSdk.startVerification(sessionToken)`.
  /// Cannot be used to create other sessions, read other users, or
  /// rotate the server-side API key. Phase 6 of the rollout migrated
  /// the client from the hosted-URL flow to the native SDK — this
  /// field became required as a result.
  final String sessionToken;

  /// Hosted-URL fallback. Kept on the response for debug builds and
  /// for the (currently unused) `url_launcher` path that we may
  /// re-introduce if the native SDK ever needs a backup channel.
  final String sessionUrl;

  final DateTime expiresAt;

  /// True when the Edge Function returned an existing open session
  /// instead of spinning up a new one. Identical UX from the user's
  /// perspective — included for analytics / log.
  final bool reused;
}

class IdentityAlreadyVerified extends IdentitySessionResult {
  const IdentityAlreadyVerified();
}

class IdentitySessionError extends IdentitySessionResult {
  const IdentitySessionError({
    required this.code,
    required this.userMessage,
  });

  /// Short tag for analytics (`function_502`, `network_error`, …).
  final String code;

  /// Pre-localised message ready to surface in a SnackBar. Never the
  /// raw error code — we keep the technical detail in [code] for
  /// logs.
  final String userMessage;
}

/// One identity_verifications row, the shape the Flutter UI consumes
/// when subscribing to the user's verification stream.
class IdentityVerificationRow {
  const IdentityVerificationRow({
    required this.id,
    required this.userId,
    required this.status,
    required this.rejectReason,
    required this.sessionToken,
    required this.sessionUrl,
    required this.externalSessionId,
    required this.createdAt,
    required this.submittedAt,
    required this.decidedAt,
  });

  final String id;
  final String userId;
  final IdentityVerificationStatus status;

  /// Internal reject tag (`minor`, `face_mismatch`, `document_invalid`,
  /// `liveness_failed`, `age_mismatch`, `expired`, …). Drives the
  /// Phase 5 screen wording. **Never** surface verbatim to the user.
  final String? rejectReason;

  /// Token bound to this verification session. Read from
  /// `raw_payload.session_token`. Passed to
  /// `DiditSdk.startVerification(sessionToken)` when the user resumes
  /// an in-progress Didit session (status `pending`) — saves a
  /// round-trip to the Edge Function. See `IdentitySessionReady`
  /// docstring for the security trade-off rationale (Phase 6).
  final String? sessionToken;

  /// Hosted Didit URL — kept as a fallback for debug builds and for
  /// the (currently unused) hosted-URL path. Extracted from
  /// `raw_payload.url`. The native SDK path (Phase 6) does not use it.
  final String? sessionUrl;

  /// Didit's own session UUID — used by the webhook to find this row.
  /// Surfaced for the analytics / debug screen only.
  final String? externalSessionId;

  final DateTime createdAt;
  final DateTime? submittedAt;
  final DateTime? decidedAt;

  factory IdentityVerificationRow.fromJson(Map<String, dynamic> json) {
    final raw = (json['raw_payload'] as Map?)?.cast<String, dynamic>();
    return IdentityVerificationRow(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      status: IdentityVerificationStatus.fromWire(
        json['status'] as String?,
      ),
      rejectReason: json['reject_reason'] as String?,
      sessionToken: raw?['session_token'] as String?,
      sessionUrl:   raw?['url']           as String?,
      externalSessionId: json['external_session_id'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      submittedAt: (json['submitted_at'] as String?) != null
          ? DateTime.parse(json['submitted_at'] as String)
          : null,
      decidedAt: (json['decided_at'] as String?) != null
          ? DateTime.parse(json['decided_at'] as String)
          : null,
    );
  }
}

/// Thin wrapper around the Didit Edge Functions + the
/// `has_verified_identity()` RPC + the realtime stream on
/// `identity_verifications`. Sister of
/// `PhotoModerationRepository` (same shape, same fail-soft
/// semantics).
class IdentityRepository {
  IdentityRepository(this._client);

  final SupabaseClient _client;
  static const _log = AppLogger('Identity');

  /// Asks the server to spin up (or reuse) a Didit verification
  /// session for the caller. Returns a sealed result the caller
  /// switches on — never throws.
  ///
  /// Possible outcomes :
  ///   * [IdentitySessionReady]    — open `sessionUrl` in a WebView
  ///   * [IdentityAlreadyVerified] — short-circuit, no flow needed
  ///   * [IdentitySessionError]    — show the [userMessage] SnackBar
  Future<IdentitySessionResult> createSession() async {
    _log.info('createSession START');
    try {
      final res = await _client.functions.invoke(
        'didit-create-session',
      );
      final data = res.data;
      if (data is! Map) {
        _log.warn(
          'didit-create-session unexpected payload '
          '(status=${res.status}): $data',
        );
        return const IdentitySessionError(
          code: 'invalid_response',
          userMessage:
              'Vérification indisponible, réessaie dans un instant.',
        );
      }
      final map = data.cast<String, dynamic>();
      if (map['already_verified'] == true) {
        _log.info('createSession → already verified, no session needed');
        return const IdentityAlreadyVerified();
      }
      final sessionId    = map['session_id']    as String?;
      final sessionToken = map['session_token'] as String?;
      final sessionUrl   = map['session_url']   as String?;
      final expiresAtRaw = map['expires_at']    as String?;
      final status       = map['status']        as String?;
      if (sessionId == null || sessionToken == null || sessionUrl == null) {
        _log.warn(
          'createSession returned without session_id / session_token / '
          'session_url: $map',
        );
        return const IdentitySessionError(
          code: 'invalid_response',
          userMessage:
              'Vérification indisponible, réessaie dans un instant.',
        );
      }
      // The Edge Function returns expires_at as a UTC ISO string ;
      // when it's absent (or parse fails) we synthesise a 30-min
      // TTL in UTC so the fallback agrees with the server's
      // convention and any downstream comparison stays timezone-
      // agnostic. Phase A timezone refactor.
      final expiresAt = expiresAtRaw != null
          ? DateTime.tryParse(expiresAtRaw) ??
              DateTime.now().toUtc().add(const Duration(minutes: 30))
          : DateTime.now().toUtc().add(const Duration(minutes: 30));
      // Never log the token itself — keep observability privacy-safe.
      _log.info(
        'createSession OK — session=$sessionId status=$status '
        'expiresAt=${expiresAt.toIso8601String()} (token redacted)',
      );
      return IdentitySessionReady(
        sessionId: sessionId,
        sessionToken: sessionToken,
        sessionUrl: sessionUrl,
        expiresAt: expiresAt,
        reused: status == 'reused',
      );
    } on FunctionException catch (e) {
      // Edge Function returned a non-2xx — Didit upstream issue,
      // missing secret, db_insert_failed, etc.
      _log.error(
        'createSession FunctionException status=${e.status} '
        'reason=${e.reasonPhrase} details=${e.details}',
      );
      return IdentitySessionError(
        code: 'function_${e.status}',
        userMessage:
            'Vérification indisponible, réessaie dans un instant.',
      );
    } catch (e, st) {
      _log.error('createSession threw', e, st);
      return const IdentitySessionError(
        code: 'network_error',
        userMessage: 'Vérification indisponible, réessaie plus tard.',
      );
    }
  }

  /// Authoritative answer to "is this user verified RIGHT NOW ?".
  /// Backed by the `has_verified_identity()` SECURITY DEFINER RPC,
  /// so the client cannot peek at someone else's state. Fail-closed
  /// on any error — the Phase 6 find-date gate refuses access when
  /// uncertain (better to ask than to let a non-verified user
  /// through on a transient network failure).
  Future<bool> hasVerifiedIdentity() async {
    try {
      final res = await _client.rpc<dynamic>('has_verified_identity');
      final ok = res == true;
      _log.info('has_verified_identity → $ok');
      return ok;
    } catch (e, st) {
      _log.warn('has_verified_identity RPC failed (fail-closed): $e\n$st');
      return false;
    }
  }

  /// Realtime stream of the caller's most recent identity_verifications
  /// row, or `null` when no row exists yet (= user has never started
  /// a Didit session). Emits a new value every time the row changes
  /// — the webhook's UPDATE will land here within ~1 s and let the
  /// Phase 5 screen flip its overlay from "in progress" to the
  /// verdict without any manual refresh.
  ///
  /// Implementation note : Supabase Realtime streams emit a full
  /// `List<Map>` on every change. For each emission we sort by
  /// `created_at DESC` client-side and yield the first row. A user
  /// typically has 1-3 rows lifetime so the sort is trivial.
  Stream<IdentityVerificationRow?> watchLatest(String userId) {
    return _client
        .from('identity_verifications')
        .stream(primaryKey: ['id'])
        .eq('user_id', userId)
        .map((rows) {
      if (rows.isEmpty) return null;
      final sorted = [...rows]..sort((a, b) {
        final aDate = DateTime.parse(a['created_at'] as String);
        final bDate = DateTime.parse(b['created_at'] as String);
        return bDate.compareTo(aDate);
      });
      return IdentityVerificationRow.fromJson(
        sorted.first.cast<String, dynamic>(),
      );
    });
  }
}

// ─── Riverpod providers ────────────────────────────────────────

final identityRepositoryProvider =
    Provider<IdentityRepository?>((ref) {
  if (!ref.watch(supabaseAvailableProvider)) return null;
  return IdentityRepository(ref.watch(supabaseClientProvider));
});

/// Live "is this user identity-verified ?" boolean. Auto-refreshed
/// when invalidated (e.g. after the webhook lands the approval).
/// Mirrors [hasApprovedPhotoProvider] from the photo moderation
/// rollout — the Phase 6 find-date gate will consume it.
final hasVerifiedIdentityProvider = FutureProvider<bool>((ref) async {
  final repo = ref.watch(identityRepositoryProvider);
  if (repo == null) return false;
  return repo.hasVerifiedIdentity();
});

/// Latest identity_verifications row for the signed-in user, or
/// `null`. Drives the Phase 5 screen status overlay (waiting /
/// in_review / approved / rejected / expired).
final latestIdentityVerificationProvider =
    StreamProvider.family<IdentityVerificationRow?, String>(
  (ref, userId) {
    final repo = ref.watch(identityRepositoryProvider);
    if (repo == null) return const Stream<IdentityVerificationRow?>.empty();
    return repo.watchLatest(userId);
  },
);

/// True ONLY when the signed-in user has a Didit-issued verification
/// in the `approved` terminal state.
///
/// Distinct from [hasVerifiedIdentityProvider] on purpose :
///   * `hasVerifiedIdentityProvider` is backed by the SECURITY DEFINER
///     RPC `has_verified_identity()` — returns true for `grandfather`
///     accounts (the Phase 1 migration flipped existing dev accounts
///     to identity_verified=true with identity_provider='grandfather'
///     so they could keep using the app while Didit shipped). It
///     drives the find-date hard gate, which is intentionally lenient
///     on legacy accounts.
///   * `isDiditVerifiedProvider` ignores the grandfather grandparent
///     flag and requires a *real* Didit-approved row in
///     `identity_verifications`. It drives the UX surfaces that
///     advertise "Identité vérifiée ✓" (Settings tile, absence of
///     the Home nudge card, absence of the Profile banner) — we
///     don't want grandfather accounts to feel falsely reassured
///     and we don't want to lie to a future audit reviewer about
///     who really went through KYC.
///
/// Falls back to `false` while the stream is still loading or when
/// no row exists for the user — both are "not yet Didit-verified"
/// states from the UX standpoint.
final isDiditVerifiedProvider = Provider<bool>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) return false;
  final row = ref.watch(latestIdentityVerificationProvider(user.id)).asData?.value;
  return row?.status == IdentityVerificationStatus.approved;
});
