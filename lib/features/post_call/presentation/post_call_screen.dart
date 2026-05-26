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
import '../../../core/debug/debug_observer.dart';
import '../../../core/utils/logger.dart';
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
import '../../safety/presentation/report_sheet.dart';
import '../data/reveal_repository.dart';

/// Post-call decision screen. Reveals the candidate photo + compatibility
/// score and lets the user match or pass. Real photos surface **only** here.
class PostCallScreen extends ConsumerStatefulWidget {
  const PostCallScreen({super.key});

  @override
  ConsumerState<PostCallScreen> createState() => _PostCallScreenState();
}

/// Reveal flow stages:
///   - decide          : peer photo masked, single "Révéler" button.
///   - waiting         : self has revealed, waiting for the peer photo
///                       reveal (photo stays masked).
///   - mutual          : BOTH peers revealed — photo shown large,
///                       Match/Pass buttons.
///   - awaitingPeerMatch: self tapped Match — waiting for the peer's
///                       Match/Pass decision. No match row exists yet.
///   - matched         : both peers tapped Match → match row +
///                       conversation created.
///   - noMatch         : either peer passed → no match (server-confirmed).
///   - passed          : self passed (terminal local view).
enum _Stage {
  decide,
  waiting,
  mutual,
  awaitingPeerMatch,
  matched,
  noMatch,
  passed,
}

class _PostCallScreenState extends ConsumerState<PostCallScreen> {
  static const _log = AppLogger('PostCall');

  /// How long to wait on the peer's reveal decision before offering the
  /// user a way out — prevents an infinite "waiting" spinner when the
  /// peer closed the app or never decides.
  static const _revealTimeout = Duration(minutes: 2);

  _Stage _stage = _Stage.decide;
  Uint8List? _peerPhotoBytes;
  Timer? _peerDecisionTimer;
  Timer? _revealTimeoutTimer;
  bool _revealTimedOut = false;
  StreamSubscription<List<RevealRow>>? _revealSub;
  bool _matchPersisted = false;

  /// Set once `_persistMatch` resolves with a conversation id — drives
  /// the "Envoyer un message" CTA on the matched view. Stays null on a
  /// `RevealOutcome.declined` outcome.
  String? _matchedConversationId;

  @override
  void initState() {
    super.initState();
    DebugObserver.instance.setPhase('reveal'); // debug-observer
    _loadPeerPhoto();
  }

  /// Loads the *peer's* primary photo (never the current user's).
  ///
  /// Called at three points:
  ///   1. initState — RLS likely blocks here (no mutual reveal yet) and
  ///      bytes stay null. That's expected.
  ///   2. _onReveals when transitioning to _Stage.mutual — the
  ///      `*_select_mutual_reveal` policies just opened access, so this
  ///      is the real-fetch attempt.
  ///   3. anywhere else as a manual refresh.
  ///
  /// Logs verbosely (debug only via AppLogger) so the source of any
  /// blank photo is observable from the device console.
  Future<void> _loadPeerPhoto() async {
    final match = ref.read(activeMatchProvider);
    if (match == null) {
      _log.warn('loadPeerPhoto: no activeMatch');
      return;
    }
    final peerId = match.candidate.userId;
    final profileRepo = ref.read(profileRepositoryProvider);
    _log.info('loadPeerPhoto: peerId=$peerId');

    // Refetch through the repo so RLS-relaxed policies kick in. If the
    // refetch fails fall back to the cached candidate.
    final peer = await profileRepo.getProfile(peerId) ?? match.candidate;
    final url = peer.primaryPhotoUrl;
    _log.info('loadPeerPhoto: primaryPhotoUrl=${url ?? '∅'}');
    if (url == null) return;

    final bytes = await profileRepo.getPhotoBytes(url);
    _log.info(
      'loadPeerPhoto: bytes=${bytes == null ? '∅ (null)' : '${bytes.length} bytes'}',
    );
    if (mounted) setState(() => _peerPhotoBytes = bytes);
  }

