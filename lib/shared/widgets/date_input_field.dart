import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';

/// Premium date-of-birth field. Tapping opens a themed [showDatePicker]; the
/// selected date is rendered inside an [InputDecorator] that visually
/// matches [AppTextField] (border, fill, prefix icon).
///
/// Pairs with [FormField] so it integrates with the same `Form.validate`
/// flow used by the other auth fields.
class DateInputField extends FormField<DateTime> {
  DateInputField({
    super.key,
    super.initialValue,
    required String label,
    required String hint,
    super.validator,
    ValueChanged<DateTime?>? onChanged,
    DateTime? firstDate,
    DateTime? lastDate,
  }) : super(
          autovalidateMode: AutovalidateMode.onUserInteraction,
          builder: (state) {
            Future<void> pick() async {
              final initial =
                  state.value ?? DateTime(DateTime.now().year - 25);
              final picked = await showDatePicker(
                context: state.context,
                initialDate: initial,
                firstDate: firstDate ?? DateTime(1900),
                lastDate: lastDate ?? DateTime.now(),
                builder: (context, child) {
                  return Theme(
                    data: Theme.of(context).copyWith(
                      colorScheme: Theme.of(context).colorScheme.copyWith(
                            primary: AppColors.brandPink,
                            onPrimary: Colors.white,
                            surface: AppColors.surfaceElevated,
                            onSurface: AppColors.textPrimary,
                          ),
                    ),
                    child: child!,
                  );
                },
              );
              if (picked != null) {
                state.didChange(picked);
                onChanged?.call(picked);
              }
            }

            final localeName = Localizations.localeOf(state.context).toString();
            final display = state.value == null
                ? hint
                : DateFormat.yMMMMd(localeName).format(state.value!);

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: AppTypography.caption.copyWith(
                    color: AppColors.textSecondary,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: pick,
                    borderRadius: AppRadius.brMd,
                    child: InputDecorator(
                      isFocused: false,
                      decoration: InputDecoration(
                        prefixIcon: const Icon(
                          Icons.cake_outlined,
                          color: AppColors.textTertiary,
                          size: 20,
                        ),
                        errorText: state.errorText,
                        suffixIcon: const Icon(
                          Icons.calendar_today_rounded,
                          color: AppColors.textTertiary,
                          size: 18,
                        ),
                      ),
                      child: Text(
                        display,
                        style: AppTypography.bodyLarge.copyWith(
                          color: state.value == null
                              ? AppColors.textTertiary
                              : AppColors.textPrimary,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
}
