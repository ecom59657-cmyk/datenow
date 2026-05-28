import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/app_routes.dart';
import '../../../app/scaffold/active_tab.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/utils/display_name.dart';
import '../../../core/utils/extensions.dart';
import '../../../core/utils/logger.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/app_button.dart';
import '../../../shared/widgets/app_scaffold.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../auth/presentation/providers/auth_provider.dart';
import '../../presence/data/presence_repository.dart';
import '../../profile_setup/data/profile_repository.dart';
import '../../profile_setup/presentation/providers/profile_provider.dart';
import '../../quota/data/quota_repository.dart';
import '../../quota/presentation/widgets/quota_limit_sheet.dart';
import '../../subscription/presentation/providers/subscription_provider.dart';
import 'widgets/available_dates_display.dart';
import 'widgets/home_header.dart';
import 'widgets/home_hero_card.dart';
import 'widgets/stat_tile.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with TabScrollResetMixin {
  @override
  int get tabIndex => 0; // Home=0, Discover=1, Profile=2

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final user = ref.watch(currentUserProvider);
    // currentProfileProvider streams from public.profiles in realtime,
    // so once onboarding writes `first_name` the home name flips
    // without needing a manual refresh. We never bubble the email
    // here — Apple Private Relay aliases like
    // `ttsfv4hm22@privaterelay.appleid.com` previously leaked through
    // the old `user.displayName ?? user.email` fallback.
    final profile = ref.watch(currentProfileProvider).asData?.value;
    final humaneName = resolveUserDisplayName(profile, user);

    return AppScaffold(
      body: ListView(
        controller: tabScrollController,
        padding: const EdgeInsets.only(bottom: 120),
        physics: const BouncingScrollPhysics(),
        children: [
          const SizedBox(height: AppSpacing.md),
          HomeHeader(
            displayName: humaneName,
            // Tapping the avatar switches to the Profile tab via the
            // existing shell branch — no new screen, no extra route.
            onAvatarTap: () => context.goNamed(AppRoute.profile.name),
          ).animate().fadeIn(duration: 350.ms),
          const SizedBox(height: AppSpacing.xl),
          HomeHeroCard(
            onPressed: _onFindDate,
          ),
          const SizedBox(height: AppSpacing.xl),
          Text(l10n.tonightOnDatenow, style: AppTypography.h3),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: StatTile(
                  icon: Icons.people_alt_rounded,
                  value: '1.2k',
                  label: l10n.peopleOnline,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: StatTile(
                  icon: Icons.bolt_rounded,
                  value: '38s',
                  label: l10n.avgMatchTime,
                  accent: AppColors.brandViolet,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Builder(builder: (context) {
            // "Dates proposés aujourd'hui" — count comes from
            // available_date_proposals_today() server-side, which filters
            // out offline / banned / blocked / already-in-call peers.
            // Display states (loading / count / empty) live in
            // [formatAvailableDates] so they're unit-testable in isolation.
            final state = ref.watch(availableDateProposalsCountProvider);
            final display = formatAvailableDates(l10n, state);
            return StatTile(
              icon: Icons.favorite_rounded,
              value: display.value,
              label: display.label,
              onTap: () => context.goNamed(AppRoute.discover.name),
            );
          }),
          // Compact Premium teaser — placed AFTER the "Ce soir sur
          // DateNow" stats and BEFORE the "Comment ça marche" section
          // (visible early but never blocks the live-date CTA). Hidden
          // for users who are already Premium.
          Builder(builder: (context) {
            final isPremium = ref
                    .watch(subscriptionStateProvider)
                    .asData
                    ?.value
                    .isPremium ??
                false;
            if (isPremium) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xl),
              child: _PremiumTeaserCard(
                onTap: () =>
                    context.pushNamed(AppRoute.settingsSubscription.name),
              ),
            );
          }),
          const SizedBox(height: AppSpacing.xl),
          Text(l10n.howItWorks, style: AppTypography.h3),
          const SizedBox(height: AppSpacing.sm),
          _HowItWorksCard(
            steps: [
              (l10n.howItWorksStep1Title, l10n.howItWorksStep1Body),
              (l10n.howItWorksStep2Title, l10n.howItWorksStep2Body),
              (l10n.howItWorksStep3Title, l10n.howItWorksStep3Body),
              (l10n.howItWorksStep4Title, l10n.howItWorksStep4Body),
            ],
          ),
        ],
      ),
    );
  }

  static const _log = AppLogger('FindDate');

  /// Entry point for the "Find a date now" CTA.
  ///
  /// The chain is intentionally noisy in the console so a future
  /// "the button does nothing" report is debuggable from the logs alone:
  ///
  ///   Find date clicked
  ///   User authenticated: `uid`
  ///   Profile complete for `uid`
  ///   Quota OK: used=`n` cap=`n|null`     (or "Quota check failed")
  ///   Matching started → navigating to /matching
  ///
  /// Every failure path also surfaces a localized [SnackBar] so the user
  /// gets feedback instead of an apparently dead tap.
  Future<void> _onFindDate() async {
    _log.info('Find date clicked');
    final l10n = AppLocalizations.of(context);

    // 1. Auth — the user must be signed in. Router redirects should keep
    //    us out of /home without it, but we don't trust that contract.
    final user = ref.read(currentUserProvider);
    if (user == null) {
      _log.warn('No authenticated user — aborting.');
      if (context.mounted) {
        context.showSnack(l10n.findDateNotAuthenticated);
      }
      return;
    }
    _log.info('User authenticated: ${user.id}');

    // 2. Profile must be complete. Same router-guarantee caveat applies.
    final profile = ref.read(currentProfileProvider).asData?.value;
    if (profile == null || !profile.isComplete) {
      _log.warn(
        'Profile not ready (loaded=${profile != null}, '
        'complete=${profile?.isComplete ?? false}) — aborting.',
      );
      if (context.mounted) {
        context.showSnack(l10n.findDateProfileIncomplete);
      }
      return;
    }
    _log.info('Profile complete for ${user.id}');

    // 2.5. Photo guard — the reveal is the product payoff; no photo,
    //      no point matching. Backed server-side too (claim_match raises
    //      `photo_required`), so a tampered client can't bypass.
    //
    //      We can't trust the cached `currentProfileProvider` value
    //      alone: the user may have just uploaded a photo during the
    //      onboarding steps and the stream snapshot we're reading is
    //      pre-upload. Before blocking the live flow we force a fresh
    //      fetch from `profiles` + `user_photos`. We only show the
    //      "Ajoute une photo" sheet if the *server-truth* says no
    //      photo exists.
    if (profile.primaryPhotoUrl == null) {
      _log.info(
        'cache reports no primary photo — re-fetching profile from Supabase '
        'before blocking the live flow',
      );
      try {
        final fresh = await ref
            .read(profileRepositoryProvider)
            .getProfile(user.id);
        if (fresh?.primaryPhotoUrl != null) {
          _log.info(
            'fresh profile has primary photo — local cache was stale, '
            'invalidating currentProfileProvider and continuing',
          );
          // Nudge the StreamProvider so any other consumer of
          // currentProfileProvider sees the up-to-date value.
          ref.invalidate(currentProfileProvider);
        } else {
          _log.warn(
            'fresh profile still has no photo → blocking match '
            '(server-truth: photoUrls=${fresh?.photoUrls.length ?? 0})',
          );
          if (!context.mounted) return;
          await _showPhotoRequiredSheet(context);
          return;
        }
      } catch (e, st) {
        // If the refresh itself fails (network / transient), fall back
        // to the cached truth: cached says no photo, block. This keeps
        // the existing safety net intact when the refetch is unable to
        // disprove the cache.
        _log.error('photo refresh failed — falling back to cache', e, st);
        if (!context.mounted) return;
        await _showPhotoRequiredSheet(context);
        return;
      }
    }

    // 3. Quota — wrapped: a broken quota backend should NOT block the
    //    button. We log and proceed in that case.
    try {
      final status =
          await ref.read(quotaRepositoryProvider).currentStatus(profile);
      _log.info(
        'Quota OK: used=${status.usedToday} cap=${status.cap ?? "∞"}',
      );
      if (status.isExhausted) {
        _log.info('Quota exhausted — showing limit sheet.');
        if (!context.mounted) return;
        await showQuotaLimitSheet(context);
        return;
      }
    } catch (e, st) {
      _log.error('Quota check failed (continuing anyway): $e', e, st);
    }

    // 4. Navigate to the matching screen. The matching screen owns the
    //    "find candidate → start call session → open call screen" chain.
    if (!context.mounted) return;
    _log.info('Matching started → navigating to /matching');
    try {
      context.pushNamed(AppRoute.matching.name);
    } catch (e, st) {
      _log.error('Navigation to /matching failed: $e', e, st);
      if (!context.mounted) return;
      context.showSnack(l10n.findDateError);
    }
  }

  /// Premium bottom sheet shown when the user taps "Find a date" without
  /// a profile photo. Offers a one-tap path to the photos editor.
  Future<void> _showPhotoRequiredSheet(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return showModalBottomSheet<void>(
      context: context,
      // Push onto the ROOT navigator — without this the sheet lives
      // inside the StatefulShellRoute branch and the bottom nav of
      // MainShell stays visible *on top* of the CTAs (the bug seen on
      // iPhone 13). With useRootNavigator the modal covers the whole
      // screen, nav included.
      useRootNavigator: true,
      // Allows the sheet to scroll if its content is taller than the
      // available space (small screens) and to honour MediaQuery.viewInsets
      // when the keyboard is up.
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        top: false,
        // Honour the iPhone home indicator inset so the "Plus tard"
        // button is never glued to the very bottom of the screen.
        minimum: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.sm,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 80,
                height: 80,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: AppColors.brandGradient,
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.brandPink.withValues(alpha: 0.4),
                      blurRadius: 24,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.camera_alt_rounded,
                  color: Colors.white,
                  size: 36,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                l10n.findDatePhotoRequiredTitle,
                textAlign: TextAlign.center,
                style: AppTypography.h2,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                l10n.findDatePhotoRequiredBody,
                textAlign: TextAlign.center,
                style: AppTypography.body
                    .copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: AppSpacing.lg),
              AppButton(
                label: l10n.findDatePhotoRequiredCta,
                icon: Icons.add_a_photo_rounded,
                size: AppButtonSize.large,
                onPressed: () {
                  Navigator.of(sheetContext).pop();
                  context.pushNamed(AppRoute.editPhotos.name);
                },
              ),
              const SizedBox(height: AppSpacing.sm),
              AppButton(
                label: l10n.findDatePhotoRequiredCancel,
                variant: AppButtonVariant.secondary,
                onPressed: () => Navigator.of(sheetContext).pop(),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
          ),
        ),
      ),
    );
  }
}

