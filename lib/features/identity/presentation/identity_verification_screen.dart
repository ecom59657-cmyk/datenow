// =============================================================================
// DateNow — IdentityVerificationScreen  (Phase 4 + Phase 6 of the Didit rollout)
//
// Phase 6 swap : the user no longer leaves DateNow for Safari. We
// install the official didit_sdk plugin (verified publisher didit.me
// on pub.dev) and call DiditSdk.startVerification(token). The
// verification UI runs in-app and the SDK returns a sealed
// VerificationResult we switch on for immediate UX feedback. The
// Didit webhook remains the authoritative source of truth — it
// lands on Supabase, updates the identity_verifications row, and
// the Realtime stream rebuilds the screen automatically.
//
// Visual states driven by latestIdentityVerificationProvider :
//   - null            → "À démarrer"        + CTA "Vérifier mon identité"
//   - pending         → "Vérification en cours" + CTA "Reprendre"
//   - inReview        → "Vérification en cours…" + loader, no CTA
//   - approved        → "Identité vérifiée ✓"  no CTA
//   - rejected        → "Vérification refusée" + reason + CTA "Réessayer"
//   - expired         → "Session expirée"      + CTA "Recommencer"
//
// Background → foreground robustness :
//   The SDK runs in-app, so the user does NOT leave DateNow during
//   the flow. The WidgetsBindingObserver is kept anyway — on iOS the
//   SDK may briefly background us for permission prompts, and on
//   Android for system dialogs. Invalidating the stream on resumed
//   is a cheap belt-and-suspenders.
// =============================================================================

import 'package:didit_sdk/sdk_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/utils/logger.dart';
import '../../../shared/widgets/app_button.dart';
import '../../auth/presentation/providers/auth_provider.dart';
import '../data/identity_repository.dart';
import '../domain/identity_verification_status.dart';

class IdentityVerificationScreen extends ConsumerStatefulWidget {
  const IdentityVerificationScreen({super.key});

  @override
  ConsumerState<IdentityVerificationScreen> createState() =>
      _IdentityVerificationScreenState();
}

