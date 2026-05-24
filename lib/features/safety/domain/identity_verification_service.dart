/// Abstraction for third-party identity / age verification (Didit, Veriff,
/// Onfido, …). The MVP ships a permissive [MockIdentityVerificationService]
/// so the UI flow stays exercisable end-to-end; the production wiring will
/// plug Didit (or similar) behind the same interface without touching any
/// caller.
///
/// Apple's expectation for a dating app is "reasonable measures" — we
/// already enforce 18+ at four layers (UI validator, repo, DB trigger,
/// CHECK constraint). Identity verification is the next step up the
/// trust ladder and is intentionally kept behind a swap-in abstraction
/// so it can be enabled without a code-wide refactor.
abstract class IdentityVerificationService {
  /// Best-effort current status for [userId]. Returns
  /// [IdentityVerificationStatus.notRequired] in builds where verification
  /// isn't enabled yet so dependent UI can stay neutral.
  Future<IdentityVerificationStatus> statusFor(String userId);

  /// Hands the user off to the provider's flow (web view / SDK / OS sheet)
  /// and resolves with the resulting status. The mock implementation
  /// short-circuits to [IdentityVerificationStatus.verified] so dev builds
  /// keep behaving.
  Future<IdentityVerificationStatus> start(String userId);
}

enum IdentityVerificationStatus {
  /// Verification is not enabled in this build / region.
  notRequired,

  /// The user hasn't started or completed the flow yet.
  pending,

  /// The provider returned a green light.
  verified,

  /// The provider rejected the verification (under-age, mismatched docs,
  /// etc.). The UI should fall back to a clear "you can't use DateNow"
  /// message — see `MinorBlockedScreen`.
  rejected,
}

/// Permissive stub used when no real provider is wired. Always reports
/// `notRequired` so the rest of the app behaves as if verification was
/// off. Swapping in a real implementation is a one-line provider edit.
class MockIdentityVerificationService implements IdentityVerificationService {
  const MockIdentityVerificationService();

  @override
  Future<IdentityVerificationStatus> statusFor(String userId) async {
    return IdentityVerificationStatus.notRequired;
  }

  @override
  Future<IdentityVerificationStatus> start(String userId) async {
    return IdentityVerificationStatus.verified;
  }
}
