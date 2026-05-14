import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/app_routes.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/app_button.dart';
import '../../../shared/widgets/app_scaffold.dart';
import '../../discover/data/discover_repository.dart';
import '../../matching/data/matching_repository.dart';
import '../../messaging/data/messaging_repository.dart';
import '../../matching/domain/active_match.dart';
import '../../matching/presentation/providers/active_match_provider.dart';
import '../../matching/presentation/widgets/compatibility_badge.dart';
import '../../profile_setup/data/profile_repository.dart';
import '../../profile_setup/presentation/providers/profile_provider.dart';
import '../../profile_setup/presentation/widgets/blurred_avatar.dart';

/// Post-call decision screen. Reveals the candidate photo + compatibility
/// score and lets the user match or pass. Real photos surface **only** here.
class PostCallScreen extends ConsumerStatefulWidget {
  const PostCallScreen({super.key});

  @override
  ConsumerState<PostCallScreen> createState() => _PostCallScreenState();
}

enum _Stage { decide, waiting, matched, noMatch, passed }

class _PostCallScreenState extends ConsumerState<PostCallScreen> {
  _Stage _stage = _Stage.decide;
  bool _revealed = false;
  Uint8List? _peerPhotoBytes;
  Timer? _peerDecisionTimer;

  @override
  void initState() {
    super.initState();
    _loadPeerPhoto();
  }

  Future<void> _loadPeerPhoto() async {
    // For MVP demo we don't ship real candidate photos. Reuse the current
    // user's own primary photo as the stand-in so the reveal effect is
    // demoable end-to-end. Real builds will pull the matched profile's
    // primary photo from the repository.
    final ownProfile = ref.read(currentProfileProvider).asData?.value;
    final ownUrl = ownProfile?.primaryPhotoUrl;
    if (ownUrl != null) {
      final bytes =
          await ref.read(profileRepositoryProvider).getPhotoBytes(ownUrl);
      if (mounted) setState(() => _peerPhotoBytes = bytes);
    }
  }

  void _match() async {
    final match = ref.read(activeMatchProvider);
    final self = ref.read(currentProfileProvider).asData?.value;
    if (match == null || self == null) return;

    setState(() => _stage = _Stage.waiting);
    await ref.read(matchingRepositoryProvider).recordDecision(
          self: self,
          candidate: match.candidate,
          wantsMatch: true,
        );

    // Mock the peer's decision after a short wait — 60% accept, 40% pass.
    // In production this will arrive over realtime.
    _peerDecisionTimer = Timer(const Duration(milliseconds: 1600), () async {
      if (!mounted) return;
      final peerAccepts = Random().nextDouble() < 0.6;
      setState(() => _stage = peerAccepts ? _Stage.matched : _Stage.noMatch);

      if (peerAccepts) {
        final discover = ref.read(discoverRepositoryProvider);
        await discover.recordMutualMatch(
          self: self,
          candidate: match.candidate,
          score: match.score,
        );
        final sourceId = match.sourceSuggestionId;
        if (sourceId != null) {
          await discover.markSuggestionMatched(sourceId);
        }
        // Spin up the private messaging room. This is the ONLY place in
        // the app where a conversation is created — per the product rule
        // "no chat before a mutual match".
        try {
          await ref.read(messagingRepositoryProvider).ensureConversation(
                currentUserId: self.userId,
                peer: match.candidate,
              );
        } catch (e) {
          // Non-fatal: the user can still match. They'll be able to start
          // the conversation later from the Discover match card, which
          // calls ensureConversation again.
          // ignore: avoid_print
          // (silent — log already happens in the repo)
        }
      }
    });
  }

  void _pass() async {
    final match = ref.read(activeMatchProvider);
    final self = ref.read(currentProfileProvider).asData?.value;
    if (match != null && self != null) {
      await ref.read(matchingRepositoryProvider).recordDecision(
            self: self,
            candidate: match.candidate,
            wantsMatch: false,
          );
    }
    if (!mounted) return;
    setState(() => _stage = _Stage.passed);
  }

  void _backHome() {
    ref.read(activeMatchProvider.notifier).state = null;
    if (!mounted) return;
    context.goNamed(AppRoute.home.name);
  }

  void _findAnother() {
    ref.read(activeMatchProvider.notifier).state = null;
    if (!mounted) return;
    context.goNamed(AppRoute.matching.name);
  }

  @override
  void dispose() {
    _peerDecisionTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final match = ref.watch(activeMatchProvider);

    final body = switch (_stage) {
      _Stage.decide => _DecideView(
          match: match,
          revealed: _revealed,
          peerPhotoBytes: _peerPhotoBytes,
          onReveal: () => setState(() => _revealed = true),
          onMatch: _match,
          onPass: _pass,
        ),
      _Stage.waiting => const _WaitingView(),
      _Stage.matched => _ResolvedView(
          matched: true,
          onBackHome: _backHome,
          onFindAnother: _findAnother,
        ),
      _Stage.noMatch => _ResolvedView(
          matched: false,
          onBackHome: _backHome,
          onFindAnother: _findAnother,
        ),
      _Stage.passed => _PassedView(onFindAnother: _findAnother),
    };

    return AppScaffold(
      glowIntensity: _stage == _Stage.matched ? 1.2 : 0.6,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(l10n.postCallTitle),
      ),
      body: body,
    );
  }
}

// ---------------------------------------------------------------------------
// Stage views
// ---------------------------------------------------------------------------

class _DecideView extends StatelessWidget {
  const _DecideView({
    required this.match,
    required this.revealed,
    required this.peerPhotoBytes,
    required this.onReveal,
    required this.onMatch,
    required this.onPass,
  });

