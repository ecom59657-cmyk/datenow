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
        gradient: fromMe ? AppColors.brandGradient : null,
        color: fromMe ? null : AppColors.surfaceElevated,
        border: fromMe ? null : Border.all(color: AppColors.hairline),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(fromMe ? 18 : 4),
          bottomRight: Radius.circular(fromMe ? 4 : 18),
        ),
        boxShadow: fromMe
            ? [
                BoxShadow(
                  color: AppColors.brandPink.withValues(alpha: 0.18),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ]
            : null,
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
  final h = when.hour.toString().padLeft(2, '0');
  final m = when.minute.toString().padLeft(2, '0');
  return '$h:$m';
}
