import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_spacing.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/utils/extensions.dart';
import '../../../core/utils/logger.dart';
import '../../../shared/widgets/app_button.dart';
import '../../auth/presentation/providers/auth_provider.dart';
import '../data/report_repository.dart';
import '../domain/report_reason.dart';

/// Opens the standard "Signaler / Report" bottom sheet. Returns `true`
/// once a report has been filed (caller can show its own confirmation,
/// pop the screen, etc.).
///
/// Always asks the user whether to also block the reported peer so we
/// satisfy Apple's "Objectionable Content" rule (both report AND block
/// are reachable from the same surface).
Future<bool?> showReportSheet(
  BuildContext context, {
  required String reportedUserId,
  String? reportedDisplayName,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ReportSheet(
      reportedUserId: reportedUserId,
      reportedDisplayName: reportedDisplayName,
    ),
  );
}

class _ReportSheet extends ConsumerStatefulWidget {
  const _ReportSheet({
    required this.reportedUserId,
    required this.reportedDisplayName,
  });

  final String reportedUserId;
  final String? reportedDisplayName;

  @override
  ConsumerState<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends ConsumerState<_ReportSheet> {
  static const _log = AppLogger('ReportSheet');

  ReportReason? _selected;
  bool _alsoBlock = true;
  bool _submitting = false;
  final _detailsCtrl = TextEditingController();

  @override
  void dispose() {
    _detailsCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final reason = _selected;
    if (reason == null || _submitting) return;
    final reporter = ref.read(currentUserProvider);
    if (reporter == null) return;

    setState(() => _submitting = true);
    final repo = ref.read(reportRepositoryProvider);
    final isFr = Localizations.localeOf(context).languageCode == 'fr';

    var blockFailed = false;
    var reportFailed = false;
    try {
      await repo.submit(
        reporterUserId: reporter.id,
        reportedUserId: widget.reportedUserId,
        reason: reason,
        details: _detailsCtrl.text,
      );
    } catch (e, st) {
      reportFailed = true;
      _log.error('report submit failed', e, st);
    }

    if (_alsoBlock) {
      try {
        await repo.blockUser(reportedUserId: widget.reportedUserId);
      } catch (e, st) {
        blockFailed = true;
        _log.error('block_user failed', e, st);
      }
    }

    if (!mounted) return;
    if (reportFailed) {
      context.showSnack(
        isFr
            ? 'Impossible d\'envoyer le signalement. Réessaie plus tard.'
            : 'Couldn\'t send the report. Try again later.',
      );
      setState(() => _submitting = false);
      return;
    }

    Navigator.of(context).pop(true);
    final msg = blockFailed
        ? (isFr
            ? 'Merci, notre équipe examinera ce signalement. (Blocage à finaliser dans Réglages.)'
            : 'Thanks — our team will review this report. (Finish the block from Settings.)')
        : (isFr
            ? 'Merci, notre équipe examinera ce signalement.'
            : 'Thanks — our team will review this report.');
    context.showSnack(msg);
  }

  @override
  Widget build(BuildContext context) {
    final isFr = Localizations.localeOf(context).languageCode == 'fr';
    final viewInsets = MediaQuery.of(context).viewInsets;

    final title = isFr ? 'Signaler' : 'Report';
    final intro = widget.reportedDisplayName == null
        ? (isFr
            ? 'Choisis le motif. Nous gardons ton signalement confidentiel.'
            : 'Pick a reason. Your report stays confidential.')
        : (isFr
            ? 'Tu signales ${widget.reportedDisplayName!}. Nous gardons ton signalement confidentiel.'
            : 'You are reporting ${widget.reportedDisplayName!}. Your report stays confidential.');
    final detailsLabel =
        isFr ? 'Détails (facultatif)' : 'Details (optional)';
    final blockLabel =
        isFr ? 'Bloquer aussi cette personne' : 'Also block this person';
    final submitLabel = isFr ? 'Envoyer le signalement' : 'Send report';
    final cancelLabel = isFr ? 'Annuler' : 'Cancel';

    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.md,
          AppSpacing.lg,
          AppSpacing.lg,
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.hairline,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                Text(title, style: AppTypography.h2),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  intro,
                  style: AppTypography.body.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                for (final r in ReportReason.values)
                  _ReasonTile(
                    label: r.label(isFr: isFr),
                    selected: _selected == r,
                    onTap: () => setState(() => _selected = r),
                  ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: _detailsCtrl,
                  minLines: 2,
                  maxLines: 4,
                  maxLength: 500,
                  decoration: InputDecoration(
                    labelText: detailsLabel,
                    border: const OutlineInputBorder(),
                  ),
                ),
                CheckboxListTile(
                  value: _alsoBlock,
                  onChanged: (v) => setState(() => _alsoBlock = v ?? true),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(
                    blockLabel,
                    style: AppTypography.body,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                AppButton(
                  label: submitLabel,
                  size: AppButtonSize.large,
                  isLoading: _submitting,
                  onPressed:
                      _selected == null || _submitting ? null : _submit,
                ),
                const SizedBox(height: AppSpacing.sm),
                AppButton(
                  label: cancelLabel,
                  variant: AppButtonVariant.secondary,
                  onPressed: _submitting
                      ? null
                      : () => Navigator.of(context).pop(false),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ReasonTile extends StatelessWidget {
  const _ReasonTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected
            ? AppColors.brandPink.withValues(alpha: 0.12)
            : AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: selected ? AppColors.brandPink : AppColors.hairline,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color:
                      selected ? AppColors.brandPink : AppColors.textTertiary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: Text(label, style: AppTypography.body)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
