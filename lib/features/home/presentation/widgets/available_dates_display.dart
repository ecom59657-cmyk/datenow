import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/app_localizations.dart';

/// `value` (big number) + `label` (text underneath) for the
/// "dates proposés aujourd'hui" Home stat tile. Keeps the three states
/// (loading / empty / count) in one pure place so they can be tested
/// without mounting the screen.
class AvailableDatesDisplay {
  const AvailableDatesDisplay({required this.value, required this.label});
  final String value;
  final String label;
}

AvailableDatesDisplay formatAvailableDates(
  AppLocalizations l10n,
  AsyncValue<int?> state,
) {
  return state.when(
    loading: () => AvailableDatesDisplay(
      value: l10n.availableDatesValueLoading,
      label: l10n.availableDatesLabelLoading,
    ),
    // Don't surface a wrong number on error — fall back to the empty look.
    error: (_, _) => AvailableDatesDisplay(
      value: l10n.availableDatesValueEmpty,
      label: l10n.availableDatesLabelEmpty,
    ),
    data: (count) {
      if (count == null || count <= 0) {
        return AvailableDatesDisplay(
          value: l10n.availableDatesValueEmpty,
          label: l10n.availableDatesLabelEmpty,
        );
      }
      return AvailableDatesDisplay(
        value: '$count',
        label: l10n.availableDatesLabel(count),
      );
    },
  );
}
