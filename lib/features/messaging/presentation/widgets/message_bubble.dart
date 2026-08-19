import 'package:flutter/material.dart';

import '../../../../app/theme/app_colors.dart';
import '../../../../app/theme/app_spacing.dart';
import '../../../../app/theme/app_typography.dart';
import '../../domain/message.dart';

/// A single chat bubble. Mine = right-aligned gradient, peer = left
/// glass-tone. Time appears below the bubble, only on the most recent
/// message of a same-author streak (the parent strips it on the others).
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.fromMe,
    this.showTime = true,
  });

  final Message message;
  final bool fromMe;
  final bool showTime;

  @override
  Widget build(BuildContext context) {
    final align = fromMe ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final bubble = Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.72,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm + 2,
      ),
      decoration: BoxDecoration(
        // Sent = flat bordeaux, received = paper with a hairline. A
        // gradient on a chat bubble reads as a button, not as speech.
        color: fromMe ? AppColors.bordeaux : AppColors.paper,
        border: fromMe ? null : Border.all(color: AppColors.line),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(fromMe ? 18 : 4),
          bottomRight: Radius.circular(fromMe ? 4 : 18),
        ),
      ),
      child: Text(
        message.body,
        style: AppTypography.bodyLarge.copyWith(
          color: fromMe ? Colors.white : AppColors.textPrimary,
          height: 1.35,
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: 3,
      ),
      child: Column(
        crossAxisAlignment: align,
        children: [
          bubble,
          if (showTime)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _formatTime(message.createdAt),
                style: AppTypography.caption.copyWith(
                  color: AppColors.textTertiary,
                  fontSize: 11,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

String _formatTime(DateTime when) {
  // Messages arrive parsed as UTC DateTime (Supabase TIMESTAMPTZ with
  // a trailing Z → DateTime.parse returns isUtc=true). Without the
  // .toLocal() the .hour getter reads UTC, so a 15:46 Paris message
  // showed up as 13:46. Convert to the device's local timezone
  // before extracting the wall-clock fields. DB stays UTC; only the
  // render edge converts.
  final local = when.toLocal();
  final h = local.hour.toString().padLeft(2, '0');
  final m = local.minute.toString().padLeft(2, '0');
  return '$h:$m';
}
