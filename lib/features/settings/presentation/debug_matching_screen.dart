import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/services/supabase_service.dart';
import '../../../shared/widgets/app_button.dart';
import '../../../shared/widgets/app_scaffold.dart';
import '../../matching/data/matching_repository.dart';
import '../../matching/data/matching_service.dart';
import '../../matching/domain/match_score.dart';
import '../../profile_setup/data/profile_repository.dart';
import '../../profile_setup/domain/user_profile.dart';
import '../../profile_setup/presentation/providers/profile_provider.dart';

/// Temporary developer surface that walks the full matching pipeline end
/// to end for the currently signed-in user. It is intentionally not
/// localized — this screen is a diagnostic tool, not a product feature.
///
/// What it shows:
///   - Is Supabase actually being used? Are the env vars present?
///   - The current user's id + preferences (the inputs to matching).
///   - Every potential candidate fetched from Supabase, with a per-axis
///     pass/fail breakdown and the final compatibility score.
///   - For each candidate, the reason they were excluded if they were.
class DebugMatchingScreen extends ConsumerStatefulWidget {
  const DebugMatchingScreen({super.key});

  @override
  ConsumerState<DebugMatchingScreen> createState() =>
      _DebugMatchingScreenState();
}

class _DebugMatchingScreenState extends ConsumerState<DebugMatchingScreen> {
  _Report? _report;
  bool _running = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final self = ref.read(currentProfileProvider).asData?.value;
      if (self == null) {
        throw StateError('current profile not loaded yet');
      }
      final supabaseUp = ref.read(supabaseAvailableProvider);
      final urlSet = (dotenv.env['SUPABASE_URL']?.isNotEmpty ?? false);
      final keyRaw = dotenv.env['SUPABASE_ANON_KEY'] ?? '';
      final keyMasked = keyRaw.isEmpty
          ? 'MISSING'
          : '${keyRaw.substring(0, keyRaw.length < 8 ? keyRaw.length : 8)}…(${keyRaw.length})';

      final fetcher = ref.read(profileRepositoryProvider);
      final service = ref.read(matchingServiceProvider);

      final candidates =
          await fetcher.fetchPotentialCandidates(selfUserId: self.userId);

      final perCandidate = <_CandidateDiag>[];
      for (final c in candidates) {
        final hardGates = _checkHardGates(self, c);
        // Use a fixed distance approximation since we don't have geo yet.
        const distanceKm = 10;
        MatchScore? score;
        if (hardGates.isEmpty) {
          score = service.calculateCompatibility(
            self,
            c,
            distanceKm: distanceKm,
          );
        }
        perCandidate.add(_CandidateDiag(
          candidate: c,
          distanceKm: distanceKm,
          failedGates: hardGates,
          score: score,
        ));
      }

