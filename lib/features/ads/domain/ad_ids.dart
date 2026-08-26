import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

/// AdMob identifiers, split by platform and by build mode.
///
/// Debug builds always use Google's public test units. Serving live ads to
/// a developer's own device is a policy violation and inflates the account's
/// invalid-traffic ratio, so the switch is tied to [kReleaseMode] rather
/// than left to a flag someone can forget to flip.
///
/// The release constants below are intentionally empty until the real units
/// exist in the AdMob console. [isConfigured] reports that, and the ad
/// service stays dormant instead of firing requests that would 404.
abstract final class AdIds {
  // --- Google's official test units (safe, always fill) -------------------
  static const _testAppIdIos = 'ca-app-pub-3940256099942544~1458002511';
  static const _testAppIdAndroid = 'ca-app-pub-3940256099942544~3347511713';
  static const _testRewardedIos = 'ca-app-pub-3940256099942544/1712485313';
  static const _testRewardedAndroid = 'ca-app-pub-3940256099942544/5224354917';

  // --- Real units — publisher pub-7977656042089301 -----------------------
  // iOS is fully registered. Android has no AdMob app entry yet, so its
  // constants stay empty on purpose: isConfigured then reports false there
  // and the entry point hides itself rather than firing a doomed request.
  // TODO(datenow): register the Android app in AdMob before shipping to Play.
  static const _liveAppIdIos = 'ca-app-pub-7977656042089301~4639616959';
  static const _liveAppIdAndroid = '';
  static const _liveRewardedIos = 'ca-app-pub-7977656042089301/4131973190';
  static const _liveRewardedAndroid = '';

  static bool get _isAndroid => Platform.isAndroid;

  static String get appId {
    if (!kReleaseMode) {
      return _isAndroid ? _testAppIdAndroid : _testAppIdIos;
    }
    return _isAndroid ? _liveAppIdAndroid : _liveAppIdIos;
  }

  static String get rewardedUnitId {
    if (!kReleaseMode) {
      return _isAndroid ? _testRewardedAndroid : _testRewardedIos;
    }
    return _isAndroid ? _liveRewardedAndroid : _liveRewardedIos;
  }

  /// False in release until the real units are pasted above. Callers use
  /// this to hide ad entry points rather than showing a button that can
  /// only fail.
  static bool get isConfigured => rewardedUnitId.isNotEmpty;
}
