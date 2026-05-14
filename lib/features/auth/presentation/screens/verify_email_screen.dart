import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/router/app_routes.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../shared/widgets/app_scaffold.dart';

/// Shown after a successful sign-up when Supabase requires email
/// confirmation (the project's auth setting is on, so `signUp` returns
/// the user but no session).
///
/// Intentionally minimal: a single CTA to the sign-in screen. We do **not**
/// call `resend`, `signInWithOtp`, `resetPasswordForEmail` or any other
/// Supabase auth API from here — every additional automatic round-trip
/// risks tripping the rate-limit that brought us to this screen in the
/// first place.
class VerifyEmailScreen extends StatelessWidget {
  const VerifyEmailScreen({super.key, required this.email});

  /// Email the user just signed up with. Passed via `GoRouterState.extra`.
  final String email;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return AppScaffold(
      appBar: AppBar(automaticallyImplyLeading: false),
      body: Column(
        children: [
          const Spacer(),
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              gradient: AppColors.brandGradient,
              borderRadius: BorderRadius.circular(28),
              boxShadow: [
                BoxShadow(
                  color: AppColors.brandPink.withValues(alpha: 0.35),
                  blurRadius: 28,
                  offset: const Offset(0, 14),
                ),
              ],
            ),
            child: const Icon(
              Icons.mark_email_read_outlined,
              color: Colors.white,
              size: 44,
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          Text(
            l10n.verifyEmailTitle,
            textAlign: TextAlign.center,
            style: AppTypography.h1,
          ),
          const SizedBox(height: AppSpacing.sm),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Text(
              l10n.verifyEmailBody(email),
              textAlign: TextAlign.center,
              style:
                  AppTypography.body.copyWith(color: AppColors.textSecondary),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Text(
              l10n.verifyEmailHint,
              textAlign: TextAlign.center,
              style: AppTypography.caption.copyWith(
                color: AppColors.textTertiary,
              ),
            ),
          ),
          const Spacer(flex: 2),
          AppButton(
            label: l10n.verifyEmailDoneCta,
            icon: Icons.arrow_forward_rounded,
            size: AppButtonSize.large,
            onPressed: () => context.goNamed(AppRoute.signIn.name),
          ),
          const SizedBox(height: AppSpacing.lg),
        ],
      ),
    );
  }
}
