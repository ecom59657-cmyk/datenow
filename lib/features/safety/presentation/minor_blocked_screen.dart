import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/app_routes.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../shared/widgets/app_button.dart';
import '../../../shared/widgets/app_scaffold.dart';

/// Static under-18 / verification-failed screen. Apple expects a dating
/// app to make the 18+ rule explicit, and to give the user a calm exit
/// when they hit it (vs. a generic error toast).
///
/// Reachable from:
///   * sign-up rejection path (`MinorSignUpFailure`) — show inline.
///   * future identity-verification rejection.
///   * `/minor-blocked` deep link — for support email content.
class MinorBlockedScreen extends StatelessWidget {
  const MinorBlockedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isFr = Localizations.localeOf(context).languageCode == 'fr';
    return AppScaffold(
      appBar: AppBar(
        title: Text(isFr ? '18 ans minimum' : '18 and older'),
        leading: const BackButton(),
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        child: Column(
          children: [
            const Spacer(flex: 2),
            const Icon(
              Icons.shield_moon_outlined,
              size: 72,
              color: AppColors.textTertiary,
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              isFr
                  ? 'DateNow est réservé aux utilisateurs majeurs.'
                  : 'DateNow is reserved for adults.',
              textAlign: TextAlign.center,
              style: AppTypography.h2,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              isFr
                  ? 'Tu dois avoir 18 ans ou plus pour utiliser DateNow. '
                      'Si tu penses qu\'il s\'agit d\'une erreur, contacte '
                      'support@datenow.app.'
                  : 'You must be 18 or older to use DateNow. If you think '
                      'this is a mistake, please contact '
                      'support@datenow.app.',
              textAlign: TextAlign.center,
              style:
                  AppTypography.body.copyWith(color: AppColors.textSecondary),
            ),
            const Spacer(flex: 3),
            AppButton(
              label: isFr ? 'Retour' : 'Back',
              size: AppButtonSize.large,
              onPressed: () {
                if (context.canPop()) {
                  context.pop();
                } else {
                  context.goNamed(AppRoute.authLanding.name);
                }
              },
            ),
            const SizedBox(height: AppSpacing.lg),
          ],
        ),
      ),
    );
  }
}
