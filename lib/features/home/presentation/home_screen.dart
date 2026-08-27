import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../app/router/app_routes.dart';
import '../../../app/scaffold/active_tab.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/config/app_config.dart';
import '../../../core/config/feature_flags.dart';
import '../../../core/services/location_service.dart';
import '../../../core/utils/display_name.dart';
import '../../../core/utils/extensions.dart';
import '../../../core/utils/logger.dart';
import '../../identity/data/identity_repository.dart';
import '../../profile_moderation/domain/photo_moderation_status.dart';
import '../../profile_moderation/data/photo_moderation_repository.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/app_button.dart';
import '../../../shared/widgets/app_scaffold.dart';
import '../../../shared/widgets/app_card.dart';
import '../../auth/presentation/providers/auth_provider.dart';
import '../../presence/data/presence_repository.dart';
import '../../profile_setup/presentation/providers/profile_provider.dart';
import '../../quota/data/quota_repository.dart';
import '../../quota/presentation/widgets/quota_limit_sheet.dart';
import '../../subscription/data/date_milestone_repository.dart';
import '../../../core/services/preferences_service.dart';
import '../../subscription/presentation/providers/subscription_provider.dart';
import 'widgets/available_dates_display.dart';
import 'widgets/home_discover_link.dart';
import 'widgets/people_online_display.dart';
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

  /// Guards against a second push while the first is still animating —
  /// the provider can settle again before the route is on screen.
  bool _pitching = false;

  /// The completed-date count as Home first read it this session.
  ///
  /// The pitch belongs to the moment the third date lands, not to the
  /// history someone already carries when they sign in. Without this,
  /// every returning user with three dates behind them opened the app
  /// straight onto the subscription page — the count is historical, so it
  /// was already over the threshold on the very first frame of Home.
  int? _countAtEntry;

  /// Opens the Premium page once, after the third completed date.
  ///
  /// Placed on Home rather than at the end of the call: the moment a date
  /// ends is the reveal, and putting a price in front of someone deciding
  /// whether they liked a person is both crass and bad selling. Coming back
  /// to Home, dates behind you, is when the offer means something.
  Future<void> _maybePitchPremium() async {
    if (_pitching) return;
    final should = ref.read(shouldPitchPremiumProvider).asData?.value ?? false;
    final isPremium =
        ref.read(subscriptionStateProvider).asData?.value.isPremium ?? false;
    if (!should || isPremium) return;

    _pitching = true;
    final prefs = ref.read(sharedPreferencesProvider).asData?.value;
    // Marked BEFORE showing: a crash or a swipe-away must not turn the
    // pitch into something that returns on every launch.
    if (prefs != null) await PremiumPitchSeen.mark(prefs);
    if (!mounted) return;
    await context.pushNamed(AppRoute.settingsSubscription.name);
    if (mounted) _pitching = false;
  }

  @override
  Widget build(BuildContext context) {
    // Fires when the counter and the subscription state have both settled.
    ref.listen(completedDatesProvider, (_, next) {
      final count = next.asData?.value;
      if (count == null) return;
      // First reading of the session: remember it and pitch nothing. This
      // is the frame right after sign-in, and a paywall there is what the
      // whole milestone was meant to avoid.
      if (_countAtEntry == null) {
        _countAtEntry = count;
        return;
      }
      // Only a date completed while the app was open opens the pitch.
      if (count <= _countAtEntry!) return;
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _maybePitchPremium());
    });
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
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        physics: const BouncingScrollPhysics(),
        children: [
          const SizedBox(height: AppSpacing.md),
          HomeHeader(
            displayName: humaneName,
            // Tapping the avatar switches to the Profile tab via the
            // existing shell branch — no new screen, no extra route.
            onAvatarTap: () => context.goNamed(AppRoute.profile.name),
          ).animate().fadeIn(duration: 350.ms),
          // Non-blocking identity-verification nudge for users who have
          // not yet gone through the Didit flow — including grandfather
          // accounts (Phase 1 migration leftovers). Hidden as soon as
          // [isDiditVerifiedProvider] flips to true. The find-date
          // hard gate (FeatureFlags.requireIdentityVerification) lives
          // in `_onFindDate` and is the actual blocker — this card
          // only frames the verification as a *community safety* step.
          if (FeatureFlags.requireIdentityVerification) ...[
            const SizedBox(height: AppSpacing.lg),
            _HomeIdentityNudge(),
          ],
          const SizedBox(height: AppSpacing.xl),
          HomeHeroCard(
            onPressed: _onFindDate,
          ),
          // Tighter gap (md vs xl) so the secondary CTA reads as a
          // *quiet alternative* to the live pill above, not as a new
          // section. The full xl gap is restored below before the
          // stats block, which IS a new section.
          const SizedBox(height: AppSpacing.md),
          HomeDiscoverLink(
            // Discover lives in the same StatefulShell branch as Home
            // (`/discover`). `goNamed` swaps branches cleanly and keeps
            // the bottom nav state intact — exactly the pattern used
            // by the "Dates proposés aujourd'hui" stat tile below.
            onPressed: () => context.goNamed(AppRoute.discover.name),
          ),
          const SizedBox(height: AppSpacing.xl),
          Text(l10n.tonightOnDatenow, style: AppTypography.h3),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: Builder(builder: (context) {
                  // "Personnes en ligne" — live count from the
                  // active_profiles_count() RPC (server clock, 60 s
                  // freshness window), same wiring as the "dates
                  // proposes" tile below. Never a hard-coded audience
                  // figure: a fake real-time counter is misleading
                  // metadata (2.3.1) and would undercut the
                  // availability-based matching claim itself.
                  final state = ref.watch(activeProfilesCountProvider);
                  final display = formatPeopleOnline(l10n, state);
                  return StatTile(
                    icon: Icons.people_alt_rounded,
                    value: display.value,
                    label: display.label,
                  );
                }),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: StatTile(
                  icon: Icons.bolt_rounded,
                  // Product fact (a date lasts 5 min), not a measured
                  // audience stat — replaces the old hard-coded "38s
                  // temps de match moyen", which we could not back with
                  // real data at launch volume.
                  value: l10n.dateDurationValue(
                    AppConfig.maxCallDuration.inMinutes,
                  ),
                  label: l10n.dateDurationLabel,
                  accent: AppColors.clay,
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

    // 2.5. Approved-photo guard — the reveal is the product payoff,
    //      and the V1 photo moderation pipeline requires at least one
    //      `user_photos` row with status='approved' before the user
    //      can show up to a peer. We bust the provider cache on each
    //      tap so a freshly-moderated photo (added since the last
    //      gate evaluation) is picked up immediately.
    //
    //      Backed server-side by the `has_approved_photo()` RPC
    //      (SECURITY DEFINER, scoped to `auth.uid()`) so a tampered
    //      client cannot self-affirm by mutating local state. Fail-
    //      closed on RPC error — better to ask for a photo than to
    //      let a network blip open the live flow.
    ref.invalidate(hasApprovedPhotoProvider);
    final hasApproved =
        await ref.read(hasApprovedPhotoProvider.future);
    if (!hasApproved) {
      // "No approved photo" covers two very different situations, and
      // telling someone to add a photo they just added is the worse of the
      // two mistakes. A photo still pending or analyzing means the Vision
      // pipeline has not answered yet — seconds, usually — so the honest
      // message is "wait", not "upload".
      ref.invalidate(myPhotoStatusesProvider);
      final statuses = await ref.read(myPhotoStatusesProvider.future);
      final awaitingVerdict = statuses.values.any(
        (s) =>
            s == PhotoModerationStatus.pending ||
            s == PhotoModerationStatus.analyzing,
      );
      _log.warn(
        'No approved photo for ${user.id} — blocking find date '
        '(cached photoUrls=${profile.photoUrls.length}, '
        'awaitingVerdict=$awaitingVerdict)',
      );
      if (!context.mounted) return;
      final retry =
          await _showPhotoRequiredSheet(context, pending: awaitingVerdict);
      // The verdict usually lands while the sheet is open, so a retry is
      // very often all it takes.
      if (retry == true && mounted) unawaited(_onFindDate());
      return;
    }
    _log.info('Approved photo confirmed — gate cleared');

    // 2.6. Identity gate — Phase 5 + final-build strictness.
    //
    //      Two paths controlled by [FeatureFlags.allowGrandfatherBypass]
    //      (default false, see feature_flags.dart for the rationale) :
    //
    //        STRICT (default, production builds)
    //          Uses [isDiditVerifiedProvider] — true ONLY when the
    //          user has a real `identity_verifications` row with
    //          `status='approved'`. Grandfather accounts (Phase 1
    //          migration leftovers) are BLOCKED here. This is the
    //          "every user must have gone through Didit" stance the
    //          product spec mandates for the final build.
    //
    //        LENIENT (`ALLOW_GRANDFATHER_BYPASS=true` in .env)
    //          Falls back to the original `has_verified_identity()`
    //          RPC which accepts grandfather. Used by the dev /
    //          QA team so their pre-Didit accounts can keep
    //          working through the matching flow during daily
    //          development.
    //
    //      Whole block is gated by
    //      [FeatureFlags.requireIdentityVerification] — flip
    //      `IDENTITY_GATE=false` in .env to fully disarm the gate
    //      (emergency fuse).
    //
    //      Note : like every other Flutter-side gate in this file,
    //      a tampered client can technically bypass this. Real
    //      server-side enforcement would require checking
    //      identity_verified in the matching RPCs themselves, which
    //      is explicitly out of scope per the current product spec.
    if (FeatureFlags.requireIdentityVerification) {
      bool verified;
      if (FeatureFlags.allowGrandfatherBypass) {
        // Lenient path — invalidate the RPC provider so a freshly
        // landed webhook flips the gate without an app restart.
        ref.invalidate(hasVerifiedIdentityProvider);
        verified = await ref.read(hasVerifiedIdentityProvider.future);
        _log.info(
          'Identity gate (lenient/grandfather-bypass) → verified=$verified',
        );
      } else {
        // Strict path — derived from the realtime stream of
        // `identity_verifications`. No async work, no RPC round
        // trip ; the provider re-evaluates synchronously when the
        // stream emits.
        verified = ref.read(isDiditVerifiedProvider);
        _log.info('Identity gate (strict/didit-only) → verified=$verified');
      }
      if (!verified) {
        _log.warn(
          'Identity not verified for ${user.id} — blocking find date',
        );
        if (!context.mounted) return;
        await _showIdentityRequiredSheet(context);
        return;
      }
      _log.info('Identity verified — gate cleared');
    }

    // 3. Quota — wrapped: a broken quota backend should NOT block the
    //    button. We log and proceed in that case.
    try {
      // Awaited rather than read off the cached AsyncValue: a paying user
      // whose subscription stream has not resolved yet would otherwise be
      // measured against the free cap and blocked at 3.
      final isPremium =
          (await ref.read(subscriptionStateProvider.future)).isPremium;
      final status = await ref
          .read(quotaRepositoryProvider)
          .currentStatus(profile, isPremium: isPremium);
      _log.info(
        'Quota OK: used=${status.usedToday} cap=${status.cap ?? "∞"}',
      );
      if (status.isExhausted) {
        _log.info('Quota exhausted — showing limit sheet.');
        if (!context.mounted) return;
        await showQuotaLimitSheet(
          context,
          dailyCap: status.effectiveCap ?? 0,
        );
        return;
      }
    } catch (e, st) {
      _log.error('Quota check failed (continuing anyway): $e', e, st);
    }

    // 3.5. Location guard — `find_best_live_candidate_v1` hard-rejects
    //      callers with `profiles.location IS NULL` via
    //      `rejection_reason = 'no_location_self'` (see
    //      `supabase/migrations/20260526170000_find_best_live_candidate_v1.sql:89-95`).
    //      Without this gate the user enters the queue but the scoring
    //      RPC refuses them every poll and they never match.
    //
    //      `refreshIfStale` is cheap when fresh (one column SELECT) and
    //      only triggers a GPS read + `update_my_location` RPC when the
    //      cached `location_updated_at` is missing or > 24 h old —
    //      which is exactly the "first time the user taps Find a date"
    //      case we are repairing here.
    final locResult = await LocationService.instance.refreshIfStale();
    if (locResult is LocationDenied) {
      _log.warn(
        'Location denied — aborting match. permanently=${locResult.permanently}',
      );
      if (!context.mounted) return;
      context.showSnack(
        locResult.permanently
            ? l10n.privacyLocationStatusDeniedForever
            : l10n.privacyLocationDeniedSnack,
      );
      return;
    }
    if (locResult is LocationServicesOff) {
      _log.warn('Device location services OFF — aborting match.');
      if (!context.mounted) return;
      context.showSnack(l10n.privacyLocationServicesOff);
      return;
    }
    if (locResult is LocationFailed) {
      _log.warn(
        'Location capture failed (${locResult.reason}) — aborting match.',
      );
      if (!context.mounted) return;
      context.showSnack(l10n.privacyLocationFailedSnack);
      return;
    }
    // null  → cached location_updated_at is fresh (< 24 h) → proceed.
    // Captured → just pushed → proceed.
    _log.info(
      'Location ready (${locResult is LocationCaptured ? "captured+pushed" : "cached fresh"})',
    );

    // 3.6. Camera + microphone gate — validated HERE, before the first
    //       date, instead of mid-call inside the Agora bootstrap. Asking
    //       after the user matched + waited is the worst possible moment;
    //       a refusal there is a dead-end. We request up-front and, on
    //       refusal, surface a dialog with an "Ouvrir les réglages" deep
    //       link so the user is never stuck.
    if (!context.mounted) return;
    // ignore: use_build_context_synchronously
    final permsOk = await _ensureCallPermissions(context);
    if (!permsOk) {
      _log.warn('Camera/mic not granted — blocking find date');
      return;
    }
    _log.info('Camera + mic granted — gate cleared');

    // 4. Navigate to the matching screen. The matching screen owns the
    //    "find candidate → start call session → open call screen" chain.
    if (!context.mounted) return;
    _log.info('Matching started → navigating to /matching');
    try {
      await context.pushNamed(AppRoute.matching.name);
      // Back on Home: the date that just happened has to be counted, or the
      // Premium pitch can never fire at the moment it was written for.
      // Nothing else in the app invalidates this counter.
      if (mounted) ref.invalidate(completedDatesProvider);
    } catch (e, st) {
      _log.error('Navigation to /matching failed: $e', e, st);
      if (!context.mounted) return;
      context.showSnack(l10n.findDateError);
    }
  }

  /// Ensures camera + microphone are granted BEFORE the first date.
  /// Returns true only when both are granted. On refusal it shows a
  /// dialog with "Continuer" (re-request) and "Ouvrir les réglages"
  /// (deep link via `openAppSettings()`), so the user always has a way
  /// forward — never a dead-end at the call screen.
  Future<bool> _ensureCallPermissions(BuildContext context) async {
    final cam = await Permission.camera.status;
    final mic = await Permission.microphone.status;
    if (cam.isGranted && mic.isGranted) return true;

    // First, try the native prompt (no-op if iOS already denied for good
    // — that path falls through to the settings dialog below).
    final results = await [Permission.camera, Permission.microphone].request();
    final camOk = results[Permission.camera]?.isGranted ?? false;
    final micOk = results[Permission.microphone]?.isGranted ?? false;
    if (camOk && micOk) return true;

    if (!context.mounted) return false;
    final retry = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Autorisation requise'),
        content: const Text(
          'DateNow a besoin de la caméra et du micro pour lancer une date '
          'vidéo.',
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await openAppSettings();
              if (ctx.mounted) Navigator.of(ctx).pop(false);
            },
            child: const Text('Ouvrir les réglages'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Continuer'),
          ),
        ],
      ),
    );

    // "Continuer" → one more request pass (covers the not-yet-permanent
    // case). "Ouvrir les réglages" / dismiss → don't proceed this round;
    // the user re-taps "Lancer un date" when they come back.
    if (retry == true) {
      final r =
          await [Permission.camera, Permission.microphone].request();
      return (r[Permission.camera]?.isGranted ?? false) &&
          (r[Permission.microphone]?.isGranted ?? false);
    }
    return false;
  }

  /// Premium bottom sheet shown when the user taps "Find a date" without
  /// a profile photo. Offers a one-tap path to the photos editor.
  /// Returns true when the user asked to try again — only offered while a
  /// verdict is still pending, since retrying changes nothing otherwise.
  Future<bool?> _showPhotoRequiredSheet(
    BuildContext context, {
    bool pending = false,
  }) {
    final l10n = AppLocalizations.of(context);
    return showModalBottomSheet<bool>(
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
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.tint,
                ),
                child: Icon(
                  pending
                      ? Icons.hourglass_top_rounded
                      : Icons.camera_alt_rounded,
                  color: AppColors.bordeaux,
                  size: 34,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                pending
                    ? l10n.findDatePhotoPendingTitle
                    : l10n.findDatePhotoRequiredTitle,
                textAlign: TextAlign.center,
                style: AppTypography.h2,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                pending
                    ? l10n.findDatePhotoPendingBody
                    : l10n.findDatePhotoRequiredBody,
                textAlign: TextAlign.center,
                style: AppTypography.body
                    .copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: AppSpacing.lg),
              AppButton(
                label: pending
                    ? l10n.findDatePhotoPendingCta
                    : l10n.findDatePhotoRequiredCta,
                icon: pending
                    ? Icons.refresh_rounded
                    : Icons.add_a_photo_rounded,
                size: AppButtonSize.large,
                onPressed: () {
                  if (pending) {
                    Navigator.of(sheetContext).pop(true);
                    return;
                  }
                  Navigator.of(sheetContext).pop(false);
                  context.pushNamed(AppRoute.editPhotos.name);
                },
              ),
              const SizedBox(height: AppSpacing.sm),
              AppButton(
                label: l10n.findDatePhotoRequiredCancel,
                variant: AppButtonVariant.secondary,
                onPressed: () => Navigator.of(sheetContext).pop(false),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
          ),
        ),
      ),
    );
  }

  /// Premium bottom sheet shown when the user taps Find-date without a
  /// completed Didit identity verification. Mirrors
  /// [_showPhotoRequiredSheet] visually so the two pre-flight gates
  /// read as the same UX language.
  ///
  /// Strings are hardcoded FR for now — these are launch-blocking
  /// surfaces, getting them into AppLocalizations is the next chore
  /// after Phase 6 ships. Tagged with `TODO(i18n-identity)`.
  Future<void> _showIdentityRequiredSheet(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        top: false,
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
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.tint,
                ),
                child: const Icon(
                  Icons.verified_user_outlined,
                  color: AppColors.bordeaux,
                  size: 34,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'Vérification d\'identité requise', // TODO(i18n-identity)
                textAlign: TextAlign.center,
                style: AppTypography.h2,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                // TODO(i18n-identity)
                'Pour protéger la communauté DateNow, vérifie ton '
                'identité avant de lancer une rencontre.',
                textAlign: TextAlign.center,
                style: AppTypography.body
                    .copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: AppSpacing.lg),
              AppButton(
                label: 'Vérifier maintenant', // TODO(i18n-identity)
                icon: Icons.shield_outlined,
                size: AppButtonSize.large,
                onPressed: () {
                  Navigator.of(sheetContext).pop();
                  context.pushNamed(AppRoute.identityVerification.name);
                },
              ),
              const SizedBox(height: AppSpacing.sm),
              AppButton(
                label: 'Plus tard', // TODO(i18n-identity)
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
    return AppCard(
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
                    color: AppColors.tint,
                    borderRadius: AppRadius.brSm,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '${i + 1}',
                    style: AppTypography.caption.copyWith(
                      color: AppColors.bordeaux,
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return AppCard(
      onTap: onTap,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: 18,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Clay chip: Premium is warm-accent territory, not a second
            // bordeaux CTA competing with the hero.
            Container(
              width: 46,
              height: 46,
              decoration: const BoxDecoration(
                color: AppColors.clayTint,
                borderRadius: AppRadius.brSm,
              ),
              child: const Icon(
                Icons.workspace_premium_rounded,
                color: AppColors.clay,
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
            // Outlined pill: the row is already tappable, so this only
            // has to name the action — filling it would put a second
            // bordeaux block on a screen that already has the hero.
            Container(
              decoration: const BoxDecoration(
                borderRadius: AppRadius.brPill,
                color: AppColors.tint,
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
                        color: AppColors.bordeaux,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.arrow_forward_rounded,
                      size: 16,
                      color: AppColors.bordeaux,
                    ),
                  ],
                ),
              ),
            ),
          ],
      ),
    );
  }
}

