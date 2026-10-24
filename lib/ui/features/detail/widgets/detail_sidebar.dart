import 'package:flutter/material.dart';

import 'package:hoshi/data/app_contract.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/core/widgets.dart';
import 'package:hoshi/ui/theme/md3_tokens.dart';

/// 详情页左侧信息栏（双栏 / 三栏）。
///
/// 结构照 animeko 的 `SubjectSidebar`：
/// 封面 → 播放按钮 → 收藏按钮 → 统计 → 分隔线 → 作品信息表 → 标签。
///
/// 与中栏的分工：**这里放「这部作品是什么」的静态事实**，中栏放需要
/// 阅读与操作的内容（简介、选集）。所以标题、简介都不在侧栏重复。
class DetailSidebar extends StatelessWidget {
  const DetailSidebar({
    super.key,
    required this.drama,
    required this.repository,
    required this.width,
    required this.itemSpacing,
    required this.playLabel,
    required this.onPlay,
    this.onDownload,
    this.followControl,
    this.coverOverlay,
  });

  final Drama drama;
  final AppRepository repository;
  final double width;
  final double itemSpacing;

  final String playLabel;
  final VoidCallback? onPlay;
  final VoidCallback? onDownload;

  /// 追剧状态控件（复用页面已有的下拉菜单）。
  final Widget? followControl;

  /// 叠在封面上的浮钮（收藏）。
  final Widget? coverOverlay;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 封面：固定海报比例，不随图片本征尺寸变形。
          AspectRatio(
            aspectRatio: Md3Grid.posterRatio,
            child: Stack(
              children: [
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(Md3Shape.large),
                    child: DramaCover(
                      drama: drama,
                      repository: repository,
                      radius: Md3Shape.large,
                      heroTag: 'cover-${drama.id}',
                    ),
                  ),
                ),
                if (coverOverlay != null)
                  Positioned(
                    left: Md3Spacing.sm,
                    bottom: Md3Spacing.sm,
                    child: coverOverlay!,
                  ),
              ],
            ),
          ),
          SizedBox(height: itemSpacing),
          FilledButton.icon(
            key: const ValueKey('detail-sidebar-play'),
            onPressed: onPlay,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              shape: RoundedRectangleBorder(borderRadius: Md3Shape.pill),
            ),
            icon: const Icon(Icons.play_arrow_rounded, size: 22),
            label: Text(
              playLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onDownload != null) ...[
            const SizedBox(height: Md3Spacing.sm),
            FilledButton.tonalIcon(
              key: const ValueKey('detail-sidebar-download'),
              onPressed: onDownload,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(44),
                shape: RoundedRectangleBorder(borderRadius: Md3Shape.pill),
              ),
              icon: const Icon(Icons.download_rounded, size: 20),
              label: Text(l10n.downloadPickerTitle),
            ),
          ],
          if (followControl != null) ...[
            const SizedBox(height: Md3Spacing.sm),
            followControl!,
          ],
          SizedBox(height: itemSpacing),
          Divider(color: colors.outlineVariant, height: 1),
          SizedBox(height: itemSpacing),
          Text(
            l10n.detailInfoTitle,
            style: TextStyle(
              fontSize: Md3Type.titleSmall,
              fontWeight: FontWeight.w700,
              color: colors.onSurface,
            ),
          ),
          const SizedBox(height: Md3Spacing.md),
          _InfoTable(drama: drama, l10n: l10n),
          if (drama.tags.isNotEmpty) ...[
            SizedBox(height: itemSpacing),
            Text(
              l10n.detailTagsTitle,
              style: TextStyle(
                fontSize: Md3Type.titleSmall,
                fontWeight: FontWeight.w700,
                color: colors.onSurface,
              ),
            ),
            const SizedBox(height: Md3Spacing.sm),
            Wrap(
              spacing: Md3Spacing.sm,
              runSpacing: Md3Spacing.sm,
              children: [
                for (final tag in drama.tags)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerHighest,
                      borderRadius: Md3Shape.chip,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      child: Text(
                        tag,
                        style: TextStyle(
                          fontSize: Md3Type.bodySmall,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 作品信息表：两列键值，缺失字段整行省略。
class _InfoTable extends StatelessWidget {
  const _InfoTable({required this.drama, required this.l10n});

  final Drama drama;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final site = SourceSite.byId(drama.source);
    final rows = <(String, String)>[
      (l10n.detailSourceLabel, site.name),
      if (drama.category.isNotEmpty) (l10n.detailCategoryLabel, drama.category),
      if (drama.episodes > 0)
        (l10n.detailTotalEpisodesLabel, '${drama.episodes}'),
      if (drama.releaseStatus.isNotEmpty && drama.releaseStatus != 'unknown')
        (l10n.detailStatusLabel, drama.releaseLabel),
      if (drama.onlineDate.isNotEmpty)
        (l10n.detailOnlineLabel, drama.onlineDate),
      if (drama.heat.isNotEmpty) (l10n.detailHeatLabel, drama.heat),
      if (drama.views.isNotEmpty) (l10n.detailViewsLabel, drama.views),
    ];
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: Md3Spacing.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 64,
                  child: Text(
                    row.$1,
                    style: TextStyle(
                      fontSize: Md3Type.bodySmall,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    row.$2,
                    style: TextStyle(
                      fontSize: Md3Type.bodySmall,
                      color: colors.onSurface,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
