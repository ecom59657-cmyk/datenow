import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../app/router/app_routes.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/config/app_config.dart';
import '../../../core/debug/debug_observer.dart';
import '../../../core/services/supabase_service.dart';
import '../../../core/utils/logger.dart';
import '../../../shared/widgets/app_button.dart';
import '../../../shared/widgets/app_scaffold.dart';
import '../../auth/presentation/providers/auth_provider.dart';
import '../../call/data/agora_token_repository.dart';
import '../../call/data/call_session_repository.dart';
import '../../matching/data/matching_repository.dart';
import '../../matching/data/matchmaking_repository.dart';
import '../../matching/domain/active_match.dart';
import '../../matching/domain/match_score.dart';
import '../../matching/presentation/providers/active_match_provider.dart';
import '../../post_call/data/reveal_repository.dart';
import '../../presence/data/presence_repository.dart';
import '../../presence/presentation/presence_controller.dart';
import '../../profile_setup/data/profile_repository.dart';
import '../../profile_setup/presentation/providers/profile_provider.dart';

/// Developer hub for end-to-end testing with two real accounts.
///
/// Strictly debug-only — the Settings tile and the route are both gated
/// on [kDebugMode], so this never ships in a release build.
///
/// Three live sections (Matching / Call / Reveal) plus a row of test
/// actions. Everything reads straight from Supabase so it reflects the
/// real server state, not local guesses.
class DebugDateNowScreen extends ConsumerStatefulWidget {
  const DebugDateNowScreen({super.key});

  @override
  ConsumerState<DebugDateNowScreen> createState() =>
      _DebugDateNowScreenState();
}

class _DebugDateNowScreenState extends ConsumerState<DebugDateNowScreen> {
  static const _log = AppLogger('Debug');
  static const _floor = 75;

  bool _loading = false;
  String? _error;
  _Snapshot? _snap;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  SupabaseClient get _db => ref.read(supabaseClientProvider);

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final self = ref.read(currentProfileProvider).asData?.value;
      if (self == null) throw StateError('no current profile');
      final selfId = self.userId;

      // --- Matching -------------------------------------------------------
      final now = DateTime.now().toUtc();
      DateTime? parseTs(dynamic raw) =>
          raw is String ? DateTime.parse(raw).toUtc() : null;

      final myQueueRows = await _db
          .from('matchmaking_queue')
          .select('user_id, heartbeat_at')
          .eq('user_id', selfId);
      final inQueue = myQueueRows.isNotEmpty;
      final selfHeartbeatAt = myQueueRows.isEmpty
          ? null
          : parseTs(myQueueRows.first['heartbeat_at']);

      final queueRows = await _db
          .from('matchmaking_queue')
          .select('user_id, heartbeat_at')
          .neq('user_id', selfId);
      final queueHeartbeats = <String, DateTime?>{
        for (final r in queueRows)
          r['user_id'] as String: parseTs(r['heartbeat_at']),
      };
      final queueIds = queueHeartbeats.keys.toSet();

      final service = ref.read(matchingServiceProvider);
      final allCandidates = await ref
          .read(profileRepositoryProvider)
          .fetchPotentialCandidates(selfUserId: selfId);
      final peers = <_PeerScore>[];
      for (final c in allCandidates.where((c) => queueIds.contains(c.userId))) {
        final score = service.calculateCompatibility(self, c, distanceKm: 10);
        final hb = queueHeartbeats[c.userId];
        final ageSec =
            hb == null ? null : now.difference(hb).inSeconds;
        peers.add(_PeerScore(
          userId: c.userId,
          name: c.firstName ?? '—',
          score: score?.percentage,
          hardGateFail: score == null,
          heartbeatAgeSec: ageSec,
          fresh: ageSec != null && ageSec < 30,
        ));
      }
      peers.sort((a, b) => (b.score ?? -1).compareTo(a.score ?? -1));

      // --- Call -----------------------------------------------------------
      final callRows = await _db
          .from('calls')
          .select()
          .or('caller_id.eq.$selfId,callee_id.eq.$selfId')
          .neq('status', 'ended')
          .order('started_at', ascending: false)
          .limit(1);
      final activeCall =
          callRows.isEmpty ? null : CallSessionRow.fromJson(callRows.first);

