import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../l10n/app_localizations.dart';

/// `value` (big number) + `label` (text underneath) for the "personnes en
/// ligne" Home stat tile. Same shape as [AvailableDatesDisplay]: the three
/// states (loading / empty / count) live in one pure place so they can be
/// tested without mounting the screen.
class PeopleOnlineDisplay {
  const PeopleOnlineDisplay({required this.value, required this.label});
  final String value;
  final String label;
}

PeopleOnlineDisplay formatPeopleOnline(
  AppLocalizations l10n,
  AsyncValue<int?> state,
) {
  return state.when(
    loading: () => PeopleOnlineDisplay(
      value: l10n.peopleOnlineValueLoading,
      label: l10n.peopleOnlineLabelLoading,
    ),
    // Don't surface a wrong number on error — fall back to the empty look.
    error: (_, _) => PeopleOnlineDisplay(
      value: l10n.peopleOnlineValueEmpty,
      label: l10n.peopleOnlineLabelEmpty,
    ),
    data: (count) {
      if (count == null || count <= 0) {
        return PeopleOnlineDisplay(
          value: l10n.peopleOnlineValueEmpty,
          label: l10n.peopleOnlineLabelEmpty,
        );
      }
      return PeopleOnlineDisplay(
        value: '$count',
        label: l10n.peopleOnlineLabel(count),
      );
    },
  );
}