  /// Submits the user's reveal=true and moves to the waiting state.
  /// The photo stays masked here — it only appears once Realtime tells
  /// us BOTH peers have revealed (handled in [_onReveals]).
  void _submitReveal() async {
    final match = ref.read(activeMatchProvider);
    final self = ref.read(currentProfileProvider).asData?.value;
    if (match == null || self == null) return;

    setState(() => _stage = _Stage.waiting);

    final callId = ref.read(activeCallIdProvider);
    final revealRepo = ref.read(revealRepositoryProvider);

    if (callId != null && revealRepo != null) {
      try {
        await revealRepo.submitReveal(
          callId: callId,
          userId: self.userId,
          revealed: true,
        );
        DebugLog.reveal('reveal submitted'); // debug-observer
      } catch (e, st) {
        _log.error('submitReveal(true) failed', e, st);
      }
      _revealSub = revealRepo.watchReveals(callId).listen(
        (rows) => _onReveals(
          rows,
          callId: callId,
          self: self,
          match: match,
        ),
        onError: (e, st) => _log.error('watchReveals error', e, st),
      );
      _startRevealTimeout();
      return;
    }

    // Fallback (no Supabase / no call id): keep the demo alive with a
    // mocked peer reveal so the flow is testable offline. Lands on the
    // mutual-reveal stage so the tester can still tap Match/Pass.
    _log.warn('No callId/revealRepo — falling back to mock peer reveal');
    _peerDecisionTimer = Timer(const Duration(milliseconds: 1600), () {
      if (!mounted) return;
      final peerReveals = Random().nextDouble() < 0.6;
      setState(() => _stage = peerReveals ? _Stage.mutual : _Stage.noMatch);
    });
  }

  /// Tapped on the mutual-reveal view when the user confirms the match.
  /// Writes *only* the user's own decision = 'match' to the server and
  /// flips to the awaiting-peer state. The permanent match row + the
  /// conversation are created only when [_onReveals] sees the peer's
  /// row also resolve to decision = 'match'.
  void _confirmMatch() async {
    final self = ref.read(currentProfileProvider).asData?.value;
    final callId = ref.read(activeCallIdProvider);
    final revealRepo = ref.read(revealRepositoryProvider);
    if (self == null || callId == null || revealRepo == null) return;
    setState(() => _stage = _Stage.awaitingPeerMatch);
    DebugLog.reveal('match decision: self -> match');
    try {
      await revealRepo.submitDecision(
        callId: callId,
        userId: self.userId,
        decision: 'match',
      );
    } catch (e, st) {
      _log.error('submitDecision(match) failed', e, st);
    }
  }

  /// Tapped on the mutual-reveal view (or the awaiting-peer view) when
  /// the user passes after seeing the photo. Writes decision = 'pass'
  /// on the server so the peer's stream resolves to a `passed` outcome
  /// and they leave the matched view too.
  void _passAfterReveal() async {
    final self = ref.read(currentProfileProvider).asData?.value;
    final callId = ref.read(activeCallIdProvider);
    final revealRepo = ref.read(revealRepositoryProvider);
    if (self != null && callId != null && revealRepo != null) {
      try {
        await revealRepo.submitDecision(
          callId: callId,
          userId: self.userId,
          decision: 'pass',
        );
        DebugLog.reveal('match decision: self -> pass');
      } catch (e, st) {
        _log.error('submitDecision(pass) post-mutual failed', e, st);
      }
    }
    if (!mounted) return;
    _revealSub?.cancel();
    _revealTimeoutTimer?.cancel();
    ref.read(activeMatchProvider.notifier).state = null;
    setState(() => _stage = _Stage.passed);
  }

  /// (Re)arms the reveal-timeout timer. When it fires the waiting view
  /// surfaces "Continuer à attendre" / "Passer" so the user is never
  /// stuck waiting on a peer who has gone silent.
  void _startRevealTimeout() {
    _revealTimeoutTimer?.cancel();
    _revealTimedOut = false;
    _revealTimeoutTimer = Timer(_revealTimeout, () {
      if (!mounted || _stage != _Stage.waiting) return;
      _log.info('Reveal wait timed out — offering exit to user');
      setState(() => _revealTimedOut = true);
    });
  }

