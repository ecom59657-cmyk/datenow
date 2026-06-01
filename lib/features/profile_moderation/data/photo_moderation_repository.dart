import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/services/supabase_service.dart';
import '../../../core/utils/logger.dart';
import '../domain/photo_moderation_status.dart';

/// Verdict returned by the `analyze-profile-photo` Edge Function.
///
/// Two orthogonal axes :
///   * [status] — what the server actually decided (`approved` /
///     `rejected` / `manual_review`). Mirrors `user_photos.status`.
///   * [serverError] — true when the Edge Function call FAILED
///     before producing a real verdict (HTTP 4xx / 5xx, network
///     timeout, malformed payload). The UI must use a different copy
///     in that case so the user is not falsely told "Photo en cours
///     de vérification" when the real problem is server-side.
class PhotoModerationVerdict {
  const PhotoModerationVerdict({
    required this.status,
    required this.rejectReason,
    required this.userMessage,
    this.serverError = false,
    this.errorCode,
  });

  final PhotoModerationStatus status;

  /// Raw, internal reason (e.g. `nsfw`, `no_face`, `multiple_faces`).
  /// Useful for logs + analytics; **never** surface verbatim to the
  /// user.
  final String? rejectReason;

  /// Pre-localised, premium message ready to show in the UI:
  ///   * approved      → "Photo validée"
  ///   * rejected      → "Votre photo n'a pas pu être validée"
  ///   * manual_review → "Photo en cours de vérification"
  ///   * server error  → "Erreur de vérification photo, réessaie
  ///                       plus tard"
  /// The previous behaviour conflated the manual_review and server-
  /// error cases under the same "en cours" message, which silently
  /// masked Vision / billing / trigger failures during TestFlight.
  final String userMessage;

  /// True ONLY when the verdict was NOT produced by the server —
  /// i.e. the Edge Function call failed (4xx / 5xx / unreachable /
  /// malformed payload). When true the UI shows a retry-style
  /// message; when false the verdict is the server's decision and
  /// must be trusted as-is.
  final bool serverError;

  /// Short tag for analytics + Studio audit when [serverError] is
  /// true. Examples : `function_401`, `function_502`,
  /// `vision_unreachable`, `network_error`, `invalid_response`.
  final String? errorCode;
}

/// Talks to the `analyze-profile-photo` Edge Function + the
/// `has_approved_photo` RPC. Everything else (upload bytes, DB
/// metadata writes) stays in [ProfileRepository] — this class only
/// owns the moderation surface.
class PhotoModerationRepository {
  PhotoModerationRepository(this._client);

  final SupabaseClient _client;
  static const _log = AppLogger('Moderation');

  /// Triggers the Edge Function for [storagePath] (the value returned
  /// by `ProfileRepository.uploadPhoto`). The Edge Function looks up
  /// the matching `user_photos` row, calls Google Vision, persists
  /// the verdict, and returns it.
  ///
  /// Idempotent : if the photo is already in a terminal state
  /// (`approved` / `rejected`), the Edge Function short-circuits and
  /// returns the cached verdict without spending another Vision quota
  /// call.
  Future<PhotoModerationVerdict> analyzeByStoragePath(
    String storagePath,
  ) async {
    _log.info('analyzeByStoragePath path=$storagePath');
    try {
      final res = await _client.functions.invoke(
        'analyze-profile-photo',
        body: <String, dynamic>{'storage_path': storagePath},
      );
      final data = res.data;
      if (data is! Map) {
        _log.warn(
          'analyze-profile-photo unexpected payload '
          '(status=${res.status}): $data',
        );
        return _serverErrorVerdict('invalid_response');
      }
      // 2xx + Map → the server produced a real verdict. Trust it.
      // The Edge Function only ever returns `approved` / `rejected`
      // / `manual_review` in this branch; the `pending` /
      // `analyzing` transient states never appear in a 2xx body.
      final status = PhotoModerationStatus.fromWire(
        data['status'] as String?,
      );
      final reason = data['reject_reason'] as String?;
      final msg = data['message'] as String? ??
          'Photo en cours de vérification';
      _log.info(
        'verdict status=${status.name} reason=${reason ?? '—'}',
      );
      return PhotoModerationVerdict(
        status: status,
        rejectReason: reason,
        userMessage: msg,
      );
    } on FunctionException catch (e) {
      // Edge Function returned a non-2xx. Surface the real outcome
      // to the user — "Erreur de vérification photo, réessaie plus
      // tard" — instead of pretending we are still in progress. The
      // photo row stays at whatever the trigger / Edge Function
      // already wrote (typically `pending` after the Edge Function's
      // own rollback on Vision failure); a retry / cron / next user
      // tap can re-invoke.
      final code = 'function_${e.status}';
      _log.error(
        'analyze-profile-photo FunctionException status=${e.status} '
        'reason=${e.reasonPhrase} details=${e.details} → $code',
      );
      return _serverErrorVerdict(code);
    } catch (e, st) {
      // Network blip, JSON parse failure, isolate cancellation… The
      // call did not even reach the function or did not return a
      // parseable response. Show the same retry message as a server
      // 5xx — from the user's perspective the failure mode is
      // identical.
      _log.error(
        'analyze-profile-photo threw — surfacing as server error',
        e,
        st,
      );
      return _serverErrorVerdict('network_error');
    }
  }

