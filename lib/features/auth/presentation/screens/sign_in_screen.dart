import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/router/app_routes.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../core/utils/validators.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_text_field.dart';
import '../providers/auth_provider.dart';
import '../utils/auth_error_mapper.dart';
import 'email_otp_screen.dart';

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _submitting = true);
    context.hideKeyboard();
    try {
      final email = _emailCtrl.text.trim();
      final outcome =
          await ref.read(authControllerProvider.notifier).requestSigninOtp(
                email: email,
              );
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      switch (outcome) {
        case OtpRequestOutcome.sent:
          context.pushReplacementNamed(
            AppRoute.emailOtp.name,
            extra: EmailOtpArgs(email: email, isSignup: false),
          );
        case OtpRequestOutcome.failed:
          final err = ref.read(authControllerProvider).error;
          context.showSnack(_humanError(err, l10n));
        case OtpRequestOutcome.alreadyInFlight:
          break;
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String _humanError(Object? err, AppLocalizations l10n) =>
      humaneAuthError(err, l10n, fallback: AuthFallback.signIn);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final auth = ref.watch(authControllerProvider);
    final busy = auth.isLoading || _submitting;

    return AppScaffold(
      appBar: AppBar(leading: const BackButton()),
      body: Form(
        key: _formKey,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            const SizedBox(height: AppSpacing.lg),
            Text(l10n.signInTitle, style: AppTypography.h1),
            const SizedBox(height: AppSpacing.xs),
            Text(
              l10n.signInSubtitleOtp,
              style: AppTypography.body.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            AppTextField(
              controller: _emailCtrl,
              label: l10n.emailLabel,
              hint: l10n.emailHint,
              prefixIcon: Icons.mail_outline_rounded,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.email],
              validator: (v) => Validators.email(v, l10n),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: AppSpacing.xl),
            AppButton(
              label: l10n.signInSendCode,
              size: AppButtonSize.large,
              isLoading: busy,
              onPressed: busy ? null : _submit,
            ),
            const SizedBox(height: AppSpacing.md),
            Center(
              child: TextButton(
                onPressed: busy
                    ? null
                    : () =>
                        context.pushReplacementNamed(AppRoute.signUp.name),
                child: Text(l10n.authCreateAccount),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
