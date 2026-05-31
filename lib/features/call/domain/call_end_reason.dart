import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Why the call ended. Determines which post-call screen the user is
/// routed to and the wording shown.
///
/// `isInterrupted == false` routes to the romantic reveal flow
/// (`PostCallScreen`). `isInterrupted == true` routes to the neutral
/// `CallInterruptedScreen` — no photo reveal, no compatibility score,
/// just a calm "the connection was lost" message + CTA back home.
///
/// Lives in `domain/` so it can be referenced from both the call
/// screen (sets it on exit) and the post-call screens (read it on
/// entry) without either side depending on the other.
enum CallEndReason {
  /// Local user tapped the explicit "Terminer le date" button.
  normalHangup,

  /// The 5-minute call cap reached naturally.
  timerCompleted,

  /// Realtime signal that the peer flipped the row to `ended` first.
  /// From the local side we treat it as a normal end — we cannot
  /// distinguish "peer hung up" from "peer hit its own timer" without
  /// a server-side `end_reason` column (out of scope for this PR;
  /// would be a `calls` table migration).
  peerHangup,

  /// Remote went offline (Agora `onUserOffline`) and our 10 s
  /// countdown expired before they came back.
  remoteTimeout,

  /// OUR OWN Agora connection stayed in the `reconnecting` state past
  /// the 15 s grace — definitive network drop on our end.
  networkLost,

  /// App stayed in `AppLifecycleState.paused` past the 30 s grace —
  /// user backgrounded for too long.
  appBackgroundTimeout,

  /// `AppLifecycleState.detached` fired — process being killed by the
  /// OS or the user. Best-effort end before iOS suspends us.
  appDetached,

  /// Catch-all when we cannot determine the cause (defensive). Lands
  /// on `CallInterruptedScreen` so the user is never falsely told
  /// "Votre date est terminé" when something undocumented went wrong.
  unknown;

  /// True for any reason that did NOT include both users completing
  /// the date together. Drives the routing decision in
  /// `CallScreen._endCall`.
  bool get isInterrupted => switch (this) {
        CallEndReason.normalHangup ||
        CallEndReason.timerCompleted ||
        CallEndReason.peerHangup =>
          false,
        CallEndReason.remoteTimeout ||
        CallEndReason.networkLost ||
        CallEndReason.appBackgroundTimeout ||
        CallEndReason.appDetached ||
        CallEndReason.unknown =>
          true,
      };
}

/// Set by `CallScreen._endCall` just before navigating to the
/// post-call / interrupted screen. The destination screen reads it
/// to adapt its own copy (e.g. the interrupted screen shows a slightly
/// different headline for `networkLost` vs `remoteTimeout`).
///
/// Cleared by the destination screen on dispose so the next call
/// starts from a clean slate.
final lastCallEndReasonProvider =
    StateProvider<CallEndReason?>((_) => null);
