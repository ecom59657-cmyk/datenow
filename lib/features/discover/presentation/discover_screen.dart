import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/app_routes.dart';
import '../../../app/scaffold/active_tab.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/app_scaffold.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../shared/widgets/loading_indicator.dart';
import '../../messaging/data/messaging_repository.dart';
import '../../profile_setup/presentation/providers/profile_provider.dart';
import '../data/discover_repository.dart';
import '../domain/suggestion_status.dart';
import 'providers/discover_providers.dart';
import 'widgets/match_card.dart';
import 'widgets/suggestion_card.dart';

/// The Discover tab. Two distinct sections:
/// - Weekly suggestions: up to 3 reciprocal-compatible profiles (≥75 %).
///   Photos stay hidden until after a real live date.
/// - Confirmed matches: people the user mutually matched with post-call.
class DiscoverScreen extends ConsumerStatefulWidget {
  const DiscoverScreen({super.key});

  @override
  ConsumerState<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends ConsumerState<DiscoverScreen>
    with TabScrollResetMixin {
  @override
  int get tabIndex => 1; // Home=0, Discover=1, Profile=2

  bool _batchEnsured = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final profile = ref.watch(currentProfileProvider).asData?.value;
    final suggestionsAsync = ref.watch(weeklySuggestionsProvider);
    final matchesAsync = ref.watch(mutualMatchesProvider);

    // Generate this week's batch once per screen mount. Idempotent in the
    // repository — re-opens within the same week are no-ops.
    if (!_batchEnsured && profile != null) {
      _batchEnsured = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref
            .read(discoverRepositoryProvider)
            .ensureWeeklyBatch(profile);
      });
    }

    return AppScaffold(
      body: ListView(
        controller: tabScrollController,
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        physics: const BouncingScrollPhysics(),
        children: [
          const SizedBox(height: AppSpacing.md),
          Text(l10n.discoverTitle, style: AppTypography.h1),
          const SizedBox(height: AppSpacing.xs),
          Text(
            l10n.discoverSubtitle,
            style:
                AppTypography.body.copyWith(color: AppColors.textSecondary),
          ),
          // Diagnostic banner — ONLY in local debug builds. kDebugMode is a
          // compile-time false in release / TestFlight / App Store, so the
          // widget is excluded from the tree entirely.
          if (kDebugMode) ...[
            const SizedBox(height: AppSpacing.md),
            _DiscoverDebugBanner(
              currentUserId: profile?.userId,
              suggestionsAsync: suggestionsAsync,
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          _SectionHeader(label: l10n.discoverSuggestionsSection),
          const SizedBox(height: AppSpacing.sm),
          _SuggestionsBody(state: suggestionsAsync, emptyLabel: l10n.suggestionsEmpty),
          const SizedBox(height: AppSpacing.xl),
          _SectionHeader(label: l10n.discoverMatchesSection),
          const SizedBox(height: AppSpacing.sm),
          _MatchesBody(state: matchesAsync, emptyLabel: l10n.matchesEmpty),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: AppTypography.h3,
    );
  }
}

class _SuggestionsBody extends ConsumerWidget {
  const _SuggestionsBody({required this.state, required this.emptyLabel});

  final AsyncValue<List<dynamic>> state;
  final String emptyLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return state.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(AppSpacing.lg),
        child: LoadingIndicator(),
      ),
      error: (e, _) => _EmptyCard(message: AppLocalizations.of(context).errorLoadContent),
      data: (_) {
        final list = ref.watch(weeklySuggestionsProvider).asData!.value;
        // A suggestion is CONSUMED the moment a date is launched with it
        // (status callStarted) — or once it became a match. Only the
        // still-available (pending) ones are offered; consumed ones never
        // re-appear here (they live in Matchs effectués / Messages instead).
        final pending = list
            .where((s) => s.status == SuggestionStatus.pending)
            .toList(growable: false);
        final consumed = list
            .where((s) =>
                s.status == SuggestionStatus.callStarted ||
                s.status == SuggestionStatus.matched)
            .length;

        if (pending.isEmpty) {
          // All of this week's suggestions have been used → premium "done"
          // state. Truly-no-batch (new user / no candidates) keeps the
          // generic empty card.
          return consumed > 0
              ? _AllConsumedCard(total: consumed)
              : _EmptyCard(message: emptyLabel);
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _RemainingSuggestions(remaining: pending.length),
            const SizedBox(height: AppSpacing.sm),
            for (final s in pending) ...[
              SuggestionCard(
                suggestion: s,
                onStartDate: () => startDateFromSuggestion(context, ref, s),
                onDismiss: () => ref
                    .read(discoverRepositoryProvider)
                    .dismissSuggestion(s.id),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
          ],
        );
      },
    );
  }
}

