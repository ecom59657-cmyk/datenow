// =============================================================================
// DateNow — IdentityVerificationScreen  (Phase 4 of the Didit rollout)
//
// Standalone screen reachable at `/identity` for manual QA. Not yet
// wired into onboarding nor into the find-date gate — both ship in
// Phases 5-6. The route exists so the team can :
//
//   * tap "Vérifier" → see a real Didit session URL open in Safari,
//   * complete the sandbox flow on the actual hosted page,
//   * watch this screen flip status live (Realtime → webhook UPDATE),
//   * confirm `profiles.identity_verified` flips server-side in SQL.
//
// Visual states driven by `latestIdentityVerificationProvider` :
//
//   - null            → "À démarrer"        + CTA "Vérifier mon identité"
//   - pending         → "Vérification en cours" + CTA "Reprendre"
//   - inReview        → "Vérification en cours…" + loader, no CTA
//   - approved        → "Identité vérifiée ✓"  no CTA
//   - rejected        → "Vérification refusée" + reason + CTA "Réessayer"
//   - expired         → "Session expirée"      + CTA "Recommencer"
//
// Background → foreground robustness :
//   When the user taps "Vérifier" we launch the Didit URL via
//   `url_launcher` with `LaunchMode.externalApplication` — opens the
//   default browser (Safari). When the user comes back from the
//   browser (deep link `datenow://didit/return` OR the iOS back gesture
//   on the Safari overlay), this screen is still mounted. Supabase
//   Realtime usually re-syncs on its own, but to be safe we invalidate
//   the stream provider on `AppLifecycleState.resumed`.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

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

  Future<void> _onPrimaryAction({String? reuseUrl}) async {
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
      // 1. If we already have a URL from a still-open session, reuse
      //    it. Avoids hitting the Edge Function (and Didit quota) when
      //    the user is just returning to finish a started session.
      if (reuseUrl != null) {
        _log.info('reusing existing session URL');
        await _launch(reuseUrl, messenger);
        return;
      }

      // 2. Otherwise spin up (or have the function reuse) a session.
      final result = await repo.createSession();
      if (!mounted) return;

      switch (result) {
        case IdentitySessionReady(:final sessionUrl, :final reused):
          _log.info('createSession → ready (reused=$reused)');
          await _launch(sessionUrl, messenger);
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

  Future<void> _launch(String url, ScaffoldMessengerState messenger) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      _log.warn('invalid session URL: $url');
      messenger.showSnackBar(const SnackBar(
        content: Text('URL de vérification invalide.'),
      ));
      return;
    }
    // External browser — Didit's hosted flow needs cookies + camera
    // access that an in-app WebView can't always grant cleanly. Safari
    // / Chrome handle both. The return path is the
    // `datenow://didit/return` deep link declared in the Edge Function
    // callback URL.
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) {
      _log.warn('launchUrl returned false for $url');
      messenger.showSnackBar(const SnackBar(
        content: Text('Impossible d\'ouvrir la page de vérification.'),
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
                  reuseUrl: status == IdentityVerificationStatus.pending
                      ? row?.sessionUrl
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
          'DateNow vérifie ton âge et ton identité via un partenaire externe (Didit). '
          'Cela prend environ 2 minutes : pièce d\'identité + selfie. '
          'Nous ne stockons pas tes documents.',
          style: AppTypography.body.copyWith(color: AppColors.textSecondary),
        ),
      ],
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
