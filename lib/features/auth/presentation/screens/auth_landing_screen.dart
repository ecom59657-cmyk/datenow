import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/router/app_routes.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../shared/widgets/app_logo.dart';
import '../../../../shared/widgets/app_scaffold.dart';

/// Entry point of the auth flow — lets the user pick between signing in and
/// creating an account. Lives outside [SignInScreen]/[SignUpScreen] so the
/// landing copy can stay marketing-heavy.
class AuthLandingScreen extends StatelessWidget {
  const AuthLandingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AppScaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Spacer(flex: 2),
          Center(child: const AppLogo(fontSize: 44))
              .animate()
              .fadeIn(duration: 600.ms)
              .slideY(begin: 0.15, end: 0, curve: Curves.easeOutCubic),
          const SizedBox(height: AppSpacing.lg),
          Text(
            '${l10n.authTaglineLine1}\n${l10n.authTaglineLine2}',
            textAlign: TextAlign.center,
            style: AppTypography.body.copyWith(
              color: AppColors.textSecondary,
              fontSize: 16,
              height: 1.5,
            ),
          ).animate().fadeIn(delay: 200.ms, duration: 600.ms),
          const Spacer(flex: 3),
          AppButton(
            label: l10n.authCreateAccount,
            size: AppButtonSize.large,
            onPressed: () => context.pushNamed(AppRoute.signUp.name),
          ).animate().fadeIn(delay: 400.ms).slideY(begin: 0.2, end: 0),
          const SizedBox(height: AppSpacing.sm),
          AppButton(
            label: l10n.authHaveAccount,
            variant: AppButtonVariant.secondary,
            size: AppButtonSize.large,
            onPressed: () => context.pushNamed(AppRoute.signIn.name),
          ).animate().fadeIn(delay: 500.ms).slideY(begin: 0.2, end: 0),
          const SizedBox(height: AppSpacing.lg),
          Text(
            l10n.authTerms,
            textAlign: TextAlign.center,
            style: AppTypography.caption,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
      ),
    );
  }
}
