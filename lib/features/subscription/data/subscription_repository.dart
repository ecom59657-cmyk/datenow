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

  // ignore: unused_field
  final sb.SupabaseClient _client;

  @override
  bool get isConfigured => false;

  @override
  Stream<SubscriptionState> watchState(String userId) {
    // TODO(datenow): subscribe to a `subscriptions` table fed by a Stripe
    // webhook function so the UI updates immediately after checkout.
    throw UnimplementedError('SupabaseSubscriptionRepository.watchState');
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