class _IdentityVerificationScreenState
    extends ConsumerState<IdentityVerificationScreen>
    with WidgetsBindingObserver {
  static const _log = AppLogger('IdentityScreen');

  /// True between the tap on the CTA and the URL hand-off to the OS.
  /// Disables the CTA so a double-tap never fires two createSession
  /// calls (idempotency is server-side too, but keeping it visual is
  /// cheaper than the round-trip).
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s != AppLifecycleState.resumed) return;
    final userId = ref.read(currentUserProvider)?.id;
    if (userId == null) return;
    // Force a fresh subscription after backgrounding. The Realtime
    // stream auto-reconnects in most cases, but invalidating here
    // is the cheapest belt-and-suspenders against the corner case
    // where the connection dropped silently while the Didit flow
    // was happening in Safari.
    _log.info('app resumed → invalidating stream for $userId');
    ref.invalidate(latestIdentityVerificationProvider(userId));
  }

  Future<void> _onPrimaryAction({String? reuseToken}) async {
    if (_creating) return;

    final messenger = ScaffoldMessenger.of(context);
    final repo = ref.read(identityRepositoryProvider);
    if (repo == null) {
      messenger.showSnackBar(const SnackBar(
        content: Text('Vérification indisponible hors-ligne.'),
      ));
      return;
    }

    setState(() => _creating = true);
    try {
      // 1. If we already have a token from a still-open session, reuse
      //    it. Avoids hitting the Edge Function (and the Didit quota)
      //    when the user is just returning to finish a started session.
      if (reuseToken != null) {
        _log.info('reusing existing session token');
        await _runSdk(reuseToken, messenger);
        return;
      }

      // 2. Otherwise spin up (or have the function reuse) a session.
      final result = await repo.createSession();
      if (!mounted) return;

      switch (result) {
        case IdentitySessionReady(:final sessionToken, :final reused):
          _log.info('createSession → ready (reused=$reused), launching SDK');
          await _runSdk(sessionToken, messenger);
        case IdentityAlreadyVerified():
          _log.info('createSession → already verified, no flow needed');
          messenger.showSnackBar(const SnackBar(
            content: Text('Identité déjà vérifiée ✓'),
          ));
        case IdentitySessionError(:final code, :final userMessage):
          _log.warn('createSession error code=$code');
          messenger.showSnackBar(SnackBar(content: Text(userMessage)));
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  /// Hands the session token to the native didit_sdk plugin. The
  /// plugin opens its own in-app verification UI (camera, document
  /// scan, selfie, liveness) and returns a sealed [VerificationResult]
  /// we switch on for IMMEDIATE UX feedback. The authoritative state
  /// transition (status flip to approved/rejected) is driven by the
  /// Didit webhook landing on Supabase and emitted through the
  /// realtime stream the screen already watches.
  ///
  /// All three result branches surface a brief SnackBar so the user
  /// always gets confirmation that their tap had an effect — even
  /// if the realtime UPDATE takes a few seconds to follow.
  Future<void> _runSdk(
    String sessionToken,
    ScaffoldMessengerState messenger,
  ) async {
    try {
      _log.info('SDK startVerification — running in-app UI');
      final result = await DiditSdk.startVerification(sessionToken);
      if (!mounted) return;

      switch (result) {
        case VerificationCompleted(:final session):
          // The SDK only tells us the *immediate* status. The webhook
          // is the source of truth — but surfacing the SDK status
          // gives the user a snappy "received your submission" beat
          // while the Realtime stream catches up (typically 1-5 s).
          _log.info(
            'SDK → completed status=${session.status} '
            'sessionId=${session.sessionId}',
          );
          messenger.showSnackBar(const SnackBar(
            content: Text('Vérification envoyée, traitement en cours…'),
          ));
        case VerificationCancelled():
          _log.info('SDK → cancelled by user');
          messenger.showSnackBar(const SnackBar(
            content: Text('Vérification annulée.'),
          ));
        case VerificationFailed(:final error):
          _log.warn('SDK → failed type=${error.type} message=${error.message}');
          messenger.showSnackBar(const SnackBar(
            content: Text(
              'Erreur durant la vérification, réessaie dans un instant.',
            ),
          ));
      }
    } catch (e, st) {
      _log.error('SDK startVerification threw', e, st);
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(
        content: Text('Erreur durant la vérification, réessaie plus tard.'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);

    // Unauth fallback — should be impossible from the redirect setup,
    // but the route is reachable manually so we render something
    // sensible rather than crashing.
    if (user == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Vérification d\'identité')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(AppSpacing.lg),
            child: Text(
              'Connecte-toi pour vérifier ton identité.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final latest = ref.watch(latestIdentityVerificationProvider(user.id));
    final row = latest.asData?.value;
    final status = row?.status;

    return Scaffold(
      appBar: AppBar(title: const Text('Vérification d\'identité')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.lg,
            AppSpacing.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _IntroHeader(),
              const SizedBox(height: AppSpacing.xl),
              _StatusCard(
                status: status,
                rejectReason: row?.rejectReason,
                loading: latest.isLoading,
              ),
              const Spacer(),
              _PrimaryCta(
                status: status,
                creating: _creating,
                onPressed: () => _onPrimaryAction(
                  reuseToken: status == IdentityVerificationStatus.pending
                      ? row?.sessionToken
                      : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Header ──────────────────────────────────────────────────────

class _IntroHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Vérifie ton identité', style: AppTypography.h1),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Vérification effectuée par Didit S.L. (Espagne), notre '
          'partenaire KYC. Cela prend environ 2 minutes : pièce '
          'd\'identité + selfie + vérification de présence.',
          style: AppTypography.body.copyWith(color: AppColors.textSecondary),
        ),
        const SizedBox(height: AppSpacing.sm),
        // GDPR sprint commit 3 : transparency notice on what data
        // crosses the org boundary. Article 13/14 information
        // obligation : the user MUST know that biometric data is
        // shared with a sub-processor before the SDK launches. We
        // keep this as an inline notice (no blocking checkbox) so
        // the existing UX flow is preserved ; tapping "Vérifier
        // mon identité" below counts as informed consent to the
        // disclosed processing.
        const _InfoNotice(
          icon: Icons.info_outline_rounded,
          text:
              'En lançant la vérification, tu acceptes que ta pièce '
              'd\'identité et ton selfie soient transmis à Didit S.L. '
              'pour vérifier ton âge et ton identité. DateNow conserve '
              'uniquement le résultat de la vérification (vérifié ou non), '
              'pas tes documents.',
        ),
      ],
    );
  }
}

/// Small inline information notice used by the identity screen to
/// surface the vendor-data-flow disclosure before the verification
/// SDK launches. Neutral palette (no warning color) — purely
/// informative, not actionable.
class _InfoNotice extends StatelessWidget {
  const _InfoNotice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: AppRadius.brSm,
        border: Border.all(color: AppColors.hairlineSoft),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: AppColors.textSecondary),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: AppTypography.caption.copyWith(
                color: AppColors.textSecondary,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Status card ─────────────────────────────────────────────────

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.status,
    required this.rejectReason,
    required this.loading,
  });

  final IdentityVerificationStatus? status;
  final String? rejectReason;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final palette = _paletteFor(status);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: palette.background,
        borderRadius: AppRadius.brLg,
        border: Border.all(color: palette.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (loading)
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            )
          else
            Icon(palette.icon, color: palette.iconColor, size: 22),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(palette.title, style: AppTypography.bodyStrong),
                const SizedBox(height: 4),
                Text(
                  _subtitleFor(status, rejectReason),
                  style: AppTypography.caption
                      .copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static _StatusPalette _paletteFor(IdentityVerificationStatus? s) {
    switch (s) {
      case null:
        return _StatusPalette(
          title: 'À démarrer',
          icon: Icons.shield_outlined,
          iconColor: AppColors.textSecondary,
          background: AppColors.surface,
          border: AppColors.hairline,
        );
      case IdentityVerificationStatus.pending:
        return _StatusPalette(
          title: 'Vérification en cours',
          icon: Icons.hourglass_top_rounded,
          iconColor: AppColors.warning,
          background: AppColors.warning.withValues(alpha: 0.10),
          border: AppColors.warning.withValues(alpha: 0.30),
        );
      case IdentityVerificationStatus.inReview:
        return _StatusPalette(
          title: 'Vérification en cours…',
          icon: Icons.autorenew_rounded,
          iconColor: AppColors.warning,
          background: AppColors.warning.withValues(alpha: 0.10),
          border: AppColors.warning.withValues(alpha: 0.30),
        );
      case IdentityVerificationStatus.approved:
        return _StatusPalette(
          title: 'Identité vérifiée',
          icon: Icons.verified_rounded,
          iconColor: AppColors.success,
          background: AppColors.success.withValues(alpha: 0.10),
          border: AppColors.success.withValues(alpha: 0.30),
        );
      case IdentityVerificationStatus.rejected:
        return _StatusPalette(
          title: 'Vérification refusée',
          icon: Icons.error_outline_rounded,
          iconColor: AppColors.error,
          background: AppColors.error.withValues(alpha: 0.10),
          border: AppColors.error.withValues(alpha: 0.30),
        );
      case IdentityVerificationStatus.expired:
        return _StatusPalette(
          title: 'Session expirée',
          icon: Icons.timer_off_outlined,
          iconColor: AppColors.textSecondary,
          background: AppColors.surface,
          border: AppColors.hairline,
        );
    }
  }

  static String _subtitleFor(
    IdentityVerificationStatus? s,
    String? rejectReason,
  ) {
    switch (s) {
      case null:
        return 'Aucune vérification en cours. Lance-la pour pouvoir utiliser DateNow.';
      case IdentityVerificationStatus.pending:
        return 'Reprends la page Didit pour finir tes étapes (pièce + selfie).';
      case IdentityVerificationStatus.inReview:
        return 'Didit analyse tes documents. Cela prend quelques minutes.';
      case IdentityVerificationStatus.approved:
        return 'Tout est bon, tu peux utiliser DateNow.';
      case IdentityVerificationStatus.rejected:
        return _rejectReasonWording(rejectReason);
      case IdentityVerificationStatus.expired:
        return 'Ta session de vérification a expiré, relance-la.';
    }
  }

  /// User-safe wording for each internal reject_reason tag. We never
  /// surface the raw tag — it stays in logs only.
  static String _rejectReasonWording(String? reason) {
    switch (reason) {
      case 'minor':
        return 'DateNow est réservé aux personnes majeures.';
      case 'face_mismatch':
        return 'Le selfie ne correspond pas à la photo du document.';
      case 'liveness_failed':
        return 'Le selfie n\'a pas passé la vérification de présence.';
      case 'document_invalid':
        return 'Le document fourni n\'a pas pu être validé.';
      default:
        return 'Réessaie en suivant attentivement les instructions à l\'écran.';
    }
  }
}

class _StatusPalette {
  _StatusPalette({
    required this.title,
    required this.icon,
    required this.iconColor,
    required this.background,
    required this.border,
  });

  final String title;
  final IconData icon;
  final Color iconColor;
  final Color background;
  final Color border;
}

// ─── Primary CTA ─────────────────────────────────────────────────

class _PrimaryCta extends StatelessWidget {
  const _PrimaryCta({
    required this.status,
    required this.creating,
    required this.onPressed,
  });

  final IdentityVerificationStatus? status;
  final bool creating;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    // Approved → no CTA, save vertical space.
    if (status == IdentityVerificationStatus.approved) {
      return const SizedBox.shrink();
    }
    // In-review → no CTA (server has the ball), inline note instead.
    if (status == IdentityVerificationStatus.inReview) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Text(
          'Tu seras notifié dès que le verdict est prêt.',
          textAlign: TextAlign.center,
          style: AppTypography.caption.copyWith(
            color: AppColors.textTertiary,
          ),
        ),
      );
    }
    final label = switch (status) {
      IdentityVerificationStatus.pending => 'Reprendre la vérification',
      IdentityVerificationStatus.rejected => 'Réessayer',
      IdentityVerificationStatus.expired => 'Recommencer la vérification',
      _ => 'Vérifier mon identité',
    };
    return AppButton(
      label: label,
      isLoading: creating,
      onPressed: creating ? null : onPressed,
    );
  }
}
