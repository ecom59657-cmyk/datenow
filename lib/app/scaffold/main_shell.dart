
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/notifications/notification_scope.dart';
import '../../features/messaging/presentation/providers/messaging_providers.dart';
import '../../l10n/app_localizations.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';
import 'active_tab.dart';

/// Persistent shell hosting the bottom nav. Renders the active tab via
/// [StatefulShellRoute.indexedStack] so each branch keeps its own navigation
/// state.
class MainShell extends ConsumerWidget {
  const MainShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  void _onTap(int i) {
    navigationShell.goBranch(
      i,
      // Reset to root when re-tapping the active tab.
      initialLocation: i == navigationShell.currentIndex,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);

    // Publish the freshly-shown tab so each tab screen (via
    // TabScrollResetMixin) can slide its scroll back to the top on
    // revisit. Deferred to the next frame so we don't mutate provider
    // state during a build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final notifier = ref.read(activeTabIndexProvider.notifier);
      if (notifier.state != navigationShell.currentIndex) {
        notifier.state = navigationShell.currentIndex;
      }
    });
    // Sober Material glyphs — no emoji, so nothing renders as a coloured
    // "cartoon" icon. Inactive tabs sit on ink3, the active one on
    // bordeaux; the white tints these carried were invisible the moment
    // the bar stopped being dark glass. Accessible names via Semantics.
    final tabs = <_NavItem>[
      _NavItem(
        label: l10n.navHome,
        icon: Icons.home_rounded,
        tint: AppColors.ink3,
      ),
      _NavItem(
        label: l10n.navDiscover,
        icon: Icons.favorite_rounded,
        tint: AppColors.ink3,
      ),
      // Messages — reached only after a confirmed mutual match, so we
      // place it right next to Discover (the pre-match surface).
      _NavItem(
        label: l10n.navMessages,
        icon: Icons.chat_bubble_rounded,
        tint: AppColors.ink3,
        // Live unread badge. 0 = no badge, 1-9 = number, 10+ = "9+".
        badge: ref.watch(unreadMessagesCountProvider).maybeWhen(
              data: (n) => n,
              orElse: () => 0,
            ),
      ),
      // Same glyph as the default home _AvatarBadge (Icons.person_rounded)
      // so the tab visually points back to "your profile".
      _NavItem(
        label: l10n.navProfile,
        icon: Icons.person_rounded,
        tint: AppColors.ink3,
      ),
    ];

    // Android back from a secondary tab returns to Accueil; only a back
    // press already on Accueil leaves the app. There was no PopScope
    // anywhere in lib/, so the system back button closed DateNow from
    // any tab — including mid-conversation.
    return PopScope(
      canPop: navigationShell.currentIndex == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || navigationShell.currentIndex == 0) return;
        _onTap(0);
      },
      child: Scaffold(
      backgroundColor: AppColors.ivory,
      // The bar is an attached surface now, not a floating pill, so the
      // body must stop above it instead of scrolling underneath.
      extendBody: false,
      // Listens to inboxProvider — fires sound + haptic + snackbar on
      // fresh incoming messages while the app is foreground. No-op
      // until the user is signed in (inboxProvider returns []).
      body: NotificationScope(child: navigationShell),
      bottomNavigationBar: _GlassNavBar(
        items: tabs,
        currentIndex: navigationShell.currentIndex,
        onTap: _onTap,
      ),
      ),
    );
  }
}

class _NavItem {
  const _NavItem({
    required this.label,
    required this.icon,
    required this.tint,
    this.badge = 0,
  });

  /// Accessible name — surfaced to screen readers even though the bar
  /// only renders an icon.
  final String label;

  /// Material glyph rendered in the bar — sober, minimalist, no emoji.
  final IconData icon;

  /// Base tint when the tab is inactive. Active tabs render white for
  /// crisp contrast on the gradient pill.
  final Color tint;

  /// 0 = no badge ; 1-9 rendered literally ; >9 rendered as "9+".
  /// Currently only used by the Messages tab (unread count).
  final int badge;
}

class _GlassNavBar extends StatelessWidget {
  const _GlassNavBar({
    required this.items,
    required this.currentIndex,
    required this.onTap,
  });

  final List<_NavItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    // Attached ivory bar with a hairline on top — the same "filets plutôt
    // qu'ombres" rule as everywhere else. It used to be a floating glass
    // pill with a 22 px backdrop blur, which cost a saveLayer on every
    // frame of every scroll and clipped the last card of each list.
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: AppColors.ivory,
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 60,
          child: Row(
            children: List.generate(items.length, (i) {
              final item = items[i];
              final selected = i == currentIndex;
              return Expanded(
                child: _NavButton(
                  item: item,
                  selected: selected,
                  onTap: () => onTap(i),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final _NavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Active tab = bordeaux glyph + label. No filled pill: the nav is not
    // where the screen's one filled element belongs.
    final color = selected ? AppColors.bordeaux : item.tint;
    return Semantics(
      label: item.label,
      button: true,
      selected: selected,
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _IconWithBadge(
                icon: item.icon,
                color: color,
                badge: item.badge,
              ),
              const SizedBox(height: 3),
              Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.caption.copyWith(
                  fontSize: 10,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Pure formatting of the unread-count label rendered in the bottom-nav
/// badge. Exposed so the rule (≤0 → no badge, 1-9 → digit, 10+ → "9+")
/// is unit-testable in isolation from the widget tree.
@visibleForTesting
String? formatUnreadBadge(int count) {
  if (count <= 0) return null;
  if (count > 9) return '9+';
  return '$count';
}

/// Icon + optional unread-count badge. Small filled pink circle anchored
/// to the icon's top-right corner — bottom-nav standard, premium DateNow
/// tint. 0 → nothing rendered ; 1-9 → digit ; 10+ → "9+".
class _IconWithBadge extends StatelessWidget {
  const _IconWithBadge({
    required this.icon,
    required this.color,
    required this.badge,
  });

  final IconData icon;
  final Color color;
  final int badge;

  @override
  Widget build(BuildContext context) {
    final label = formatUnreadBadge(badge);
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        Icon(icon, size: 24, color: color),
        if (label != null)
          Positioned(
            top: -4,
            right: -8,
            child: Container(
              constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
              padding:
                  const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: AppColors.bordeaux,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.surface, width: 1.5),
              ),
              alignment: Alignment.center,
              child: Text(
                label,
                style: AppTypography.caption.copyWith(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  height: 1,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