  /// "Continuer à attendre" — give the peer another full window.
  void _keepWaiting() {
    _log.info('User chose to keep waiting for the reveal');
    setState(() => _revealTimedOut = false);
    _startRevealTimeout();
  }

  /// Drives the local stage from the live reveal rows. Handles BOTH the
  /// photo-reveal phase (decide → waiting → mutual / noMatch) AND the
  /// post-reveal match-decision phase (mutual → awaitingPeerMatch →
  /// matched / noMatch). The permanent match row + conversation are
  /// only created here, after the peer confirms decision = 'match'.
  Future<void> _onReveals(
    List<RevealRow> rows, {
    required String callId,
    required dynamic self,
    required ActiveMatch match,
  }) async {
    if (!mounted) return;
    final repo = ref.read(revealRepositoryProvider);
    if (repo == null) return;
    final selfId = self.userId as String;
    final peerId = match.candidate.userId;
    final outcome = repo.outcomeFor(rows, selfId: selfId, peerId: peerId);
    _log.info('Reveal outcome — $outcome (${rows.length} row(s))');
    // Terminal local stages must not be undone by a later realtime
    // event (the peer might flip after we navigated away).
    if (_stage == _Stage.matched || _stage == _Stage.passed) {
      return;
    }
    switch (outcome) {
      case RevealOutcome.pending:
        // Still waiting for the peer to reveal their photo — stay on
        // the waiting view.
        return;
      case RevealOutcome.declined:
        _revealTimeoutTimer?.cancel();
        DebugLog.reveal('declined');
        DebugObserver.instance.setRevealOutcome('declined');
        setState(() => _stage = _Stage.noMatch);
        return;
      case RevealOutcome.mutual:
        _revealTimeoutTimer?.cancel();
        // Land on the mutual view on first transition so Match/Pass
        // become tappable. We may also transition further on the same
        // stream tick if a decision has already been submitted.
        if (_stage != _Stage.mutual &&
            _stage != _Stage.awaitingPeerMatch) {
          DebugLog.reveal('reveal mutual');
          DebugObserver.instance.setRevealOutcome('mutual');
          setState(() => _stage = _Stage.mutual);
          // RLS on photos just opened — refetch the peer photo.
          unawaited(_loadPeerPhoto());
        }
    }

    // Mutual reveal reached — now drive the match-decision phase.
    final decision = repo.decisionOutcomeFor(
      rows,
      selfId: selfId,
      peerId: peerId,
    );
    _log.info('Match decision outcome — $decision');
    switch (decision) {
      case MatchDecisionOutcome.awaitingPeer:
        // Either nobody has decided yet (stay on mutual view) or self
        // already decided 'match' and we're waiting on the peer
        // (already on awaitingPeerMatch). Nothing to do here.
        return;
      case MatchDecisionOutcome.passed:
        DebugLog.reveal('match decision: peer -> pass');
        DebugObserver.instance.setRevealOutcome('passed');
        setState(() => _stage = _Stage.noMatch);
        return;
      case MatchDecisionOutcome.mutualMatch:
        DebugLog.reveal('match decision: both -> match');
        DebugObserver.instance.setRevealOutcome('matched');
        setState(() => _stage = _Stage.matched);
        await _persistMatch(self: self, match: match, callId: callId);
    }
  }

