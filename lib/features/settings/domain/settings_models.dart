/// User-facing notification toggles. We deliberately keep this set small —
/// adding new switches is cheap (one field + one ARB key + one UI tile).
class NotificationPrefs {
  const NotificationPrefs({
    this.pushNewMatch = true,
    this.pushSuggestions = true,
    this.pushMessages = true,
    this.emailWeeklyDigest = true,
    this.emailMarketing = false,
  });

  final bool pushNewMatch;
  final bool pushSuggestions;
  final bool pushMessages;
  final bool emailWeeklyDigest;
  final bool emailMarketing;

  NotificationPrefs copyWith({
    bool? pushNewMatch,
    bool? pushSuggestions,
    bool? pushMessages,
    bool? emailWeeklyDigest,
    bool? emailMarketing,
  }) {
    return NotificationPrefs(
      pushNewMatch: pushNewMatch ?? this.pushNewMatch,
      pushSuggestions: pushSuggestions ?? this.pushSuggestions,
      pushMessages: pushMessages ?? this.pushMessages,
      emailWeeklyDigest: emailWeeklyDigest ?? this.emailWeeklyDigest,
      emailMarketing: emailMarketing ?? this.emailMarketing,
    );
  }
}

/// Privacy toggles surfaced in the dedicated Privacy screen. Bears no link
/// with the photo-privacy product rule, which is hard-coded (photos always
/// hidden until the post-call reveal).
class PrivacyPrefs {
  const PrivacyPrefs({
    this.showOnline = true,
    this.blockScreenshots = true,
    this.shareUsageData = true,
    this.marketingConsent = false,
    this.twoFactorEnabled = false,
  });

  final bool showOnline;
  final bool blockScreenshots;
  final bool shareUsageData;
  final bool marketingConsent;

  /// Lives here (rather than on a dedicated security model) because it's
  /// the only switch on the Security screen — keeps a single source of
  /// truth for "boolean account-level prefs".
  final bool twoFactorEnabled;

  PrivacyPrefs copyWith({
    bool? showOnline,
    bool? blockScreenshots,
    bool? shareUsageData,
    bool? marketingConsent,
    bool? twoFactorEnabled,
  }) {
    return PrivacyPrefs(
      showOnline: showOnline ?? this.showOnline,
      blockScreenshots: blockScreenshots ?? this.blockScreenshots,
      shareUsageData: shareUsageData ?? this.shareUsageData,
      marketingConsent: marketingConsent ?? this.marketingConsent,
      twoFactorEnabled: twoFactorEnabled ?? this.twoFactorEnabled,
    );
  }
}

/// A user the current account has blocked. Shape matches what we'd query
/// from a `blocked_users` row in Supabase later on.
class BlockedUser {
  const BlockedUser({
    required this.id,
    required this.displayName,
    required this.blockedAt,
  });

  final String id;
  final String displayName;
  final DateTime blockedAt;
}
