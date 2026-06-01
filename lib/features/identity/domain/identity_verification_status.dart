/// Lifecycle state of a single `identity_verifications` row, mirrored
/// from the Postgres enum `identity_verification_status` (see
/// `supabase/migrations/20260601100000_identity_verification_schema.sql`).
///
/// Only `approved` photos can flip `profiles.identity_verified=true`.
/// The Find-date gate (Phase 6) will read the `has_verified_identity()`
/// RPC, which itself depends on this status making it to `approved`.
enum IdentityVerificationStatus {
  /// Didit session created server-side, user has not finished
  /// uploading their document + selfie yet. UI shows the "Vérifier
  /// mon identité" CTA + the live `session_url` to resume.
  pending,

  /// User submitted their documents — Didit is now processing
  /// (typically ~30 s to 2 min). UI shows a soft "Vérification en
  /// cours…" message so the user isn't left guessing.
  inReview,

  /// All gates green (document scan + selfie + face match + age
  /// ≥ 18 + claimed age matches extracted age within ±1 yr). The
  /// webhook flipped `profiles.identity_verified=true` server-side.
  approved,

  /// Definitive refusal. Common reasons (carried in
  /// `identity_verifications.reject_reason`) :
  ///   * `minor`            — age extracted by Didit < 18
  ///   * `face_mismatch`    — selfie does not match document photo
  ///   * `liveness_failed`  — Didit detected a static photo / video
  ///   * `document_invalid` — Didit rejected the document scan
  ///   * `rejected_other`   — Didit rejected without a specific tag
  ///   * `age_mismatch`     — extracted age vs claimed age diff > 1 yr
  ///                           (degraded to in_review by the webhook,
  ///                            never lands here directly)
  rejected,

  /// Session timed out without a verdict (~30 min default). User
  /// can start a fresh session — the existing row is preserved for
  /// audit.
  expired;

  /// Parses the wire value the Postgres enum sends back. `in_review`
  /// uses an underscore on the wire ; we de-snake it to camelCase
  /// on the Dart side. Unknown values fall back to `pending` so a
  /// future enum addition does not crash older clients.
  static IdentityVerificationStatus fromWire(String? raw) {
    switch (raw) {
      case 'pending':
        return IdentityVerificationStatus.pending;
      case 'in_review':
        return IdentityVerificationStatus.inReview;
      case 'approved':
        return IdentityVerificationStatus.approved;
      case 'rejected':
        return IdentityVerificationStatus.rejected;
      case 'expired':
        return IdentityVerificationStatus.expired;
      default:
        return IdentityVerificationStatus.pending;
    }
  }

  /// True when the verification is currently underway — i.e. the user
  /// or the Didit pipeline is still working on it. UI uses this to
  /// keep a soft loading/progress visual rather than declaring
  /// success or failure prematurely.
  bool get isInProgress =>
      this == IdentityVerificationStatus.pending ||
      this == IdentityVerificationStatus.inReview;

  /// True only for `approved` — the single gate the Phase 6 find-date
  /// check will consume via `has_verified_identity()`.
  bool get isApproved => this == IdentityVerificationStatus.approved;

  /// True when the user must restart the flow (rejected or expired).
  bool get requiresRetry =>
      this == IdentityVerificationStatus.rejected ||
      this == IdentityVerificationStatus.expired;
}
