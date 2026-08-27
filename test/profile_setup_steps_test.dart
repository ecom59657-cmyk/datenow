// The signup wizard: step order, and the promise that the background step
// never blocks.
//
// The wizard used to map validation to raw page indices — `0 =>
// isStep1Valid … 3 => isStep5Valid, 4 => isStep4Valid` — with the prompt
// moderation gate keyed on the literal `_index == 3`. Inserting a step meant
// renumbering three places by hand, and a mistake compiles cleanly: the
// wizard just validates the wrong answers. These tests pin the behaviour
// that the numbering used to carry implicitly.

import 'package:datenow/features/profile_setup/domain/enums.dart' as domain;
import 'package:datenow/features/profile_setup/domain/interest.dart';
import 'package:datenow/features/profile_setup/domain/prompt.dart';
import 'package:datenow/features/profile_setup/domain/prompt_answer.dart';
import 'package:datenow/features/profile_setup/presentation/providers/profile_setup_controller.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

ProfileDraft _empty() => ProfileDraft(userId: 'u1');

void main() {
  group('ProfileDraft — background is optional everywhere', () {
    test('an untouched draft holds nothing, not a "prefers not to say"', () {
      final d = _empty();
      expect(d.origins, isEmpty);
      expect(d.religion, isNull);
      expect(d.drinking, isNull);
      expect(d.smoking, isNull);
      expect(d.education, isNull);
    });

    test('background answers do not affect any step validity', () {
      // Every gate the wizard applies, on a draft with no background.
      final complete = ProfileDraft(
        userId: 'u1',
        firstName: 'Alex',
        birthDate: DateTime(1994, 5, 2),
        gender: domain.Gender.male,
        orientation: domain.Orientation.straight,
        seekingGenders: const {domain.Gender.female},
        intentions: const {domain.Intention.feeling},
        interests: const {Interest.music, Interest.travel, Interest.cooking},
        availability: domain.Availability.immediate,
        prompts: const [
          PromptAnswer(question: PromptQuestion.perfectSunday, answer: 'a'),
          PromptAnswer(question: PromptQuestion.badAt, answer: 'b'),
        ],
      );

      expect(complete.isStep1Valid, isTrue);
      expect(complete.isStep2Valid, isTrue);
      expect(complete.isStep3Valid, isTrue);
      expect(complete.isStep4Valid, isTrue);
      expect(complete.isStep5Valid, isTrue);
      expect(complete.isComplete, isTrue,
          reason: 'signup must complete with no background answered at all');
    });
  });

  group('ProfileDraft — the last step requires a photo and a location', () {
    // A draft that answers everything the wizard asks except the photo.
    ProfileDraft filledExceptPhoto() => ProfileDraft(
          userId: 'u1',
          firstName: 'Alex',
          birthDate: DateTime(1994, 5, 2),
          gender: domain.Gender.male,
          orientation: domain.Orientation.straight,
          seekingGenders: const {domain.Gender.female},
          intentions: const {domain.Intention.feeling},
          interests: const {Interest.music, Interest.travel, Interest.cooking},
          availability: domain.Availability.immediate,
          prompts: const [
            PromptAnswer(question: PromptQuestion.perfectSunday, answer: 'a'),
            PromptAnswer(question: PromptQuestion.badAt, answer: 'b'),
          ],
        );

    final photo = Uint8List.fromList(const [1, 2, 3]);

    test('everything answered but no photo does not finish signup', () {
      final d = filledExceptPhoto().copyWith(locationGranted: true);
      expect(d.isStep4Valid, isTrue, reason: 'availability is set');
      expect(d.isFinalizeStepValid, isFalse,
          reason: 'the Terminer button must stay disabled without a photo');
    });

    test('a photo without a location does not finish signup either', () {
      // find_best_live_candidate_v1 rejects a caller whose location is null,
      // so letting them through here only moves the dead end to the first
      // tap on Lancer un date, with nothing on screen explaining it.
      final d = filledExceptPhoto().copyWith(photoBytes: photo);
      expect(d.locationGranted, isFalse, reason: 'false until the OS grants');
      expect(d.isFinalizeStepValid, isFalse);
    });

    test('a photo and a location together unlock the last step', () {
      final d = filledExceptPhoto()
          .copyWith(photoBytes: photo, locationGranted: true);
      expect(d.isFinalizeStepValid, isTrue);
    });

    test('a refused permission leaves the step locked', () {
      // setLocationGranted(false) is what a dismissed dialog records. It must
      // not read as "asked, therefore fine".
      final d = filledExceptPhoto()
          .copyWith(photoBytes: photo, locationGranted: false);
      expect(d.isFinalizeStepValid, isFalse);
    });

    test('a photo alone is not enough — availability still counts', () {
      // Built from scratch rather than cleared with copyWith: availability
      // has no _unset sentinel, so `copyWith(availability: null)` keeps the
      // old value instead of erasing it.
      final d = ProfileDraft(
          userId: 'u1', photoBytes: photo, locationGranted: true);
      expect(d.isStep4Valid, isFalse);
      expect(d.isFinalizeStepValid, isFalse);
    });

    test('neither rule leaks into isComplete', () {
      // isComplete is what the router reads to decide whether someone
      // still owes us onboarding. photoBytes is a signup-only buffer, so
      // folding it in would send every returning user back through the
      // wizard.
      final d = filledExceptPhoto();
      expect(d.photoBytes, isNull);
      expect(d.locationGranted, isFalse);
      expect(d.isComplete, isTrue,
          reason: 'a returning user must not be sent back through signup');
    });

    test('the wizard reads the photo rule, not the bare availability rule',
        () {
      // Guards the wiring: the screen must map the finalize step to
      // isFinalizeStepValid. Swapping it back to isStep4Valid compiles
      // cleanly and silently makes the photo optional again.
      final src = File(
        'lib/features/profile_setup/presentation/profile_setup_screen.dart',
      ).readAsStringSync();
      expect(src, contains('_Step.finalize => d.isFinalizeStepValid,'));
      expect(src, isNot(contains('_Step.finalize => d.isStep4Valid,')));

      // And the card that records the grant is actually on the step.
      final step = File(
        'lib/features/profile_setup/presentation/steps/finalize_step.dart',
      ).readAsStringSync();
      expect(step, contains('LocationPermissionCard'));

      // Only a real OS grant may set the flag — never the tap that opens
      // the dialog.
      final card = File(
        'lib/features/profile_setup/presentation/widgets/'
        'location_permission_card.dart',
      ).readAsStringSync();
      expect(card, contains('_record(_granted(status))'),
          reason: 'the flag must follow the OS answer, not the tap');
      expect(card, isNot(contains('_record(true);\n    }\n\n  Future<void> _request')));
    });
  });

  group('copyWith clears, it does not just overwrite', () {
    // The single-select answers use the _unset sentinel. Without it, passing
    // null would fall through `??` and silently keep the previous value —
    // i.e. an answer given by accident could never be taken back.
    test('religion can be set and then cleared', () {
      var d = _empty().copyWith(religion: domain.Religion.buddhist);
      expect(d.religion, domain.Religion.buddhist);
      d = d.copyWith(religion: null);
      expect(d.religion, isNull);
    });

    test('drinking, smoking and education clear the same way', () {
      var d = _empty().copyWith(
        drinking: domain.Drinking.socially,
        smoking: domain.Smoking.never,
        education: domain.EducationLevel.master,
      );
      expect(d.drinking, domain.Drinking.socially);
      expect(d.smoking, domain.Smoking.never);
      expect(d.education, domain.EducationLevel.master);

      d = d.copyWith(drinking: null, smoking: null, education: null);
      expect(d.drinking, isNull);
      expect(d.smoking, isNull);
      expect(d.education, isNull);
    });

    test('an omitted field is left alone', () {
      final d = _empty()
          .copyWith(religion: domain.Religion.jewish)
          .copyWith(firstName: 'Alex');
      expect(d.religion, domain.Religion.jewish);
      expect(d.firstName, 'Alex');
    });
  });

  group('enum names are the wire format', () {
    // The CHECK constraints in 20260819200000_user_background.sql list these
    // literally. A rename here is a silent write failure in production, so
    // the two are pinned together.
    test('origins', () {
      expect(
        domain.Origin.values.map((e) => e.name).toList(),
        const [
          'africa', 'northAfrica', 'eastAsia', 'southAsia', 'southeastAsia',
          'caribbean', 'europe', 'latinAmerica', 'middleEast',
          'nativeAmerican', 'pacific', 'other',
        ],
      );
    });

    test('religion', () {
      expect(
        domain.Religion.values.map((e) => e.name).toList(),
        const [
          'agnostic', 'atheist', 'buddhist', 'catholic', 'christian', 'hindu',
          'jewish', 'muslim', 'sikh', 'spiritual', 'other',
        ],
      );
    });

    test('drinking, smoking, education', () {
      expect(domain.Drinking.values.map((e) => e.name).toList(),
          const ['never', 'socially', 'often']);
      expect(domain.Smoking.values.map((e) => e.name).toList(),
          const ['never', 'occasionally', 'regularly']);
      expect(
        domain.EducationLevel.values.map((e) => e.name).toList(),
        const [
          'highSchool', 'vocational', 'bachelor', 'master', 'doctorate',
          'other',
        ],
      );
    });
  });
}
