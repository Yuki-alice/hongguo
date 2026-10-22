import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';

import 'package:hoshi/ui/theme/md3_tokens.dart';

/// 多选下载时的底部操作条（Material 3 bottom app bar 变体）。
///
/// 只负责呈现与回调，选中集合由调用方持有。
class CatalogSelectionBar extends StatelessWidget {
  const CatalogSelectionBar({
    super.key,
    required this.count,
    required this.maxCount,
    required this.onConfirm,
    required this.confirmFocusNode,
    this.safeBottom = true,
  });

  final int count;
  final int maxCount;
  final VoidCallback onConfirm;
  final FocusNode confirmFocusNode;
  final bool safeBottom;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final summary = Semantics(
      liveRegion: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            count == 0 ? l10n.selectDramasHint : l10n.selectedDramas(count),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: Md3Spacing.xs),
          Text(
            count == 0 ? l10n.maxDramas(maxCount) : l10n.nextStepHint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
    final next = FilledButton(
      key: const ValueKey('download-selected-dramas'),
      focusNode: confirmFocusNode,
      onPressed: count == 0 ? null : onConfirm,
      style: FilledButton.styleFrom(
        minimumSize: const Size(96, 48),
        padding: const EdgeInsets.symmetric(
          horizontal: 20,
          vertical: Md3Spacing.md,
        ),
      ),
      child: Text(l10n.nextStep),
    );
    return Material(
      color: colors.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: colors.outlineVariant)),
        ),
        child: SafeArea(
          top: false,
          bottom: safeBottom,
          minimum: const EdgeInsets.symmetric(
            horizontal: Md3Spacing.lg,
            vertical: Md3Spacing.md,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 极窄窗口或超大字号时改为纵向堆叠，避免按钮被挤压。
              final stacked =
                  constraints.maxWidth < 320 ||
                  MediaQuery.textScalerOf(context).scale(14) > 21;
              if (stacked) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    summary,
                    const SizedBox(height: Md3Spacing.md),
                    next,
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: summary),
                  const SizedBox(width: Md3Spacing.lg),
                  next,
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
