import '../../../l10n/app_localizations.dart';

/// Closed bank of profile questions.
///
/// Closed on purpose. A free-text bio produces empty paragraphs and a
/// moderation load nobody here can carry; a precise question produces a
/// short, concrete answer — which is what a five-minute video date needs
/// as an opening.
///
/// Every value must also exist in the `user_prompts.question` CHECK
/// constraint, or the insert is rejected. The enum name is the wire value.
enum PromptQuestion {
  perfectSunday,
  cantShutUpAbout,
  makeMeLaugh,
  learningRightNow,
  unpopularOpinion,
  bestMealEver,
  weekendPlan,
  proudOf,
  neverAgain,
  firstThingNotice,
  simplePleasure,
  wouldTravelTo,
  badAt,
  changedMyMind,
  soundtrack,
  askMeAbout,
}

extension PromptQuestionX on PromptQuestion {
  String label(AppLocalizations l) => switch (this) {
        PromptQuestion.perfectSunday => l.promptPerfectSunday,
        PromptQuestion.cantShutUpAbout => l.promptCantShutUpAbout,
        PromptQuestion.makeMeLaugh => l.promptMakeMeLaugh,
        PromptQuestion.learningRightNow => l.promptLearningRightNow,
        PromptQuestion.unpopularOpinion => l.promptUnpopularOpinion,
        PromptQuestion.bestMealEver => l.promptBestMealEver,
        PromptQuestion.weekendPlan => l.promptWeekendPlan,
        PromptQuestion.proudOf => l.promptProudOf,
        PromptQuestion.neverAgain => l.promptNeverAgain,
        PromptQuestion.firstThingNotice => l.promptFirstThingNotice,
        PromptQuestion.simplePleasure => l.promptSimplePleasure,
        PromptQuestion.wouldTravelTo => l.promptWouldTravelTo,
        PromptQuestion.badAt => l.promptBadAt,
        PromptQuestion.changedMyMind => l.promptChangedMyMind,
        PromptQuestion.soundtrack => l.promptSoundtrack,
        PromptQuestion.askMeAbout => l.promptAskMeAbout,
      };

  /// Greyed example in the field. Without one you get "nice" and "good" —
  /// the example is what teaches the register.
  String hint(AppLocalizations l) => switch (this) {
        PromptQuestion.perfectSunday => l.promptPerfectSundayHint,
        PromptQuestion.cantShutUpAbout => l.promptCantShutUpAboutHint,
        PromptQuestion.makeMeLaugh => l.promptMakeMeLaughHint,
        PromptQuestion.learningRightNow => l.promptLearningRightNowHint,
        PromptQuestion.unpopularOpinion => l.promptUnpopularOpinionHint,
        PromptQuestion.bestMealEver => l.promptBestMealEverHint,
        PromptQuestion.weekendPlan => l.promptWeekendPlanHint,
        PromptQuestion.proudOf => l.promptProudOfHint,
        PromptQuestion.neverAgain => l.promptNeverAgainHint,
        PromptQuestion.firstThingNotice => l.promptFirstThingNoticeHint,
        PromptQuestion.simplePleasure => l.promptSimplePleasureHint,
        PromptQuestion.wouldTravelTo => l.promptWouldTravelToHint,
        PromptQuestion.badAt => l.promptBadAtHint,
        PromptQuestion.changedMyMind => l.promptChangedMyMindHint,
        PromptQuestion.soundtrack => l.promptSoundtrackHint,
        PromptQuestion.askMeAbout => l.promptAskMeAboutHint,
      };
}

/// Product rules, in one place so the UI, the model and the migration
/// cannot drift apart.
class PromptRules {
  const PromptRules._();

  /// Shown on a profile.
  static const int maxAnswered = 3;

  /// Required to finish the wizard. Hinge asks for three; this wizard
  /// already has four steps, and asking for three here would cost more
  /// signups than the third answer is worth.
  static const int minAnswered = 2;

  /// These are call openers, not biographies.
  static const int maxAnswerLength = 140;
}
