import 'package:flutter/material.dart';

import 'package:hoshi/ui/theme/md3_tokens.dart';

/// 骨架屏方块。
///
/// 用一条从左上到右下的高光扫过表面色，代替「转圈 + 空白」。首屏比
/// 转圈更少突兀：用户能先看到页面结构，数据到位后内容替换占位，布局
/// 不跳动。
///
/// 遵循两条约束：
/// - 系统关闭动画时停止扫动，只显示静态色块；
/// - 子树不可见（`TickerMode` 关闭，例如被其他路由盖住）时停止计时，
///   避免后台空转。
class Skeleton extends StatefulWidget {
  const Skeleton({
    super.key,
    this.width,
    this.height = 16,
    this.radius = Md3Shape.small,
    this.child,
  });

  /// 宽度；为空时撑满父级约束。
  final double? width;
  final double height;
  final double radius;

  /// 自定义形状（例如海报占位）。给出时忽略 [width] / [height] / [radius]。
  final Widget? child;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: Md3Motion.skeleton * 2,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final base = colors.surfaceContainerHighest;
    final highlight = Color.alphaBlend(
      colors.onSurface.withValues(alpha: .06),
      base,
    );
    final box = widget.child ??
        SizedBox(
          width: widget.width,
          height: widget.height,
        );
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(
          widget.child == null ? widget.radius : Md3Shape.cardRadius,
        ),
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final t = _controller.value;
            return DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment(-1 + 2 * t, -.3),
                  end: Alignment(-.4 + 2 * t, .3),
                  colors: [base, highlight, base],
                  stops: const [0, .5, 1],
                ),
              ),
              child: box,
            );
          },
        ),
      ),
    );
  }
}

/// 海报网格的骨架屏。
///
/// 一格 = 一张海报占位 + 两行文字条，与真实海报卡片同形。列数与
/// [tileExtent] 必须由调用方用**与真实网格同一组值**算出来
/// （[Md3Grid.columns] / [Md3Grid.tileWidth] + 卡片的行高函数），
/// 否则数据到位时会跳版。
class SkeletonGrid extends StatelessWidget {
  const SkeletonGrid({
    super.key,
    required this.columns,
    required this.tileExtent,
    this.rows = 3,
  });

  final int columns;

  /// 单格高度，等于真实网格的 `mainAxisExtent`。
  final double tileExtent;
  final int rows;

  @override
  Widget build(BuildContext context) => GridView.builder(
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    padding: EdgeInsets.zero,
    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columns,
      mainAxisExtent: tileExtent,
      crossAxisSpacing: Md3Grid.spacing,
      mainAxisSpacing: Md3Grid.rowSpacing,
    ),
    itemCount: columns * rows,
    itemBuilder: (_, _) => const _PosterSkeleton(),
  );
}

/// 一格海报占位。
class _PosterSkeleton extends StatelessWidget {
  const _PosterSkeleton();

  @override
  Widget build(BuildContext context) => const Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      // 海报吃掉除文字区以外的全部高度，因此总高与真实卡片严格一致。
      Expanded(child: Skeleton(child: SizedBox.expand())),
      SizedBox(height: Md3Spacing.xs),
      FractionallySizedBox(
        widthFactor: .85,
        alignment: Alignment.centerLeft,
        child: Skeleton(height: Md3Type.bodyMedium, radius: Md3Shape.extraSmall),
      ),
      SizedBox(height: Md3Spacing.xs),
      FractionallySizedBox(
        widthFactor: .55,
        alignment: Alignment.centerLeft,
        child: Skeleton(height: Md3Type.bodySmall, radius: Md3Shape.extraSmall),
      ),
    ],
  );
}

/// 列表骨架屏：若干行「图标 + 两行文字」。
class SkeletonList extends StatelessWidget {
  const SkeletonList({super.key, this.rows = 6, this.showLeading = true});

  final int rows;
  final bool showLeading;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (var index = 0; index < rows; index++)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Md3Spacing.sm),
          child: Row(
            children: [
              if (showLeading) ...[
                const Skeleton(width: 44, height: 44, radius: Md3Shape.medium),
                const SizedBox(width: Md3Spacing.lg),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Skeleton(
                      width: index.isEven ? 200 : 150,
                      height: 14,
                      radius: Md3Shape.extraSmall,
                    ),
                    const SizedBox(height: Md3Spacing.sm),
                    Skeleton(
                      width: index.isEven ? 120 : 180,
                      height: 12,
                      radius: Md3Shape.extraSmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
    ],
  );
}
