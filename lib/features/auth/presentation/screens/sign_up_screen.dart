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

class SignUpScreen extends ConsumerStatefulWidget {
  const SignUpScreen({super.key});

  @override
  ConsumerState<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends ConsumerState<SignUpScreen> {
  final _formKey = GlobalKey<FormState>();
  final _firstNameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  DateTime? _birthDate;

  /// Screen-level re-entrance guard. Flipped to `true` synchronously at
  /// the start of [_submit], so even if the user double-taps the button
  /// before Riverpod's `state.isLoading` has propagated to the rebuild,
  /// the second tap is dropped without ever calling `signUp` twice.
  bool _submitting = false;

  @override
  void dispose() {
    _firstNameCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_birthDate == null) return;

    setState(() => _submitting = true);
    context.hideKeyboard();

    try {
      final outcome = await ref.read(authControllerProvider.notifier).signUp(
            firstName: _firstNameCtrl.text.trim(),
            email: _emailCtrl.text.trim(),
            password: _passwordCtrl.text,
            birthDate: _birthDate!,
          );

      if (!mounted) return;
      final l10n = AppLocalizations.of(context);

      switch (outcome) {
        case SignUpOutcome.signedIn:
          // Router automatically pushes /profile-setup once
          // authStateProvider emits the new user.
          break;
        case SignUpOutcome.needsEmailConfirmation:
          context.pushReplacementNamed(
            AppRoute.verifyEmail.name,
            extra: _emailCtrl.text.trim(),
          );
          break;
        case SignUpOutcome.failed:
          final err = ref.read(authControllerProvider).error;
          String msg;
          if (err is Failure && err.code == 'rate_limited') {
            msg = l10n.signupRateLimited;
          } else if (err is Failure) {
            msg = err.message;
          } else {
            msg = l10n.couldNotSignUp;
          }
          context.showSnack(msg);
          break;
        case SignUpOutcome.alreadyInFlight:
          // Should never reach here from the UI thanks to `_submitting`,
          // but if it ever does, silently ignore.
          break;
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
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
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.email],
              validator: (v) => Validators.email(v, l10n),
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              controller: _passwordCtrl,
              label: l10n.passwordLabel,
              hint: l10n.passwordHintNew,
              prefixIcon: Icons.lock_outline_rounded,
              obscureText: true,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.newPassword],
              validator: (v) => Validators.password(v, l10n),
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              controller: _confirmCtrl,
              label: l10n.confirmPasswordLabel,
              hint: l10n.confirmPasswordHint,
              prefixIcon: Icons.lock_outline_rounded,
              obscureText: true,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.newPassword],
              validator: (v) =>
                  Validators.confirmPassword(v, _passwordCtrl.text, l10n),
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

// The legacy "demo mode" banner has been removed: whether the app is
// running against a real Supabase project is a developer-only concern
// surfaced via console logs in main.dart and the auth repository — never
// inline in the sign-up UI.