  /// Builds the "the server side failed, ask the user to retry"
  /// verdict shape. status stays `pending` because the photo row's
  /// state at this point is genuinely unknown to us — but the
  /// `serverError = true` flag tells callers to treat this as a
  /// failure mode rather than a legitimate in-progress decision.
  PhotoModerationVerdict _serverErrorVerdict(String code) {
    return PhotoModerationVerdict(
      status: PhotoModerationStatus.pending,
      rejectReason: code,
      userMessage:
          'Erreur de vérification photo, réessaie plus tard',
      serverError: true,
      errorCode: code,
    );
  }

  /// Returns the moderation status of every `user_photos` row owned by
  /// the caller, keyed by `storage_path`. Drives the per-tile overlay
  /// on the `EditPhotosScreen` grid so a `rejected` photo shows
  /// greyed-out with a "Photo refusée" badge while a `pending` /
  /// `manual_review` one shows a discreet "En vérification…" badge.
  ///
  /// Implicitly scoped to `auth.uid()` via the
  /// `user_photos_all_owner` RLS policy — the SELECT cannot leak
  /// other users' statuses.
  ///
  /// Returns an empty map on any error (fail-soft) so the UI falls
  /// back to "no overlay" (= approved) rather than crashing or
  /// flashing red flags on every tile.
  Future<Map<String, PhotoModerationStatus>> myPhotoStatuses() async {
    try {
      final rows = await _client
          .from('user_photos')
          .select('storage_path, status');
      final map = <String, PhotoModerationStatus>{};
      for (final raw in rows as List<dynamic>) {
        final r = (raw as Map).cast<String, dynamic>();
        final path = r['storage_path'] as String?;
        if (path == null) continue;
        map[path] =
            PhotoModerationStatus.fromWire(r['status'] as String?);
      }
      _log.info('myPhotoStatuses → ${map.length} rows');
      // Per-row dump for UX debugging : if a tile shows "Validée"
      // without a matching ".jpg = approved" line in this log, the
      // green badge came from a UI fallback — not from a Google
      // Vision verdict.
      for (final e in map.entries) {
        final short = e.key.contains('/')
            ? e.key.substring(e.key.lastIndexOf('/') + 1)
            : e.key;
        _log.info('  $short = ${e.value.name}');
      }
      return map;
    } catch (e, st) {
      _log.warn('myPhotoStatuses failed (returning empty): $e\n$st');
      return const <String, PhotoModerationStatus>{};
    }
  }

  /// Authoritative answer to "can this user launch a date right now,
  /// or must they upload a moderated photo first?".
  ///
  /// Backed by the `has_approved_photo()` SECURITY DEFINER RPC, so
  /// the client cannot peek at someone else's approval state. False
  /// on any error — fail-closed (better to ask the user for a photo
  /// than to let a malformed query open the find-date gate).
  Future<bool> hasApprovedPhoto() async {
    try {
      final res = await _client.rpc<dynamic>('has_approved_photo');
      final ok = res == true;
      _log.info('has_approved_photo → $ok');
      return ok;
    } catch (e, st) {
      _log.warn('has_approved_photo RPC failed (fail-closed): $e\n$st');
      return false;
    }
  }
}

final photoModerationRepositoryProvider =
    Provider<PhotoModerationRepository?>((ref) {
  if (!ref.watch(supabaseAvailableProvider)) return null;
  return PhotoModerationRepository(ref.watch(supabaseClientProvider));
});

/// Live "do I have an approved photo?" boolean, auto-refreshed every
/// time something invalidates this provider (e.g. after a successful
/// `analyzeByStoragePath` returns approved). The find-date gate reads
/// this synchronously via `.future` on tap.
final hasApprovedPhotoProvider = FutureProvider<bool>((ref) async {
  final repo = ref.watch(photoModerationRepositoryProvider);
  if (repo == null) return false;
  return repo.hasApprovedPhoto();
});

/// Per-photo moderation status map keyed by `storage_path`. Watched by
/// the `EditPhotosScreen` grid so each `PhotoTile` can render its own
/// overlay (greyscale + "Photo refusée" for rejected; discreet "En
/// vérification…" for pending / manual_review). Empty map on error so
/// the grid falls back to "no overlay" rather than failing.
///
/// Invalidate this provider after :
///   * Edge Function returns a verdict (`_moderateAndSurface`)
///   * a photo is deleted (`_deletePhoto`)
final myPhotoStatusesProvider =
    FutureProvider<Map<String, PhotoModerationStatus>>((ref) async {
  final repo = ref.watch(photoModerationRepositoryProvider);
  if (repo == null) return const <String, PhotoModerationStatus>{};
  return repo.myPhotoStatuses();
});