  /// Writes the permanent match + opens the conversation. Idempotent —
  /// `_matchPersisted` guards against the reveal stream firing twice.
  Future<void> _persistMatch({
    required dynamic self,
    required ActiveMatch match,
    required String? callId,
  }) async {
    if (_matchPersisted) return;
    _matchPersisted = true;
    final selfId = self.userId as String;

    if (callId != null) {
      final repo = ref.read(revealRepositoryProvider);
      try {
        await repo?.createMatch(
          callId: callId,
          userA: selfId,
          userB: match.candidate.userId,
          compatibilityScore: match.score.percentage,
        );
      } catch (e, st) {
        _log.error('createMatch failed', e, st);
      }
    }

    // Keep the Discover "matches" surface in sync.
    try {
      await ref.read(discoverRepositoryProvider).recordMutualMatch(
            self: self,
            candidate: match.candidate,
            score: match.score,
          );
      final sourceId = match.sourceSuggestionId;
      if (sourceId != null) {
        await ref
            .read(discoverRepositoryProvider)
            .markSuggestionMatched(sourceId);
      }
    } catch (e, st) {
      _log.error('recordMutualMatch failed (non-fatal)', e, st);
    }

    // Open the private conversation — the only place chat is created.
    // We capture the id so the matched view can offer a direct
    // "Envoyer un message" CTA without forcing a detour through Messages.
    try {
      final conv = await ref
          .read(messagingRepositoryProvider)
          .ensureConversation(
            currentUserId: selfId,
            peer: match.candidate,
          );
      if (mounted) {
        setState(() => _matchedConversationId = conv.id);
      }
    } catch (e, st) {
      _log.error('ensureConversation failed (non-fatal)', e, st);
    }
  }

  void _pass() async {
    final match = ref.read(activeMatchProvider);
    final self = ref.read(currentProfileProvider).asData?.value;
    if (match != null && self != null) {
      _log.info('Passed candidate uid=${match.candidate.userId}');
      final callId = ref.read(activeCallIdProvider);
      final revealRepo = ref.read(revealRepositoryProvider);
      if (callId != null && revealRepo != null) {
        // Record the explicit pass so the peer's screen resolves to
        // "declined" instead of waiting forever.
        try {
          await revealRepo.submitReveal(
            callId: callId,
            userId: self.userId,
            revealed: false,
          );
          DebugLog.reveal('reveal submitted (pass)'); // debug-observer
        } catch (e, st) {
          _log.error('submitReveal(false) failed', e, st);
        }
      } else {
        await ref.read(matchingRepositoryProvider).recordDecision(
              self: self,
              candidate: match.candidate,
              wantsMatch: false,
            );
      }
    }
    if (!mounted) return;
    _revealSub?.cancel();
    _revealTimeoutTimer?.cancel();
    // Reset the shared match state immediately. _findAnother also does this,
    // but resetting here guarantees no stale match leaks into a subsequent
    // flow regardless of which exit the user takes from _PassedView.
    ref.read(activeMatchProvider.notifier).state = null;
    _log.info('Matching state reset');
    setState(() => _stage = _Stage.passed);
  }

  void _backHome() {
    ref.read(activeMatchProvider.notifier).state = null;
    _log.info('Matching state reset');
    if (!mounted) return;
    context.goNamed(AppRoute.home.name);
  }

  void _findAnother() {
    ref.read(activeMatchProvider.notifier).state = null;
    _log.info('Matching state reset');
    if (!mounted) return;
    _log.info('New match flow started');
    // Use pushReplacement instead of goNamed so the matching → call →
    // post-call chain keeps a sane back stack: the cross / Annuler buttons
    // on the next MatchingScreen need a real route to pop back to.
    context.pushReplacementNamed(AppRoute.matching.name);
  }

  void _openConversation() {
    final id = _matchedConversationId;
    if (id == null) return;
    ref.read(activeMatchProvider.notifier).state = null;
    _log.info('Opening conversation $id after match');
    if (!mounted) return;
    // pushReplacement: the matched post-call should not sit underneath
    // the chat in the back stack — closing the chat returns the user to
    // Home / wherever the router redirect lands them.
    context.pushReplacementNamed(
      AppRoute.conversation.name,
      pathParameters: {'id': id},
    );
  }

