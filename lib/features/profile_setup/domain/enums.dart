import '../../../l10n/app_localizations.dart';

/// Gender identity. Kept short for DateNow — we can expand later if needed.
enum Gender { female, male, nonBinary }

/// Sexual orientation. Self-declared; the label is also used at matching time
/// alongside [Gender] to filter candidates.
enum Orientation { straight, gay, lesbian, bi, pan, asexual, queer }

/// What the user is here for. Multi-select.
enum Intention { serious, feeling, talk, casual }

/// Whether the user wants to be matched right now or queued for later.
enum Availability { immediate, sometime }

extension GenderX on Gender {
  String label(AppLocalizations l) => switch (this) {
        Gender.female => l.genderFemale,
        Gender.male => l.genderMale,
        Gender.nonBinary => l.genderNonBinary,
      };
}

extension OrientationX on Orientation {
  String label(AppLocalizations l) => switch (this) {
        Orientation.straight => l.orientationStraight,
        Orientation.gay => l.orientationGay,
        Orientation.lesbian => l.orientationLesbian,
        Orientation.bi => l.orientationBi,
        Orientation.pan => l.orientationPan,
        Orientation.asexual => l.orientationAsexual,
        Orientation.queer => l.orientationQueer,
      };
}

extension IntentionX on Intention {
  String label(AppLocalizations l) => switch (this) {
        Intention.serious => l.intentionSerious,
        Intention.feeling => l.intentionFeeling,
        Intention.talk => l.intentionTalk,
        Intention.casual => l.intentionCasual,
      };

  String body(AppLocalizations l) => switch (this) {
        Intention.serious => l.intentionSeriousBody,
        Intention.feeling => l.intentionFeelingBody,
        Intention.talk => l.intentionTalkBody,
        Intention.casual => l.intentionCasualBody,
      };
}

extension AvailabilityX on Availability {
  String title(AppLocalizations l) => switch (this) {
        Availability.immediate => l.availabilityImmediateTitle,
        Availability.sometime => l.availabilitySometimeTitle,
      };

  String body(AppLocalizations l) => switch (this) {
        Availability.immediate => l.availabilityImmediateBody,
        Availability.sometime => l.availabilitySometimeBody,
      };
}
