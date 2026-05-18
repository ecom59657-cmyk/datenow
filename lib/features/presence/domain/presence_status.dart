/// What a user is doing right now, surfaced across the app for the
/// "living app" feel: the matching screen, the call screen and Debug all
/// read it.
///
/// `offline` is never written by a healthy client — it is *implied* when
/// a presence row's `updated_at` goes stale (the app was backgrounded or
/// killed and stopped refreshing). [PresenceStatus.fromRow] applies that
/// staleness rule so callers always get a truthful value.
enum PresenceStatus {
  online('online', 'En ligne'),
  searching('searching', 'En recherche'),
  inCall('in_call', 'En date vidéo'),
  offline('offline', 'Hors ligne');

  const PresenceStatus(this.wire, this.label);

  /// The value stored in `user_presence.status`.
  final String wire;

  /// Human-readable French label for UI / Debug.
  final String label;

  static PresenceStatus fromWire(String? wire) {
    return PresenceStatus.values.firstWhere(
      (s) => s.wire == wire,
      orElse: () => PresenceStatus.offline,
    );
  }

  /// A presence row is only trustworthy while its heartbeat is recent.
  /// Past [staleAfter] the user is treated as offline regardless of the
  /// stored status.
  static const staleAfter = Duration(seconds: 60);

  /// Resolves the *effective* status from a stored value + its timestamp.
  static PresenceStatus fromRow(String? wire, DateTime? updatedAt) {
    if (updatedAt == null) return PresenceStatus.offline;
    final age = DateTime.now().toUtc().difference(updatedAt.toUtc());
    if (age > staleAfter) return PresenceStatus.offline;
    return fromWire(wire);
  }
}
