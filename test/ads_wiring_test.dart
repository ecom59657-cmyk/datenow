// The rewarded-ad path, checked where it can actually be wrong.
//
// quota_bonus_test.dart proves the arithmetic downstream of "Google said
// yes". Everything upstream of that sentence is untested: which ad unit a
// build uses, whether consent is gathered before a request, whether the
// grant is really gated on the reward callback, and whether the platform
// manifests still agree with the Dart constants. Those are the failures
// that cost money or an account suspension rather than a red test.
//
// The AdMob SDK cannot be instantiated in `flutter test`, so the service
// itself is asserted at source level and everything reachable without the
// SDK is exercised for real.

import 'dart:io';

import 'package:datenow/features/ads/data/consent_service.dart';
import 'package:datenow/features/ads/data/rewarded_ad_service.dart';
import 'package:datenow/features/ads/domain/ad_ids.dart';
import 'package:datenow/features/ads/presentation/providers/ads_providers.dart';
import 'package:datenow/features/profile_setup/domain/enums.dart';
import 'package:datenow/features/profile_setup/domain/user_profile.dart';
import 'package:datenow/features/profile_setup/presentation/providers/profile_provider.dart';
import 'package:datenow/features/quota/data/quota_repository.dart';
import 'package:datenow/features/quota/data/quota_service.dart';
import 'package:datenow/features/quota/presentation/widgets/quota_limit_sheet.dart';
import 'package:datenow/features/subscription/domain/subscription_state.dart';
import 'package:datenow/features/subscription/presentation/providers/subscription_provider.dart';
import 'package:datenow/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String _src(String path) => File(path).readAsStringSync();

const _adIdsPath = 'lib/features/ads/domain/ad_ids.dart';
const _servicePath = 'lib/features/ads/data/rewarded_ad_service.dart';
const _sheetPath =
    'lib/features/quota/presentation/widgets/quota_limit_sheet.dart';

/// Pulls `static const _name = 'value';` out of ad_ids.dart.
String _constant(String name) {
  final match =
      RegExp("$name\\s*=\\s*'([^']*)'").firstMatch(_src(_adIdsPath));
  expect(match, isNotNull, reason: '$name not found in ad_ids.dart');
  return match!.group(1)!;
}

/// The `<string>` that follows a `<key>` in an Info.plist.
String? _plistValue(String key) {
  final src = _src('ios/Runner/Info.plist');
  final keyIdx = src.indexOf('<key>$key</key>');
  if (keyIdx < 0) return null;
  final match = RegExp(r'<string>([^<]*)</string>')
      .firstMatch(src.substring(keyIdx));
  return match?.group(1);
}

/// A rewarded service that never touches the SDK. `earn` is what Google
/// would have answered.
class _FakeAds extends RewardedAdService {
  _FakeAds({required this.earn}) : super(const ConsentService());

  final bool earn;
  int shows = 0;

  /// What was handed to Google as the person to credit. Google echoes this
  /// back in the SSV callback, so an empty one means a reward nobody gets.
  String? lastUserId;

  @override
  bool get isReady => true;

  @override
  Future<void> preload() async {}

  @override
  Future<bool> showAndAwaitReward({required String userId}) async {
    shows++;
    lastUserId = userId;
    return earn;
  }

  @override
  void dispose() {}
}

const _male = UserProfile(userId: 'u-male', gender: Gender.male);

