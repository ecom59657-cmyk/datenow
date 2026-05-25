import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Index of the currently-visible top-level tab in [MainShell]
/// (`0 = Home`, `1 = Discover`, `2 = Profile` — matches the order of
/// branches in [StatefulShellRoute.indexedStack]).
///
/// MainShell pushes this on every branch change; each tab screen reads
/// it via [ref.listenManual] to slide its scroll back to the top when it
/// re-appears, giving the modern social-app feel the user expects.
final activeTabIndexProvider = StateProvider<int>((_) => 0);

/// Drop into any top-level tab screen's `ConsumerState` to get a
/// [tabScrollController] that auto-animates to the top whenever the
/// active tab returns to *this* screen. Implement [tabIndex] with the
/// screen's position in the StatefulShellRoute branches list.
///
/// Why a mixin and not a wrapper widget: the controller has to be the
/// SAME instance attached to the screen's scrollable, so a mixin on the
/// state object (which owns the scroll widget) is the cleanest fit.
mixin TabScrollResetMixin<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  /// Index of this tab in the bottom-nav / shell branches.
  int get tabIndex;

  /// Attach this controller to your tab's primary scrollable.
  final ScrollController tabScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // Re-arm on every visit: when the active-tab index becomes ours,
    // slide back to the top with a short, premium curve. Animation is
    // skipped silently if the user hasn't yet scrolled (already at 0)
    // or the controller isn't attached.
    ref.listenManual<int>(activeTabIndexProvider, (prev, next) {
      if (next != tabIndex) return;
      if (!tabScrollController.hasClients) return;
      if (tabScrollController.offset <= 0) return;
      tabScrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void dispose() {
    tabScrollController.dispose();
    super.dispose();
  }
}
