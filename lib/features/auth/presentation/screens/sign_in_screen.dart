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
import '../providers/auth_provider.dart';

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    context.hideKeyboard();
    final l10n = AppLocalizations.of(context);
    final ok = await ref.read(authControllerProvider.notifier).signIn(
          email: _emailCtrl.text.trim(),
          password: _passwordCtrl.text,
        );
    if (!ok && mounted) {
      final err = ref.read(authControllerProvider).error;
      final msg = err is Failure ? err.message : l10n.couldNotSignIn;
      context.showSnack(msg);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final auth = ref.watch(authControllerProvider);
    final isLoading = auth.isLoading;

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
              l10n.signInSubtitle,
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
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.email],
              validator: (v) => Validators.email(v, l10n),
            ),
            const SizedBox(height: AppSpacing.md),
            AppTextField(
              controller: _passwordCtrl,
              label: l10n.passwordLabel,
              hint: l10n.passwordHintCurrent,
              prefixIcon: Icons.lock_outline_rounded,
              obscureText: true,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.password],
              validator: (v) => Validators.password(v, l10n),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: isLoading ? null : () {},
                child: Text(l10n.forgotPassword),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            AppButton(
              label: l10n.signInButton,
              size: AppButtonSize.large,
              isLoading: isLoading,
              onPressed: isLoading ? null : _submit,
            ),
            const SizedBox(height: AppSpacing.md),
            Center(
              child: TextButton(
                onPressed: isLoading
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

// The legacy "demo mode" banner has been removed — whether the app is
// running against a real Supabase project is a developer-only concern
// surfaced via console logs.
