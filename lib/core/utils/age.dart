/// Hard age floor for DateNow. The rule lives here so every layer (UI,
/// controller, repository, database) reads from a single constant.
const int kMinAgeYears = 18;

/// Returns the calendar age in completed years for a given date of birth.
///
/// `now` is injectable so tests don't depend on the wall clock — production
/// callers can omit it.
int ageFromBirthDate(DateTime birthDate, {DateTime? now}) {
  final today = now ?? DateTime.now();
  var age = today.year - birthDate.year;
  final beforeBirthdayThisYear = today.month < birthDate.month ||
      (today.month == birthDate.month && today.day < birthDate.day);
  if (beforeBirthdayThisYear) age -= 1;
  return age;
}

/// Convenience: did the person hit `kMinAgeYears` (18) on or before `now`?
bool isOfMinimumAge(DateTime birthDate, {DateTime? now}) {
  return ageFromBirthDate(birthDate, now: now) >= kMinAgeYears;
}
