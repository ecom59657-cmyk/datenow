enum SubscriptionTier { free, premium }

/// Snapshot of the user's billing state. Returned by the subscription
/// repository — concrete impls (mock / Stripe) keep the shape stable.
class SubscriptionState {
  const SubscriptionState({
    required this.tier,
    this.activeUntil,
  });

  /// Convenience constructor for the free tier (most users at any moment).
  const SubscriptionState.free() : this(tier: SubscriptionTier.free);

  final SubscriptionTier tier;

  /// `null` while on free; date when the current paid cycle expires
  /// otherwise. Demo mode picks a 30-day window.
  final DateTime? activeUntil;

  bool get isPremium => tier == SubscriptionTier.premium;
}
