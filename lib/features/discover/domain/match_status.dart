import '../../../l10n/app_localizations.dart';

/// Lifecycle of a confirmed [MutualMatch] in the user's "Matches" section.
enum MatchStatus { newMatch, conversationOpen }

extension MatchStatusX on MatchStatus {
  String label(AppLocalizations l) => switch (this) {
        MatchStatus.newMatch => l.matchStatusNew,
        MatchStatus.conversationOpen => l.matchStatusConversation,
      };
}
