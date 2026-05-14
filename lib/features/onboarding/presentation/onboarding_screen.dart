import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/app_routes.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../l10n/app_localizations.dart';
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
  final _controller = PageController();
  int _index = 0;
  static const _pageCount = 3;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _isLast => _index == _pageCount - 1;

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

  List<OnboardingPageData> _buildPages(AppLocalizations l10n) {
    return [
      OnboardingPageData(
        icon: Icons.favorite_rounded,
        title: l10n.onboarding1Title,
        subtitle: l10n.onboarding1Subtitle,
      ),
      OnboardingPageData(
        icon: Icons.bolt_rounded,
        title: l10n.onboarding2Title,
        subtitle: l10n.onboarding2Subtitle,
      ),
      OnboardingPageData(
        icon: Icons.lock_outline_rounded,
        title: l10n.onboarding3Title,
        subtitle: l10n.onboarding3Subtitle,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final pages = _buildPages(l10n);

    return AppScaffold(
      applyHorizontalPadding: false,
      body: Column(
        children: [
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
                    child: Text(l10n.onboardingSkip),
                  ),
              ],
            ),
          ),
          Expanded(
            child: PageView.builder(
              controller: _controller,
              itemCount: pages.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (_, i) => OnboardingPage(data: pages[i]),
            ),
          ),
          _PageIndicators(count: pages.length, current: _index),
          const SizedBox(height: AppSpacing.lg),
          Padding(
            padding: AppSpacing.pagePadding,
            child: AppButton(
              label:
                  _isLast ? l10n.onboardingGetStarted : l10n.onboardingContinue,
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
