import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/services/supabase_service.dart';
import '../../../core/utils/logger.dart';
import '../domain/photo_moderation_status.dart';

/// Verdict returned by the `analyze-profile-photo` Edge Function.
class PhotoModerationVerdict {
  const PhotoModerationVerdict({
    required this.status,
    required this.rejectReason,
    required this.userMessage,
  });

  final PhotoModerationStatus status;

  /// Raw, internal reason (e.g. `nsfw`, `no_face`, `multiple_faces`).
  /// Useful for logs + analytics; **never** surface verbatim to the
  /// user.
  final String? rejectReason;

  /// Pre-localised, premium message ready to show in the UI:
  ///   * approved      → "Photo validée"
  ///   * rejected      → "Votre photo n'a pas pu être validée"
  ///   * pending/manual_review → "Photo en cours de vérification"
  final String userMessage;
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
          'analyze-profile-photo unexpected payload (status=${res.status}): $data',
        );
        return const PhotoModerationVerdict(
          status: PhotoModerationStatus.pending,
          rejectReason: 'invalid_response',
          userMessage: 'Photo en cours de vérification',
        );
      }
      final status = PhotoModerationStatus.fromWire(
        data['status'] as String?,
      );
      final reason = data['reject_reason'] as String?;
      final msg = data['message'] as String? ?? 'Photo en cours de vérification';
      _log.info(
        'verdict status=${status.name} reason=${reason ?? '—'}',
      );
      return PhotoModerationVerdict(
        status: status,
        rejectReason: reason,
        userMessage: msg,
      );
    } on FunctionException catch (e) {
      // Edge Function returned a non-2xx — keep the photo in
      // pending so a retry / cron can pick it up; UX keeps showing
      // the soft "in progress" message.
      _log.error(
        'analyze-profile-photo FunctionException status=${e.status} '
        'reason=${e.reasonPhrase} details=${e.details}',
      );
      return const PhotoModerationVerdict(
        status: PhotoModerationStatus.pending,
        rejectReason: 'function_error',
        userMessage: 'Photo en cours de vérification',
      );
    } catch (e, st) {
      _log.error('analyze-profile-photo threw — keeping pending', e, st);
      return const PhotoModerationVerdict(
        status: PhotoModerationStatus.pending,
        rejectReason: 'network_error',
        userMessage: 'Photo en cours de vérification',
      );
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
