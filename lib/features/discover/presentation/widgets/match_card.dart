import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../core/utils/profile_format.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/widgets/glass_card.dart';
import '../../../profile_setup/data/profile_repository.dart';
import '../../../profile_setup/domain/user_profile.dart';
import '../../domain/mutual_match.dart';

/// Card for a confirmed mutual match in the Discover "Matchs effectués"
/// section.
///
/// Redesign goals (premium, minimal, iOS-native feel):
///   • Real profile photo (already revealed during post-call) inside a thin
///     brand-gradient ring with a soft glow — never the bare initial.
///   • Full name + age, never truncated. The layout reserves enough room
///     by keeping the right-hand button icon-only.
///   • A single quiet compatibility pill ("93 % compatible") with a subtle
///     pink glow, replacing the old loud "Nouveau match" status badge.
///   • An icon-only message button (round, hairline-brand, vertical-centered)
///     — the only secondary action the card needs.
///
/// Photo loading mirrors `conversation_tile.dart`: a `FutureBuilder` on
/// `ProfileRepository.getPhotoBytes(storagePath)` returns the cached bytes
/// or a graceful initial fallback while in flight / on miss.
class MatchCard extends ConsumerWidget {
  const MatchCard({super.key, required this.match, this.onTap});

  final MutualMatch match;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final candidate = match.candidate;

    return GlassCard(
      // Slightly more breathing room than the default md inset so the
      // avatar, name and action don't feel compressed.
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _MatchAvatar(profile: candidate),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Name + age. We refuse ellipsis: with the right-side
                // action reduced to a 42pt icon button the row reserves
                // ~135pt for the name on the smallest iPhone (SE), which
                // accommodates virtually any first name. The very rare
                // edge case (compound names) wraps to a 2nd line.
                Text(
                  formatProfileNameAge(
                    l10n,
                    firstName: candidate.firstName,
                    age: candidate.age,
                  ),
                  style: AppTypography.bodyStrong.copyWith(
                    fontSize: 17,
                    letterSpacing: 0.1,
                    height: 1.2,
                  ),
                  maxLines: 2,
                  softWrap: true,
                ),
                const SizedBox(height: 6),
                _CompatibilityPill(percentage: match.compatibilityScore),
              ],
            ),
          ),
          if (onTap != null) ...[
            const SizedBox(width: AppSpacing.sm),
            _MessageButton(onTap: onTap),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Avatar — real photo (Image.memory via FutureBuilder) inside a thin
// brand-gradient ring + soft pink halo. Initial fallback if the profile has
// no photoUrl yet (rare: photos are required to start a date).
// ---------------------------------------------------------------------------

class _MatchAvatar extends ConsumerWidget {
  const _MatchAvatar({required this.profile});

  final UserProfile profile;

  /// 56 pt = visually substantial without crowding the row on small devices.
  static const double _size = 56;
  static const double _ringThickness = 1.6;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = profile.primaryPhotoUrl;
    return Container(
      width: _size,
      height: _size,
      // The gradient ring lives in the outer container's background; the
      // inner ClipOval carves out a pixel of padding for the ring effect.
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: AppColors.brandGradient,
        boxShadow: [
          BoxShadow(
            color: AppColors.brandPink.withValues(alpha: 0.22),
            blurRadius: 14,
            spreadRadius: 0,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      padding: const EdgeInsets.all(_ringThickness),
      child: ClipOval(
        child: ColoredBox(
          color: AppColors.surfaceElevated,
          child: url == null
              ? _InitialFill(firstName: profile.firstName)
              : _AsyncPhoto(
                  storagePath: url,
                  fallbackInitial: _firstInitial(profile.firstName),
                ),
        ),
      ),
    );
  }
}

class _AsyncPhoto extends ConsumerWidget {
  const _AsyncPhoto({
    required this.storagePath,
    required this.fallbackInitial,
  });

  final String storagePath;
  final String fallbackInitial;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<Uint8List?>(
      future: ref.read(profileRepositoryProvider).getPhotoBytes(storagePath),
      builder: (context, snap) {
        final bytes = snap.data;
        if (bytes == null) {
          return _InitialFill.fromInitial(fallbackInitial);
        }
        return Image.memory(
          bytes,
          fit: BoxFit.cover,
          gaplessPlayback: true,
        );
      },
    );
  }
}

class _InitialFill extends StatelessWidget {
  const _InitialFill({required this.firstName}) : _initial = null;
  const _InitialFill.fromInitial(this._initial) : firstName = null;

  final String? firstName;
  final String? _initial;

  @override
  Widget build(BuildContext context) {
    final letter = _initial ?? _firstInitial(firstName);
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: AppColors.brandGradient),
      child: Center(
        child: Text(
          letter,
          style: AppTypography.bodyStrong.copyWith(
            color: Colors.white,
            fontSize: 22,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }
}

String _firstInitial(String? firstName) {
  final trimmed = firstName?.trim();
  if (trimmed == null || trimmed.isEmpty) return '·';
  return trimmed.characters.first.toUpperCase();
}

// ---------------------------------------------------------------------------
// Compatibility pill — quiet, single-line "93 % compatible" with a subtle
// pink halo. Uses the existing `compatibilityValue` l10n key (FR / EN both
// already render "X % compatible" / "X% compatible").
// ---------------------------------------------------------------------------

class _CompatibilityPill extends StatelessWidget {
  const _CompatibilityPill({required this.percentage});

  final int percentage;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.brandPink.withValues(alpha: 0.10),
        borderRadius: AppRadius.brPill,
        border: Border.all(
          color: AppColors.brandPink.withValues(alpha: 0.28),
          width: 0.6,
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.brandPink.withValues(alpha: 0.16),
            blurRadius: 12,
            spreadRadius: 0,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.bolt_rounded,
            color: AppColors.brandPink,
            size: 13,
          ),
          const SizedBox(width: 5),
          Text(
            l10n.compatibilityValue(percentage),
            style: AppTypography.caption.copyWith(
              color: AppColors.brandPink,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
              fontSize: 12,
            ),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.fade,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Message button — icon-only, 42 pt round (above the 44 pt iOS HIG tap
// target is the surrounding row, the visible circle is 42 pt for finesse).
// Glass tint + hairline-pink + a soft halo so it reads as the primary
// action on the right without competing with the avatar's energy.
// ---------------------------------------------------------------------------

class _MessageButton extends StatelessWidget {
  const _MessageButton({required this.onTap});

  final VoidCallback? onTap;
  static const double _size = 42;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        splashColor: AppColors.brandPink.withValues(alpha: 0.18),
        highlightColor: AppColors.brandPink.withValues(alpha: 0.08),
        child: Container(
          width: _size,
          height: _size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.glass,
            border: Border.all(
              color: AppColors.brandPink.withValues(alpha: 0.34),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.brandPink.withValues(alpha: 0.18),
                blurRadius: 10,
                spreadRadius: 0,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: const Icon(
            Icons.chat_bubble_rounded,
            color: AppColors.brandPink,
            size: 18,
          ),
        ),
      ),
    );
  }
}
