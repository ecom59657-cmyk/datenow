// =============================================================================
// DateNow — test observation mode  (DEBUG-ONLY, temporary)
//
// Lightweight instrumentation for the first real 2-phone test: a discreet
// floating overlay + ultra-short milestone logs + a "copy session summary"
// helper. It changes NO product logic.
//
// Removal after MVP validation:
//   1. delete this file (lib/core/debug/debug_observer.dart);
//   2. delete the DebugOverlay wrap in lib/app/app.dart;
//   3. grep for `// debug-observer` and delete those one-line call sites.
//
// Every public method is a NO-OP when `!kDebugMode`, so a release build
// carries zero runtime cost and the overlay never mounts.
// =============================================================================

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/call/data/agora_token_repository.dart';
import '../utils/logger.dart';

// -----------------------------------------------------------------------------
// Ultra-short milestone logs — one line per critical event, no JSON, no token.
// -----------------------------------------------------------------------------

/// Focused milestone logger. Streams stay greppable as `[DateNow][MATCH]`,
/// `[DateNow][CALL]`, `[DateNow][AGORA]`, `[DateNow][REVEAL]`.
class DebugLog {
  const DebugLog._();

  static const _match = AppLogger('MATCH');
  static const _call = AppLogger('CALL');
  static const _agora = AppLogger('AGORA');
  static const _reveal = AppLogger('REVEAL');

  static void match(String event) {
    if (kDebugMode) _match.info(event);
  }

  static void call(String event) {
    if (kDebugMode) _call.info(event);
  }

  static void agora(String event) {
    if (kDebugMode) _agora.info(event);
  }

  static void reveal(String event) {
    if (kDebugMode) _reveal.info(event);
  }
}

// -----------------------------------------------------------------------------
// Live observation state
// -----------------------------------------------------------------------------

/// Process-wide observation board.
///
/// It is a plain singleton (`DebugObserver.instance`) — NOT a Riverpod
/// provider — so it can be written from repositories, timers and async
/// callbacks without a `WidgetRef` (which would throw once a screen is
/// disposed). Every mutation is a no-op in release.
class DebugObserver extends ChangeNotifier {
  DebugObserver._();

  /// The single shared instance — lives for the whole process.
  static final DebugObserver instance = DebugObserver._();

  /// searching | matched | waiting_peer | joining | live | reveal | ended | idle
  String phase = 'idle';
  String? callId;
  String? channelName;
  String? selfUserId;
  String? peerUserId;
  int? peerUid;
  int remainingSeconds = -1; // -1 = n/a
  String netQuality = '—';
  String revealOutcome = '—';
  DateTime? startedAt;
  DateTime? endedAt;

  bool _notifyScheduled = false;

  /// Notifies listeners — but never *during* a build/layout phase, where
  /// `notifyListeners()` would trigger `markNeedsBuild()` on the overlay
  /// mid-frame. In that case the notification is deferred to after the
  /// current frame.
  void _changed() {
    if (!kDebugMode) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      notifyListeners();
      return;
    }
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _notifyScheduled = false;
      notifyListeners();
    });
  }

  /// Resets the board for a fresh search → keeps "copy summary" honest.
  void startSession() {
    if (!kDebugMode) return;
    phase = 'searching';
    callId = null;
    channelName = null;
    selfUserId = null;
    peerUserId = null;
    peerUid = null;
    remainingSeconds = -1;
    netQuality = '—';
    revealOutcome = '—';
    startedAt = null;
    endedAt = null;
    _changed();
  }

  void setPhase(String value) {
    if (!kDebugMode) return;
    phase = value;
    _changed();
  }

  void setCall({
    String? callId,
    String? channelName,
    String? selfUserId,
    String? peerUserId,
    DateTime? startedAt,
  }) {
    if (!kDebugMode) return;
    if (callId != null) this.callId = callId;
    if (channelName != null) this.channelName = channelName;
    if (selfUserId != null) this.selfUserId = selfUserId;
    if (peerUserId != null) {
      this.peerUserId = peerUserId;
      peerUid = AgoraTokenRepository.uidForUser(peerUserId);
    }
    if (startedAt != null) this.startedAt = startedAt;
    _changed();
  }

  void setRemaining(int seconds) {
    if (!kDebugMode) return;
    remainingSeconds = seconds;
    _changed();
  }

  void setNetQuality(String label) {
    if (!kDebugMode) return;
    netQuality = label;
    _changed();
  }

  void setRevealOutcome(String value) {
    if (!kDebugMode) return;
    revealOutcome = value;
    _changed();
  }

  void markEnded() {
    if (!kDebugMode) return;
    endedAt = DateTime.now();
    phase = 'ended';
    _changed();
  }

  /// Compact, copy-pasteable session summary for sharing after a test.
  /// [reconnectCount] / [selfUid] are pulled from the Agora debug
  /// providers by the caller.
  String summaryText({required int reconnectCount, int? selfUid}) {
    String fmt(DateTime? d) => d?.toIso8601String() ?? '—';
    return [
      'DateNow — session debug',
      'phase       : $phase',
      'call_id     : ${callId ?? '—'}',
      'channel     : ${channelName ?? '—'}',
      'uid self    : ${selfUid ?? '—'}',
      'uid peer    : ${peerUid ?? '—'}',
      'started_at  : ${fmt(startedAt)}',
      'ended_at    : ${fmt(endedAt)}',
      'reveal      : $revealOutcome',
      'reconnects  : $reconnectCount',
      'net quality : $netQuality',
    ].join('\n');
  }
}

