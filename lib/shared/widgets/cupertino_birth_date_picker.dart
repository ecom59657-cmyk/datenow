import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app/theme/app_colors.dart';
import '../../app/theme/app_spacing.dart';
import '../../app/theme/app_typography.dart';
import '../../core/utils/age.dart';
import '../../l10n/app_localizations.dart';

/// Birth-date selector with three iOS-native [CupertinoPicker] wheels
/// (day / month / year). Tapping the visible card opens a bottom modal
/// with the three scrollable wheels + Cancel / Done buttons — the
/// Apple-native pattern used by Hinge, Raya, etc.
///
/// Form-friendly: extends [FormField<DateTime>] so the existing
/// `Validators.birthDate` flow keeps working without changes. Outputs
/// a [DateTime] — the same shape `auth_repository.dart` already feeds
/// into Supabase as an ISO `YYYY-MM-DD` string. Locale-aware month
/// labels via `intl.DateFormat.MMMM`.
///
/// Defaults:
///   * `firstDate` = 100 years ago today
///   * `lastDate`  = `kMinAgeYears` years ago today (= 18 → enforced
///                   visually so the wheels never let a user pick an
///                   age below the minimum; the validator stays as a
///                   server-aligned belt-and-suspenders check)
class CupertinoBirthDatePicker extends FormField<DateTime> {
  CupertinoBirthDatePicker({
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
            final now = DateTime.now();
            final firstAllowed = firstDate ?? DateTime(now.year - 100);
            final lastAllowed =
                lastDate ?? DateTime(now.year - kMinAgeYears, now.month, now.day);

            Future<void> openPicker() async {
              final initial = state.value ??
                  DateTime(now.year - 25, now.month, now.day);
              final picked = await showCupertinoModalPopup<DateTime>(
                context: state.context,
                builder: (ctx) => _BirthDatePickerSheet(
                  initial: _clamp(initial, firstAllowed, lastAllowed),
                  firstDate: firstAllowed,
                  lastDate: lastAllowed,
                ),
              );
              if (picked == null) return;
              state.didChange(picked);
              onChanged?.call(picked);
            }

            final value = state.value;
            final hasValue = value != null;
            return InkWell(
              onTap: openPicker,
              borderRadius: AppRadius.brMd,
              child: InputDecorator(
                isFocused: false,
                isEmpty: !hasValue,
                decoration: InputDecoration(
                  labelText: label,
                  hintText: hint,
                  prefixIcon: const Icon(
                    Icons.cake_outlined,
                    color: AppColors.textTertiary,
                  ),
                  errorText: state.errorText,
                  floatingLabelBehavior: FloatingLabelBehavior.auto,
                ),
                child: hasValue
                    ? Text(
                        DateFormat.yMMMMd(_localeTag(state.context))
                            .format(value),
                        style: AppTypography.bodyLarge,
                      )
                    : const SizedBox.shrink(),
              ),
            );
          },
        );

  static DateTime _clamp(DateTime d, DateTime min, DateTime max) {
    if (d.isBefore(min)) return min;
    if (d.isAfter(max)) return max;
    return d;
  }

  static String _localeTag(BuildContext context) {
    return Localizations.localeOf(context).toLanguageTag();
  }
}

/// Bottom sheet that hosts the three [CupertinoPicker] wheels and the
/// Cancel / Done buttons. Self-contained so it can be tested in
/// isolation later if needed.
class _BirthDatePickerSheet extends StatefulWidget {
  const _BirthDatePickerSheet({
    required this.initial,
    required this.firstDate,
    required this.lastDate,
  });

  final DateTime initial;
  final DateTime firstDate;
  final DateTime lastDate;

  @override
  State<_BirthDatePickerSheet> createState() => _BirthDatePickerSheetState();
}

class _BirthDatePickerSheetState extends State<_BirthDatePickerSheet> {
  late int _day;
  late int _month;
  late int _year;

  late FixedExtentScrollController _dayCtrl;
  late FixedExtentScrollController _monthCtrl;
  late FixedExtentScrollController _yearCtrl;

