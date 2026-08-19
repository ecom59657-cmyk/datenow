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

// ---------------------------------------------------------------------------
// Background — the five optional attributes collected at signup.
//
// Every one of them is nullable (or an empty set), and "not answered" stores
// nothing at all rather than a "prefers not to say" marker. That is not a UI
// preference: origins and religion are special-category data under GDPR
// article 9 and "Sensitive Info" in Apple's privacy labels, so the only safe
// default is to hold no row for someone who did not answer. Signup must never
// require them.
// ---------------------------------------------------------------------------

/// Origins. Multi-select on purpose — a single slot forces mixed heritage to
/// pick a side, which is the opposite of the point.
enum Origin {
  africa,
  northAfrica,
  eastAsia,
  southAsia,
  southeastAsia,
  caribbean,
  europe,
  latinAmerica,
  middleEast,
  nativeAmerican,
  pacific,
  other,
}

/// Religion or spirituality. Single-select.
enum Religion {
  agnostic,
  atheist,
  buddhist,
  catholic,
  christian,
  hindu,
  jewish,
  muslim,
  sikh,
  spiritual,
  other,
}

/// How often the person drinks.
enum Drinking { never, socially, often }

/// Tobacco and vaping alike — the question people actually mean to ask.
enum Smoking { never, occasionally, regularly }

/// Highest level reached, not the diploma held: "started a master's" is an
/// answer people give, and the ladder has to accommodate it.
enum EducationLevel {
  highSchool,
  vocational,
  bachelor,
  master,
  doctorate,
  other,
}

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

extension OriginX on Origin {
  String label(AppLocalizations l) => switch (this) {
        Origin.africa => l.originAfrica,
        Origin.northAfrica => l.originNorthAfrica,
        Origin.eastAsia => l.originEastAsia,
        Origin.southAsia => l.originSouthAsia,
        Origin.southeastAsia => l.originSoutheastAsia,
        Origin.caribbean => l.originCaribbean,
        Origin.europe => l.originEurope,
        Origin.latinAmerica => l.originLatinAmerica,
        Origin.middleEast => l.originMiddleEast,
        Origin.nativeAmerican => l.originNativeAmerican,
        Origin.pacific => l.originPacific,
        Origin.other => l.originOther,
      };
}

extension ReligionX on Religion {
  String label(AppLocalizations l) => switch (this) {
        Religion.agnostic => l.religionAgnostic,
        Religion.atheist => l.religionAtheist,
        Religion.buddhist => l.religionBuddhist,
        Religion.catholic => l.religionCatholic,
        Religion.christian => l.religionChristian,
        Religion.hindu => l.religionHindu,
        Religion.jewish => l.religionJewish,
        Religion.muslim => l.religionMuslim,
        Religion.sikh => l.religionSikh,
        Religion.spiritual => l.religionSpiritual,
        Religion.other => l.religionOther,
      };
}

extension DrinkingX on Drinking {
  String label(AppLocalizations l) => switch (this) {
        Drinking.never => l.drinkingNever,
        Drinking.socially => l.drinkingSocially,
        Drinking.often => l.drinkingOften,
      };
}

extension SmokingX on Smoking {
  String label(AppLocalizations l) => switch (this) {
        Smoking.never => l.smokingNever,
        Smoking.occasionally => l.smokingOccasionally,
        Smoking.regularly => l.smokingRegularly,
      };
}

extension EducationLevelX on EducationLevel {
  String label(AppLocalizations l) => switch (this) {
        EducationLevel.highSchool => l.educationHighSchool,
        EducationLevel.vocational => l.educationVocational,
        EducationLevel.bachelor => l.educationBachelor,
        EducationLevel.master => l.educationMaster,
        EducationLevel.doctorate => l.educationDoctorate,
        EducationLevel.other => l.educationOther,
      };
}
