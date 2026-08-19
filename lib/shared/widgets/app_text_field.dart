import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';

/// The app's text field: paper ground, hairline border, and a 3 px [tint]
/// halo on focus instead of a coloured glow.
///
/// The halo is drawn by the wrapper rather than by [InputDecoration],
/// which has no way to paint outside its own border.
class AppTextField extends StatefulWidget {
  const AppTextField({
    super.key,
    this.controller,
    this.label,
    this.hint,
    this.prefixIcon,
    this.obscureText = false,
    this.keyboardType,
    this.textInputAction,
    this.inputFormatters,
    this.validator,
    this.autofillHints,
    this.onChanged,
    this.onSubmitted,
    this.enabled = true,
  });

  final TextEditingController? controller;
  final String? label;
  final String? hint;
  final IconData? prefixIcon;
  final bool obscureText;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final List<TextInputFormatter>? inputFormatters;
  final String? Function(String?)? validator;
  final Iterable<String>? autofillHints;
  final void Function(String)? onChanged;
  final void Function(String)? onSubmitted;
  final bool enabled;

  @override
  State<AppTextField> createState() => _AppTextFieldState();
}

class _AppTextFieldState extends State<AppTextField> {
  late bool _obscured = widget.obscureText;
  final FocusNode _focusNode = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      if (_focusNode.hasFocus != _focused) {
        setState(() => _focused = _focusNode.hasFocus);
      }
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.label != null) ...[
          Text(
            widget.label!,
            style: AppTypography.caption.copyWith(
              color: AppColors.ink2,
              letterSpacing: 0.3,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
        ],
        AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            borderRadius: AppRadius.brMd,
            boxShadow: _focused
                ? const [BoxShadow(color: AppColors.tint, spreadRadius: 3)]
                : null,
          ),
          child: TextFormField(
            focusNode: _focusNode,
            controller: widget.controller,
            obscureText: _obscured,
            keyboardType: widget.keyboardType,
            textInputAction: widget.textInputAction,
            inputFormatters: widget.inputFormatters,
            validator: widget.validator,
            autofillHints: widget.autofillHints,
            onChanged: widget.onChanged,
            onFieldSubmitted: widget.onSubmitted,
            enabled: widget.enabled,
            style: AppTypography.bodyLarge,
            cursorColor: AppColors.bordeaux,
            decoration: InputDecoration(
              hintText: widget.hint,
              prefixIcon: widget.prefixIcon != null
                  ? Icon(widget.prefixIcon, color: AppColors.ink3, size: 20)
                  : null,
              suffixIcon: widget.obscureText
                  ? IconButton(
                      onPressed: () => setState(() => _obscured = !_obscured),
                      // 48 px minimum tap target — the default IconButton
                      // constraints are 40.
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                      icon: Icon(
                        _obscured
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                        color: AppColors.ink3,
                        size: 20,
                      ),
                    )
                  : null,
            ),
          ),
        ),
      ],
    );
  }
}
