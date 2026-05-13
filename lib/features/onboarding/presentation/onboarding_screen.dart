import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/app_routes.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../shared/widgets/app_button.dart';
import '../../../shared/widgets/app_scaffold.dart';
import 'providers/onboarding_provider.dart';
import 'widgets/onboarding_page.dart';

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  static const _pages = <OnboardingPageData>[
    OnboardingPageData(
      icon: Icons.favorite_rounded,
      title: 'Welcome to DateNow',
      subtitle:
          'A new kind of dating. No swipes, no waiting — just real people, '
          'live, right now.',
    ),
    OnboardingPageData(
      icon: Icons.bolt_rounded,
      title: 'Instant live dates',
      subtitle:
          'We match you with someone compatible and online, then start a '
          '5-minute audio or video date instantly.',
    ),
    OnboardingPageData(
      icon: Icons.lock_outline_rounded,
      title: 'You stay in control',
      subtitle:
          'After 5 minutes, choose to keep talking, swap profiles, or move '
          'on. Always your call.',
    ),
  ];

  final _controller = PageController();
  int _index = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _isLast => _index == _pages.length - 1;

  Future<void> _next() async {
    if (_isLast) {
      await ref.read(onboardingControllerProvider).complete();
      if (mounted) context.goNamed(AppRoute.authLanding.name);
      return;
    }
    _controller.nextPage(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _skip() async {
    await ref.read(onboardingControllerProvider).complete();
    if (mounted) context.goNamed(AppRoute.authLanding.name);
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      applyHorizontalPadding: false,
      body: Column(
        children: [
          // Top bar with skip.
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.sm,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (!_isLast)
                  TextButton(
                    onPressed: _skip,
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.textSecondary,
                    ),
                    child: const Text('Skip'),
                  ),
              ],
            ),
          ),
          Expanded(
            child: PageView.builder(
              controller: _controller,
              itemCount: _pages.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (_, i) => OnboardingPage(data: _pages[i]),
            ),
          ),
          // Indicators.
          _PageIndicators(count: _pages.length, current: _index),
          const SizedBox(height: AppSpacing.lg),
          Padding(
            padding: AppSpacing.pagePadding,
            child: AppButton(
              label: _isLast ? 'Get started' : 'Continue',
              icon: _isLast ? Icons.arrow_forward_rounded : null,
              size: AppButtonSize.large,
              onPressed: _next,
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
        ],
      ),
    );
  }
}

class _PageIndicators extends StatelessWidget {
  const _PageIndicators({required this.count, required this.current});

  final int count;
  final int current;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (i) {
        final active = i == current;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOut,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          height: 6,
          width: active ? 28 : 6,
          decoration: BoxDecoration(
            color: active ? AppColors.brandPink : AppColors.hairline,
            borderRadius: BorderRadius.circular(99),
          ),
        );
      }),
    );
  }
}

