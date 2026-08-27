// What a user actually walks through between signing up and their first date.
//
// Every gate here is correct in isolation and was tested that way. What is
// not testable in isolation is their *arrangement*: which one fires first,
// which ones the user has already cleared by the time they tap, and whether
// a gate that blocks says something true. Those are properties of the whole
// journey, and the way they break is by drifting one edit at a time.
//
// Source-level, like release_safety_test.dart: these assert an arrangement,
// and an arrangement is what a widget test cannot see.

import 'dart:io';

import 'package:datenow/features/profile_setup/domain/enums.dart';
import 'package:datenow/features/quota/data/quota_service.dart';
import 'package:flutter_test/flutter_test.dart';

String _src(String p) => File(p).readAsStringSync();

const _home = 'lib/features/home/presentation/home_screen.dart';
const _wizard =
    'lib/features/profile_setup/presentation/profile_setup_screen.dart';
const _finalize =
    'lib/features/profile_setup/presentation/steps/finalize_step.dart';
const _perms = 'lib/features/permissions/presentation/permissions_screen.dart';

void main() {
  // -------------------------------------------------------------------
  group('nothing is asked at the tap that could have been asked earlier', () {
    test('location is requested during signup, not at the CTA', () {
      // It used to fire only inside _onFindDate, stacking a third system
      // dialog on top of camera and microphone — the first one with no
      // explanation at all.
      expect(_src(_finalize), contains('LocationPermissionCard'),
          reason: 'the signup step must ask for location');
    });

    test('and the wizard refuses to finish without it', () {
      // Asking without gating would let someone decline and hit the same
      // dead end later, just further from the explanation.
      expect(
        _src(
          'lib/features/profile_setup/presentation/providers/'
          'profile_setup_controller.dart',
        ),
        contains('isStep4Valid && photoBytes != null && locationGranted'),
      );
    });

    test('the position is pushed as soon as the profile row exists', () {
      // Otherwise the first "Lancer un date" spends a GPS read on a spinner
      // for something that could have happened while the user read a screen.
      final src = _src(_wizard);
      final save = src.indexOf('Profile saved');
      expect(save, greaterThan(-1));
      expect(src.substring(save, save + 600), contains('captureAndPush'));
    });

    test('camera and microphone are asked before Home, not at the CTA', () {
      final src = _src(_perms);
      expect(src, contains('Permission.camera'));
      expect(src, contains('Permission.microphone'));
      // And the wizard routes through that screen rather than straight home.
      expect(_src(_wizard), contains('AppRoute.permissions.name'));
    });

    test('the CTA still re-checks them, for whoever skipped', () {
      // The permissions screen has a skip. Trusting it would drop that user
      // into a call with no camera and no way back.
      expect(_src(_home), contains('_ensureCallPermissions(context)'));
    });
  });

  // -------------------------------------------------------------------
  group('the gates fire in an order that makes sense', () {
    test('photo, then identity, then quota, then location, then devices', () {
      final src = _src(_home);
      final start = src.indexOf('Future<void> _onFindDate() async {');
      expect(start, greaterThan(-1));
      final body = src.substring(start);

      final order = [
        'hasApprovedPhotoProvider',        // who you are to a peer
        'requireIdentityVerification',     // who you are to us
        'currentStatus(profile',           // may you have another date
        'refreshIfStale',                  // where you are
        '_ensureCallPermissions',          // can you actually talk
      ];
      var previous = -1;
      for (final marker in order) {
        final at = body.indexOf(marker);
        expect(at, greaterThan(previous), reason: '$marker is out of order');
        previous = at;
      }
    });

    test('the cheap checks come before the expensive ones', () {
      // A GPS fix and a permission round-trip are the two slow steps. Running
      // them before the quota check would make an exhausted user wait for
      // them to be told no.
      final body = _src(_home);
      expect(body.indexOf('currentStatus(profile'),
          lessThan(body.indexOf('refreshIfStale')));
    });
  });

  // -------------------------------------------------------------------
  group('a gate that blocks explains itself', () {
    test('identity says why, in terms of protecting people', () {
      final src = _src(_home);
      expect(src, contains('Pour protéger la communauté DateNow'));
      expect(src, contains("vérifie ton "));
      // And it offers the way forward, not just the refusal.
      expect(src, contains('AppRoute.identityVerification.name'));
    });

    test('the same message is offered before the block, on Home', () {
      // Discovering the requirement at the moment you wanted a date is a
      // worse first encounter than being told in advance.
      final src = _src(_home);
      expect(src, contains('_HomeIdentityNudge'));
      expect(src, contains('Protège tes rencontres'));
      final nudge = src.indexOf('_HomeIdentityNudge()');
      final hero = src.indexOf('HomeHeroCard');
      expect(nudge, lessThan(hero),
          reason: 'the nudge belongs above the button it is about');
    });

    test('a photo still being checked is not called a missing photo', () {
      // Telling someone to add the photo they just added sends them to add a
      // second one for nothing.
      final src = _src(_home);
      expect(src, contains('PhotoModerationStatus.pending'));
      expect(src, contains('PhotoModerationStatus.analyzing'));
      expect(src, contains('findDatePhotoPendingTitle'));
    });

    test('and that case offers a retry rather than an upload', () {
      final src = _src(_home);
      final pendingBranch = src.indexOf('if (pending) {');
      expect(pendingBranch, greaterThan(-1));
      final window = src.substring(pendingBranch, pendingBranch + 200);
      expect(window, contains('pop(true)'));
      expect(window, isNot(contains('editPhotos')),
          reason: 'a pending verdict is not fixed by uploading again');
    });

    test('the retry actually re-runs the gate', () {
      expect(_src(_home), contains('unawaited(_onFindDate())'));
    });
  });

  // -------------------------------------------------------------------
  group('the allowance a man actually gets', () {
    const service = QuotaService();

    test('three a day on the free tier', () {
      expect(QuotaService.freeDailyCap, 3);
      expect(service.capFor(Gender.male, isPremium: false), 3);
    });

    test('six once paying', () {
      expect(service.capFor(Gender.male, isPremium: true), 6);
    });

    test('one more for a watched video', () {
      // The grant itself is Google's to make; what is pinned here is that
      // one video buys exactly one date.
      expect(
        _src('supabase/migrations/20260827110000_quota_bonus_ssv.sql'),
        contains("VALUES\n    (p_user_id, v_day, 'rewarded_ad'"),
      );
      expect(_src('lib/l10n/app_fr.arb'),
          contains('Regarder une vidéo (+1 date)'));
    });

    test('and one more again on a boosted day', () {
      expect(QuotaService.boostDates, 1);
      expect(QuotaService.boostOneInN, 4);
    });

    test('so a free man tops out at seven on his best day', () {
      // 3 base + 3 videos + 1 boost. Worth stating out loud: it is the
      // number a repackaged client could reach, and it is bounded.
      expect(QuotaService.freeDailyCap + 3 + QuotaService.boostDates, 7);
      expect(
        _src('supabase/migrations/20260827110000_quota_bonus_ssv.sql'),
        contains('c_max   CONSTANT INT := 3'),
      );
    });
  });
}