// -----------------------------------------------------------------------------
// Floating overlay
// -----------------------------------------------------------------------------

/// Wraps the app. In release it returns [child] untouched; in debug it
/// stacks a small, collapsible observation panel on top of every screen.
class DebugOverlay extends StatelessWidget {
  const DebugOverlay({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode) return child;
    return Stack(
      children: [
        child,
        const Positioned(left: 6, top: 0, child: SafeArea(child: _Panel())),
      ],
    );
  }
}

class _Panel extends ConsumerStatefulWidget {
  const _Panel();

  @override
  ConsumerState<_Panel> createState() => _PanelState();
}

class _PanelState extends ConsumerState<_Panel> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final observer = DebugObserver.instance;
    final conn = ref.watch(agoraConnectionDebugProvider);
    final token = ref.watch(agoraTokenDebugProvider);

    return Material(
      color: Colors.transparent,
      child: AnimatedBuilder(
        animation: observer,
        builder: (context, _) {
          final peerState = !conn.joined
              ? '—'
              : conn.reconnecting
                  ? 'reconnecting'
                  : conn.remoteCount > 0
                      ? 'online'
                      : 'absent';
          return GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            child: _expanded
                ? _expandedBox(observer, conn, token, peerState)
                : _collapsedPill(observer.phase, peerState),
          );
        },
      ),
    );
  }

  Widget _collapsedPill(String phase, String peerState) {
    return _box(
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('OBS', style: _kKeyStyle),
          const SizedBox(width: 6),
          Text(phase, style: _kValStyle),
          const SizedBox(width: 6),
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _dotColor(peerState),
            ),
          ),
        ],
      ),
    );
  }

  Widget _expandedBox(
    DebugObserver o,
    AgoraConnectionDebug conn,
    AgoraTokenDebugInfo token,
    String peerState,
  ) {
    final remaining = o.remainingSeconds < 0
        ? '—'
        : '${o.remainingSeconds ~/ 60}:'
            '${(o.remainingSeconds % 60).toString().padLeft(2, '0')}';
    return _box(
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('DateNow · OBSERVATION', style: _kKeyStyle),
          const SizedBox(height: 4),
          _row('phase', o.phase),
          _row('call_id', _short(o.callId)),
          _row('channel', o.channelName ?? '—'),
          _row('uid self', '${token.uid ?? '—'}'),
          _row('uid peer', '${o.peerUid ?? '—'}'),
          _row('timer', remaining),
          _row('peer', peerState),
          _row('reconnect', '${conn.reconnectAttempts}'),
          _row('net', o.netQuality),
          const SizedBox(height: 2),
          const Text('tap pour réduire', style: _kHintStyle),
        ],
      ),
    );
  }

  Widget _box(Widget child) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
      ),
      child: child,
    );
  }

  Widget _row(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(width: 64, child: Text(k, style: _kKeyStyle)),
          Text(v, style: _kValStyle),
        ],
      ),
    );
  }

  static String _short(String? id) {
    if (id == null) return '—';
    return id.length <= 8 ? id : '${id.substring(0, 8)}…';
  }

  static Color _dotColor(String peerState) => switch (peerState) {
        'online' => const Color(0xFF34D399),
        'reconnecting' => const Color(0xFFFBBF24),
        'absent' => const Color(0xFFF87171),
        _ => const Color(0xFF6B7280),
      };
}

const _kKeyStyle = TextStyle(
  color: Color(0xFF9CA3AF),
  fontSize: 10,
  fontWeight: FontWeight.w700,
  letterSpacing: 0.4,
);
const _kValStyle = TextStyle(
  color: Colors.white,
  fontSize: 11,
  fontWeight: FontWeight.w600,
  fontFamilyFallback: ['monospace'],
);
const _kHintStyle = TextStyle(
  color: Color(0xFF6B7280),
  fontSize: 9,
);
