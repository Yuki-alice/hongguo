import 'package:flutter/material.dart';

import 'package:hoshi/ui/theme/md3_tokens.dart';

/// 页面骨架。
///
/// 全应用只有这一处决定「内容多宽、两侧留白多少」，避免每个页面自己写
/// `ConstrainedBox(maxWidth: 720)` 这类字面量——改造前仓库里有 640 / 680 /
/// 720 / 960 / 1000 / 1200 六种互不相同又都没有依据的上限。
///
/// 三种宽度策略：
/// - [AppPageWidth.text]：表单、设置、诊断等长文本页面，上限 1040；
/// - [AppPageWidth.media]：海报网格、卡片列表，上限 1440；
/// - [AppPageWidth.full]：播放器、沉浸页，铺满（由调用方自行控制）。
///
/// 留白随窗口等级增长（见 [Md3Spacing.pageInset]），因此 2560 宽的窗口
/// 不会出现「一行文字横跨整个屏幕」。
enum AppPageWidth {
  /// 长文本与表单。
  text(Md3Spacing.contentMaxWidth),

  /// 媒体网格。
  media(Md3Spacing.wideMaxWidth),

  /// 铺满可用空间。
  full(double.infinity);

  const AppPageWidth(this.maxWidth);
  final double maxWidth;
}

/// 把内容约束到页面宽度策略内，并加水平留白。
///
/// 作为 `Scaffold.body` 的直接子节点使用：
///
/// ```dart
/// Scaffold(
///   appBar: ...,
///   body: AppPage(width: AppPageWidth.text, child: ListView(...)),
/// )
/// ```
class AppPage extends StatelessWidget {
  const AppPage({
    super.key,
    required this.child,
    this.width = AppPageWidth.text,
    this.vertical = 0,
    this.padded = true,
    this.alignment = Alignment.topCenter,
  });

  final Widget child;
  final AppPageWidth width;

  /// 额外的上下内边距（顶部通常已由 AppBar 提供）。
  final double vertical;

  /// 是否加水平留白。内部已经自带留白的页面（例如铺满的网格）传 false。
  final bool padded;

  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final available = constraints.maxWidth;
      final inset = padded ? Md3Spacing.pageInset(available) : 0.0;
      final maxWidth = width.maxWidth;
      return Align(
        alignment: alignment,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: maxWidth.isFinite ? maxWidth : double.infinity,
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: inset,
              vertical: vertical,
            ),
            child: child,
          ),
        ),
      );
    },
  );
}

/// 只返回内容宽度（不含留白），供需要在页面内部对齐的组件使用。
///
/// 例如吸底播放条要和内容区同宽，而不是和窗口同宽。
class AppPageScope extends InheritedWidget {
  const AppPageScope({
    super.key,
    required this.contentWidth,
    required this.inset,
    required super.child,
  });

  /// 内容可用宽度（已扣除留白，且不超过策略上限）。
  final double contentWidth;

  /// 两侧留白。
  final double inset;

  static AppPageScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppPageScope>();

  static double contentWidthOf(BuildContext context, double fallback) =>
      maybeOf(context)?.contentWidth ?? fallback;

  @override
  bool updateShouldNotify(AppPageScope oldWidget) =>
      contentWidth != oldWidget.contentWidth || inset != oldWidget.inset;
}

/// 在 [AppPage] 内部建立 [AppPageScope]，让子组件知道内容宽度。
class AppPageMetrics extends StatelessWidget {
  const AppPageMetrics({
    super.key,
    required this.width,
    required this.inset,
    required this.child,
  });

  final double width;
  final double inset;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      AppPageScope(contentWidth: width, inset: inset, child: child);
}
