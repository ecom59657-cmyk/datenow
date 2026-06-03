// Parsing guard for the get_matched_profile RPC row → MatchedProfile.
// Locks the two things the screen depends on: (1) age comes through already
// computed and birth_date is never present, (2) interests map from the
// server's TEXT[] enum names to the Interest enum, dropping unknowns.

import 'package:datenow/features/matching/domain/matched_profile.dart';
import 'package:datenow/features/profile_setup/domain/interest.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MatchedProfile.fromRpc', () {
    test('maps every field from a full RPC row', () {
      final p = MatchedProfile.fromRpc({
        'user_id': 'u-123',
        'first_name': 'Camille',
        'age': 29,
        'compatibility_score': 82,
        'main_photo_path': 'u-123/primary.jpg',
        'interests': ['music', 'travel', 'cooking'],
      });

      expect(p.userId, 'u-123');
      expect(p.firstName, 'Camille');
      expect(p.age, 29);
      expect(p.compatibilityScore, 82);
      expect(p.mainPhotoPath, 'u-123/primary.jpg');
      expect(p.interests,
          [Interest.music, Interest.travel, Interest.cooking]);
    });

    test('drops unknown / legacy interest strings instead of rendering raw',
        () {
      final p = MatchedProfile.fromRpc({
        'user_id': 'u-1',
        'first_name': 'Alex',
        'age': 31,
        'compatibility_score': 60,
        'main_photo_path': null,
        'interests': ['music', 'totally_unknown', 'art'],
      });

      expect(p.interests, [Interest.music, Interest.art]);
    });

    test('tolerates a null photo, null name and empty interests', () {
      final p = MatchedProfile.fromRpc({
        'user_id': 'u-2',
        'first_name': null,
        'age': null,
        'compatibility_score': 0,
        'main_photo_path': null,
        'interests': <dynamic>[],
      });

      expect(p.mainPhotoPath, isNull);
      expect(p.firstName, isNull);
      expect(p.age, isNull);
      expect(p.interests, isEmpty);
    });

    test('never reads birth_date even if the backend leaked it', () {
      // Defense-in-depth: the model only knows about `age`. Presence of a
      // stray birth_date key must not surface anywhere on the object.
      final p = MatchedProfile.fromRpc({
        'user_id': 'u-3',
        'first_name': 'Sam',
        'age': 25,
        'birth_date': '2001-01-01',
        'compatibility_score': 70,
        'main_photo_path': null,
        'interests': <dynamic>[],
      });

      expect(p.age, 25);
      // The object exposes no birth_date accessor — this just documents that
      // the parser ignores it entirely.
    });
  });
}
