// Design preview — NOT part of the shipped app.
//
// Flutter only compiles the entry point it is given, so this file exists on
// disk and never in a release binary. Build it explicitly:
//
//   flutter run -t lib/main_preview.dart
//   flutter build ios --simulator --debug -t lib/main_preview.dart
//
// Why it exists: the three surfaces that show a peer — the Discover card,
// the answers as read on a profile, and the confirmed-match row — can only
// be seen with a second account that has filled its prompts, been suggested
// this week, and finished a call. That is a long setup to judge a font size.
// This renders the real widgets (no copies) against a mock profile, so the
// composition can be looked at directly.
//
// Everything below the mock data is production code: SuggestionCard,
// PromptCard and MatchCard are imported, never reimplemented. If they change,
// this preview changes with them — that is the point.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/theme/app_colors.dart';
import 'app/theme/app_spacing.dart';
import 'app/theme/app_theme.dart';
import 'app/theme/app_typography.dart';
import 'features/discover/domain/mutual_match.dart';
import 'features/discover/domain/suggestion_status.dart';
import 'features/discover/domain/weekly_suggestion.dart';
import 'features/discover/presentation/widgets/match_card.dart';
import 'features/discover/presentation/widgets/suggestion_card.dart';
import 'features/profile_setup/domain/enums.dart' as domain;
import 'features/profile_setup/domain/interest.dart';
import 'features/profile_setup/domain/prompt.dart';
import 'features/profile_setup/domain/prompt_answer.dart';
import 'features/profile_setup/domain/user_profile.dart';
import 'features/profile_setup/presentation/widgets/prompt_card.dart';
import 'l10n/app_localizations.dart';

// ---------------------------------------------------------------------------
// Mock — one plausible person, filled the way the rules allow: three answers
// (PromptRules.maxAnswered), each within the 140-character ceiling.
// ---------------------------------------------------------------------------

final _prompts = <PromptAnswer>[
  const PromptAnswer(
    question: PromptQuestion.perfectSunday,
    answer: 'Marché le matin, trop de fromage acheté, '
        'puis un film que j’ai déjà vu quatre fois.',
    position: 0,
  ),
  const PromptAnswer(
    question: PromptQuestion.cantShutUpAbout,
    answer: 'Les vieux ponts. Je connais l’année de construction de la '
        'moitié de ceux de Lyon et personne ne me l’a demandé.',
    position: 1,
  ),
  const PromptAnswer(
    question: PromptQuestion.wouldTravelTo,
    answer: 'Lisbonne, en novembre, quand il n’y a plus personne '
        'et que la lumière est basse.',
    position: 2,
  ),
];

/// Age is derived from `birthDate`, never stored — so the mock sets a date
/// (30 as of today) rather than an age the model would ignore.
final _candidate = UserProfile(
  userId: 'preview-peer',
  firstName: 'Léa',
  birthDate: DateTime(1996, 3, 14),
  gender: domain.Gender.female,
  orientation: domain.Orientation.straight,
  seekingGenders: const {domain.Gender.male},
  seekingAgeMin: 26,
  seekingAgeMax: 38,
  maxDistanceKm: 25,
  intentions: const {domain.Intention.feeling},
  interests: const {Interest.music, Interest.travel, Interest.cooking},
  availability: domain.Availability.immediate,
  prompts: _prompts,
);

final _suggestion = WeeklySuggestion(
  id: 'preview-suggestion',
  userId: 'preview-me',
  suggestedUserId: 'preview-peer',
  compatibilityScore: 93,
  weekStartDate: DateTime(2026, 8, 17),
  status: SuggestionStatus.pending,
  createdAt: DateTime(2026, 8, 19),
  candidate: _candidate,
  // 0 means "unknown" and the card hides the line; a real figure is more
  // useful to look at.
  distanceKm: 7,
);

final _match = MutualMatch(
  id: 'preview-match',
  userId: 'preview-me',
  candidate: _candidate,
  compatibilityScore: 93,
  matchedAt: DateTime(2026, 8, 19),
);

void main() => runApp(const ProviderScope(child: _PreviewApp()));

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DateNow — aperçu',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      locale: const Locale('fr'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const _PreviewScreen(),
    );
  }
}

class _PreviewScreen extends StatefulWidget {
  const _PreviewScreen();

  @override
  State<_PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<_PreviewScreen> {
  final _controller = ScrollController();
  Timer? _timer;
  int _step = 0;

  /// The preview walks itself down the page and back to the top, on a loop.
  /// `simctl` can take a screenshot but cannot send a touch, so a preview
  /// that only ever shows its first screenful is a preview of one third of
  /// the work. Five seconds a stop is long enough to catch any position
  /// with a single `screenshot` call.
  static const _stops = <double>[0, 700, 1400, 2100];

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_controller.hasClients) return;
      _step = (_step + 1) % _stops.length;
      _controller.animateTo(
        _stops[_step].clamp(0.0, _controller.position.maxScrollExtent),
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: ListView(
          controller: _controller,
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            const _Section(
              title: 'Avant l’appel',
              note: 'Onglet Découvrir. La photo est sous le voile, une seule '
                  'réponse est montrée — celle qui ouvre la conversation.',
            ),
            SuggestionCard(
              suggestion: _suggestion,
              onStartDate: () {},
              onDismiss: () {},
            ),
            const SizedBox(height: AppSpacing.xl),

            const _Section(
              title: 'Le profil',
              note: 'Les trois réponses, en entier. Une carte est un coup '
                  'd’œil, un profil est là où on lit quelqu’un.',
            ),
            Text(
              l10n.profilePromptsPeerTitle.toUpperCase(),
              style: AppTypography.overline,
            ),
            const SizedBox(height: AppSpacing.xs),
            for (final prompt in _prompts) ...[
              PromptCard(answer: prompt, maxLines: 5),
              const SizedBox(height: AppSpacing.xs),
            ],
            const SizedBox(height: AppSpacing.xl),

            const _Section(
              title: 'Après le match',
              note: 'La ligne « Matchs effectués », et sa pastille de '
                  'compatibilité à côté du bouton message.',
            ),
            MatchCard(match: _match, onTap: () {}, onAvatarTap: () {}),
            const SizedBox(height: AppSpacing.xl),
          ],
        ),
      ),
    );
  }
}

/// Preview-only chrome, so each block says which screen it comes from.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.note});

  final String title;
  final String note;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AppTypography.h2),
          const SizedBox(height: 4),
          Text(note, style: AppTypography.caption),
        ],
      ),
    );
  }
}
