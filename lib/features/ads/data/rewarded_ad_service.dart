import 'dart:async';

import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../../../core/utils/logger.dart';
import '../domain/ad_ids.dart';
import 'consent_service.dart';

/// Loads and shows the rewarded video that grants one extra date.
///
/// Rewarded is the only format DateNow serves: it is opt-in, so a user who
/// declines sees exactly the app they saw before. Banners and interstitials
/// were deliberately left out — on a dating product the cost to perceived
/// quality outweighs their far lower eCPM.
///
/// A rewarded ad is single-use: once shown it must be disposed and a fresh
/// one loaded. [preload] is therefore called again right after a show.
class RewardedAdService {
  RewardedAdService(this._consent);

  final ConsentService _consent;

  static const _log = AppLogger('RewardedAd');

  RewardedAd? _ad;
  bool _loading = false;
  bool _consentGathered = false;

  bool get isReady => _ad != null;

  /// Fetches an ad in the background. Safe to call repeatedly — concurrent
  /// calls collapse into the in-flight one.
  Future<void> preload() async {
    if (!AdIds.isConfigured || _loading || _ad != null) return;
    _loading = true;

    // Consent is gathered here, not at start-up, so the UMP form only ever
    // appears to users who actually reach an ad. It must complete before
    // the first request: serving an EEA user without it is a policy breach.
    if (!_consentGathered) {
      await _consent.gather();
      _consentGathered = true;
    }
    if (!await _consent.canRequestAds()) {
      _loading = false;
      _log.info('consent withheld — no ad requested');
      return;
    }

    final completer = Completer<void>();
    RewardedAd.load(
      adUnitId: AdIds.rewardedUnitId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) {
          _ad = ad;
          _loading = false;
          _log.info('rewarded ad ready');
          if (!completer.isCompleted) completer.complete();
        },
        onAdFailedToLoad: (error) {
          _ad = null;
          _loading = false;
          // Code 3 is "no fill" — normal on test traffic and in small
          // markets. Logged at warn, never surfaced to the user.
          _log.warn('rewarded load failed (${error.code}): ${error.message}');
          if (!completer.isCompleted) completer.complete();
        },
      ),
    );

    return completer.future;
  }

  /// Shows the ad and resolves `true` only if the user actually earned the
  /// reward — i.e. watched far enough for Google to call back.
  ///
  /// Resolves `false` when no ad is available or the user dismissed early.
  /// Callers must treat `false` as "grant nothing".
  ///
  /// [userId] is handed to Google so its server-side verification callback
  /// can name who to pay. Without it the callback still arrives, signed and
  /// valid, with nobody attached — and the reward is lost. It is set here
  /// rather than at load time because it is the last moment we are certain
  /// which account is on screen.
  Future<bool> showAndAwaitReward({required String userId}) async {
    final ad = _ad;
    if (ad == null) {
      _log.warn('show requested with no ad loaded');
      return false;
    }

    try {
      await ad.setServerSideOptions(
        ServerSideVerificationOptions(userId: userId),
      );
    } catch (e) {
      // Showing anyway would burn an impression for a reward nobody can be
      // credited with. Better to fail before the video than after it.
      _log.error('could not set SSV options ($e) — refusing to show');
      return false;
    }

    var earned = false;
    final completer = Completer<bool>();

    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        _ad = null;
        if (!completer.isCompleted) completer.complete(earned);
        unawaited(preload());
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        _log.warn('rewarded show failed: ${error.message}');
        ad.dispose();
        _ad = null;
        if (!completer.isCompleted) completer.complete(false);
        unawaited(preload());
      },
    );

    await ad.show(onUserEarnedReward: (_, __) => earned = true);
    return completer.future;
  }

  void dispose() {
    _ad?.dispose();
    _ad = null;
  }
}
