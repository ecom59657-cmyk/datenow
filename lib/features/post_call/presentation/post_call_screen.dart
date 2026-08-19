import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/app_routes.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/debug/debug_observer.dart';
import '../../../core/utils/logger.dart';
import '../../../core/utils/profile_format.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/app_button.dart';
import '../../../shared/widgets/app_scaffold.dart';
import '../../../shared/widgets/veil.dart';
import '../../discover/data/discover_repository.dart';
import '../../matching/data/matching_repository.dart';
import '../../messaging/data/messaging_repository.dart';
import '../../matching/domain/active_match.dart';
import '../../matching/presentation/providers/active_match_provider.dart';
import '../../profile/presentation/edit/providers/profile_photos_provider.dart';
import '../../profile_setup/data/profile_repository.dart';
import '../../profile_setup/domain/user_profile.dart';
import '../../profile_setup/presentation/providers/profile_provider.dart';
import '../../profile_setup/presentation/widgets/blurred_avatar.dart';
import '../../settings/presentation/widgets/destructive_dialog.dart';
import '../../safety/presentation/report_sheet.dart';
import '../data/reveal_repository.dart';

/// Post-call decision screen. Reveals the candidate photo + compatibility
/// score and lets the user match or pass. Real photos surface **only** here.
class PostCallScreen extends ConsumerStatefulWidget {
  const PostCallScreen({super.key});

  @override
  ConsumerState<PostCallScreen> createState() => _PostCallScreenState();
}