  @override
  void dispose() {
    _peerDecisionTimer?.cancel();
    _revealTimeoutTimer?.cancel();
    _revealSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final match = ref.watch(activeMatchProvider);

    final body = switch (_stage) {
      // Decide — peer photo MASKED (no local "show photo" toggle any
      // more); single "Révéler" CTA which submits reveal=true and
      // moves to waiting until the peer reveals too.
      _Stage.decide => _DecideView(
          match: match,
          onReveal: _submitReveal,
        ),
      _Stage.waiting => _WaitingView(
          timedOut: _revealTimedOut,
          onKeepWaiting: _keepWaiting,
          onGiveUp: _pass,
        ),
      // Mutual reveal — BOTH peers submitted revealed=true. Photo
      // shown large-format here, Match/Pass buttons available.
      _Stage.mutual => _MutualRevealView(
          match: match,
          peerPhotoBytes: _peerPhotoBytes,
          onMatch: _confirmMatch,
          onPass: _passAfterReveal,
        ),
      // User tapped Match — waiting for the peer's decision before any
      // match/conversation row is written.
      _Stage.awaitingPeerMatch => _AwaitingPeerMatchView(
          match: match,
          peerPhotoBytes: _peerPhotoBytes,
          onCancel: _passAfterReveal,
        ),
      _Stage.matched => _ResolvedView(
          matched: true,
          onBackHome: _backHome,
          onFindAnother: _findAnother,
          // Surfaced only once the conversation has been ensured server-side.
          onSendMessage:
              _matchedConversationId == null ? null : _openConversation,
        ),
      _Stage.noMatch => _ResolvedView(
          matched: false,
          onBackHome: _backHome,
          onFindAnother: _findAnother,
          onSendMessage: null,
        ),
      _Stage.passed => _PassedView(
          onFindAnother: _findAnother,
          onBackHome: _backHome,
        ),
    };

    return AppScaffold(
      glowIntensity: _stage == _Stage.matched ? 1.2 : 0.6,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(l10n.postCallTitle),
        actions: [
          if (match != null)
            IconButton(
              tooltip:
                  Localizations.localeOf(context).languageCode == 'fr'
                      ? 'Signaler'
                      : 'Report',
              icon: const Icon(Icons.flag_outlined),
              onPressed: () => showReportSheet(
                context,
                reportedUserId: match.candidate.userId,
                reportedDisplayName: match.candidate.firstName,
              ),
            ),
        ],
      ),
      body: body,
    );
  }
}

// ---------------------------------------------------------------------------
// Stage views
// ---------------------------------------------------------------------------

/// Decide stage — peer photo is ALWAYS masked here. Tapping "Révéler"
/// commits the user's reveal=true to the server and moves the screen
/// to the waiting state until the peer reveals too. The large photo
/// + Match/Pass buttons only appear in [_MutualRevealView] once BOTH
/// peers have revealed.
class _DecideView extends StatelessWidget {
  const _DecideView({
    required this.match,
    required this.onReveal,
  });

  final ActiveMatch? match;
  final VoidCallback onReveal;

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
        // Always masked at this stage — `revealed: false` ⇒ silhouette.
        const Center(child: _PhotoReveal(revealed: false, bytes: null)),
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
        AppButton(
          label: l10n.postCallReveal,
          icon: Icons.visibility_outlined,
          size: AppButtonSize.large,
          onPressed: onReveal,
        ),
        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }
}

/// Mutual-reveal stage — BOTH peers submitted revealed=true. Photo
/// shown large-format + Match/Pass buttons. The match row is only
/// created if the user taps Match (in [_PostCallScreenState._confirmMatch]).
class _MutualRevealView extends StatelessWidget {
  const _MutualRevealView({
    required this.match,
    required this.peerPhotoBytes,
    required this.onMatch,
    required this.onPass,
  });

