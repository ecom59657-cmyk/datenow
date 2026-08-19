// Guideline 1.2 asks a UGC app for a filter, reporting, blocking and
// contact details. Reporting and blocking already existed; this covers the
// filter.
//
// The authority is the database trigger — a rule that only lives in the app
// is not a rule, and a tampered client would walk straight past it. What is
// tested here is the client-side half: the structural shapes, caught while
// typing so the answer never leaves the phone.

import 'dart:io';

import 'package:datenow/features/profile_setup/domain/prompt_moderation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('contact details are refused', () {
    const samples = [
      'écris-moi sur alex@example.com',
      'mon insta cest @alex.thomas',
      '06 12 34 56 78 si tu veux',
      '0612345678',
      'https://instagram.com/alex',
      'www.monsite.fr',
      'on continue sur Snapchat ?',
      'telegram plutôt',
    ];

    for (final sample in samples) {
      test('"$sample"', () {
        expect(
          PromptModeration.check(sample),
          PromptRejection.contact,
          reason: 'moving someone off-platform is where reporting and '
              'blocking stop existing',
        );
      });
    }
  });

  group('ordinary answers pass', () {
    const samples = [
      'Un marché le matin, un vieux film l\'après-midi.',
      'Les fonds marins. Vraiment des heures.',
      'Des pâtes dans une gare, à Naples, à 2 h du matin.',
      'J\'ai 32 ans et 2 chats',
      'Le 15 août 2019, sans hésiter',
      'Manger, sport, dodo',
    ];

    for (final sample in samples) {
      test('"$sample"', () {
        expect(PromptModeration.check(sample), isNull);
      });
    }
  });

  group('server refusals map back to a reason', () {
    test('contact', () {
      expect(
        PromptModeration.fromServerError(
          Exception('PostgrestException: prompt_rejected:contact'),
        ),
        PromptRejection.contact,
      );
    });

    test('a term falls back to the vaguer message', () {
      expect(
        PromptModeration.fromServerError(
          Exception('PostgrestException: prompt_rejected:term'),
        ),
        PromptRejection.term,
      );
    });

    test('an unrelated failure is not a rejection', () {
      expect(
        PromptModeration.fromServerError(Exception('network unreachable')),
        isNull,
      );
    });
  });

  group('the filter is enforced server-side too', () {
    test('a trigger guards user_prompts', () {
      final sql =
          File('supabase/migrations/20260819190000_prompt_moderation.sql')
              .readAsStringSync();
      expect(sql, contains('BEFORE INSERT OR UPDATE OF answer ON public.user_prompts'));
      expect(sql, contains('prompt_rejected:'));
    });

    test('the term list is not shipped in the app bundle', () {
      // Publishing the list publishes the way around it, and a Flutter
      // bundle is readable.
      final dart =
          File('lib/features/profile_setup/domain/prompt_moderation.dart')
              .readAsStringSync();
      expect(dart.contains('moderation_blocklist'), isFalse);
    });
  });
}
