import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../profile_setup/domain/prompt.dart';
import '../../../profile_setup/domain/prompt_answer.dart';
import '../../../profile_setup/presentation/providers/profile_provider.dart';

/// The peer's written answers, one tap away, during the call.
///
/// This is the piece of the prompts feature no photo-first app can copy:
/// five minutes of live video with a stranger has a failure mode — the
/// silence at ninety seconds — and these are what you reach for.
///
/// Deliberately additive and inert:
///   * it is a sibling in CallScreen's Stack, never inside AgoraCallView.
///     The blur is a BackdropFilter over an iOS PlatformView, and
///     reordering that stack is exactly what would switch it off. Pillar 3
///     of the App Store appeal rests on that blur, so this stays away from
///     it;
///   * with no answers it renders nothing at all, so for every account that
///     has not written any, the call screen is what it was;
///   * collapsed by default, and it sits above the control bar so it can
///     never cover mic, camera or hang-up.
class PromptLifeline extends ConsumerStatefulWidget {
  const PromptLifeline({super.key, required this.peerUserId});

  final String peerUserId;

  @override
  ConsumerState<PromptLifeline> createState() => _PromptLifelineState();
}

class _PromptLifelineState extends ConsumerState<PromptLifeline> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final prompts =
        ref.watch(peerPromptsProvider(widget.peerUserId)).asData?.value ??
            const <PromptAnswer>[];
    if (prompts.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      child: AnimatedSize(
        duration: AppDurations.fast,
        curve: Curves.easeOut,
        alignment: Alignment.bottomCenter,
        child: _open
            ? _Panel(
                title: l10n.callLifelineTitle,
                prompts: prompts,
                onClose: () => setState(() => _open = false),
              )
            : _Pill(
                label: l10n.callLifelineOpen,
                onTap: () => setState(() => _open = true),
              ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.bordeauxDeep.withValues(alpha: 0.72),
      borderRadius: AppRadius.brPill,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadius.brPill,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: 10,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.format_quote_rounded,
                size: 16,
                color: AppColors.paper,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: AppTypography.caption.copyWith(
                  color: AppColors.paper,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.title,
    required this.prompts,
    required this.onClose,
  });

  final String title;
  final List<PromptAnswer> prompts;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 220),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        // Warm dark, like the rest of the call. Never black.
        color: AppColors.bordeauxDeep.withValues(alpha: 0.88),
        borderRadius: AppRadius.brLg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title.toUpperCase(),
                  style: AppTypography.overline.copyWith(
                    color: AppColors.paper.withValues(alpha: 0.7),
                    fontSize: 10,
                  ),
                ),
              ),
              InkWell(
                onTap: onClose,
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: AppColors.paper,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: prompts.length,
              separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
              itemBuilder: (_, i) {
                final p = prompts[i];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.question.label(l10n).toUpperCase(),
                      style: AppTypography.overline.copyWith(
                        color: AppColors.paper.withValues(alpha: 0.55),
                        fontSize: 9,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      p.answer,
                      style: AppTypography.h3.copyWith(
                        fontSize: 15,
                        color: AppColors.paper,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
