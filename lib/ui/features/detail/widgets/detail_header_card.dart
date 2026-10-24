import 'package:flutter/material.dart';

import 'package:hoshi/data/app_contract.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/core/widgets.dart';
import 'package:hoshi/ui/theme/md3_tokens.dart';

/// 详情页头部信息卡（参照应用的 `BangumiInfoCardV`）。
///
/// 固定 300 高、最大宽 950，内部是「标题 + 左海报 / 右信息列」。
/// 信息列用 `FittedBox` 包住：系统字号调大时整块等比缩小，而不是溢出——
/// 卡片高度是固定的，一旦文字撑开就会裁掉。
///
/// 右列展示什么取决于数据：参照应用有评分、排名与评分分布直方图，我们的
/// 站源只提供集数、上线日期与热度。因此右列放「总集数 / 上线 / 热度」，
/// 数字用 primary 加粗——那是参照应用里日期与排名用的同一套视觉重量。
class DetailHeaderCard extends StatelessWidget {
  const DetailHeaderCard({
    super.key,
    required this.drama,
    required this.repository,
    this.loading = false,
    this.coverOverlay,
  });

  final Drama drama;
  final AppRepository repository;
  final bool loading;

  /// 叠在封面左下角的浮钮（收藏）。参照应用在同一位置放 `CollectButton`。
  final Widget? coverOverlay;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    return SizedBox(
      // 卡片固定铺满调用方给的最大宽（参照应用 950），标题因此在左边缘，
      // 而不是被内容宽度挤成一条窄块再整体居中。
      width: double.infinity,
      height: Md3Detail.cardHeight,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            drama.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: Md3Type.headlineSmall,
              fontWeight: FontWeight.w700,
              height: 1.25,
              color: colors.onSurface,
            ),
          ),
          const SizedBox(height: Md3Spacing.lg),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Flexible(
                  child: AspectRatio(
                    aspectRatio: Md3Grid.posterRatio,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: DramaCover(
                            drama: drama,
                            repository: repository,
                            heroTag: 'cover-${drama.id}',
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
                ),
                const SizedBox(width: Md3Spacing.lg),
                Flexible(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Flexible(
                        child: SizedBox(
                          width: double.infinity,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.topLeft,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                for (final (index, row) in _metaRows(
                                  drama,
                                  l10n,
                                ).indexed) ...[
                                  if (index > 0)
                                    const SizedBox(height: Md3Spacing.sm),
                                  _Label(row.$1),
                                  _Value(row.$2),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (loading)
                        const SizedBox(
                          height: 40,
                          child: Center(
                            child: SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 右列固定「总集数 + 上线日期」；热度（或评分）有值时才补第三行。
/// 缺失的字段整行省略，不写占位符——固定卡高下占位会挤出真正的信息。
List<(String, String)> _metaRows(Drama drama, AppLocalizations l10n) => [
  if (drama.episodes > 0) (l10n.detailTotalEpisodesLabel, '${drama.episodes}'),
  if (drama.onlineDate.isNotEmpty)
    (l10n.detailOnlineDateLabel, drama.onlineDate),
  if (drama.heat.isNotEmpty) (l10n.detailHeatLabel, drama.heat),
];

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      fontSize: Md3Type.bodyMedium,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}

/// 数值：参照应用里日期 / 评分 / 排名都是 `primary` 加粗，这里沿用。
class _Value extends StatelessWidget {
  const _Value(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.bold,
      color: Theme.of(context).colorScheme.primary,
    ),
  );
}