Widget _sheetHost({
  required MockQuotaRepository repo,
  required RewardedAdService ads,
  required bool adsEnabled,
}) =>
    ProviderScope(
      overrides: [
        adsEnabledProvider.overrideWithValue(adsEnabled),
        rewardedAdServiceProvider.overrideWithValue(ads),
        quotaRepositoryProvider.overrideWithValue(repo),
        currentProfileProvider
            .overrideWith((ref) => Stream<UserProfile?>.value(_male)),
      ],
      child: MaterialApp(
        locale: const Locale('fr'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showQuotaLimitSheet(context, dailyCap: 3),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

Future<void> _openSheet(
  WidgetTester tester,
  Widget host, {
  bool profileLoaded = true,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(host);
  await tester.pumpAndSettle();

  if (profileLoaded) {
    // The sheet reads the profile with `ref.read` at reward time. Nothing
    // in the sheet itself watches it, so in a test it is still in its
    // loading state unless somebody warms it first. In the running app the
    // Home and Discover screens have been watching it since sign-in — this
    // reproduces that, rather than a state the user is ever really in.
    final container =
        ProviderScope.containerOf(tester.element(find.text('open')));
    await container.read(currentProfileProvider.future);
    await tester.pumpAndSettle();
  }

  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  // -------------------------------------------------------------------------
  group('AdIds — the right unit for the build', () {
    test('a non-release build serves Google test units, never live ones', () {
      // kReleaseMode is false under `flutter test`. Serving live ads to a
      // developer device is a policy violation and poisons the account's
      // invalid-traffic ratio.
      expect(AdIds.rewardedUnitId, startsWith('ca-app-pub-3940256099942544'));
      expect(AdIds.appId, startsWith('ca-app-pub-3940256099942544'));
      expect(AdIds.rewardedUnitId, isNot(contains('7977656042089301')));
    });

    test('the entry point is available in debug so it can be exercised', () {
      expect(AdIds.isConfigured, isTrue);
    });

    test('app ids use ~ and ad units use /, on both platforms', () {
      // The two are not interchangeable: an app id in a unit slot fails
      // every request, and the reverse crashes the SDK at launch.
      for (final name in ['_liveAppIdIos', '_testAppIdIos', '_testAppIdAndroid']) {
        expect(_constant(name), contains('~'), reason: '$name must be an app id');
      }
      for (final name in [
        '_liveRewardedIos',
        '_testRewardedIos',
        '_testRewardedAndroid',
      ]) {
        expect(_constant(name), contains('/'), reason: '$name must be a unit id');
      }
    });

    test('an unconfigured platform reports itself instead of half-working', () {
      // Android has no AdMob app yet. The invariant that matters: a live
      // unit id is either empty or complete — never a placeholder that
      // would fire a doomed request.
      final android = _constant('_liveRewardedAndroid');
      expect(
        android.isEmpty || android.startsWith('ca-app-pub-'),
        isTrue,
        reason: 'a live Android unit must be empty or a real unit id',
      );
    });
  });

  // -------------------------------------------------------------------------
  group('the platform manifests agree with the Dart constants', () {
    test('Info.plist carries the same iOS app id as ad_ids.dart', () {
      // A mismatch here is silent: the SDK reads the plist, the Dart code
      // reads its own constant, and only the revenue report shows it.
      expect(_plistValue('GADApplicationIdentifier'), _constant('_liveAppIdIos'));
    });

    test('the ATT purpose string is present and written in French', () {
      // Without NSUserTrackingUsageDescription the app crashes the moment
      // ATT is requested, and App Review rejects it outright.
      final att = _plistValue('NSUserTrackingUsageDescription');
      expect(att, isNotNull);
      expect(att!.length, greaterThan(30));
      expect(att.toLowerCase(), contains('publicit'));
    });

    test('SKAdNetwork identifiers are declared', () {
      expect(_src('ios/Runner/Info.plist'), contains('SKAdNetworkItems'));
      expect(
        RegExp('skadnetwork').allMatches(_src('ios/Runner/Info.plist')).length,
        greaterThanOrEqualTo(10),
      );
    });

    test('the Android manifest declares an AdMob application id', () {
      final manifest = _src('android/app/src/main/AndroidManifest.xml');
      expect(manifest, contains('com.google.android.gms.ads.APPLICATION_ID'));
      final value = RegExp(
        r'com\.google\.android\.gms\.ads\.APPLICATION_ID"\s*\n?\s*android:value="([^"]+)"',
      ).firstMatch(manifest)?.group(1);
      expect(value, isNotNull, reason: 'APPLICATION_ID has no value');
      expect(value, contains('~'), reason: 'must be an app id, not a unit id');
    });

    test('the day Android gets real ids, the manifest must follow', () {
      // Drift guard, not a current failure. While _liveAppIdAndroid is
      // empty the manifest legitimately holds Google's test id; the moment
      // someone pastes a real id in Dart, this fails until the manifest
      // is updated too.
      final liveAndroid = _constant('_liveAppIdAndroid');
      if (liveAndroid.isEmpty) return;
      expect(
        _src('android/app/src/main/AndroidManifest.xml'),
        contains(liveAndroid),
        reason: 'AndroidManifest still ships a different AdMob app id',
      );
    });
  });

  // -------------------------------------------------------------------------
  group('consent comes before any ad request', () {
    test('gather() and canRequestAds() both precede RewardedAd.load', () {
      final src = _src(_servicePath);
      final gather = src.indexOf('_consent.gather()');
      final can = src.indexOf('canRequestAds()');
      final load = src.indexOf('RewardedAd.load(');

      expect(gather, greaterThan(-1), reason: 'consent is never gathered');
      expect(can, greaterThan(-1), reason: 'canRequestAds is never checked');
      expect(load, greaterThan(-1));
      expect(gather, lessThan(load),
          reason: 'an EEA request before the UMP form is a policy breach');
      expect(can, lessThan(load),
          reason: 'a withheld consent must stop the request');
    });

    test('a withheld consent returns instead of falling through', () {
      final src = _src(_servicePath);
      final can = src.indexOf('canRequestAds()');
      final load = src.indexOf('RewardedAd.load(');
      expect(src.substring(can, load), contains('return'),
          reason: 'no early return between the check and the request');
    });

    test('ATT is only requested on iOS', () {
      expect(_src('lib/features/ads/data/consent_service.dart'),
          contains('if (!Platform.isIOS) return;'));
    });

    test('consent failures degrade to "no ads", never to a crash', () {
      final src = _src('lib/features/ads/data/consent_service.dart');
      expect(RegExp(r'catch').allMatches(src).length, greaterThanOrEqualTo(3),
          reason: 'every consent call must be wrapped');
    });
  });

  // -------------------------------------------------------------------------
  group('the reward is granted only when Google confirms it', () {
    test('earned is set in onUserEarnedReward and nowhere else', () {
      final src = _src(_servicePath);
      final assignments = RegExp(r'earned\s*=\s*true').allMatches(src).toList();
      expect(assignments.length, 1,
          reason: 'exactly one place may declare the reward earned');
      final window = src.substring(
        (assignments.first.start - 120).clamp(0, src.length),
        assignments.first.start,
      );
      expect(window, contains('onUserEarnedReward'));
    });

    test('a dismissal resolves with the real outcome, not with true', () {
      final src = _src(_servicePath);
      final dismissed = src.indexOf('onAdDismissedFullScreenContent');
      final failed = src.indexOf('onAdFailedToShowFullScreenContent');
      final body = src.substring(dismissed, failed);
      expect(body, contains('complete(earned)'));
      expect(body, isNot(contains('complete(true)')));
    });

    test('the sheet waits for the bonus only inside the earned branch', () {
      final src = _src(_sheetPath);
      final settle = src.indexOf('awaitRewardedBonus');
      final guard = src.lastIndexOf('if (earned)', settle);
      expect(guard, greaterThan(-1),
          reason: 'awaitRewardedBonus must sit under `if (earned)`');
      expect(src.substring(guard, settle), isNot(contains('}\n    }')));
    });

    test('the app has no way to grant itself a date', () {
      // The whole point of SSV. If this string comes back, someone gave the
      // client its own grant again and "you must watch the video" is a
      // promise the app makes to itself.
      final repo = _src('lib/features/quota/data/quota_repository.dart');
      expect(repo, isNot(contains("rpc('grant_quota_bonus')")),
          reason: 'the client must not call the self-grant RPC');
      expect(
        _src('supabase/migrations/20260827110000_quota_bonus_ssv.sql'),
        contains(
            'REVOKE EXECUTE ON FUNCTION public.grant_quota_bonus() FROM authenticated'),
        reason: 'the grant must be revoked server-side, not just unused',
      );
    });

    test('Google is told who to credit, before the video plays', () {
      final src = _src(_servicePath);
      final options = src.indexOf('setServerSideOptions');
      final show = src.indexOf('await ad.show');
      expect(options, greaterThan(-1),
          reason: 'without SSV options the callback names nobody');
      expect(options, lessThan(show),
          reason: 'options must be set before the ad is shown');
    });

    test('a failed show never grants', () {
      final src = _src(_servicePath);
      final failed = src.indexOf('onAdFailedToShowFullScreenContent');
      final body = src.substring(failed, src.indexOf('await ad.show'));
      expect(body, contains('complete(false)'));
    });
  });

  // -------------------------------------------------------------------------
  group('adsEnabledProvider — who is offered an ad', () {
    Future<bool> resolve(SubscriptionState state) async {
      final container = ProviderContainer(overrides: [
        subscriptionStateProvider.overrideWith((ref) => Stream.value(state)),
      ]);
      addTearDown(container.dispose);
      await container.read(subscriptionStateProvider.future);
      return container.read(adsEnabledProvider);
    }

    test('a free user is offered the video', () async {
      expect(await resolve(const SubscriptionState.free()), isTrue);
    });

    test('a paying user never is', () async {
      // Removing ads is the clearest thing the subscription buys.
      expect(
        await resolve(const SubscriptionState(tier: SubscriptionTier.premium)),
        isFalse,
      );
    });

    test('while the tier is unknown, nothing is offered', () {
      final container = ProviderContainer(overrides: [
        subscriptionStateProvider
            .overrideWith((ref) => const Stream<SubscriptionState>.empty()),
      ]);
      addTearDown(container.dispose);
      // Better a briefly missing button than an ad flashed at a subscriber.
      expect(container.read(adsEnabledProvider), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  group('the quota sheet, driven the way a thumb drives it', () {
    late MockQuotaRepository repo;

    setUp(() => repo = MockQuotaRepository(const QuotaService()));

    testWidgets('a free user sees the video button', (tester) async {
      await _openSheet(
        tester,
        _sheetHost(
            repo: repo, ads: _FakeAds(earn: true), adsEnabled: true),
      );
      expect(find.text('Regarder une vidéo (+1 date)'), findsOneWidget);
      expect(find.text('Revenir demain'), findsOneWidget);
    });

    testWidgets('a premium user sees no video button', (tester) async {
      await _openSheet(
        tester,
        _sheetHost(
            repo: repo, ads: _FakeAds(earn: true), adsEnabled: false),
      );
      expect(find.text('Regarder une vidéo (+1 date)'), findsNothing);
      expect(find.text('Débloquer plus de dates'), findsOneWidget);
    });

    testWidgets('watching to the end grants one date and closes the sheet',
        (tester) async {
      var status = await repo.currentStatus(_male, isPremium: false);
      while (!status.isExhausted) {
        await repo.recordMatch(_male);
        status = await repo.currentStatus(_male, isPremium: false);
      }

      final ads = _FakeAds(earn: true);
      await _openSheet(
        tester,
        _sheetHost(repo: repo, ads: ads, adsEnabled: true),
      );
      await tester.tap(find.text('Regarder une vidéo (+1 date)'));
      await tester.pumpAndSettle();

      expect(ads.shows, 1);
      status = await repo.currentStatus(_male, isPremium: false);
      expect(status.bonusToday, 1);
      expect(status.isExhausted, isFalse,
          reason: 'the user can start another date');
      expect(find.text('Revenir demain'), findsNothing,
          reason: 'the sheet must close once the date is unlocked');
    });

    testWidgets('closing the video early grants nothing', (tester) async {
      // The forgeable path: if a dismissal granted a date, the ad would be
      // pure cost with no revenue.
      final ads = _FakeAds(earn: false);
      await _openSheet(
        tester,
        _sheetHost(repo: repo, ads: ads, adsEnabled: true),
      );
      await tester.tap(find.text('Regarder une vidéo (+1 date)'));
      await tester.pumpAndSettle();

      expect(ads.shows, 1);
      expect((await repo.currentStatus(_male, isPremium: false)).bonusToday, 0);
      expect(find.text('Revenir demain'), findsOneWidget,
          reason: 'the sheet stays open — nothing was unlocked');
    });

    testWidgets('with no profile loaded, the video is not even played',
        (tester) async {
      // This used to play the ad and then discover there was nobody to
      // credit — thirty seconds watched for nothing. The profile is now
      // read before the video, so the failure happens before the cost.
      final ads = _FakeAds(earn: true);
      await _openSheet(
        tester,
        _sheetHost(repo: repo, ads: ads, adsEnabled: true),
        profileLoaded: false,
      );
      await tester.tap(find.text('Regarder une vidéo (+1 date)'));
      await tester.pumpAndSettle();

      expect(ads.shows, 0, reason: 'no impression burned for nobody');
      expect((await repo.currentStatus(_male, isPremium: false)).bonusToday, 0);
    });

    testWidgets('the signed-in user is the one Google is told to credit',
        (tester) async {
      final ads = _FakeAds(earn: true);
      await _openSheet(
        tester,
        _sheetHost(repo: repo, ads: ads, adsEnabled: true),
      );
      await tester.tap(find.text('Regarder une vidéo (+1 date)'));
      await tester.pumpAndSettle();

      expect(ads.lastUserId, _male.userId);
    });

    testWidgets('the button is preloaded, not fetched on tap', (tester) async {
      // A rewarded video takes a second or two to arrive. Asking after the
      // tap makes the button feel broken.
      expect(_src(_sheetPath).indexOf('preload()'),
          lessThan(_src(_sheetPath).indexOf('_watchAdForBonus')));
    });
  });

  // -------------------------------------------------------------------------
  group('ads never take down start-up', () {
    test('MobileAds.initialize is wrapped in a try/catch in main', () {
      final src = _src('lib/main.dart');
      final init = src.indexOf('MobileAds.instance.initialize()');
      expect(init, greaterThan(-1));
      final before = src.substring((init - 200).clamp(0, init), init);
      expect(before, contains('try {'),
          reason: 'a failing ad SDK must not block the app');
    });

    test('no ad is requested at start-up', () {
      // The UMP form must only appear to users who actually reach an ad.
      expect(_src('lib/main.dart'), isNot(contains('RewardedAd.load')));
      expect(_src('lib/main.dart'), isNot(contains('preload()')));
    });
  });
}