  final ActiveMatch? match;
  final Uint8List? peerPhotoBytes;
  final VoidCallback onMatch;
  final VoidCallback onPass;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final candidate = match?.candidate;
    return Column(
      children: [
        const SizedBox(height: AppSpacing.lg),
        Text(
          'C\'est réciproque ✨',
          textAlign: TextAlign.center,
          style: AppTypography.h2,
        ),
        const SizedBox(height: AppSpacing.sm),
        const Spacer(),
        // peerPhotoBytes lands asynchronously after the mutual outcome
        // triggers _loadPeerPhoto. While the bytes are in flight, show
        // a soft skeleton — NOT the "Photo cachée" silhouette which
        // would lie about the state. If bytes never arrive (peer has
        // no photo somehow, RLS error), the skeleton is replaced by an
        // explicit message after a short timeout.
        Center(
          child: peerPhotoBytes == null
              ? const _PhotoLoadingSkeleton()
              : _PhotoReveal(revealed: true, bytes: peerPhotoBytes),
        ),
        const SizedBox(height: AppSpacing.lg),
        if (candidate != null)
          Text(
            candidate.age != null
                ? '${candidate.firstName ?? '—'}, ${candidate.age}'
                : candidate.firstName ?? '—',
            style: AppTypography.h2,
          ),
        const Spacer(),
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
        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }
}

/// Shown after the user tapped "Je veux matcher" but the peer hasn't
/// confirmed their decision yet. No match row exists yet — the screen
/// is reactive, the realtime stream will flip it to matched or noMatch
/// as soon as the peer picks Match or Pass.
class _AwaitingPeerMatchView extends StatelessWidget {
  const _AwaitingPeerMatchView({
    required this.match,
    required this.peerPhotoBytes,
    required this.onCancel,
  });

  final ActiveMatch? match;
  final Uint8List? peerPhotoBytes;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final candidate = match?.candidate;
    return Column(
      children: [
        const SizedBox(height: AppSpacing.lg),
        Text(
          'Match envoyé ✨',
          textAlign: TextAlign.center,
          style: AppTypography.h2,
        ),
        const SizedBox(height: AppSpacing.sm),
        Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: Text(
            'En attente de la réponse de votre date…',
            textAlign: TextAlign.center,
            style:
                AppTypography.body.copyWith(color: AppColors.textSecondary),
          ),
        ),
        const Spacer(),
        Center(
          child: peerPhotoBytes == null
              ? const _PhotoLoadingSkeleton()
              : _PhotoReveal(revealed: true, bytes: peerPhotoBytes),
        ),
        const SizedBox(height: AppSpacing.lg),
        if (candidate != null)
          Text(
            candidate.age != null
                ? '${candidate.firstName ?? '—'}, ${candidate.age}'
                : candidate.firstName ?? '—',
            style: AppTypography.h2,
          ),
        const SizedBox(height: AppSpacing.md),
        const SizedBox(
          height: 28,
          width: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2.4,
            valueColor: AlwaysStoppedAnimation(AppColors.brandPink),
          ),
        ),
        const Spacer(),
        AppButton(
          label: 'Annuler',
          variant: AppButtonVariant.secondary,
          size: AppButtonSize.large,
          onPressed: onCancel,
        ),
        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }
}

/// Lightweight placeholder shown on the mutual-reveal view between the
/// outcome flip and the peer photo bytes landing. Matches the dimensions
/// of `_PhotoReveal` post-reveal so the layout doesn't jump when the
/// real image swaps in.
class _PhotoLoadingSkeleton extends StatelessWidget {
  const _PhotoLoadingSkeleton();

  static const double _maxWidth = 360;
  static const double _aspect = 4 / 5;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.clamp(0.0, _maxWidth);
        final height = width / _aspect;
        return Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            color: AppColors.surface,
            border: Border.all(color: AppColors.hairlineSoft),
          ),
          alignment: Alignment.center,
          child: const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              valueColor: AlwaysStoppedAnimation(AppColors.brandPink),
            ),
          ),
        );
      },
    );
  }
}

class _WaitingView extends StatelessWidget {
  const _WaitingView({
    required this.timedOut,
    required this.onKeepWaiting,
    required this.onGiveUp,
  });