/// Subtle "X propositions restantes cette semaine" reassurance line.
class _RemainingSuggestions extends StatelessWidget {
  const _RemainingSuggestions({required this.remaining});

  final int remaining;

  @override
  Widget build(BuildContext context) {
    final label = remaining <= 1
        ? '$remaining proposition restante cette semaine'
        : '$remaining propositions restantes cette semaine';
    return Row(
      children: [
        const Icon(Icons.auto_awesome_rounded,
            size: 15, color: AppColors.bordeaux),
        const SizedBox(width: 6),
        Text(
          label,
          style: AppTypography.caption.copyWith(
            color: AppColors.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// Premium empty state once all of the week's suggestions have been used.
class _AllConsumedCard extends StatelessWidget {
  const _AllConsumedCard({required this.total});

  final int total;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        children: [
          const Icon(Icons.celebration_rounded,
              size: 44, color: AppColors.bordeaux),
          const SizedBox(height: AppSpacing.md),
          Text(
            'Tu as déjà rencontré tes $total '
            '${total <= 1 ? 'proposition' : 'propositions'} de la semaine.',
            textAlign: TextAlign.center,
            style: AppTypography.bodyStrong,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'De nouvelles propositions arriveront bientôt.',
            textAlign: TextAlign.center,
            style: AppTypography.body.copyWith(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _MatchesBody extends ConsumerWidget {
  const _MatchesBody({required this.state, required this.emptyLabel});

  final AsyncValue<List<dynamic>> state;
  final String emptyLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return state.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(AppSpacing.lg),
        child: LoadingIndicator(),
      ),
      error: (e, _) => _EmptyCard(message: AppLocalizations.of(context).errorLoadContent),
      data: (_) {
        final list = ref.watch(mutualMatchesProvider).asData!.value;
        if (list.isEmpty) return _EmptyCard(message: emptyLabel);
        return Column(
          children: [
            for (final m in list) ...[
              MatchCard(
                match: m,
                onTap: () => _openConversationFromMatch(context, ref, m),
                onAvatarTap: () => context.pushNamed(
                  AppRoute.matchedProfile.name,
                  pathParameters: {'userId': m.candidate.userId},
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
          ],
        );
      },
    );
  }
}

Future<void> _openConversationFromMatch(
  BuildContext context,
  WidgetRef ref,
  dynamic match,
) async {
  final self = ref.read(currentProfileProvider).asData?.value;
  if (self == null) return;
  // `ensureConversation` is idempotent — if the conversation was created
  // at match-time by the post-call screen, we get that one back; if it
  // wasn't (older match), we create it on the fly. Either way the user
  // lands inside a real chat room rather than the inbox.
  final conv = await ref.read(messagingRepositoryProvider).ensureConversation(
        currentUserId: self.userId,
        peer: match.candidate,
      );
  if (!context.mounted) return;
  context.pushNamed(
    AppRoute.conversation.name,
    pathParameters: {'id': conv.id},
  );
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Row(
        children: [
          const Icon(Icons.auto_awesome_rounded,
              color: AppColors.bordeauxLight, size: 20),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: AppTypography.body.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact diagnostic banner — surfaces matching state without leaving
/// the Discover tab. Mirrors what the full `Debug · Matching` screen
/// shows but keeps it one tap away.
class _DiscoverDebugBanner extends StatelessWidget {
  const _DiscoverDebugBanner({
    required this.currentUserId,
    required this.suggestionsAsync,
  });

  final String? currentUserId;
  final AsyncValue<List<dynamic>> suggestionsAsync;

  @override
  Widget build(BuildContext context) {
    final count = suggestionsAsync.maybeWhen(
      data: (rows) => rows.length,
      orElse: () => null,
    );
    return GlassCard(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.bordeauxLight.withValues(alpha: 0.18),
              border: Border.all(
                color: AppColors.bordeauxLight.withValues(alpha: 0.4),
              ),
            ),
            alignment: Alignment.center,
            child: const Icon(
              Icons.bug_report_outlined,
              color: AppColors.bordeauxLight,
              size: 16,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'me: ${currentUserId == null ? '—' : '${currentUserId!.substring(0, 8)}…'}'
                  '   suggestions: ${count ?? '—'}',
                  style: AppTypography.caption.copyWith(
                    color: AppColors.textSecondary,
                    fontFamily: 'monospace',
                  ),
                ),
                Text(
                  'Tap → Debug Matching',
                  style: AppTypography.caption.copyWith(
                    color: AppColors.bordeauxLight,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(
              Icons.chevron_right_rounded,
              color: AppColors.bordeauxLight,
            ),
            onPressed: () =>
                context.pushNamed(AppRoute.debugMatching.name),
          ),
        ],
      ),
    );
  }
}
