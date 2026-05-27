import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/utils/extensions.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/widgets/app_button.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../providers/auth_provider.dart';
import '../utils/auth_error_mapper.dart';

/// Arguments passed via `context.pushReplacementNamed(emailOtp, extra:
/// EmailOtpArgs(...))`. Carries the email being verified + whether the
/// user came from signup (in which case first_name + birth_date are
/// kept so a Resend re-attaches the metadata) or signin (resend is a
/// plain re-request).
class EmailOtpArgs {
  const EmailOtpArgs({
    required this.email,
    required this.isSignup,
    this.firstName,
    this.birthDate,
  });

  final String email;
  final bool isSignup;
  final String? firstName;
  final DateTime? birthDate;
}

/// Six-digit OTP entry screen. Auto-focuses, accepts paste, validates
/// length, surfaces humane errors. Resend button armed after a 30 s
/// cooldown to mirror Supabase's rate-limit + nudge the user not to
/// spam.
class EmailOtpScreen extends ConsumerStatefulWidget {
  const EmailOtpScreen({super.key, required this.args});

  final EmailOtpArgs args;

  @override
  ConsumerState<EmailOtpScreen> createState() => _EmailOtpScreenState();
}

class _EmailOtpScreenState extends ConsumerState<EmailOtpScreen> {
  static const _codeLength = 6;
  static const _resendCooldownSeconds = 30;

  final TextEditingController _codeCtrl = TextEditingController();
  final FocusNode _codeFocus = FocusNode();
  Timer? _resendTimer;
  int _resendSecondsLeft = _resendCooldownSeconds;
  bool _verifying = false;

  @override
  void initState() {
    super.initState();
    _startResendCooldown();
    // Autofocus after the first frame so the keyboard rises without a
    // setState-induced jank.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _codeFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _resendTimer?.cancel();
    _codeCtrl.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  void _startResendCooldown() {
    _resendSecondsLeft = _resendCooldownSeconds;
    _resendTimer?.cancel();
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        _resendSecondsLeft = (_resendSecondsLeft - 1).clamp(0, 9999);
        if (_resendSecondsLeft == 0) t.cancel();
      });
    });
  }

  bool get _canResend => _resendSecondsLeft == 0 && !_verifying;

  Future<void> _verify() async {
    if (_verifying) return;
    final code = _codeCtrl.text.trim();
    if (code.length != _codeLength) return;
    setState(() => _verifying = true);
    context.hideKeyboard();
    final ok = await ref.read(authControllerProvider.notifier).verifyOtp(
          email: widget.args.email,
          token: code,
        );
    if (!mounted) return;
    setState(() => _verifying = false);
    if (ok) {
      // Auth state stream will emit → router redirect handles the next
      // screen (profile-setup or home depending on isComplete).
      return;
    }
    final l10n = AppLocalizations.of(context);
    final err = ref.read(authControllerProvider).error;
    context.showSnack(_humanError(err, l10n));
    // Clear the invalid code so the user can retype without backspace
    // spam — keeps focus to keep the keyboard up.
    _codeCtrl.clear();
    _codeFocus.requestFocus();
  }

  Future<void> _resend() async {
    if (!_canResend) return;
    setState(() => _verifying = true);
    final controller = ref.read(authControllerProvider.notifier);
    final OtpRequestOutcome outcome;
    if (widget.args.isSignup) {
      outcome = await controller.requestSignupOtp(
        email: widget.args.email,
        firstName: widget.args.firstName ?? '',
        birthDate: widget.args.birthDate ?? DateTime.now(),
      );
    } else {
      outcome = await controller.requestSigninOtp(email: widget.args.email);
    }
    if (!mounted) return;
    setState(() => _verifying = false);
    final l10n = AppLocalizations.of(context);
    switch (outcome) {
      case OtpRequestOutcome.sent:
        context.showSnack(l10n.otpResentSnack);
        _startResendCooldown();
      case OtpRequestOutcome.failed:
        final err = ref.read(authControllerProvider).error;
        context.showSnack(_humanError(err, l10n));
      case OtpRequestOutcome.alreadyInFlight:
        break;
    }
  }

  String _humanError(Object? err, AppLocalizations l10n) =>
      humaneAuthError(err, l10n, fallback: AuthFallback.otpVerify);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AppScaffold(
      appBar: AppBar(leading: const BackButton()),
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          const SizedBox(height: AppSpacing.lg),
          Text(l10n.otpTitle, style: AppTypography.h1),
          const SizedBox(height: AppSpacing.sm),
          Text.rich(
            TextSpan(
              style: AppTypography.body
                  .copyWith(color: AppColors.textSecondary),
              children: [
                TextSpan(text: l10n.otpSubtitlePrefix),
                const TextSpan(text: ' '),
                TextSpan(
                  text: widget.args.email,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                TextSpan(text: l10n.otpSubtitleSuffix),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          _OtpCodeField(
            controller: _codeCtrl,
            focusNode: _codeFocus,
            onCompleted: (_) => _verify(),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            l10n.otpHelper,
            style: AppTypography.caption.copyWith(
              color: AppColors.textTertiary,
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          AppButton(
            label: l10n.otpValidate,
            size: AppButtonSize.large,
            isLoading: _verifying,
            onPressed: _verifying ? null : _verify,
          ),
          const SizedBox(height: AppSpacing.md),
          Center(
            child: TextButton(
              onPressed: _canResend ? _resend : null,
              child: Text(
                _canResend
                    ? l10n.otpResend
                    : l10n.otpResendIn(_resendSecondsLeft),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Single-field 6-digit input with a monospace, generously-spaced
/// look. Pure TextField under the hood — works with iOS autofill of
/// SMS / email codes (Securityassisted suggestions surface above the
/// keyboard automatically thanks to `autofillHints: [oneTimeCode]`).
class _OtpCodeField extends StatelessWidget {
  const _OtpCodeField({
    required this.controller,
    required this.focusNode,
    required this.onCompleted,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onCompleted;

  static const int _codeLength = 6;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      keyboardType: TextInputType.number,
      textAlign: TextAlign.center,
      autofillHints: const [AutofillHints.oneTimeCode],
      maxLength: _codeLength,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(_codeLength),
      ],
      style: AppTypography.display.copyWith(
        fontSize: 36,
        letterSpacing: 12,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
      decoration: const InputDecoration(
        counterText: '',
        contentPadding: EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: 18,
        ),
        filled: true,
        fillColor: AppColors.surfaceElevated,
        border: OutlineInputBorder(
          borderRadius: AppRadius.brMd,
          borderSide: BorderSide(color: AppColors.hairline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppRadius.brMd,
          borderSide: BorderSide(color: AppColors.hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AppRadius.brMd,
          borderSide: BorderSide(
            color: AppColors.brandPink,
            width: 1.5,
          ),
        ),
      ),
      onChanged: (v) {
        if (v.length == _codeLength) onCompleted(v);
      },
    );
  }
}
