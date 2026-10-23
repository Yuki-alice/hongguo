import 'package:flutter/material.dart';

import 'package:hoshi/ui/core/app_layout.dart';
import 'package:hoshi/domain/catalog_sort.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/core/l10n_labels.dart';
import 'package:hoshi/ui/theme/md3_tokens.dart';

/// 选择目录排序与筛选条件。
///
/// 形态随窗口变化：手机 / 平板用底部弹层（拇指可达），桌面用居中对话框
/// （在 1440 高的窗口里，从底部滑出的面板离触发它的工具栏太远，视线要
/// 跨越整个屏幕）。
Future<CatalogView?> chooseCatalogView(
  BuildContext context,
  CatalogView current,
) {
  final wide =
      MediaQuery.sizeOf(context).width >= Md3WindowClass.expanded &&
      !AppLayout.isTelevision(context);
  if (wide) {
    return showDialog<CatalogView>(
      context: context,
      builder: (context) => _CatalogViewDialog(current: current),
    );
  }
  return showModalBottomSheet<CatalogView>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => _CatalogViewSheet(current: current),
  );
}

/// 排序与筛选的实际内容。两种形态共用，保证选项一致。
///
/// 受控组件：状态只在宿主那一层，避免子组件各持一份 `_selected` 导致
/// 两处选择互相覆盖。
class _CatalogViewContent extends StatelessWidget {
  const _CatalogViewContent({
    required this.current,
    required this.onChanged,
  });

  final CatalogView current;
  final ValueChanged<CatalogView> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.episodeStatusFilter,
          style: TextStyle(
            fontSize: Md3Type.labelLarge,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        const SizedBox(height: Md3Spacing.sm),
        Wrap(
          spacing: Md3Spacing.sm,
          runSpacing: Md3Spacing.sm,
          children: [
            for (final entry in {
              '': l10n.filterAll,
              'ongoing': l10n.releaseOngoing,
              'finished': l10n.releaseFinished,
              'unknown': l10n.statusUnknown,
            }.entries)
              ChoiceChip(
                key: ValueKey('release-${entry.key.isEmpty ? 'all' : entry.key}'),
                label: Text(entry.value),
                selected: current.release == entry.key,
                onSelected: (_) =>
                    onChanged(current.copyWith(release: entry.key)),
              ),
          ],
        ),
      ],
    );
  }
}

/// 排序选项列表。同样受控。
class _SortOptions extends StatelessWidget {
  const _SortOptions({required this.current, required this.onChanged});

  final CatalogView current;
  final ValueChanged<CatalogView> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.sortAndFilterTitle,
          style: TextStyle(
            fontSize: Md3Type.labelLarge,
            fontWeight: FontWeight.w700,
            color: colors.primary,
          ),
        ),
        const SizedBox(height: Md3Spacing.sm),
        Wrap(
          spacing: Md3Spacing.sm,
          runSpacing: Md3Spacing.sm,
          children: [
            for (final sort in CatalogSort.values)
              ChoiceChip(
                key: ValueKey('sort-${sort.name}'),
                autofocus:
                    AppLayout.isTelevision(context) &&
                    sort == CatalogSort.values.first,
                label: Text(catalogSortLabel(sort, l10n)),
                selected: current.sort == sort,
                onSelected: (_) =>
                    onChanged(current.copyWith(sort: sort)),
              ),
          ],
        ),
      ],
    );
  }
}

class _CatalogViewSheet extends StatefulWidget {
  const _CatalogViewSheet({required this.current});
  final CatalogView current;

  @override
  State<_CatalogViewSheet> createState() => _CatalogViewSheetState();
}

class _CatalogViewSheetState extends State<_CatalogViewSheet> {
  late CatalogView _selected = widget.current;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        Md3Spacing.xl,
        0,
        Md3Spacing.xl,
        Md3Spacing.xl + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SortOptions(
            current: _selected,
            onChanged: (next) => setState(() => _selected = next),
          ),
          const SizedBox(height: Md3Spacing.xl),
          _CatalogViewContent(
            current: _selected,
            onChanged: (next) => setState(() => _selected = next),
          ),
          const SizedBox(height: Md3Spacing.lg),
          Text(
            l10n.sortFilterHint,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: Md3Spacing.xl),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.pop(context, _selected),
              child: Text(l10n.apply),
            ),
          ),
        ],
      ),
    );
  }
}

/// 桌面：居中对话框，宽 520。
class _CatalogViewDialog extends StatefulWidget {
  const _CatalogViewDialog({required this.current});
  final CatalogView current;

  @override
  State<_CatalogViewDialog> createState() => _CatalogViewDialogState();
}

class _CatalogViewDialogState extends State<_CatalogViewDialog> {
  late CatalogView _selected = widget.current;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.sortAndFilterTitle),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SortOptions(
                current: _selected,
                onChanged: (next) => setState(() => _selected = next),
              ),
              const SizedBox(height: Md3Spacing.xl),
              _CatalogViewContent(
                current: _selected,
                onChanged: (next) => setState(() => _selected = next),
              ),
              const SizedBox(height: Md3Spacing.lg),
              Text(
                l10n.sortFilterHint,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _selected),
          child: Text(l10n.apply),
        ),
      ],
    );
  }
}
