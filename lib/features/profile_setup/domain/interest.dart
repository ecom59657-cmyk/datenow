import '../../../l10n/app_localizations.dart';

/// Catalog of interests proposed during profile setup. Stored on the profile
/// as a `Set<Interest>` — order doesn't matter and duplicates are impossible.
enum Interest {
  music,
  films,
  sports,
  fitness,
  foodie,
  travel,
  books,
  gaming,
  dance,
  nature,
  photography,
  art,
  fashion,
  wellness,
  cooking,
  animals,
}

extension InterestX on Interest {
  String label(AppLocalizations l) => switch (this) {
        Interest.music => l.interestMusic,
        Interest.films => l.interestFilms,
        Interest.sports => l.interestSports,
        Interest.fitness => l.interestFitness,
        Interest.foodie => l.interestFoodie,
        Interest.travel => l.interestTravel,
        Interest.books => l.interestBooks,
        Interest.gaming => l.interestGaming,
        Interest.dance => l.interestDance,
        Interest.nature => l.interestNature,
        Interest.photography => l.interestPhotography,
        Interest.art => l.interestArt,
        Interest.fashion => l.interestFashion,
        Interest.wellness => l.interestWellness,
        Interest.cooking => l.interestCooking,
        Interest.animals => l.interestAnimals,
      };
}