/// Soft community-safety nudge shown on Home for any user who has
/// NOT been Didit-approved yet. Reads [isDiditVerifiedProvider] so a
/// grandfather account (identity_provider='grandfather' from the
/// Phase 1 migration) is still asked to go through Didit, while a
/// real approved account sees nothing.
///
/// Visual tone : premium + reassuring. Brand gradient on the icon
/// (same warm orb used by the photo-required sheet) plus a soft
/// glass-card body. NOT a warning color — the goal is "join the
/// secure crew", not "you are suspicious".
///
/// Whole card is tappable (single primary CTA). No dismiss button —
/// the card hides itself the moment the Didit webhook flips the
/// row's status to `approved` (Realtime stream → provider rebuild).
///
/// TODO(i18n-identity): hardcoded FR until Phase 5+ stabilises.
class _HomeIdentityNudge extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final diditVerified = ref.watch(isDiditVerifiedProvider);
    if (diditVerified) return const SizedBox.shrink();

    return Material(
      color: Colors.transparent,
      borderRadius: AppRadius.brLg,
      child: InkWell(
        onTap: () =>
            context.pushNamed(AppRoute.identityVerification.name),
        borderRadius: AppRadius.brLg,
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: AppColors.surfaceElevated,
            borderRadius: AppRadius.brLg,
            border: Border.all(color: AppColors.hairline),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Warm gradient orb — same visual language as
              // _showPhotoRequiredSheet's hero icon, so the two
              // community-safety surfaces read as the same family.
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: AppColors.signatureGradient,
                ),
                child: const Icon(
                  Icons.shield_outlined,
                  color: Colors.white,
                  size: 22,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Protège tes rencontres',
                      style: AppTypography.bodyStrong,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'La vérification d\'identité aide à garder '
                      'DateNow sûr pour tout le monde.',
                      style: AppTypography.caption.copyWith(
                        color: AppColors.textSecondary,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      'Vérifier mon identité  →',
                      style: AppTypography.caption.copyWith(
                        color: AppColors.bordeaux,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
