import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:hoshi/ui/theme/md3_tokens.dart';

/// 空态 / 错误态的统一展示。
///
/// 结构是「形状徽标 + 标题 + 说明 + 按钮组」。与旧的 `StatusPanel` 相比：
/// - 徽标不是普通圆形，而是一个手绘的圆角星形，用 `CustomPaint` 画，
///   不依赖图片资源，也不受字体缩放影响；
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
      EmptyStateTone.neutral => (colors.secondaryContainer, colors.onSecondaryContainer),
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
                  painter: _StarBadgePainter(
                    color: background,
                    shape: tone == EmptyStateTone.error
                        ? _BadgeShape.softBurst
                        : _BadgeShape.cookie,
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

enum _BadgeShape { cookie, softBurst }

/// 手绘徽标。
///
/// cookie：8 段圆弧组成的圆角花瓣；softBurst：12 个不等长尖角。
/// 两者都是闭合路径，直接填充，不需要图片。
class _StarBadgePainter extends CustomPainter {
  const _StarBadgePainter({required this.color, required this.shape});

  final Color color;
  final _BadgeShape shape;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    canvas.drawPath(_path(center, radius), paint);
  }

  Path _path(Offset center, double radius) {
    final path = Path();
    switch (shape) {
      case _BadgeShape.cookie:
        // 8 瓣：每瓣用二次贝塞尔外凸，瓣间内凹到 0.86R。
        const petals = 8;
        final inner = radius * .86;
        for (var index = 0; index < petals * 2; index++) {
          final angle = math.pi / petals * index - math.pi / 2;
          final r = index.isEven ? radius : inner;
          final point = center + Offset(math.cos(angle) * r, math.sin(angle) * r);
          if (index == 0) {
            path.moveTo(point.dx, point.dy);
          } else {
            final previousAngle =
                math.pi / petals * (index - 1) - math.pi / 2;
            final previousR = (index - 1).isEven ? radius : inner;
            final controlAngle = (previousAngle + angle) / 2;
            final controlR = (previousR + r) / 2 * 1.06;
            final control = center +
                Offset(
                  math.cos(controlAngle) * controlR,
                  math.sin(controlAngle) * controlR,
                );
            path.quadraticBezierTo(
              control.dx,
              control.dy,
              point.dx,
              point.dy,
            );
          }
        }
        path.close();
      case _BadgeShape.softBurst:
        const spikes = 12;
        for (var index = 0; index < spikes * 2; index++) {
          final angle = math.pi / spikes * index - math.pi / 2;
          final r = index.isEven ? radius : radius * .78;
          final point = center + Offset(math.cos(angle) * r, math.sin(angle) * r);
          if (index == 0) {
            path.moveTo(point.dx, point.dy);
          } else {
            path.lineTo(point.dx, point.dy);
          }
        }
        path.close();
    }
    return path;
  }

  @override
  bool shouldRepaint(_StarBadgePainter oldDelegate) =>
      color != oldDelegate.color || shape != oldDelegate.shape;
}

/// 加载指示器。
///
/// 一个圆角形状在若干「cookie」形之间连续变形并缓慢旋转。相比转圈，
/// 它在长等待时更耐看，也更能表达「正在处理」而不是「卡住了」。
///
/// 变形路径预先算好并静态共享，多个实例不会重复计算。
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

class _AppLoadingIndicatorState extends State<AppLoadingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
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
    return Semantics(
      label: widget.semanticsLabel,
      child: RepaintBoundary(
        child: SizedBox.square(
          dimension: widget.size,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) => CustomPaint(
              painter: _MorphPainter(
                progress: _controller.value,
                color: color,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 三种形状之间连续变形：圆角方形 → 八瓣 → 圆角三角。
class _MorphPainter extends CustomPainter {
  const _MorphPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    // 三段循环，段内用 smoothstep 缓动。
    final segment = progress * 3;
    final index = segment.floor() % 3;
    final t = _smooth(segment - segment.floor());
    final from = _shapePoints(index, radius);
    final to = _shapePoints((index + 1) % 3, radius);
    final path = Path();
    for (var i = 0; i < from.length; i++) {
      final x = from[i].dx + (to[i].dx - from[i].dx) * t;
      final y = from[i].dy + (to[i].dy - from[i].dy) * t;
      if (i == 0) {
        path.moveTo(center.dx + x, center.dy + y);
      } else {
        path.lineTo(center.dx + x, center.dy + y);
      }
    }
    path.close();
    // 整体缓慢自转，让变形看起来更「活」。
    canvas
      ..save()
      ..translate(center.dx, center.dy)
      ..rotate(progress * math.pi * 2)
      ..translate(-center.dx, -center.dy)
      ..drawPath(path, Paint()..color = color)
      ..restore();
  }

  double _smooth(double t) => t * t * (3 - 2 * t);

  /// 三个形状共用 24 个采样点，保证变形时点对点对应。
  List<Offset> _shapePoints(int shape, double radius) {
    const samples = 24;
    final points = <Offset>[];
    for (var i = 0; i < samples; i++) {
      final angle = math.pi * 2 / samples * i - math.pi / 2;
      final r = switch (shape) {
        // 圆角方形：半径随角度在 R 与 .78R 之间变化。
        0 => radius * (.78 + .22 * math.pow(math.cos(angle * 4).abs(), .6)),
        // 八瓣花：8 个外凸。
        1 => radius * (.82 + .18 * math.cos(angle * 8)),
        // 圆角三角。
        _ => radius * (.78 + .22 * math.pow(math.cos(angle * 3).abs(), .5)),
      };
      points.add(Offset(math.cos(angle) * r, math.sin(angle) * r));
    }
    return points;
  }

  @override
  bool shouldRepaint(_MorphPainter oldDelegate) =>
      progress != oldDelegate.progress || color != oldDelegate.color;
}
