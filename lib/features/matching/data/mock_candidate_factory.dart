import 'dart:math' as math;

import '../../profile_setup/domain/enums.dart';
import '../../profile_setup/domain/interest.dart';
import '../../profile_setup/domain/user_profile.dart';

/// Synthesises plausible candidate profiles for the mock backend.
///
/// Shared between [MockMatchingRepository] (one-shot live matches) and the
/// mock discover repository (weekly suggestions) so the same compatibility
/// distribution drives both surfaces.
class MockCandidateFactory {
  MockCandidateFactory({math.Random? random})
      : _random = random ?? math.Random();

  final math.Random _random;

  static const _firstNames = [
    'Alex', 'Sam', 'Jordan', 'Camille', 'Robin',
    'Charlie', 'Léa', 'Noa', 'Maxime', 'Inès',
    'Maël', 'Salomé', 'Aaron', 'Yasmine', 'Ezra',
  ];

  /// Generates a candidate consistent with [self]'s seeking criteria — so
  /// the reciprocal hard gates in `MatchingService` always pass — or
  /// returns `null` if [self] hasn't filled in the bits we need to build
  /// against (gender, age, seeking genders).
  UserProfile? build(UserProfile self) {
    if (self.seekingGenders.isEmpty ||
        self.gender == null ||
        self.age == null) {
      return null;
    }

    final gender = self.seekingGenders.elementAt(
      _random.nextInt(self.seekingGenders.length),
    );

    final ageCentre =
        ((self.seekingAgeMin + self.seekingAgeMax) / 2).round();
    final ageJitter =
        ((self.seekingAgeMax - self.seekingAgeMin) ~/ 3).clamp(1, 99);
    final age = (ageCentre - ageJitter + _random.nextInt(ageJitter * 2 + 1))
        .clamp(self.seekingAgeMin, self.seekingAgeMax);
    // Anchor a real DOB at "today minus `age` years" so the synthetic
    // candidate passes the same age-derivation logic as real users.
    final today = DateTime.now();
    final candidateBirthDate =
        DateTime(today.year - age, today.month, today.day);

    final seekingGenders = <Gender>{self.gender!};
    for (final g in [...Gender.values]..shuffle(_random)) {
      if (seekingGenders.length >= 2) break;
      if (_random.nextBool()) seekingGenders.add(g);
    }

    final candidateAgeRangeMin =
        math.min(self.age!, age) - 2 - _random.nextInt(4);
    final candidateAgeRangeMax =
        math.max(self.age!, age) + 2 + _random.nextInt(6);

    final candidateIntentions = <Intention>{};
    if (self.intentions.isNotEmpty) {
      candidateIntentions.add(
        self.intentions.elementAt(_random.nextInt(self.intentions.length)),
      );
    }
    for (final i in [...Intention.values]..shuffle(_random)) {
      if (candidateIntentions.length >= 2) break;
      if (_random.nextDouble() < 0.5) candidateIntentions.add(i);
    }

    final shuffledSelf = self.interests.toList()..shuffle(_random);
    final keep =
        shuffledSelf.take(shuffledSelf.length.clamp(0, 5)).toSet();
    final extras = <Interest>{};
    for (final i in [...Interest.values]..shuffle(_random)) {
      if (extras.length >= 3) break;
      if (self.interests.contains(i)) continue;
      extras.add(i);
    }
    final candidateInterests = {...keep, ...extras};

    final availability = _random.nextDouble() < 0.7
        ? Availability.immediate
        : Availability.sometime;

    return UserProfile(
      userId: 'mock-candidate-${_random.nextInt(1 << 31)}',
      firstName: _firstNames[_random.nextInt(_firstNames.length)],
      birthDate: candidateBirthDate,
      gender: gender,
      orientation: self.orientation, // safe stand-in for the demo
      seekingGenders: seekingGenders,
      seekingAgeMin: candidateAgeRangeMin.clamp(18, 80),
      seekingAgeMax: candidateAgeRangeMax.clamp(18, 80),
      maxDistanceKm: self.maxDistanceKm,
      intentions: candidateIntentions,
      interests: candidateInterests,
      availability: availability,
    );
  }

  /// A plausible "current distance" between [self] and a freshly generated
  /// candidate, capped at the user's preference.
  int distanceFor(UserProfile self) {
    return 1 + _random.nextInt(self.maxDistanceKm.clamp(1, 500));
  }
}
