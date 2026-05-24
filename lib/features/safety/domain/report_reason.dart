/// Bounded list of report categories. Mirrored by the `reports_reason_check`
/// CHECK constraint server-side — any new value must be added in BOTH
/// places or the insert is rejected.
enum ReportReason {
  inappropriateBehavior('inappropriate_behavior'),
  nuditySexual('nudity_sexual'),
  harassment('harassment'),
  minor('minor'),
  fakeProfile('fake_profile'),
  spam('spam'),
  other('other');

  const ReportReason(this.wire);

  /// Value persisted in `reports.reason`. Stable across releases.
  final String wire;

  /// User-facing label, French and English mirror the same set so any
  /// dating-app vocabulary stays consistent across locales.
  String label({required bool isFr}) => switch (this) {
        ReportReason.inappropriateBehavior =>
          isFr ? 'Comportement inapproprié' : 'Inappropriate behaviour',
        ReportReason.nuditySexual =>
          isFr ? 'Nudité / contenu sexuel' : 'Nudity or sexual content',
        ReportReason.harassment =>
          isFr ? 'Harcèlement / propos haineux' : 'Harassment or hate speech',
        ReportReason.minor =>
          isFr ? 'Profil semble mineur' : 'Profile appears to be a minor',
        ReportReason.fakeProfile =>
          isFr ? 'Faux profil / usurpation' : 'Fake profile or impersonation',
        ReportReason.spam => isFr ? 'Spam / publicité' : 'Spam or ads',
        ReportReason.other => isFr ? 'Autre' : 'Other',
      };
}