      // --- Reveal ---------------------------------------------------------
      List<RevealRow> reveals = const [];
      bool? matchExists;
      if (activeCall != null) {
        final revRows = await _db
            .from('reveals')
            .select()
            .eq('call_id', activeCall.id);
        reveals = revRows.map(RevealRow.fromJson).toList();

        final peerId = activeCall.callerId == selfId
            ? activeCall.calleeId
            : activeCall.callerId;
        final ordered = [selfId, peerId]..sort();
        final matchRows = await _db
            .from('matches')
            .select('id')
            .eq('user_a_id', ordered.first)
            .eq('user_b_id', ordered.last)
            .limit(1);
        matchExists = matchRows.isNotEmpty;
      }

      // --- Presence -------------------------------------------------------
      final presenceRepo = ref.read(presenceRepositoryProvider);
      final selfPresence = await presenceRepo?.fetchPresence(selfId);
      PresenceRow? peerPresence;
      if (presenceRepo != null && activeCall != null) {
        final peerId = activeCall.callerId == selfId
            ? activeCall.calleeId
            : activeCall.callerId;
        peerPresence = await presenceRepo.fetchPresence(peerId);
      }

      if (!mounted) return;
      setState(() {
        _snap = _Snapshot(
          selfId: selfId,
          selfName: self.firstName ?? '—',
          inQueue: inQueue,
          selfHeartbeatAt: selfHeartbeatAt,
          selfPresence: selfPresence,
          peerPresence: peerPresence,
          peers: peers,
          activeCall: activeCall,
          reveals: reveals,
          matchExists: matchExists,
        );
        _loading = false;
      });
    } catch (e, st) {
      _log.error('refresh failed: $e', e, st);
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  // --- Actions ----------------------------------------------------------

  Future<void> _forceLeaveQueue() async {
    final repo = ref.read(matchmakingRepositoryProvider);
    final selfId = ref.read(currentUserProvider)?.id;
    if (repo == null || selfId == null) return;
    await repo.leaveQueue(selfId);
    _log.info('forced leaveQueue');
    await _refresh();
  }

  Future<void> _resetMyReveal() async {
    final selfId = ref.read(currentUserProvider)?.id;
    final callId = _snap?.activeCall?.id;
    if (selfId == null || callId == null) return;
    await _db
        .from('reveals')
        .delete()
        .eq('call_id', callId)
        .eq('user_id', selfId);
    _log.info('reset my reveal for call=$callId');
    await _refresh();
  }

  Future<void> _forceEndCall() async {
    final selfId = ref.read(currentUserProvider)?.id;
    final callId = _snap?.activeCall?.id;
    if (selfId == null || callId == null) return;
    final repo = ref.read(callSessionRepositoryProvider);
    await repo?.end(callId: callId, byUserId: selfId);
    _log.info('forced end call=$callId');
    await _refresh();
  }

  Future<void> _joinLastActiveCall() async {
    final self = ref.read(currentProfileProvider).asData?.value;
    final call = _snap?.activeCall;
    if (self == null || call == null) return;
    final peerId =
        call.callerId == self.userId ? call.calleeId : call.callerId;
    final peer = await ref.read(profileRepositoryProvider).getProfile(peerId);
    if (peer == null || !mounted) return;
    final score = ref
        .read(matchingServiceProvider)
        .calculateCompatibility(self, peer, distanceKm: 10);
    ref.read(activeMatchProvider.notifier).state = ActiveMatch(
      candidate: peer,
      distanceKm: 10,
      score: score ??
          const MatchScore(percentage: 75, breakdown: <String, int>{}),
    );
    ref.read(activeCallIdProvider.notifier).state = call.id;
    _log.info('joining last active call=${call.id}');
    context.pushNamed(AppRoute.call.name);
  }

  /// Builds a compact, shareable text dump of the current/last session
  /// from the debug observer + the live Agora debug providers.
  Future<void> _copySessionSummary() async {
    final observer = DebugObserver.instance;
    final token = ref.read(agoraTokenDebugProvider);
    final conn = ref.read(agoraConnectionDebugProvider);
    final text = observer.summaryText(
      reconnectCount: conn.reconnectAttempts,
      selfUid: token.uid,
    );
    await _copy('Résumé session', text);
  }

  Future<void> _copy(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label copié')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      appBar: AppBar(title: const Text('Debug · DateNow')),
      body: ListView(
        children: [
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(AppSpacing.lg),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            _Card(
              title: 'Erreur',
              color: AppColors.error,
              rows: [('detail', _error!)],
            )
          else if (_snap != null) ...[
            _matchingCard(_snap!),
            _presenceCard(_snap!),
            _callCard(_snap!),
            _connectionCard(),
            _tokenCard(),
            _revealCard(_snap!),
            _actionsCard(_snap!),
          ],
          const SizedBox(height: AppSpacing.md),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: AppButton(
              label: 'Rafraîchir',
              icon: Icons.refresh_rounded,
              onPressed: _loading ? null : _refresh,
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
        ],
      ),
    );
  }

  Widget _matchingCard(_Snapshot s) {
    // The real matcher only sees fresh peers (active_queue_peers filters
    // on heartbeat < 30 s), so a matchable peer must also be fresh.
    final best = s.peers
        .where((p) =>
            !p.hardGateFail && (p.score ?? 0) >= _floor && p.fresh)
        .toList();
    final hb = s.selfHeartbeatAt;
    final hbLabel = hb == null
        ? '—'
        : '${DateTime.now().toUtc().difference(hb).inSeconds}s';
    final freshCount = s.peers.where((p) => p.fresh).length;
    return _Card(
      title: 'Matching',
      rows: [
        ('user_id', s.selfId),
        ('name', s.selfName),
        ('online', 'true (app au premier plan)'),
        ('searching / in queue', '${s.inQueue}'),
        ('mon heartbeat (âge)', hbLabel),
        ('seuil', '$_floor %'),
        ('peers en queue', '${s.peers.length} (dont $freshCount frais <30s)'),
        ('meilleur peer ≥75%',
            best.isEmpty ? '—' : '${best.first.userId} (${best.first.score}%)'),
        for (final p in s.peers)
          (
            '· ${p.name} ${p.userId.substring(0, 8)}…',
            '${p.hardGateFail ? 'HARD GATE FAIL' : '${p.score}% '
                '${(p.score ?? 0) >= _floor ? '✓' : '✗ <75'}'}'
                ' · hb ${p.heartbeatAgeSec == null ? '—' : '${p.heartbeatAgeSec}s'}'
                ' ${p.fresh ? '(frais)' : '(périmé)'}',
          ),
      ],
    );
  }

  String _presenceLabel(PresenceRow? row) {
    if (row == null) return 'aucune ligne';
    final age = DateTime.now().toUtc().difference(row.updatedAt).inSeconds;
    return '${row.status.label} · maj ${age}s';
  }

  Widget _presenceCard(_Snapshot s) {
    final controller = ref.read(presenceControllerProvider);
    final pushed = controller.lastPushedAt;
    final pushedAge = pushed == null
        ? '—'
        : '${DateTime.now().toUtc().difference(pushed).inSeconds}s';
    return _Card(
      title: 'Présence',
      rows: [
        ('intention (app)', controller.intent.label),
        ('dernier push présence', pushedAge),
        ('statut self (serveur)', _presenceLabel(s.selfPresence)),
        (
          'statut peer (serveur)',
          s.activeCall == null
              ? '— (aucun call actif)'
              : _presenceLabel(s.peerPresence),
        ),
      ],
    );
  }

  Widget _connectionCard() {
    final conn = ref.watch(agoraConnectionDebugProvider);
    final precall = ref.watch(precallStateProvider);
    return _Card(
      title: 'Connexion Agora',
      rows: [
        ('état pré-call', precall),
        ('joined', '${conn.joined}'),
        ('participants distants', '${conn.remoteCount}'),
        ('reconnexion en cours', conn.reconnecting ? 'oui' : 'non'),
        ('tentatives de reconnexion', '${conn.reconnectAttempts}'),
      ],
    );
  }

  Widget _callCard(_Snapshot s) {
    final c = s.activeCall;
    if (c == null) {
      return const _Card(title: 'Call', rows: [('active call', 'aucun')]);
    }
    // Server-based countdown: identical maths to CallScreen's ticker, so
    // this row is the ground truth for "what time-left both peers see".
    final elapsed = DateTime.now().toUtc().difference(c.startedAt);
    final remaining = AppConfig.maxCallDuration - elapsed;
    final remLabel = remaining.isNegative
        ? 'expiré (${(-remaining.inSeconds)}s de retard)'
        : '${remaining.inMinutes}m '
            '${(remaining.inSeconds % 60).toString().padLeft(2, '0')}s';
    return _Card(
      title: 'Call',
      rows: [
        ('call_id', c.id),
        ('channel_name', c.channelName ?? '—'),
        ('caller_id', c.callerId),
        ('callee_id', c.calleeId),
        ('status', c.status),
        ('started_at', c.startedAt.toIso8601String()),
        ('temps restant (serveur)', remLabel),
        ('ended_by', c.endedBy ?? '—'),
      ],
    );
  }

  Widget _tokenCard() {
    final info = ref.watch(agoraTokenDebugProvider);
    final exp = info.expiresAt;
    final expLabel = exp == null
        ? '—'
        : exp.toLocal().toIso8601String().substring(11, 19);
    return _Card(
      title: 'Agora Token',
      rows: [
        ('token généré', info.generated ? 'oui' : 'non'),
        ('uid utilisé', '${info.uid ?? '—'}'),
        ('expiration approx.', expLabel),
        // The token string itself is deliberately never surfaced here.
      ],
    );
  }

  Widget _revealCard(_Snapshot s) {
    final c = s.activeCall;
    if (c == null) {
      return const _Card(
        title: 'Reveal',
        rows: [('reveal', 'aucun call actif')],
      );
    }
    final peerId =
        c.callerId == s.selfId ? c.calleeId : c.callerId;
    String decision(String uid) {
      final row = s.reveals.where((r) => r.userId == uid).firstOrNull;
      if (row == null) return 'pending';
      return row.revealed ? 'revealed' : 'passed';
    }

    final selfD = decision(s.selfId);
    final peerD = decision(peerId);
    final String outcome;
    if (selfD == 'passed' || peerD == 'passed') {
      outcome = 'declined';
    } else if (selfD == 'revealed' && peerD == 'revealed') {
      outcome = 'mutual';
    } else {
      outcome = 'pending';
    }

    return _Card(
      title: 'Reveal',
      rows: [
        ('call_id', c.id),
        ('décision self', selfD),
        ('décision peer', peerD),
        ('outcome', outcome),
        ('match permanent créé', '${s.matchExists ?? false}'),
        ('conversation créée', s.matchExists == true ? 'oui (mutual)' : 'non'),
      ],
    );
  }

  Widget _actionsCard(_Snapshot s) {
    final c = s.activeCall;
    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Actions de test', style: AppTypography.h3),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              _ActionChip(
                label: 'Copier résumé session',
                onTap: _copySessionSummary,
              ),
              _ActionChip(label: 'Force leaveQueue', onTap: _forceLeaveQueue),
              // TEMP — manual entry point for Phase 4 Didit QA. Remove
              // once Phase 5 wires the screen into the normal funnel.
              _ActionChip(
                label: 'QA · /identity',
                onTap: () => context.pushNamed(
                  AppRoute.identityVerification.name,
                ),
              ),
              if (c != null)
                _ActionChip(label: 'Reset ma décision', onTap: _resetMyReveal),
              if (c != null)
                _ActionChip(label: 'Forcer fin call', onTap: _forceEndCall),
              if (c != null)
                _ActionChip(
                    label: 'Rejoindre ce call',
                    onTap: _joinLastActiveCall),
              if (c?.channelName != null)
                _ActionChip(
                  label: 'Copier channel_name',
                  onTap: () => _copy('channel_name', c!.channelName!),
                ),
              if (c != null)
                _ActionChip(
                  label: 'Copier call_id',
                  onTap: () => _copy('call_id', c.id),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Data + small widgets
// ---------------------------------------------------------------------------

class _Snapshot {
  const _Snapshot({
    required this.selfId,
    required this.selfName,
    required this.inQueue,
    required this.selfHeartbeatAt,
    required this.selfPresence,
    required this.peerPresence,
    required this.peers,
    required this.activeCall,
    required this.reveals,
    required this.matchExists,
  });

  final String selfId;
  final String selfName;
  final bool inQueue;
  final DateTime? selfHeartbeatAt;
  final PresenceRow? selfPresence;
  final PresenceRow? peerPresence;
  final List<_PeerScore> peers;
  final CallSessionRow? activeCall;
  final List<RevealRow> reveals;
  final bool? matchExists;
}

class _PeerScore {
  const _PeerScore({
    required this.userId,
    required this.name,
    required this.score,
    required this.hardGateFail,
    required this.heartbeatAgeSec,
    required this.fresh,
  });

  final String userId;
  final String name;
  final int? score;
  final bool hardGateFail;

  /// Seconds since this peer last refreshed their queue heartbeat.
  final int? heartbeatAgeSec;

  /// True when the heartbeat is recent enough (< 30 s) for the matcher
  /// to consider this peer — mirrors the `active_queue_peers()` filter.
  final bool fresh;
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.rows, this.color});

  final String title;
  final List<(String, String)> rows;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: (color ?? AppColors.hairline).withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: AppTypography.h3.copyWith(color: color)),
          const SizedBox(height: AppSpacing.sm),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 150,
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

class _ActionChip extends StatelessWidget {
  const _ActionChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.brandViolet.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: Text(
            label,
            style: AppTypography.caption.copyWith(
              color: AppColors.brandViolet,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}
