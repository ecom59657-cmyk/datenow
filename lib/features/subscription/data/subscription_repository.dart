import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

import '../../../core/services/supabase_service.dart';
import '../../../core/utils/logger.dart';
import '../domain/subscription_state.dart';

abstract class SubscriptionRepository {
  /// Whether the backing payment provider (Stripe) is actually wired up.
  /// Drives the "demo" banner on the upgrade screen.
  bool get isConfigured;

  Stream<SubscriptionState> watchState(String userId);

  /// Upgrades [userId] to the premium tier. In mock mode this is instant;
  /// in production it'll round-trip through Stripe Checkout.
  Future<void> upgradeToPremium(String userId);
}

// ---------------------------------------------------------------------------
// Mock — flips the tier in memory after a short fake "checkout" delay.
// ---------------------------------------------------------------------------

class MockSubscriptionRepository implements SubscriptionRepository {
  static const _log = AppLogger('MockSubscription');

  final Map<String, SubscriptionState> _byUser = {};
  final Map<String, StreamController<SubscriptionState>> _streams = {};

  StreamController<SubscriptionState> _stream(String userId) {
    return _streams.putIfAbsent(
      userId,
      () => StreamController<SubscriptionState>.broadcast(),
    );
  }

  @override
  bool get isConfigured => false;

  @override
  Stream<SubscriptionState> watchState(String userId) async* {
    yield _byUser[userId] ?? const SubscriptionState.free();
    yield* _stream(userId).stream;
  }

  @override
  Future<void> upgradeToPremium(String userId) async {
    // Simulate a Stripe Checkout round-trip so the loading state is real.
    await Future<void>.delayed(const Duration(milliseconds: 700));
    final next = SubscriptionState(
      tier: SubscriptionTier.premium,
      activeUntil: DateTime.now().add(const Duration(days: 30)),
    );
    _byUser[userId] = next;
    _stream(userId).add(next);
    _log.info('$userId upgraded to premium (mock)');
  }
}

// ---------------------------------------------------------------------------
// Stripe-backed Supabase variant — stub kept honest with [UnimplementedError].
// ---------------------------------------------------------------------------

class SupabaseSubscriptionRepository implements SubscriptionRepository {
  SupabaseSubscriptionRepository(this._client);

  final sb.SupabaseClient _client;

  static const _log = AppLogger('SupabaseSubscription');

  @override
  bool get isConfigured => false;

  /// Follows the caller's row in `public.subscriptions`.
  ///
  /// This used to throw, which had a consequence nobody was looking for:
  /// every reader of the tier — the rewarded-ad entry point among them —
  /// saw an error instead of a value and quietly assumed "not premium".
  /// The ad button therefore never rendered in a build talking to Supabase.
  ///
  /// A missing row means free: `handle_new_user` does not create one, and
  /// absence is exactly what free means. An expired `active_until` also
  /// means free — a lapsed subscription must not keep paying for itself.
  ///
  /// A failure means free too, and it has to *say so*. The previous version
  /// logged the error and dropped it, which looks harmless and is not: the
  /// stream then emitted nothing at all, ever. Every reader waiting on
  /// `subscriptionStateProvider.future` — the Home "Lancer un date" gate
  /// among them — waited forever, and the button died silently. That is
  /// exactly what happened in production while `public.subscriptions` was
  /// missing from the database. An error we cannot answer is still an
  /// answer: not premium.
  @override
  Stream<SubscriptionState> watchState(String userId) {
    return _client
        .from('subscriptions')
        .stream(primaryKey: ['user_id'])
        .eq('user_id', userId)
        .map(_stateFrom)
        .transform(
          StreamTransformer<SubscriptionState, SubscriptionState>.fromHandlers(
            handleError: (Object e, StackTrace st, EventSink<SubscriptionState> sink) {
              _log.error('subscription stream failed: $e', e, st);
              sink.add(const SubscriptionState.free());
            },
          ),
        );
  }

  static SubscriptionState _stateFrom(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) return const SubscriptionState.free();
    final row = rows.first;
    final until = row['active_until'] == null
        ? null
        : DateTime.tryParse(row['active_until'] as String);
    final paid = row['tier'] == 'premium' &&
        (until == null || until.isAfter(DateTime.now()));
    return SubscriptionState(
      tier: paid ? SubscriptionTier.premium : SubscriptionTier.free,
      activeUntil: until,
    );
  }

  @override
  Future<void> upgradeToPremium(String userId) {
    // TODO(datenow): call a Postgres function that creates a Stripe Checkout
    // session and returns its URL — the UI will then redirect to it.
    throw UnimplementedError(
      'SupabaseSubscriptionRepository.upgradeToPremium',
    );
  }
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

final subscriptionRepositoryProvider = Provider<SubscriptionRepository>((ref) {
  final available = ref.watch(supabaseAvailableProvider);
  if (available) {
    return SupabaseSubscriptionRepository(ref.watch(supabaseClientProvider));
  }
  return MockSubscriptionRepository();
});
