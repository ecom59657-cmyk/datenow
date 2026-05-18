import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/logger.dart';
import '../data/presence_repository.dart';
import '../domain/presence_status.dart';

/// Owns the user's live presence for the whole app session.
///
/// Screens declare *intent* — the matching screen calls
/// [setIntent]`(searching)`, the call screen `(inCall)` — and the
/// controller re-publishes that intent on every app resume and on a
/// 20 s refresh so the row never goes stale while foregrounded. On pause
/// it best-effort writes `offline`; if the process is killed first the
/// staleness window in [PresenceStatus] makes the user offline anyway.
class PresenceController {
  PresenceController(this._ref);

  final Ref _ref;
  static const _log = AppLogger('Presence');
  static const _refreshEvery = Duration(seconds: 20);

  PresenceStatus _intent = PresenceStatus.online;
  Timer? _refresh;
  DateTime? _lastPushedAt;

  /// What the user is currently doing, per the most recent screen intent.
  PresenceStatus get intent => _intent;

  /// When the controller last successfully pushed presence (for Debug).
  DateTime? get lastPushedAt => _lastPushedAt;

  PresenceRepository? get _repo => _ref.read(presenceRepositoryProvider);

  /// Declares a new intent (online / searching / in_call) and pushes it.
  Future<void> setIntent(PresenceStatus status) async {
    if (status == PresenceStatus.offline) return; // offline is implicit
    _intent = status;
    _log.info('presence intent → ${status.wire}');
    await _push(status);
  }

  /// Called once when the app boots and on every resume.
  void onResume() {
    _push(_intent);
    _refresh?.cancel();
    _refresh = Timer.periodic(_refreshEvery, (_) => _push(_intent));
  }

  /// Called when the app is backgrounded — flip to offline and stop the
  /// refresh so the row ages out cleanly.
  void onPause() {
    _refresh?.cancel();
    _refresh = null;
    _log.info('app paused — presence → offline');
    _push(PresenceStatus.offline);
  }

  void dispose() {
    _refresh?.cancel();
    _refresh = null;
  }

  Future<void> _push(PresenceStatus status) async {
    final repo = _repo;
    if (repo == null) return;
    await repo.setStatus(status);
    _lastPushedAt = DateTime.now().toUtc();
  }
}

final presenceControllerProvider = Provider<PresenceController>((ref) {
  final controller = PresenceController(ref);
  ref.onDispose(controller.dispose);
  return controller;
});

/// Wraps the app and bridges Flutter's lifecycle events into the
/// [PresenceController]. Mount it just inside the `ProviderScope`,
/// around `MaterialApp`.
class PresenceScope extends ConsumerStatefulWidget {
  const PresenceScope({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<PresenceScope> createState() => _PresenceScopeState();
}

class _PresenceScopeState extends ConsumerState<PresenceScope>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Boot presence on the first frame so providers are settled.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(presenceControllerProvider).onResume();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = ref.read(presenceControllerProvider);
    switch (state) {
      case AppLifecycleState.resumed:
        controller.onResume();
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        controller.onPause();
      case AppLifecycleState.inactive:
        break; // transient (e.g. notification shade) — ignore
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ref.read(presenceControllerProvider).onPause();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
