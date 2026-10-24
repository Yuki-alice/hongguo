import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_new_shapes/material_new_shapes.dart';

import 'package:hoshi/ui/theme/md3_tokens.dart';

/// 空态 / 错误态的统一展示。
///
/// 结构是「形状徽标 + 标题 + 说明 + 按钮组」。与旧的 `StatusPanel` 相比：
/// - 徽标是 M3 Expressive 的几何形状（cookie4Sided / softBurst），与加载器
///   共用同一套 shape 定义，因此整站的「形状语言」只有一个来源；
/// - 按钮用 `Wrap` 而不是固定行，窄屏或大字号时自动换行；
/// - 标题带 `Semantics(header)`，读屏可以按标题跳转。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    this.message = '',
    this.icon = Icons.movie_filter_outlined,
    this.actions = const [],
    this.compact = false,
    this.tone = EmptyStateTone.neutral,
  });

  final String title;
  final String message;
  final IconData icon;
  final List<Widget> actions;

  /// 紧凑模式：用于嵌在卡片或侧栏里的空态。
  final bool compact;

  final EmptyStateTone tone;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (background, foreground) = switch (tone) {
      EmptyStateTone.neutral => (
        colors.secondaryContainer,
        colors.onSecondaryContainer,
      ),
      EmptyStateTone.error => (colors.errorContainer, colors.onErrorContainer),
    };
    final badge = compact ? 56.0 : 84.0;
    return Center(
      child: SingleChildScrollView(
        primary: false,
        padding: EdgeInsets.symmetric(
          horizontal: Md3Spacing.xl,
          vertical: compact ? Md3Spacing.lg : Md3Spacing.xxl,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ExcludeSemantics(
                child: CustomPaint(
                  painter: ShapeBadgePainter(
                    color: background,
                    shape: tone == EmptyStateTone.error
                        ? MaterialShapes.softBurst
                        : MaterialShapes.cookie4Sided,
                  ),
                  child: SizedBox.square(
                    dimension: badge,
                    child: Icon(
                      icon,
                      size: compact ? 26 : 34,
                      color: foreground,
                    ),
                  ),
                ),
              ),
              SizedBox(height: compact ? Md3Spacing.md : Md3Spacing.xl),
              Semantics(
                header: true,
                liveRegion: true,
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: compact
                        ? Md3Type.titleMedium
                        : Md3Type.titleLarge,
                    fontWeight: FontWeight.w700,
                    color: colors.onSurface,
                    height: 1.3,
                  ),
                ),
              ),
              if (message.isNotEmpty) ...[
                const SizedBox(height: Md3Spacing.md),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: Md3Type.bodyMedium,
                    color: colors.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ],
              if (actions.isNotEmpty) ...[
                SizedBox(height: compact ? Md3Spacing.md : Md3Spacing.xl),
                Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: Md3Spacing.sm,
                  runSpacing: Md3Spacing.sm,
                  children: actions,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

enum EmptyStateTone { neutral, error }

/// 形状徽标。
///
/// 直接使用 M3 Expressive 的 `RoundedPolygon`：空态、错误态与加载器因此
/// 共享同一套几何定义，不会出现「手绘的八瓣花」和「包里的 cookie」两种
/// 风格并存。
class ShapeBadgePainter extends CustomPainter {
  const ShapeBadgePainter({required this.color, required this.shape});

  final Color color;
  final RoundedPolygon shape;

  /// 归一化后的路径缓存在实例上：`normalized()` 每次都要算一遍边界，
  /// 而徽标在空态里是不动的，重复算没有意义。
  static final _cache = <RoundedPolygon, Path>{};

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;
    final path = _cache.putIfAbsent(shape, () => shape.normalized().toPath());
    canvas
      ..save()
      ..translate((size.width - side) / 2, (size.height - side) / 2)
      ..scale(side)
      ..drawPath(path, Paint()..color = color)
      ..restore();
  }

  @override
  bool shouldRepaint(ShapeBadgePainter oldDelegate) =>
      color != oldDelegate.color || shape != oldDelegate.shape;
}

/// 加载指示器。
///
/// 一个形状在 7 个 M3 Expressive 形状之间连续变形，整体同时缓慢自转。
/// 相比转圈，它在长等待时更耐看，也更能表达「正在处理」而不是「卡住了」。
///
/// 7 段 × 650ms = 4550ms 一轮，与参照应用一致。morph 对象与形状列表都是
/// 静态共享的：构造 `Morph` 要做顶点匹配，逐帧或逐实例算都很贵。
class AppLoadingIndicator extends StatefulWidget {
  const AppLoadingIndicator({
    super.key,
    this.size = 44,
    this.color,
    this.semanticsLabel = '加载中',
  });

  final double size;
  final Color? color;
  final String semanticsLabel;

  @override
  State<AppLoadingIndicator> createState() => _AppLoadingIndicatorState();
}

/// 变形序列。顺序有讲究：顶点数差太远的两个形状直接相邻时，中间帧会
/// 出现明显的「折叠」，因此从瓣多的往瓣少的逐步过渡。
final _loadingShapes = [
  MaterialShapes.softBurst,
  MaterialShapes.cookie9Sided,
  MaterialShapes.pill,
  MaterialShapes.sunny,
  MaterialShapes.cookie4Sided,
  MaterialShapes.oval,
  MaterialShapes.cookie7Sided,
];

const _morphDuration = Duration(milliseconds: 650);

final _loadingMorphs = List<Morph>.generate(
  _loadingShapes.length,
  (index) => Morph(
    _loadingShapes[index],
    _loadingShapes[(index + 1) % _loadingShapes.length],
  ),
);

class _AppLoadingIndicatorState extends State<AppLoadingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _morphDuration * _loadingShapes.length,
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
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    // 静态帧（关闭动画时）取第一个形状，而不是空白：一个静止的花形仍然
    // 能读出「这里有个指示器」，比什么都不画好。
    if (!_controller.isAnimating) {
      return Semantics(
        label: widget.semanticsLabel,
        child: RepaintBoundary(
          child: CustomPaint(
            size: Size.square(widget.size),
            painter: ShapeBadgePainter(
              color: color,
              shape: _loadingShapes.first,
            ),
          ),
        ),
      );
    }
    return Semantics(
      label: widget.semanticsLabel,
      child: RepaintBoundary(
        child: SizedBox.square(
          dimension: widget.size,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) => CustomPaint(
              painter: _MorphPainter(progress: _controller.value, color: color),
            ),
          ),
        ),
      ),
    );
  }
}