  /// True once the reveal wait has exceeded its timeout — surfaces an
  /// explicit way out instead of an endless spinner.
  final bool timedOut;
  final VoidCallback onKeepWaiting;
  final VoidCallback onGiveUp;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
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
              'Votre date réfléchit…',
              textAlign: TextAlign.center,
              style:
                  AppTypography.body.copyWith(color: AppColors.textSecondary),
            ),
            if (timedOut) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Cette personne n\'a pas encore répondu.',
                textAlign: TextAlign.center,
                style: AppTypography.caption.copyWith(
                  color: AppColors.textTertiary,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              AppButton(
                label: 'Continuer à attendre',
                icon: Icons.hourglass_bottom_rounded,
                size: AppButtonSize.large,
                onPressed: onKeepWaiting,
              ),
              const SizedBox(height: AppSpacing.sm),
              AppButton(
                label: 'Passer',
                variant: AppButtonVariant.secondary,
                size: AppButtonSize.large,
                onPressed: onGiveUp,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ResolvedView extends StatelessWidget {
  const _ResolvedView({
    required this.matched,
    required this.onBackHome,
    required this.onFindAnother,
    required this.onSendMessage,
  });

  final bool matched;
  final VoidCallback onBackHome;
  final VoidCallback onFindAnother;
  /// Null until [ensureConversation] has returned. When null the
  /// "Envoyer un message" CTA is hidden so the user never taps a button
  /// that would route to a missing chat.
  final VoidCallback? onSendMessage;

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
          matched ? 'C\'est réciproque ✨' : 'Pas cette fois',
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
        if (matched) ...[
          if (onSendMessage != null) ...[
            AppButton(
              label: 'Envoyer un message',
              icon: Icons.chat_bubble_rounded,
              size: AppButtonSize.large,
              onPressed: onSendMessage,
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
          AppButton(
            label: l10n.postCallBackHome,
            icon: Icons.home_rounded,
            variant: onSendMessage == null
                ? AppButtonVariant.primary
                : AppButtonVariant.secondary,
            size: AppButtonSize.large,
            onPressed: onBackHome,
          ),
        ] else ...[
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
  const _PassedView({
    required this.onFindAnother,
    required this.onBackHome,
  });

  final VoidCallback onFindAnother;
  final VoidCallback onBackHome;

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
        const SizedBox(height: AppSpacing.sm),
        // Secondary escape — lets the user step out of the date flow
        // entirely instead of being funnelled into another match.
        AppButton(
          label: l10n.postCallBackHome,
          icon: Icons.home_rounded,
          variant: AppButtonVariant.secondary,
          onPressed: onBackHome,
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

  /// Pre-reveal — still a circular silhouette (the "mystery" stage of
  /// the product). Size kept reasonable so it doesn't dominate the
  /// pre-reveal screen.
  static const double _preRevealSize = 220;

  /// Post-reveal — a large, rounded-rectangle portrait. ~85 % of the
  /// screen width / capped at 360 dp so it stays inside the safe area
  /// on every iPhone, and 4:5 aspect (Instagram-style portrait) so the
  /// face fills the frame. This is the emotional moment of the app;
  /// the old 220 px circle made it look like a list-tile avatar.
  static const double _revealMaxWidth = 360;
  static const double _revealAspect = 4 / 5;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    if (!revealed || bytes == null) {
      return Column(
        children: [
          Stack(
            alignment: Alignment.center,
            children: [
              const BlurredAvatar(size: _preRevealSize),
              if (bytes != null)
                ClipOval(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                    child: const SizedBox(
                      width: _preRevealSize,
                      height: _preRevealSize,
                    ),
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

    // Reveal — large portrait card with a brand-pink glow + a soft
    // "developing from blur" animation. The image fills the card via
    // BoxFit.cover so a tall portrait shows the face without letterbox.
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.clamp(0.0, _revealMaxWidth);
        final height = width / _revealAspect;
        return Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: AppColors.brandPink.withValues(alpha: 0.32),
                blurRadius: 36,
                spreadRadius: 2,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 26, end: 0),
              duration: const Duration(milliseconds: 1100),
              curve: Curves.easeOutCubic,
              builder: (context, sigma, child) {
                return ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                  child: child,
                );
              },
              child: Image.memory(
                bytes!,
                width: width,
                height: height,
                fit: BoxFit.cover,
              ),
            ),
          ),
        )
            .animate()
            .scale(
              duration: 520.ms,
              begin: const Offset(0.92, 0.92),
              end: const Offset(1, 1),
              curve: Curves.easeOutBack,
            )
            .fadeIn(duration: 380.ms);
      },
    );
  }
}