  // Year range derived from firstDate / lastDate.
  late final int _minYear = widget.firstDate.year;
  late final int _maxYear = widget.lastDate.year;

  // Cached month labels in the active locale (full names, e.g. "janvier").
  late final List<String> _monthLabels = List<String>.generate(12, (i) {
    return DateFormat.MMMM(_localeTag).format(DateTime(2000, i + 1));
  });

  String get _localeTag => Localizations.localeOf(context).toLanguageTag();

  @override
  void initState() {
    super.initState();
    _day = widget.initial.day;
    _month = widget.initial.month;
    _year = widget.initial.year;
    _dayCtrl = FixedExtentScrollController(initialItem: _day - 1);
    _monthCtrl = FixedExtentScrollController(initialItem: _month - 1);
    _yearCtrl = FixedExtentScrollController(initialItem: _year - _minYear);
  }

  @override
  void dispose() {
    _dayCtrl.dispose();
    _monthCtrl.dispose();
    _yearCtrl.dispose();
    super.dispose();
  }

  int _daysInMonth(int year, int month) {
    // Trick: day 0 of the next month is the last day of this month.
    return DateTime(year, month + 1, 0).day;
  }

  /// Clamps the current `_day` if the month/year change shortens the
  /// available days (e.g. user lands on Feb 30 when February has 28).
  void _clampDayIfNeeded() {
    final maxDay = _daysInMonth(_year, _month);
    if (_day > maxDay) {
      _day = maxDay;
      _dayCtrl.jumpToItem(_day - 1);
    }
  }

  /// Returns the selected date clamped to the allowed [firstDate, lastDate].
  DateTime _selected() {
    final raw = DateTime(_year, _month, _day);
    if (raw.isBefore(widget.firstDate)) return widget.firstDate;
    if (raw.isAfter(widget.lastDate)) return widget.lastDate;
    return raw;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final maxDay = _daysInMonth(_year, _month);

    return Container(
      height: 320,
      decoration: const BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            // Header — Cancel + title + Done
            Container(
              height: 52,
              padding:
                  const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              decoration: const BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: AppColors.hairlineSoft),
                ),
              ),
              child: Row(
                children: [
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () => Navigator.pop(context),
                    child: Text(
                      l10n.cancel,
                      style: AppTypography.bodyStrong
                          .copyWith(color: AppColors.textSecondary),
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: Text(
                        l10n.birthDateLabel,
                        style: AppTypography.bodyStrong,
                      ),
                    ),
                  ),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () => Navigator.pop(context, _selected()),
                    child: Text(
                      l10n.commonDone,
                      style: AppTypography.bodyStrong
                          .copyWith(color: AppColors.brandPink),
                    ),
                  ),
                ],
              ),
            ),
            // Three-wheel picker. Day on the LEFT, then month, then year
            // — matches the French / English natural reading order in
            // both locales we support.
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: CupertinoPicker(
                      scrollController: _dayCtrl,
                      itemExtent: 36,
                      onSelectedItemChanged: (i) {
                        setState(() => _day = i + 1);
                      },
                      children: [
                        for (var d = 1; d <= maxDay; d++)
                          Center(
                            child: Text(
                              d.toString().padLeft(2, '0'),
                              style: AppTypography.bodyLarge,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    flex: 4,
                    child: CupertinoPicker(
                      scrollController: _monthCtrl,
                      itemExtent: 36,
                      onSelectedItemChanged: (i) {
                        setState(() {
                          _month = i + 1;
                          _clampDayIfNeeded();
                        });
                      },
                      children: [
                        for (var m = 0; m < 12; m++)
                          Center(
                            child: Text(
                              _monthLabels[m],
                              style: AppTypography.bodyLarge,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: CupertinoPicker(
                      scrollController: _yearCtrl,
                      itemExtent: 36,
                      onSelectedItemChanged: (i) {
                        setState(() {
                          _year = _minYear + i;
                          _clampDayIfNeeded();
                        });
                      },
                      children: [
                        for (var y = _minYear; y <= _maxYear; y++)
                          Center(
                            child: Text(
                              '$y',
                              style: AppTypography.bodyLarge,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
