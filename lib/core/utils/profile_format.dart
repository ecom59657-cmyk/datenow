import '../../l10n/app_localizations.dart';

/// Renders a profile's display label in the form "Emma, 25 ans" (FR) or
/// "Emma, 25" (EN). Centralised so every card / banner / match view in
/// the app reads the same string — change the format once in the .arb
/// (`profileNameAge`) and every consumer follows.
///
/// Returns the bare name (falling back to "—") when [age] is null so a
/// freshly-onboarded profile without a birth date doesn't surface as
/// "Emma, null".
String formatProfileNameAge(
  AppLocalizations l10n, {
  required String? firstName,
  required int? age,
}) {
  final name = firstName?.trim().isNotEmpty == true ? firstName!.trim() : '—';
  if (age == null) return name;
  return l10n.profileNameAge(name, age);
}
