import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/router/app_routes.dart';
import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/errors/failures.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../core/utils/validators.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_text_field.dart';
import '../../../../shared/widgets/cupertino_birth_date_picker.dart';
import '../providers/auth_provider.dart';
import 'email_otp_screen.dart';

class SignUpScreen extends ConsumerStatefulWidget {
  const SignUpScreen({super.key});

  @override
  ConsumerState<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends ConsumerState<SignUpScreen> {
  final _formKey = GlobalKey<FormState>();
  final _firstNameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  DateTime? _birthDate;
  bool _submitting = false;

  @override
  void dispose() {
    _firstNameCtrl.dispose();
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_birthDate == null) return;
    setState(() => _submitting = true);
    context.hideKeyboard();
    try {
      final email = _emailCtrl.text.trim();
      final firstName = _firstNameCtrl.text.trim();
      final outcome =
          await ref.read(authControllerProvider.notifier).requestSignupOtp(
                email: email,
                firstName: firstName,
                birthDate: _birthDate!,
              );
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      switch (outcome) {
        case OtpRequestOutcome.sent:
          context.pushReplacementNamed(
            AppRoute.emailOtp.name,
            extra: EmailOtpArgs(
              email: email,
              isSignup: true,
              firstName: firstName,
              birthDate: _birthDate,
            ),
          );
        case OtpRequestOutcome.failed:
          final err = ref.read(authControllerProvider).error;
          context.showSnack(_humanError(err, l10n));
        case OtpRequestOutcome.alreadyInFlight:
          // double-tap guard
          break;
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String _humanError(Object? err, AppLocalizations l10n) {
    if (err is Failure) {
      switch (err.code) {
        case 'rate_limited':
          return l10n.signupRateLimited;
        case 'minor_sign_up':
          return l10n.validatorBirthDateMinor;
        default:
          return err.message;
      }
    }
    return l10n.couldNotSignUp;
  }

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
            Text(l10n.signUpTitle, style: AppTypography.h1),
            const SizedBox(height: AppSpacing.xs),
            Text(
              l10n.signUpSubtitle,
              style:
                  AppTypography.body.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.xl),
            AppTextField(
              controller: _firstNameCtrl,
              label: l10n.firstNameLabel,
              hint: l10n.firstNameHint,
              prefixIcon: Icons.person_outline_rounded,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.givenName],
              validator: (v) => Validators.firstName(v, l10n),
            ),
            const SizedBox(height: AppSpacing.md),
            CupertinoBirthDatePicker(
              initialValue: _birthDate,
              label: l10n.birthDateLabel,
              hint: l10n.birthDateHint,
              validator: (v) => Validators.birthDate(v, l10n),
              onChanged: (v) => setState(() => _birthDate = v),
            ),
            const SizedBox(height: AppSpacing.md),
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
              label: l10n.signUpButton,
              size: AppButtonSize.large,
              isLoading: busy,
              onPressed: busy ? null : _submit,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              l10n.signUpAgeNotice,
              textAlign: TextAlign.center,
              style: AppTypography.caption,
            ),
            // Tappable Terms + Privacy links — Apple expects them within
            // one tap of the sign-up CTA, not only from Settings.
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton(
                  onPressed: busy
                      ? null
                      : () =>
                          context.pushNamed(AppRoute.settingsTerms.name),
                  child: Text(l10n.settingsTerms),
                ),
                const Text('·',
                    style: TextStyle(color: AppColors.textTertiary)),
                TextButton(
                  onPressed: busy
                      ? null
                      : () => context
                          .pushNamed(AppRoute.settingsPrivacyPolicy.name),
                  child: Text(l10n.settingsPrivacyPolicy),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  l10n.signUpAlreadyHaveAccount,
                  style: AppTypography.body.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () => context.pushReplacementNamed(
                            AppRoute.signIn.name,
                          ),
                  child: Text(l10n.signUpSignInLink),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
          ],
        ),
      ),
    );
  }
}