  final ActiveMatch? match;
  final bool revealed;
  final Uint8List? peerPhotoBytes;
  final VoidCallback onReveal;
  final VoidCallback onMatch;
  final VoidCallback onPass;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final candidate = match?.candidate;
    final score = match?.score;

    return Column(
      children: [
        const SizedBox(height: AppSpacing.lg),
        Text(
          l10n.postCallSubtitle,
          textAlign: TextAlign.center,
          style: AppTypography.body.copyWith(color: AppColors.textSecondary),
        ),
        const Spacer(),
        Center(
          child: _PhotoReveal(
            revealed: revealed,
            bytes: peerPhotoBytes,
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        if (candidate != null)
          Text(
            candidate.age != null
                ? '${candidate.firstName ?? '—'}, ${candidate.age}'
                : candidate.firstName ?? '—',
            style: AppTypography.h2,
          ),
        const SizedBox(height: 4),
        if (match != null)
          Text(
            '${match!.distanceKm} km',
            style:
                AppTypography.body.copyWith(color: AppColors.textSecondary),
          ),
        if (score != null) ...[
          const SizedBox(height: AppSpacing.sm),
          CompatibilityBadge(score: score),
        ],
        const Spacer(),
        if (!revealed) ...[
          AppButton(
            label: l10n.postCallReveal,
            icon: Icons.visibility_outlined,
            size: AppButtonSize.large,
            onPressed: onReveal,
          ),
        ] else ...[
          AppButton(
            label: l10n.postCallMatch,
            icon: Icons.favorite_rounded,
            size: AppButtonSize.large,
            onPressed: onMatch,
          ),
          const SizedBox(height: AppSpacing.sm),
          AppButton(
            label: l10n.postCallPass,
            variant: AppButtonVariant.secondary,
            size: AppButtonSize.large,
            onPressed: onPass,
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }
}

class _WaitingView extends StatelessWidget {
  const _WaitingView();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            height: 36,
            width: 36,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              valueColor: AlwaysStoppedAnimation(AppColors.brandPink),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            l10n.postCallWaiting,
            style:
                AppTypography.body.copyWith(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _ResolvedView extends StatelessWidget {
  const _ResolvedView({
    required this.matched,
    required this.onBackHome,
    required this.onFindAnother,
  });

  final bool matched;
  final VoidCallback onBackHome;
  final VoidCallback onFindAnother;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      children: [
        const Spacer(),
        Icon(
          matched ? Icons.favorite_rounded : Icons.waving_hand_rounded,
          size: 80,
          color: matched ? AppColors.brandPink : AppColors.textSecondary,
        ).animate().scale(
              duration: 500.ms,
              curve: Curves.easeOutBack,
              begin: const Offset(0.6, 0.6),
              end: const Offset(1, 1),
            ),
        const SizedBox(height: AppSpacing.lg),
        Text(
          matched ? l10n.postCallMatchedTitle : l10n.postCallNoMatchTitle,
          style: AppTypography.h1,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.sm),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: Text(
            matched ? l10n.postCallMatchedBody : l10n.postCallNoMatchBody,
            textAlign: TextAlign.center,
            style:
                AppTypography.body.copyWith(color: AppColors.textSecondary),
          ),
        ),
        const Spacer(),
        if (matched)
          AppButton(
            label: l10n.postCallBackHome,
            icon: Icons.home_rounded,
            size: AppButtonSize.large,
            onPressed: onBackHome,
          )
        else ...[
          AppButton(
            label: l10n.postCallFindAnother,
            icon: Icons.bolt_rounded,
            size: AppButtonSize.large,
            onPressed: onFindAnother,
          ),
          const SizedBox(height: AppSpacing.sm),
          AppButton(
            label: l10n.postCallBackHome,
            variant: AppButtonVariant.secondary,
            onPressed: onBackHome,
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }
}

class _PassedView extends StatelessWidget {
  const _PassedView({required this.onFindAnother});

  final VoidCallback onFindAnother;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      children: [
        const Spacer(),
        const Icon(
          Icons.bolt_rounded,
          size: 72,
          color: AppColors.brandPink,
        ).animate().scale(
              duration: 500.ms,
              curve: Curves.easeOutBack,
              begin: const Offset(0.6, 0.6),
              end: const Offset(1, 1),
            ),
        const SizedBox(height: AppSpacing.lg),
        Text(
          l10n.postCallPassTitle,
          style: AppTypography.h1,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.sm),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: Text(
            l10n.postCallPassBody,
            textAlign: TextAlign.center,
            style:
                AppTypography.body.copyWith(color: AppColors.textSecondary),
          ),
        ),
        const Spacer(),
        AppButton(
          label: l10n.postCallFindAnother,
          icon: Icons.favorite_rounded,
          size: AppButtonSize.large,
          onPressed: onFindAnother,
        ),
        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Photo reveal — the **only** place a real photo can surface
// ---------------------------------------------------------------------------

class _PhotoReveal extends StatelessWidget {
  const _PhotoReveal({required this.revealed, required this.bytes});

  final bool revealed;
  final Uint8List? bytes;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    const size = 220.0;

    if (!revealed || bytes == null) {
      return Column(
        children: [
          Stack(
            alignment: Alignment.center,
            children: [
              const BlurredAvatar(size: size),
              if (bytes != null)
                ClipOval(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                    child: const SizedBox(width: size, height: size),
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            l10n.hiddenPhotoLabel,
            style: AppTypography.caption.copyWith(
              color: AppColors.textTertiary,
            ),
          ),
        ],
      );
    }

    return ClipOval(
      child: Image.memory(
        bytes!,
        width: size,
        height: size,
        fit: BoxFit.cover,
      ),
    ).animate().scale(
          duration: 400.ms,
          begin: const Offset(0.85, 0.85),
          end: const Offset(1, 1),
          curve: Curves.easeOutBack,
        );
  }
}