class _HowItWorksCard extends StatelessWidget {
  const _HowItWorksCard({required this.steps});

  /// Each step is `(title, body)`. Title is the punchy product
  /// promise (the part scanned first), body is the explanation.
  final List<(String, String)> steps;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (i, step) in steps.indexed) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: const BoxDecoration(
                    gradient: AppColors.brandGradient,
                    borderRadius: AppRadius.brSm,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '${i + 1}',
                    style: AppTypography.caption.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          step.$1,
                          style: AppTypography.bodyStrong,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          step.$2,
                          style: AppTypography.body.copyWith(
                            color: AppColors.textSecondary,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            if (i < steps.length - 1) const SizedBox(height: AppSpacing.md),
          ],
        ],
      ),
    );
  }
}

/// Compact Premium teaser shown on Home — single tap navigates to the
/// dedicated Subscription screen. Quiet luxury vibe: a thin champagne-
/// gold outline on the card + the icon, dual brand-pink × gold glow,
/// gradient pill CTA. No price (price lives on the dedicated screen),
/// no popup, no scrim, no animation that grabs attention away from
/// the live-date hero card above.
class _PremiumTeaserCard extends ConsumerWidget {
  const _PremiumTeaserCard({required this.onTap});

  final VoidCallback onTap;

  /// Muted champagne gold. Used only as a thin tint over the brand
  /// pink/violet — never as a fill. Keeps the dark/pink/purple DA
  /// intact, only signals "this is the premium card" subliminally.
  static const Color _gold = Color(0xFFE2C68C);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    // Soft halo around the whole card — brand-pink dominant + a tiny
    // champagne tint underneath. Stays well below the live-date CTA
    // in visual weight.
    return Container(
      decoration: BoxDecoration(
        borderRadius: AppRadius.brLg,
        boxShadow: [
          BoxShadow(
            color: AppColors.brandPink.withValues(alpha: 0.18),
            blurRadius: 28,
            spreadRadius: 0,
            offset: const Offset(0, 10),
          ),
          BoxShadow(
            color: _gold.withValues(alpha: 0.06),
            blurRadius: 24,
            spreadRadius: 0,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: GlassCard(
        onTap: onTap,
        // Thin champagne-tinted outline. ~40 % alpha so it reads as
        // a subtle ring on the dark surface, never as a hard line.
        borderColor: _gold.withValues(alpha: 0.38),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: 18,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Premium icon — brand gradient fill, gold ring, dual
            // glow (pink dominant, gold ambient). The gold ring is
            // 1 dp, deliberately under-saturated.
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                gradient: AppColors.brandGradient,
                borderRadius: AppRadius.brSm,
                border: Border.all(
                  color: _gold.withValues(alpha: 0.55),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.brandPink.withValues(alpha: 0.34),
                    blurRadius: 18,
                    spreadRadius: 0,
                    offset: const Offset(0, 6),
                  ),
                  BoxShadow(
                    color: _gold.withValues(alpha: 0.18),
                    blurRadius: 14,
                    spreadRadius: 0,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: const Icon(
                Icons.workspace_premium_rounded,
                color: Colors.white,
                size: 22,
              ),
            ),
            const SizedBox(width: 14),
            // Title + body. Title gets a light positive tracking to
            // give the brand a "set-in-metal" feel without changing
            // the font.
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.subscriptionBrand,
                    style: AppTypography.bodyStrong.copyWith(
                      letterSpacing: 0.2,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    l10n.homePremiumTeaserBody,
                    style: AppTypography.caption.copyWith(
                      color: AppColors.textSecondary,
                      height: 1.35,
                      letterSpacing: 0.1,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            // Mini gradient CTA pill. Carries its own brand-pink glow
            // so it reads as the action target even when scanned at
            // a glance. Text + chevron sit on one baseline.
            Container(
              decoration: BoxDecoration(
                borderRadius: AppRadius.brPill,
                gradient: AppColors.brandGradient,
                boxShadow: [
                  BoxShadow(
                    color: AppColors.brandPink.withValues(alpha: 0.42),
                    blurRadius: 16,
                    spreadRadius: 0,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      l10n.homePremiumTeaserCta,
                      style: AppTypography.button.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.arrow_forward_rounded,
                      size: 16,
                      color: Colors.white,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
