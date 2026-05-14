import '../../l10n/app_localizations.dart';
import 'age.dart';

/// Form validators returning a localized error message or `null` when valid.
///
/// All validators take an [AppLocalizations] so error copy follows the
/// device locale. We deliberately don't fall back to hardcoded English —
/// the convention is: if you can't reach an [AppLocalizations], you can't
/// validate.
class Validators {
  const Validators._();

  static final RegExp _emailRegex =
      RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

  static String? email(String? value, AppLocalizations l10n) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) return l10n.validatorEmailRequired;
    if (!_emailRegex.hasMatch(v)) return l10n.validatorEmailInvalid;
    return null;
  }

  static String? password(String? value, AppLocalizations l10n) {
    final v = value ?? '';
    if (v.isEmpty) return l10n.validatorPasswordRequired;
    if (v.length < 8) return l10n.validatorPasswordShort;
    return null;
  }

  static String? firstName(String? value, AppLocalizations l10n) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) return l10n.validatorNameRequired;
    if (v.length < 2) return l10n.validatorNameShort;
    return null;
  }

  static String? confirmPassword(
    String? value,
    String original,
    AppLocalizations l10n,
  ) {
    final v = value ?? '';
    if (v.isEmpty) return l10n.validatorConfirmRequired;
    if (v != original) return l10n.validatorConfirmMismatch;
    return null;
  }

  /// Date-of-birth validator. Enforces the legal 18+ floor — the same
  /// message + cutoff is also used by the controller and the repository
  /// (frontend validation alone is never enough).
  static String? birthDate(DateTime? value, AppLocalizations l10n) {
    if (value == null) return l10n.validatorBirthDateRequired;
    final today = DateTime.now();
    if (value.isAfter(today)) return l10n.validatorBirthDateInvalid;
    if (!isOfMinimumAge(value)) return l10n.validatorBirthDateMinor;
    return null;
  }
}
