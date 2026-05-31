/// Lifecycle state of a single `user_photos` row, mirrored from the
/// Postgres enum `photo_status` (see
/// `supabase/migrations/20260531120000_photo_moderation_schema.sql`).
///
/// Only `approved` photos are ever surfaced publicly — match cards,
/// reveal flow, suggestions, find-date gate, every place that reads
/// a user's photo gates on this.
enum PhotoModerationStatus {
  /// Just uploaded — waiting for the Edge Function to pick it up.
  /// UI shows "Photo en cours de vérification".
  pending,

  /// `analyze-profile-photo` is in-flight (typically <2 s but the
  /// Vision API can spike to 5 s under load). UI identical to
  /// [pending] so the user does not perceive a state flicker.
  analyzing,

  /// Safe + face detected + confidence above threshold. Photo is
  /// visible everywhere it would normally appear.
  approved,

  /// Automatic refusal (nsfw, multi-face, no-face, spoof, …). UI
  /// shows the neutral "Votre photo n'a pas pu être validée" +
  /// re-upload CTA. The raw provider reason is in the DB
  /// (`reject_reason`) but is NEVER surfaced verbatim to the user.
  rejected,

  /// Doubt — needs a human review in `moderation_queue` (admin via
  /// Supabase Studio). UI identical to [pending] so the user is not
  /// stigmatised while waiting.
  manualReview;

  /// Parse the wire value emitted by Supabase + the Edge Function.
  /// Falls back to [pending] for unknown values so a future enum
  /// addition does not crash older clients.
  static PhotoModerationStatus fromWire(String? raw) {
    switch (raw) {
      case 'pending':
        return PhotoModerationStatus.pending;
      case 'analyzing':
        return PhotoModerationStatus.analyzing;
      case 'approved':
        return PhotoModerationStatus.approved;
      case 'rejected':
        return PhotoModerationStatus.rejected;
      case 'manual_review':
        return PhotoModerationStatus.manualReview;
      default:
        return PhotoModerationStatus.pending;
    }
  }

  /// True when the photo is the kind of state where the UI should
  /// show a soft "in progress" overlay (no negative emotion).
  bool get isInFlight =>
      this == PhotoModerationStatus.pending ||
      this == PhotoModerationStatus.analyzing ||
      this == PhotoModerationStatus.manualReview;

  /// True only for `approved` — the single binary gate that drives
  /// "can this photo go public" decisions everywhere.
  bool get isApproved => this == PhotoModerationStatus.approved;

  /// True for `rejected` — the only state where the UI explicitly
  /// asks the user to act (re-upload).
  bool get isRejected => this == PhotoModerationStatus.rejected;
}
