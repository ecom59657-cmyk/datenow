import 'dart:async';
import 'dart:io' show Platform;

import 'package:app_tracking_transparency/app_tracking_transparency.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../../../core/utils/logger.dart';

/// Gathers the two permissions Google requires before an ad request is legal.
///
/// Two distinct things, often confused:
///
///  * **UMP** is the GDPR/ePrivacy consent form. DateNow ships in France, so
///    EU users must answer it before any ad request. Google refuses to serve
///    personalised ads without it and can suspend accounts that skip it.
///  * **ATT** is Apple's tracking prompt (iOS 14.5+). Without it the IDFA is
///    unavailable, ads fall back to contextual targeting and eCPM drops hard.
///
/// Order matters: Apple requires ATT to be requested *after* the app is
/// visible, and Google recommends showing the UMP form first so the user
/// understands what they are consenting to.
class ConsentService {
  const ConsentService();

  static const _log = AppLogger('Consent');

  /// Runs the full flow. Never throws — a consent failure must degrade to
  /// "no ads" rather than take down app start-up.
  Future<void> gather() async {
    await _requestUmp();
    await _requestAtt();
  }

  Future<void> _requestUmp() async {
    final completer = Completer<void>();

    ConsentInformation.instance.requestConsentInfoUpdate(
      ConsentRequestParameters(),
      () async {
        try {
          await ConsentForm.loadAndShowConsentFormIfRequired((error) {
            if (error != null) {
              _log.warn('UMP form error: ${error.message}');
            }
          });
        } catch (e) {
          _log.warn('UMP form threw ($e) — continuing without consent.');
        }
        if (!completer.isCompleted) completer.complete();
      },
      (error) {
        _log.warn('UMP update failed: ${error.message}');
        if (!completer.isCompleted) completer.complete();
      },
    );

    return completer.future;
  }

  Future<void> _requestAtt() async {
    if (!Platform.isIOS) return;
    try {
      final status =
          await AppTrackingTransparency.trackingAuthorizationStatus;
      if (status == TrackingStatus.notDetermined) {
        // A short delay avoids the prompt racing the first frame, which on
        // iOS silently returns `denied` without ever showing the dialog.
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await AppTrackingTransparency.requestTrackingAuthorization();
      }
    } catch (e) {
      _log.warn('ATT prompt failed ($e) — contextual ads only.');
    }
  }

  /// Whether Google considers us allowed to request ads at all.
  Future<bool> canRequestAds() async {
    try {
      return await ConsentInformation.instance.canRequestAds();
    } catch (e) {
      _log.warn('canRequestAds failed ($e) — assuming no.');
      return false;
    }
  }
}