      if (!mounted) return;
      setState(() {
        _report = _Report(
          self: self,
          supabaseUp: supabaseUp,
          urlSet: urlSet,
          keyMasked: keyMasked,
          candidates: perCandidate,
        );
        _running = false;
      });
    } catch (e, st) {
      if (!mounted) return;
      setState(() {
        _error = '$e\n$st';
        _running = false;
      });
    }
  }

  /// Mirrors `_hardGatesPass` in [MatchingService] but accumulates a
  /// human-readable reason for every failing axis instead of bailing on
  /// the first one — that's what makes this screen useful.
  static List<String> _checkHardGates(UserProfile a, UserProfile b) {
    final fails = <String>[];
    if (a.gender == null) fails.add('self.gender = null');
    if (b.gender == null) fails.add('candidate.gender = null');
    if (a.gender != null &&
        b.gender != null &&
        !a.seekingGenders.contains(b.gender)) {
      fails.add(
        "self doesn't seek ${b.gender!.name} "
        '(seeks: ${a.seekingGenders.map((g) => g.name).toList()})',
      );
    }
    if (a.gender != null &&
        b.gender != null &&
        !b.seekingGenders.contains(a.gender)) {
      fails.add(
        "candidate doesn't seek ${a.gender!.name} "
        '(seeks: ${b.seekingGenders.map((g) => g.name).toList()})',
      );
    }
    if (a.age == null) fails.add('self.age = null');
    if (b.age == null) fails.add('candidate.age = null');
    if (a.age != null && b.age != null) {
      if (b.age! < a.seekingAgeMin || b.age! > a.seekingAgeMax) {
        fails.add(
          'candidate.age ${b.age} outside self range '
          '${a.seekingAgeMin}-${a.seekingAgeMax}',
        );
      }
      if (a.age! < b.seekingAgeMin || a.age! > b.seekingAgeMax) {
        fails.add(
          'self.age ${a.age} outside candidate range '
          '${b.seekingAgeMin}-${b.seekingAgeMax}',
        );
      }
    }
    return fails;
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      appBar: AppBar(title: const Text('Debug · Matching')),
      body: ListView(
        children: [
          if (_running)
            const Padding(
              padding: EdgeInsets.all(AppSpacing.lg),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            _ErrorCard(message: _error!)
          else if (_report != null)
            _ReportView(report: _report!),
          const SizedBox(height: AppSpacing.lg),
          AppButton(
            label: _running ? 'Running…' : 'Re-run diagnostic',
            icon: Icons.refresh_rounded,
            onPressed: _running ? null : _run,
          ),
          const SizedBox(height: AppSpacing.xl),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// View
// ---------------------------------------------------------------------------

class _ReportView extends StatelessWidget {
  const _ReportView({required this.report});

  final _Report report;

  @override
  Widget build(BuildContext context) {
    final kept = report.candidates
        .where((c) => c.failedGates.isEmpty && (c.score?.percentage ?? 0) >= 75)
        .length;
    final eligibleNoFloor = report.candidates
        .where((c) => c.failedGates.isEmpty && c.score != null)
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Section(
          title: 'Environment',
          rows: [
            ('USING_SUPABASE', report.supabaseUp ? 'true' : 'false'),
            ('SUPABASE_URL present', report.urlSet ? 'yes' : 'no'),
            ('SUPABASE_ANON_KEY', report.keyMasked),
          ],
        ),
        _Section(
          title: 'Self profile',
          rows: [
            ('user_id', report.self.userId),
            ('first_name', report.self.firstName ?? '—'),
            ('gender', report.self.gender?.name ?? '—'),
            ('orientation', report.self.orientation?.name ?? '—'),
            ('age', '${report.self.age ?? '—'}'),
            (
              'seekingGenders',
              report.self.seekingGenders.map((g) => g.name).join(', ').nullIfEmpty
                  ?? '∅',
            ),
            (
              'seekingAge',
              '${report.self.seekingAgeMin} – ${report.self.seekingAgeMax}',
            ),
            ('maxDistanceKm', '${report.self.maxDistanceKm}'),
            (
              'intentions',
              report.self.intentions.map((i) => i.name).join(', ').nullIfEmpty
                  ?? '∅',
            ),
            (
              'interests',
              '${report.self.interests.length} items',
            ),
            ('availability', report.self.availability?.name ?? '—'),
          ],
        ),
        _Section(
          title: 'Summary',
          rows: [
            ('Total fetched', '${report.candidates.length}'),
            ('Pass hard gates', '$eligibleNoFloor'),
            ('Above 75% floor', '$kept'),
          ],
        ),
        if (report.candidates.isEmpty)
          const _ErrorCard(
            message:
                'No candidate profiles returned from Supabase.\n\n'
                'Common causes:\n'
                '• The RLS migration 20260514120000_matching_discovery_rls.sql '
                'has not been applied yet (run `supabase db push`).\n'
                '• The other test user does not have a completed profile '
                '(first_name + gender + user_preferences row).\n'
                '• You are signed in with the only existing account in '
                'auth.users.',
          )
        else
          for (final c in report.candidates)
            _CandidateTile(diag: c),
      ],
    );
  }
}

class _CandidateTile extends StatelessWidget {
  const _CandidateTile({required this.diag});

  final _CandidateDiag diag;

  @override
  Widget build(BuildContext context) {
    final c = diag.candidate;
    final reason = diag.failedGates.isNotEmpty
        ? 'HARD GATE FAIL'
        : (diag.score == null
            ? 'no score'
            : (diag.score!.percentage >= 75
                ? 'KEPT (${diag.score!.percentage}%)'
                : 'BELOW FLOOR (${diag.score!.percentage}%)'));
    final color = diag.failedGates.isNotEmpty
        ? AppColors.error
        : (diag.score != null && diag.score!.percentage >= 75
            ? AppColors.online
            : AppColors.warning);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${c.firstName ?? '—'} · ${c.gender?.name ?? '?'} · '
            'age ${c.age ?? '?'} · ${c.userId.substring(0, 8)}…',
            style: AppTypography.body
                .copyWith(fontWeight: FontWeight.w700, color: Colors.white),
          ),
          const SizedBox(height: 4),
          Text(
            reason,
            style: AppTypography.caption.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (diag.failedGates.isNotEmpty) ...[
            const SizedBox(height: 6),
            for (final f in diag.failedGates)
              Text('• $f',
                  style: AppTypography.caption
                      .copyWith(color: AppColors.textSecondary)),
          ],
          if (diag.score != null) ...[
            const SizedBox(height: 6),
            Text(
              'breakdown: ${diag.score!.breakdown}',
              style: AppTypography.caption
                  .copyWith(color: AppColors.textSecondary),
            ),
          ],
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.rows});

  final String title;
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AppTypography.h3),
          const SizedBox(height: AppSpacing.sm),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 140,
                    child: Text(
                      r.$1,
                      style: AppTypography.caption
                          .copyWith(color: AppColors.textSecondary),
                    ),
                  ),
                  Expanded(
                    child: SelectableText(
                      r.$2,
                      style: AppTypography.caption
                          .copyWith(color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.error.withValues(alpha: 0.45)),
      ),
      child: SelectableText(
        message,
        style: AppTypography.caption.copyWith(color: AppColors.error),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Data
// ---------------------------------------------------------------------------

class _Report {
  const _Report({
    required this.self,
    required this.supabaseUp,
    required this.urlSet,
    required this.keyMasked,
    required this.candidates,
  });

  final UserProfile self;
  final bool supabaseUp;
  final bool urlSet;
  final String keyMasked;
  final List<_CandidateDiag> candidates;
}

class _CandidateDiag {
  const _CandidateDiag({
    required this.candidate,
    required this.distanceKm,
    required this.failedGates,
    required this.score,
  });

  final UserProfile candidate;
  final int distanceKm;
  final List<String> failedGates;
  final MatchScore? score;
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}