/// Local view stages. Computed from [PostCallStage.fromRows] — the
/// realtime `reveals` stream is the single source of truth. User taps
/// only write to Supabase; the listener recomputes the stage on every
/// emit and both clients converge to the same value.
///
/// `mutual` covers both "both pending" AND "peer wants match, self still
/// deciding" — UI is identical (Match/Pass buttons live). Same for
/// `noMatch` vs `passed`: noMatch = peer pulled out of the match, passed
/// = self pulled out.
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
  /// peer closed the app or never decides. Kept short (30 s): past that
  /// the screen reads as "broken / ghosted" rather than "still loading".
  static const _revealTimeout = Duration(seconds: 30);

  /// Hard cap on the peer-photo fetch. On timeout / 404 / RLS block the
  /// reveal must still be usable, so we stop showing a spinner and fall
  /// back to a premium initial avatar — the decision is never blocked.
  static const _photoLoadTimeout = Duration(seconds: 10);

  _Stage _stage = _Stage.decide;

  /// How many times the user has asked for another waiting window. Bounded
  /// so the screen cannot become an infinite hold: past [_maxRearms] the
  /// only remaining choices are to come back later or to decline.
  int _waitRearmCount = 0;
  static const _maxRearms = 3;
  Uint8List? _peerPhotoBytes;
  // True while the peer-photo fetch is in flight. Flips false once the
  // fetch resolves (success, null, error or timeout) so the reveal card
  // can swap its spinner for the fallback avatar instead of hanging.
  bool _peerPhotoLoading = true;
  Timer? _peerDecisionTimer;
  Timer? _revealTimeoutTimer;
  bool _revealTimedOut = false;
  StreamSubscription<List<RevealRow>>? _revealSub;
  bool _matchPersisted = false;

  /// Suspense window after the user taps Match: a finite, VISIBLE 15 s
  /// countdown waiting for the peer's match decision — never an endless
  /// spinner. This window IS the mutual-decision window: if the peer doesn't
  /// match within it, the date is over and no match may form afterwards. On
  /// expiry we therefore overwrite our own `decision` to `'pass'` server-side
  /// (the only non-'match' value the schema + create_match_if_mutual already
  /// understand → no migration), which guarantees a late peer 'match' can
  /// never satisfy the `COUNT(decision='match')=2` gate. If the peer matches
  /// BEFORE 0, the realtime stream resolves to `matched` exactly as today
  /// (Cas A) and the countdown is cancelled before any pass is written.
  static const _awaitPeerSeconds = 15;
  Timer? _awaitTimer;
  int _awaitCountdown = _awaitPeerSeconds;
  bool _awaitPeerTimedOut = false;

  /// Lets the photo reveal animation play before the 15 s countdown starts —
  /// the count begins "once the photo is fully revealed", not the instant we
  /// reach mutual. Matches the reveal animation length in [_RevealPhotoCard].
  static const _revealAnimDuration = Duration(milliseconds: 1100);
  Timer? _revealDelayTimer;

  /// Set once `_persistMatch` resolves with a conversation id — drives
  /// the "Envoyer un message" CTA on the matched view. Stays null on a
  /// `RevealOutcome.declined` outcome.
  String? _matchedConversationId;

  @override
  void initState() {
    super.initState();
    DebugObserver.instance.setPhase('reveal');
    _loadPeerPhoto();
    // Eager realtime subscription — must run BEFORE the user taps
    // anything so a hot-restart / screen rebuild / re-entry always
    // converges from server truth. Deferred one frame so the providers
    // (activeMatchProvider / activeCallIdProvider) are guaranteed
    // initialised.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _attachRevealSub();
      // Auto-reveal: the photo reveal is no longer a user action — we submit
      // revealed=true immediately so both peers land on the photo + Match/Pass
      // view (with the 15 s decision countdown) without an extra tap.
      _autoReveal();
    });
  }

  bool _autoRevealed = false;

  /// Submits revealed=true automatically (no "Révéler" button). Idempotent;
  /// also re-triggered from [_onReveals] if the stage is still pre-reveal
  /// (e.g. the stream emitted before our write landed).
  void _autoReveal() {
    if (_autoRevealed) return;
    _autoRevealed = true;
    _submitReveal();
  }

  /// Attaches the realtime `reveals` subscription if it isn't already.
  /// Idempotent: safe to call from initState + from any retry path.
  void _attachRevealSub() {
    if (_revealSub != null) return;
    final callId = ref.read(activeCallIdProvider);
    final match = ref.read(activeMatchProvider);
    final self = ref.read(currentProfileProvider).asData?.value;
    final repo = ref.read(revealRepositoryProvider);
    if (callId == null || match == null || self == null || repo == null) {
      _log.info(
        'attachRevealSub deferred — '
        'callId=${callId != null}, match=${match != null}, '
        'self=${self != null}, repo=${repo != null}',
      );
      return;
    }
    _log.info('attachRevealSub callId=$callId selfId=${self.userId}');
    _revealSub = repo.watchReveals(callId).listen(
      (rows) => _onReveals(
        rows,
        callId: callId,
        self: self,
        match: match,
      ),
      onError: (e, st) => _log.error('watchReveals error', e, st),
    );
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
    if (mounted) setState(() => _peerPhotoLoading = true);

    // The whole fetch (profile refetch + bytes download) is hard-capped
    // at [_photoLoadTimeout]. On timeout / RLS block / 404 / network
    // error we keep bytes null and let the reveal card show its premium
    // fallback avatar — the user is NEVER left on an endless spinner.
    Uint8List? bytes;
    try {
      bytes = await () async {
        // Reuse the path already carried on the match when present; only hit
        // the profile row when it isn't known yet (pre-reveal RLS). Avoids a
        // redundant profile read.
        var url = match.candidate.primaryPhotoUrl;
        if (url == null || url.isEmpty) {
          url = (await profileRepo.getProfile(peerId))?.primaryPhotoUrl;
        }
        _log.info('loadPeerPhoto: primaryPhotoUrl=${url ?? '∅'}');
        if (url == null || url.isEmpty) return null;
        // Serve from / populate the shared session cache so the matched-
        // profile screen reuses this download instead of fetching the same
        // photo again. A cached null (pre-reveal RLS block) is treated as a
        // miss → refetched, so the reveal still loads once access opens.
        final current = ref.read(photoBytesProvider(url));
        final cached = current.asData?.value;
        if (cached != null) return cached;
        if (current.hasValue) ref.invalidate(photoBytesProvider(url));
        return ref.read(photoBytesProvider(url).future);
      }()
          .timeout(_photoLoadTimeout);
      _log.info(
        'loadPeerPhoto: bytes=${bytes == null ? '∅ (null)' : '${bytes.length} bytes'}',
      );
    } catch (e, st) {
      _log.warn('loadPeerPhoto failed/timed out: $e');
      DebugLog.reveal('peer photo load failed → fallback avatar');
      if (e is! Exception) _log.error('loadPeerPhoto', e, st);
    }
    if (!mounted) return;
    setState(() {
      if (bytes != null) _peerPhotoBytes = bytes;
      _peerPhotoLoading = false;
    });
  }

  /// Writes the user's `revealed = true` row. The actual transition to
  /// the waiting / mutual stage is driven by [_onReveals] once the
  /// realtime stream re-emits with the new row — same pattern as for
  /// the match-decision step (single source of truth).
  void _submitReveal() async {
    final match = ref.read(activeMatchProvider);
    final self = ref.read(currentProfileProvider).asData?.value;
    if (match == null || self == null) return;

    // Optimistic UI hint — listener-computed stage will overwrite this
    // a moment later with the exact same value, so no flicker.
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
        DebugLog.reveal('reveal submitted');
      } catch (e, st) {
        _log.error('submitReveal(true) failed', e, st);
      }
      _attachRevealSub(); // no-op if already attached in initState
      _startRevealTimeout();
      return;
    }

    // No callId / no repo. In release this is a broken session, not a
    // demo: fabricating the other person's decision — which is what a
    // coin flip on Random() did here — invents an outcome about a real
    // human being. Nothing is written either way (_confirmMatch bails on
    // a null callId), but the user was still shown "they revealed" or
    // "they passed" as if it had happened. Release now says the reveal
    // could not complete; debug keeps a deterministic path so the flow
    // stays walkable offline.
    _log.warn('No callId/revealRepo — reveal cannot resolve');
    if (!kDebugMode) {
      _peerDecisionTimer = Timer(const Duration(milliseconds: 600), () {
        if (!mounted) return;
        setState(() => _revealTimedOut = true);
      });
      return;
    }
    _peerDecisionTimer = Timer(const Duration(milliseconds: 1600), () {
      if (!mounted) return;
      setState(() => _stage = _Stage.mutual);
    });
  }

  /// Tapped on the mutual-reveal view when the user confirms the match.
  /// Writes *only* `decision = 'match'` on the user's own row. The
  /// transition to matched (when the peer also matches) is handled by
  /// [_onReveals] once the realtime stream re-emits — same single
  /// source of truth as the photo reveal step.
  void _confirmMatch() async {
    final self = ref.read(currentProfileProvider).asData?.value;
    final callId = ref.read(activeCallIdProvider);
    final revealRepo = ref.read(revealRepositoryProvider);
    if (self == null || callId == null || revealRepo == null) return;
    // Optimistic hint: the listener will compute exactly the same
    // stage once the upsert's UPDATE event lands in our stream.
    setState(() => _stage = _Stage.awaitingPeerMatch);
    _startAwaitCountdown();
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

  /// Tapped on the mutual-reveal (or awaiting-peer-match) view when the
  /// user passes after seeing the photo. Writes `decision = 'pass'` on
  /// the user's own row — [_onReveals] handles the transition to
  /// passed locally AND will broadcast to the peer's listener so they
  /// see noMatch without any extra round-trip.
  void _passAfterReveal() async {
    final self = ref.read(currentProfileProvider).asData?.value;
    final callId = ref.read(activeCallIdProvider);
    final revealRepo = ref.read(revealRepositoryProvider);
    setState(() => _stage = _Stage.passed);
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
    _revealTimeoutTimer?.cancel();
    // Don't cancel _revealSub here — let the listener observe the
    // peer's eventual converging state for telemetry / debug logs.
    // It will short-circuit on `_stage.isTerminal` anyway.
    ref.read(activeMatchProvider.notifier).state = null;
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

  /// "Continuer à attendre" — give the peer another full window, up to
  /// [_maxRearms] times.
  void _keepWaiting() {
    if (_waitRearmCount >= _maxRearms) return;
    _waitRearmCount++;
    _log.info('Keep waiting ($_waitRearmCount/$_maxRearms)');
    setState(() => _revealTimedOut = false);
    _startRevealTimeout();
  }

  /// Leaves the screen WITHOUT declining — the difference that matters.
  ///
  /// The user's `reveals` row stays at `revealed: true`, so the pair is
  /// still possible if the peer decides later. Until then the only exit
  /// offered besides waiting was "Passer", which writes
  /// `revealed: false` — an irreversible refusal presented as a way off a
  /// screen. People leave because they are done looking at a spinner, not
  /// because they said no.
  ///
  /// Note it does not promise a notification: push is UX plan point 6.
  /// The copy says the answer is kept, which is exactly what happens.
  void _comeBackLater() {
    _log.info('User left the reveal wait without declining');
    _revealTimeoutTimer?.cancel();
    _revealSub?.cancel();
    ref.read(activeMatchProvider.notifier).state = null;
    _backHome();
  }

  /// Explicit, confirmed refusal. Irreversible, so it asks first.
  Future<void> _declineExplicitly() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDestructiveConfirm(
      context: context,
      title: l10n.postCallDeclineConfirmTitle,
      body: l10n.postCallDeclineConfirmBody,
      confirmLabel: l10n.postCallDeclineConfirmAction,
    );
    if (!confirmed || !mounted) return;
    _pass();
  }

  /// Starts the visible 15 s peer-match-decision countdown. Idempotent.
  /// Ticks 15→1; at 0 it flips [_awaitPeerTimedOut] (clean close) WITHOUT
  /// writing any decision. Auto-cancels if the stage moves off
  /// awaitingPeerMatch (e.g. the peer matched → `matched`, Cas A).
  /// On reaching mutual: hold the countdown until the reveal animation has
  /// played (~1.1 s), then start it. Idempotent.
  void _scheduleDecisionCountdown() {
    if (_awaitTimer != null ||
        _revealDelayTimer != null ||
        _awaitPeerTimedOut) {
      return;
    }
    _revealDelayTimer = Timer(_revealAnimDuration, () {
      _revealDelayTimer = null;
      _startAwaitCountdown();
    });
  }

  void _startAwaitCountdown() {
    _revealDelayTimer?.cancel();
    _revealDelayTimer = null;
    if (_awaitTimer != null || _awaitPeerTimedOut) return;
    setState(() => _awaitCountdown = _awaitPeerSeconds);
    _awaitTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted ||
          (_stage != _Stage.mutual && _stage != _Stage.awaitingPeerMatch)) {
        timer.cancel();
        _awaitTimer = null;
        return;
      }
      final next = _awaitCountdown - 1;
      if (next <= 0) {
        timer.cancel();
        _awaitTimer = null;
        // Whether the user had already tapped Match (awaitingPeerMatch) or had
        // not decided (mutual), the window is over with no mutual match.
        final matchedByMe = _stage == _Stage.awaitingPeerMatch;
        _log.info(
          'decision window: 15s elapsed (matchedByMe=$matchedByMe) — closing, '
          'writing decision=pass',
        );
        DebugLog.reveal('decision window timed out (15s) → pass');
        setState(() {
          _awaitCountdown = 0;
          if (matchedByMe) {
            // We matched, the peer did not respond in time → explicit close.
            _awaitPeerTimedOut = true;
          } else {
            // We never decided → treated as a pass (no match).
            _stage = _Stage.passed;
          }
        });
        // Close the decision window server-side (decision=pass) so a late peer
        // 'match' can never form a match. Fire-and-forget.
        unawaited(_closeDecisionWindow());
        return;
      }
      setState(() => _awaitCountdown = next);
    });
  }

  void _cancelAwaitCountdown() {
    _awaitTimer?.cancel();
    _awaitTimer = null;
    _revealDelayTimer?.cancel();
    _revealDelayTimer = null;
  }

  /// Closes the mutual-decision window when the 15 s elapsed: overwrites our
  /// own reveal row to `decision='pass'`. After this, even if the peer taps
  /// Match, `create_match_if_mutual` sees only one `decision='match'` and
  /// raises `no_mutual_reveal` → no late match, no conversation. The peer's
  /// screen also resolves to a clean no-match (their stream sees our 'pass').
  Future<void> _closeDecisionWindow() async {
    final self = ref.read(currentProfileProvider).asData?.value;
    final callId = ref.read(activeCallIdProvider);
    final repo = ref.read(revealRepositoryProvider);
    if (self == null || callId == null || repo == null) return;
    try {
      await repo.submitDecision(
        callId: callId,
        userId: self.userId,
        decision: 'pass',
      );
      _log.info('decision window closed — wrote decision=pass after timeout');
    } catch (e, st) {
      _log.error('closeDecisionWindow (pass after timeout) failed', e, st);
    }
  }

  /// Single source of truth for the local UI stage. Computed from the
  /// live `reveals` rows via [PostCallStage.fromRows], then mapped onto
  /// the local [_Stage] enum the widget renders against. Idempotent:
  /// repeated emits with the same outcome are no-ops, terminal stages
  /// (matched / passed / noMatch) cannot be undone by a later emit.
  Future<void> _onReveals(
    List<RevealRow> rows, {
    required String callId,
    required dynamic self,
    required ActiveMatch match,
  }) async {
    if (!mounted) return;
    final selfId = self.userId as String;
    final peerId = match.candidate.userId;
    final outcome =
        PostCallStage.fromRows(rows, selfId: selfId, peerId: peerId);
    _log.info(
      'Reveal recompute — outcome=$outcome rows=${rows.length} '
      '(local=$_stage)',
    );

    // Terminal stages are not undone by future emits. (The peer might
    // still send decision updates after we left the matched view.)
    if (_stage == _Stage.matched ||
        _stage == _Stage.passed ||
        _stage == _Stage.noMatch) {
      return;
    }

    // Once the 15 s peer-decision window has elapsed the experience is closed:
    // we wrote decision='pass' (see _closeDecisionWindow), so no match can
    // form anymore. Freeze the UI on the clean-close view — a late peer
    // decision (or our own 'pass' echoing back through the stream) must not
    // yank the user into any other stage.
    if (_awaitPeerTimedOut) return;

    // Map the (mine, theirs) outcome onto the local view stage.
    final next = switch (outcome) {
      PostCallStage.pending => _stage, // stay where we are
      PostCallStage.selfDecideReveal => _Stage.decide,
      PostCallStage.waitingForPeerReveal => _Stage.waiting,
      PostCallStage.selfPassedAtReveal => _Stage.passed,
      PostCallStage.peerPassedAtReveal => _Stage.noMatch,
      PostCallStage.mutual => _Stage.mutual,
      PostCallStage.peerWantsMatch => _Stage.mutual,
      PostCallStage.awaitingPeerMatch => _Stage.awaitingPeerMatch,
      PostCallStage.matched => _Stage.matched,
      PostCallStage.selfPassed => _Stage.passed,
      PostCallStage.peerPassed => _Stage.noMatch,
    };

    if (next == _stage) return; // idempotent

    // Side effects that run on the *first* transition into a stage.
    final wasMutualEntry =
        _stage != _Stage.mutual && _stage != _Stage.awaitingPeerMatch;
    if (next == _Stage.mutual && wasMutualEntry) {
      DebugLog.reveal('reveal mutual');
      DebugObserver.instance.setRevealOutcome('mutual');
      _revealTimeoutTimer?.cancel();
      unawaited(_loadPeerPhoto());
    }
    if (next == _Stage.noMatch) {
      DebugLog.reveal('match decision: declined');
      DebugObserver.instance.setRevealOutcome('declined');
      _revealTimeoutTimer?.cancel();
    }
    if (next == _Stage.passed) {
      DebugLog.reveal('match decision: self pass observed');
      _revealTimeoutTimer?.cancel();
    }
    // The 15 s decision window spans the photo-revealed phase. On reaching
    // mutual we let the reveal animation play first, then start the count; if
    // we land directly on awaitingPeerMatch (re-entry with our match already
    // recorded) we start it right away. Cancel it as soon as the stage resolves.
    if (next == _Stage.mutual) {
      _scheduleDecisionCountdown();
    } else if (next == _Stage.awaitingPeerMatch) {
      _startAwaitCountdown();
    } else {
      _cancelAwaitCountdown();
    }
    // Defensive auto-reveal: if we're still pre-reveal (peer acted first, our
    // write hasn't landed), reveal automatically — no button.
    if (next == _Stage.decide) {
      _autoReveal();
    }

    setState(() => _stage = next);

    if (next == _Stage.matched) {
      DebugLog.reveal('match decision: both -> match');
      DebugObserver.instance.setRevealOutcome('matched');
      _revealTimeoutTimer?.cancel();
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
    _awaitTimer?.cancel();
    _revealDelayTimer?.cancel();
    _revealSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final match = ref.watch(activeMatchProvider);

    final body = switch (_stage) {
      // Decide — peer photo MASKED (no local "show photo" toggle any
      // Reveal is automatic now — this is a brief transition while our
      // revealed=true write lands and the peer's row converges. No button.
      _Stage.decide => const _RevealingView(),
      _Stage.waiting => _WaitingView(
          timedOut: _revealTimedOut,
          canKeepWaiting: _waitRearmCount < _maxRearms,
          onKeepWaiting: _keepWaiting,
          onComeBackLater: _comeBackLater,
          onDecline: _declineExplicitly,
        ),
      // Mutual reveal — BOTH peers revealed. Photo shown large-format with the
      // 15 s decision countdown + Match/Pass buttons.
      _Stage.mutual => _MutualRevealView(
          match: match,
          peerPhotoBytes: _peerPhotoBytes,
          peerPhotoLoading: _peerPhotoLoading,
          countdown: _awaitCountdown,
          onMatch: _confirmMatch,
          onPass: _passAfterReveal,
        ),
      // User tapped Match — a visible 15 s countdown waits for the peer's
      // decision before any match/conversation row is written. On expiry the
      // view closes cleanly (no decision written).
      _Stage.awaitingPeerMatch => _AwaitingPeerMatchView(
          match: match,
          peerPhotoBytes: _peerPhotoBytes,
          countdown: _awaitCountdown,
          timedOut: _awaitPeerTimedOut,
          onBackHome: _backHome,
          onFindAnother: _findAnother,
        ),
      _Stage.matched => _ResolvedView(
          matched: true,
          peerCandidate: match?.candidate,
          peerPhotoBytes: _peerPhotoBytes,
          onBackHome: _backHome,
          onFindAnother: _findAnother,
          // Surfaced only once the conversation has been ensured server-side.
          onSendMessage:
              _matchedConversationId == null ? null : _openConversation,
        ),
      _Stage.noMatch => _ResolvedView(
          matched: false,
          peerCandidate: null,
          peerPhotoBytes: null,
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

/// Brief transition shown while the automatic reveal write lands and both
/// rows converge to mutual. No user action — the photo + Match/Pass + 15 s
/// countdown appear in [_MutualRevealView] as soon as both peers have revealed.
class _RevealingView extends StatelessWidget {
  const _RevealingView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            height: 36,
            width: 36,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              valueColor: AlwaysStoppedAnimation(AppColors.bordeaux),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            'Révélation…',
            textAlign: TextAlign.center,
            style: AppTypography.body.copyWith(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// Mutual-reveal stage — the emotional reveal + decision moment. The peer
/// photo auto-reveals (blur → sharp + premium zoom + magenta glow), then the
/// 15 s neon countdown ticks. Match writes the row only when both peers tap it
/// (in [_PostCallScreenState._confirmMatch]).
///
/// Minimal copy on purpose: only "À toi de jouer ! ✨", the countdown, the
/// name/age and the two buttons — the photo is the dominant element.
class _MutualRevealView extends StatefulWidget {
  const _MutualRevealView({
    required this.match,
    required this.peerPhotoBytes,
    required this.peerPhotoLoading,
    required this.countdown,
    required this.onMatch,
    required this.onPass,
  });

  final ActiveMatch? match;
  final Uint8List? peerPhotoBytes;

  /// True while the photo is still being fetched (bounded by the 10 s
  /// load timeout). Once false with null bytes the card shows the
  /// fallback avatar instead of a spinner.
  final bool peerPhotoLoading;

  /// Seconds left in the 15 s decision window (starts once the reveal anim
  /// has played) — shown in the neon circle.
  final int countdown;
  final VoidCallback onMatch;
  final VoidCallback onPass;

  @override
  State<_MutualRevealView> createState() => _MutualRevealViewState();
}

class _MutualRevealViewState extends State<_MutualRevealView> {
  /// The Veil starts where the date left it — v2, the level both people
  /// were looking at when the call ended — and only then lifts. Starting
  /// from a sharp photo would throw away the whole point of the product.
  VeilLevel _level = VeilLevel.v2;

  /// The two decision buttons stay out until [VeilTiming.decisionUnlock].
  /// Offering "On continue / Pas cette fois" while the face is still
  /// resolving forces a choice about someone the user has not yet seen.
  bool _decisionOffered = false;

  final List<Timer> _beats = [];

  @override
  void initState() {
    super.initState();
    _playReveal();
  }

  /// The choreography. The 400 ms of stillness after the first haptic is
  /// deliberate: it is the beat that makes the reveal land as an event.
  void _playReveal() {
    HapticFeedback.selectionClick();
    _beats.add(Timer(VeilTiming.stillness, () {
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      setState(() => _level = VeilLevel.v1);
    }));
    _beats.add(Timer(VeilTiming.settle, () {
      if (!mounted) return;
      HapticFeedback.lightImpact();
    }));
    _beats.add(Timer(VeilTiming.decisionUnlock, () {
      if (!mounted) return;
      setState(() => _decisionOffered = true);
    }));
  }

  @override
  void dispose() {
    for (final beat in _beats) {
      beat.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final candidate = widget.match?.candidate;
    return Column(
      children: [
        const SizedBox(height: AppSpacing.sm),
        Text(
          'À toi de jouer ! ✨',
          textAlign: TextAlign.center,
          style: AppTypography.h1,
        ),
        const SizedBox(height: AppSpacing.md),
        // Countdown, sitting between the title and the photo.
        _CountdownCircle(seconds: widget.countdown),
        const SizedBox(height: AppSpacing.md),
        // Dominant reveal photo — fills the remaining vertical space, so it
        // scales up on big iPhones without ever overflowing small ones.
        Expanded(
          child: Center(
            child: AspectRatio(
              aspectRatio: 4 / 5,
              child: AnimatedScale(
                // 0.94 → 1 travelling with the blur, so the photo settles
                // towards the viewer as it resolves.
                scale: _level == VeilLevel.v1 ? 1.0 : 0.94,
                duration: VeilTiming.reveal,
                curve: VeilTiming.curve,
                child: _RevealPhotoCard(
                  bytes: widget.peerPhotoBytes,
                  loading: widget.peerPhotoLoading,
                  fallbackName: candidate?.firstName,
                  level: _level,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        if (candidate != null)
          Text(
            formatProfileNameAge(
              l10n,
              firstName: candidate.firstName,
              age: candidate.age,
            ),
            style: AppTypography.h2,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        const SizedBox(height: AppSpacing.lg),
        // Reserved height: the buttons fade in where they will sit, so the
        // photo never jumps upward at 1600 ms.
        AnimatedOpacity(
          opacity: _decisionOffered ? 1 : 0,
          duration: AppDurations.normal,
          child: IgnorePointer(
            ignoring: !_decisionOffered,
            child: Column(
              children: [
                AppButton(
                  label: l10n.postCallMatch,
                  icon: Icons.favorite_rounded,
                  size: AppButtonSize.large,
                  onPressed: widget.onMatch,
                ),
                const SizedBox(height: AppSpacing.sm),
                AppButton(
                  label: l10n.postCallPass,
                  variant: AppButtonVariant.secondary,
                  size: AppButtonSize.large,
                  onPressed: widget.onPass,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }
}

/// Neon countdown circle — "N" over "sec" inside a glowing brand-pink ring.
class _CountdownCircle extends StatelessWidget {
  const _CountdownCircle({required this.seconds});

  final int seconds;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 76,
      height: 76,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.bordeaux.withValues(alpha: 0.1),
        border: Border.all(color: AppColors.bordeaux, width: 2),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            transitionBuilder: (child, anim) =>
                FadeTransition(opacity: anim, child: child),
            child: Text(
              '$seconds',
              key: ValueKey<int>(seconds),
              style: AppTypography.h1.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                height: 1.0,
              ),
            ),
          ),
          Text(
            'sec',
            style: AppTypography.caption.copyWith(
              color: AppColors.bordeaux,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }
}

/// The reveal photo: rounded card with a magenta/violet glow that develops
/// from blur to sharp with a subtle zoom-settle — the "I finally see them"
/// moment. Fills whatever box it's given (used inside an AspectRatio).
class _RevealPhotoCard extends StatelessWidget {
  const _RevealPhotoCard({
    required this.bytes,
    required this.level,
    this.loading = false,
    this.fallbackName,
  });

  final Uint8List? bytes;

  /// Where the Veil currently sits. The parent walks it from
  /// [VeilLevel.v2] (how the date ended) to [VeilLevel.v1].
  final VeilLevel level;

  /// While true (and bytes still null) we show a brief spinner. Bounded
  /// by the parent's 10 s photo-load timeout — it can never hang.
  final bool loading;

  /// Peer first name, used to render the fallback initial when the photo
  /// can't be loaded (timeout / 404 / RLS block).
  final String? fallbackName;

  @override
  Widget build(BuildContext context) {
    final Widget content = bytes == null
        ? (loading
            ? const ColoredBox(
                color: AppColors.sand,
                child: Center(
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      valueColor: AlwaysStoppedAnimation(AppColors.bordeaux),
                    ),
                  ),
                ),
              )
            : _PhotoFallback(name: fallbackName))
        : SizedBox.expand(
            child: Image.memory(
              bytes!,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            ),
          );

    // The Veil owns the blur, the warm cast and the grain. The card keeps
    // a hairline instead of the old double bordeaux glow — a coloured halo
    // around the face is the one thing that would cheapen this moment.
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppColors.line),
      ),
      child: Veil(
        level: level,
        shape: VeilShape.card,
        child: content,
      ),
    );
  }
}

/// Premium fallback shown inside the reveal card when the peer photo
/// can't be loaded (timeout / 404 / RLS block). Keeps the same glow
/// frame as the real photo — only the inner content changes — so the
/// reveal stays usable and on-brand instead of an endless spinner. The
/// decision countdown keeps running underneath.
class _PhotoFallback extends StatelessWidget {
  const _PhotoFallback({required this.name});

  final String? name;

  @override
  Widget build(BuildContext context) {
    final trimmed = name?.trim() ?? '';
    final initial =
        trimmed.isEmpty ? '?' : trimmed.substring(0, 1).toUpperCase();
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.bordeauxLight, AppColors.bordeaux],
        ),
      ),
      child: Center(
        child: Text(
          initial,
          style: AppTypography.h1.copyWith(
            color: Colors.white,
            fontSize: 84,
            fontWeight: FontWeight.w800,
            shadows: [
              Shadow(
                color: AppColors.bordeaux.withValues(alpha: 0.6),
                blurRadius: 28,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown after the user tapped "Je veux matcher" but the peer hasn't
/// confirmed their decision yet. No match row exists yet — the screen
/// is reactive, the realtime stream will flip it to matched or noMatch
/// as soon as the peer picks Match or Pass.
/// After the user taps Match: a visible 15 s suspense countdown waiting on the
/// peer's decision. If the peer matches in time the realtime stream flips this
/// screen to `matched` (handled by the parent — Cas A). On expiry [timedOut]
/// becomes true and the view closes the experience cleanly (Cas B): a clear
/// "no response in time" message + Retour accueil / Lancer un nouveau date —
/// never a decision auto-written, never wording that implies a later reply.
class _AwaitingPeerMatchView extends StatelessWidget {
  const _AwaitingPeerMatchView({
    required this.match,
    required this.peerPhotoBytes,
    required this.countdown,
    required this.timedOut,
    required this.onBackHome,
    required this.onFindAnother,
  });

  final ActiveMatch? match;
  final Uint8List? peerPhotoBytes;
  final int countdown;
  final bool timedOut;
  final VoidCallback onBackHome;
  final VoidCallback onFindAnother;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final candidate = match?.candidate;

    // Cas B — the 15 s elapsed without the peer deciding. Close cleanly.
    if (timedOut) {
      return Column(
        children: [
          const Spacer(),
          const Icon(
            Icons.hourglass_bottom_rounded,
            size: 72,
            color: AppColors.textSecondary,
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            'Temps écoulé',
            style: AppTypography.h1,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.sm),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Text(
              'L\'autre personne n\'a pas répondu dans le temps imparti.',
              textAlign: TextAlign.center,
              style:
                  AppTypography.body.copyWith(color: AppColors.textSecondary),
            ),
          ),
          const Spacer(),
          AppButton(
            label: 'Lancer un nouveau date',
            icon: Icons.bolt_rounded,
            size: AppButtonSize.large,
            onPressed: onFindAnother,
          ),
          const SizedBox(height: AppSpacing.sm),
          AppButton(
            label: 'Retour à l\'accueil',
            icon: Icons.home_rounded,
            variant: AppButtonVariant.secondary,
            onPressed: onBackHome,
          ),
          const SizedBox(height: AppSpacing.lg),
        ],
      );
    }

    // Suspense — visible countdown waiting on the peer.
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
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: Text(
            'Nous attendons la décision de l\'autre personne.',
            textAlign: TextAlign.center,
            style: AppTypography.body.copyWith(color: AppColors.textSecondary),
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
            formatProfileNameAge(
              l10n,
              firstName: candidate.firstName,
              age: candidate.age,
            ),
            style: AppTypography.h2,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        const SizedBox(height: AppSpacing.lg),
        // Visible 15 → 1 countdown ring.
        _CountdownBadge(seconds: countdown),
        const Spacer(),
        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }
}

/// Compact countdown pill — a small brand-pink "⏱ N s" that ticks 15 → 1.
/// Kept low-profile so it sits cleanly above the reveal photo without
/// crowding the layout on small iPhones. Pure presentation; the timer lives
/// in the parent state.
class _CountdownBadge extends StatelessWidget {
  const _CountdownBadge({required this.seconds});

  final int seconds;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.bordeaux.withValues(alpha: 0.12),
        borderRadius: AppRadius.brPill,
        border: Border.all(color: AppColors.bordeaux.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.timer_outlined,
              size: 16, color: AppColors.bordeaux),
          const SizedBox(width: 6),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: Text(
              '$seconds s',
              key: ValueKey<int>(seconds),
              style: AppTypography.bodyStrong.copyWith(
                color: Colors.white,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
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
              valueColor: AlwaysStoppedAnimation(AppColors.bordeaux),
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
    required this.canKeepWaiting,
    required this.onKeepWaiting,
    required this.onComeBackLater,
    required this.onDecline,
  });

  /// True once the reveal wait has exceeded its timeout — surfaces an
  /// explicit way out instead of an endless spinner.
  final bool timedOut;

  /// False once the user has used up their waiting windows.
  final bool canKeepWaiting;

  final VoidCallback onKeepWaiting;
  final VoidCallback onComeBackLater;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
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
                valueColor: AlwaysStoppedAnimation(AppColors.bordeaux),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              l10n.postCallWaitingTitle,
              textAlign: TextAlign.center,
              style: AppTypography.body.copyWith(color: AppColors.ink2),
            ),
            if (timedOut) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                l10n.postCallWaitingNoAnswer,
                textAlign: TextAlign.center,
                style: AppTypography.caption,
              ),
              const SizedBox(height: AppSpacing.lg),
              // Three separate intentions, where there used to be two
              // buttons covering three meanings — and where "leave" was
              // wired to the irreversible one.
              if (canKeepWaiting) ...[
                AppButton(
                  label: l10n.postCallKeepWaiting,
                  icon: Icons.hourglass_bottom_rounded,
                  size: AppButtonSize.large,
                  onPressed: onKeepWaiting,
                ),
                const SizedBox(height: AppSpacing.sm),
              ],
              AppButton(
                label: l10n.postCallComeBackLater,
                variant: canKeepWaiting
                    ? AppButtonVariant.secondary
                    : AppButtonVariant.primary,
                size: AppButtonSize.large,
                onPressed: onComeBackLater,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                l10n.postCallComeBackLaterHint,
                textAlign: TextAlign.center,
                style: AppTypography.caption,
              ),
              const SizedBox(height: AppSpacing.sm),
              AppButton(
                label: l10n.postCallDecline,
                variant: AppButtonVariant.ghost,
                size: AppButtonSize.large,
                onPressed: onDecline,
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
    required this.peerCandidate,
    required this.peerPhotoBytes,
    required this.onBackHome,
    required this.onFindAnother,
    required this.onSendMessage,
  });

  final bool matched;
  /// Peer's profile — non-null only on the matched view so the screen
  /// can render their photo + name + age. Null on the no-match view
  /// (we don't want to surface the peer who just declined).
  final UserProfile? peerCandidate;
  /// Peer photo bytes loaded by [_PostCallScreenState._loadPeerPhoto].
  /// Null when still in flight or unavailable — falls back to a soft
  /// gradient circle with the initial.
  final Uint8List? peerPhotoBytes;
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
        if (matched && peerCandidate != null) ...[
          // Premium reveal portrait — same shape as the post-reveal
          // photo card, smaller so the title + name + buttons all fit
          // without a scroll on iPhone SE.
          _MatchAvatar(
            bytes: peerPhotoBytes,
            initial: peerCandidate!.firstName?.characters.first ?? '?',
          ),
          const SizedBox(height: AppSpacing.lg),
        ] else
          Icon(
            matched ? Icons.favorite_rounded : Icons.waving_hand_rounded,
            size: 80,
            color: matched ? AppColors.bordeaux : AppColors.textSecondary,
          ).animate().scale(
                duration: 500.ms,
                curve: Curves.easeOutBack,
                begin: const Offset(0.6, 0.6),
                end: const Offset(1, 1),
              ),
        if (!matched || peerCandidate == null)
          const SizedBox(height: AppSpacing.lg),
        Text(
          matched ? l10n.postCallMatchedTitle : 'Pas cette fois',
          style: AppTypography.h1,
          textAlign: TextAlign.center,
        ),
        if (matched && peerCandidate != null) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            formatProfileNameAge(
              l10n,
              firstName: peerCandidate!.firstName,
              age: peerCandidate!.age,
            ),
            style: AppTypography.h3.copyWith(color: AppColors.textSecondary),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
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

/// Premium avatar shown on the matched view — circular, brand-pink glow,
/// fades the peer's photo in from a blur. Falls back to a brand-gradient
/// circle with the initial when bytes aren't available yet.
class _MatchAvatar extends StatelessWidget {
  const _MatchAvatar({required this.bytes, required this.initial});

  final Uint8List? bytes;
  final String initial;

  static const double _size = 168;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _size,
      height: _size,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.tint,
      ),
      child: ClipOval(
        child: bytes == null
            ? Center(
                child: Text(
                  initial.toUpperCase(),
                  style: AppTypography.h1
                      .copyWith(color: Colors.white, fontSize: 56),
                ),
              )
            : TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 18, end: 0),
                duration: const Duration(milliseconds: 900),
                curve: Curves.easeOutCubic,
                builder: (context, sigma, child) {
                  return ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                    child: child,
                  );
                },
                child: Image.memory(
                  bytes!,
                  width: _size,
                  height: _size,
                  fit: BoxFit.cover,
                ),
              ),
      ),
    )
        .animate()
        .scale(
          duration: 540.ms,
          begin: const Offset(0.7, 0.7),
          end: const Offset(1, 1),
          curve: Curves.easeOutBack,
        )
        .fadeIn(duration: 380.ms);
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
          color: AppColors.bordeaux,
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
          // Pre-reveal: the peer's own photo under the Veil when we have
          // it, the warm placeholder when we don't. Either way v3 — the
          // level the app shows between the match and the reveal.
          SizedBox(
            width: _preRevealSize,
            height: _preRevealSize,
            child: bytes == null
                ? const BlurredAvatar(size: _preRevealSize, level: VeilLevel.v3)
                : Veil(
                    level: VeilLevel.v3,
                    child: Image.memory(bytes!, fit: BoxFit.cover),
                  ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            l10n.hiddenPhotoLabel,
            style: AppTypography.caption.copyWith(color: AppColors.ink2),
          ),
        ],
      );
    }

    // Reveal — large portrait card. The Veil stays at v1: blur gone, warm
    // veil down to 35 %, grain still there, so a revealed photo still
    // reads as part of the app rather than a raw camera roll image.
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.clamp(0.0, _revealMaxWidth);
        final height = width / _revealAspect;
        return SizedBox(
          width: width,
          height: height,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: AppColors.line),
            ),
            child: Veil(
              level: VeilLevel.v1,
              shape: VeilShape.card,
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
              duration: VeilTiming.reveal,
              begin: const Offset(0.94, 0.94),
              end: const Offset(1, 1),
              curve: VeilTiming.curve,
            )
            .fadeIn(duration: 380.ms);
      },
    );
  }
}