/// 在 [_loadingMorphs] 之间连续变形并整体自转。
class _MorphPainter extends CustomPainter {
  _MorphPainter({required this.progress, required this.color})
    : super(repaint: null);

  final double progress;
  final Color color;
  final Path _path = Path();

  @override
  void paint(Canvas canvas, Size size) {
    final position = progress * _loadingMorphs.length;
    final index = position.floor() % _loadingMorphs.length;
    final t = _emphasized(position % 1);
    final path = _loadingMorphs[index].toPath(progress: t, path: _path);

    // 形状本身画在 1×1 的空间里，先按最短边缩放，再把对角线缩到 √2
    // 以内，这样旋转时不会被裁掉。
    final scale = size.shortestSide / math.sqrt2;
    canvas
      ..save()
      ..translate(size.width / 2, size.height / 2)
      ..rotate(progress * math.pi * 2)
      ..scale(scale)
      ..translate(-.5, -.5)
      ..drawPath(path, Paint()..color = color)
      ..restore();
  }

  /// 与 M3 的 `easeInOutCubicEmphasized` 同形的缓动。
  double _emphasized(double t) =>
      t < .5 ? 4 * t * t * t : 1 - math.pow(-2 * t + 2, 3) / 2;

  @override
  bool shouldRepaint(_MorphPainter oldDelegate) =>
      progress != oldDelegate.progress || color != oldDelegate.color;
}
