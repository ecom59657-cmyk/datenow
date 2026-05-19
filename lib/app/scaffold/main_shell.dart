import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';

/// Persistent shell hosting the bottom nav. Renders the active tab via
/// [StatefulShellRoute.indexedStack] so each branch keeps its own navigation
/// state.
class MainShell extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // Emoji-only tabs: instantly readable, no text. The accessible name
    // (l10n label) is kept on each button via Semantics.
    final tabs = <_NavItem>[
      _NavItem(label: l10n.navHome, emoji: '🏠'),
      _NavItem(label: l10n.navDiscover, emoji: '✨'),
      _NavItem(label: l10n.navProfile, emoji: '👤'),
    ];

    return Scaffold(
      backgroundColor: AppColors.background,
      extendBody: true,
      body: navigationShell,
      bottomNavigationBar: _GlassNavBar(
        items: tabs,
        currentIndex: navigationShell.currentIndex,
        onTap: _onTap,
      ),
    );
  }
}

class _NavItem {
  const _NavItem({required this.label, required this.emoji});

  /// Accessible name — surfaced to screen readers even though the bar
  /// only renders an emoji.
  final String label;
  final String emoji;
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
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          0,
          AppSpacing.lg,
          AppSpacing.sm,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
            child: Container(
              height: 68,
              decoration: BoxDecoration(
                color: AppColors.surface.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: AppColors.hairline),
              ),
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
    // Active: a luminous brand-gradient pill with a soft pink glow.
    // Inactive: no pill, just the emoji dimmed down so it stays visible
    // but clearly secondary.
    return Semantics(
      label: item.label,
      button: true,
      selected: selected,
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(28),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            margin: const EdgeInsets.all(6),
            alignment: Alignment.center,
            decoration: selected
                ? BoxDecoration(
                    gradient: AppColors.brandGradient,
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.brandPink.withValues(alpha: 0.45),
                        blurRadius: 18,
                        spreadRadius: 1,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  )
                : null,
            child: AnimatedScale(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutBack,
              scale: selected ? 1.18 : 1.0,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 220),
                opacity: selected ? 1.0 : 0.45,
                child: Text(
                  item.emoji,
                  style: const TextStyle(fontSize: 22, height: 1.0),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
