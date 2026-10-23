import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// 桌面窗口 chrome 的判定。
///
/// 只在真正的桌面平台生效；Android / iOS / 电视模式全部为 false，
/// 因此移动端与 TV 的布局不受任何影响。
abstract final class WindowChrome {
  /// 是否启用自绘标题栏。
  ///
  /// macOS 隐藏系统标题栏、内容延伸到红绿灯下方；Windows 隐藏标题栏
  /// 并自绘最小化 / 关闭。Linux 暂不处理（保持系统标题栏），因为
  /// `window_manager` 在 Wayland 下的 `setTitleBarStyle` 行为不稳定。
  static bool get enabled =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows);

  /// 红绿灯 / 系统按钮占用的顶部高度。
  ///
  /// macOS 的交通灯悬浮在内容左上角，需要给交互控件留出 22px 的竖向
  /// 空间；Windows 的按钮由我们自己绘制在标题栏内，不额外占位。
  static double get topInset {
    if (!enabled) return 0;
    if (Platform.isMacOS) return 22;
    return 0;
  }

  /// 自绘标题栏高度（仅 Windows）。
  static double get titleBarHeight {
    if (!enabled || !Platform.isWindows) return 0;
    return 36;
  }

  /// 系统按钮（红绿灯）占用的左侧宽度。
  ///
  /// 侧栏顶部的品牌区需要避开它，否则文字会被压到按钮下面。
  static double get leadingInset {
    if (!enabled) return 0;
    if (Platform.isMacOS) return 78;
    return 0;
  }

  /// 是否需要在 Flutter 侧绘制窗口按钮。
  ///
  /// macOS 用系统交通灯（只把标题栏隐藏），Windows 需要自己画。
  static bool get drawsWindowButtons => enabled && Platform.isWindows;

  /// 仅测试用：覆盖平台判定。为 null 时按真实平台判断。
  @visibleForTesting
  static bool? debugOverride;

  /// 测试环境下不真正调用窗口管理器。
  static bool get _interactive => debugOverride == null;
}

/// 把控件推到系统按钮下方。
///
/// 刻意只包裹**交互控件**而不是整条标题栏：这样背景色、模糊层可以照常
/// 画到红绿灯下面，只有可点击的部分被让开。
class NativeInset extends StatelessWidget {
  const NativeInset({
    super.key,
    required this.child,
    this.horizontal = false,
    this.enabled = true,
  });

  final Widget child;

  /// 是否同时让开左侧（红绿灯）宽度。
  final bool horizontal;

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    final top = WindowChrome.topInset;
    final left = horizontal ? WindowChrome.leadingInset : 0.0;
    if (top == 0 && left == 0) return child;
    return Padding(
      padding: EdgeInsets.only(top: top, left: left),
      child: child,
    );
  }
}

/// 可拖拽区域。
///
/// 桌面窗口隐藏标题栏后，必须自己提供一个能拖动窗口的区域。用
/// `onPanStart` 一次性把拖拽交给操作系统，而不是在 Flutter 里跟踪偏移，
/// 否则会与窗口管理器打架（拖动时窗口跳一下再跟上）。
class DragArea extends StatelessWidget {
  const DragArea({
    super.key,
    required this.child,
    this.enabled = true,
    this.behavior = HitTestBehavior.translucent,
  });

  final Widget child;
  final bool enabled;
  final HitTestBehavior behavior;

  @override
  Widget build(BuildContext context) {
    if (!enabled || !WindowChrome.enabled) return child;
    return GestureDetector(
      behavior: behavior,
      onPanStart: (_) {
        if (!WindowChrome._interactive) return;
        windowManager.startDragging();
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: child,
      ),
    );
  }
}

/// 自绘窗口按钮（Windows）。
///
/// 只在 `WindowChrome.drawsWindowButtons` 为真时渲染；macOS 交给系统
/// 交通灯，移动端不渲染。
class WindowButtons extends StatelessWidget {
  const WindowButtons({super.key, this.height = 36});

  final double height;

  @override
  Widget build(BuildContext context) {
    if (!WindowChrome.drawsWindowButtons) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _WindowButton(
          icon: Icons.remove_rounded,
          tooltip: '最小化',
          height: height,
          onPressed: () {
            if (WindowChrome._interactive) windowManager.minimize();
          },
        ),
        _WindowButton(
          icon: Icons.close_rounded,
          tooltip: '关闭',
          height: height,
          hoverColor: colors.error,
          hoverForeground: colors.onError,
          onPressed: () {
            if (WindowChrome._interactive) windowManager.close();
          },
        ),
      ],
    );
  }
}

class _WindowButton extends StatelessWidget {
  const _WindowButton({
    required this.icon,
    required this.tooltip,
    required this.height,
    required this.onPressed,
    this.hoverColor,
    this.hoverForeground,
  });

  final IconData icon;
  final String tooltip;
  final double height;
  final VoidCallback onPressed;
  final Color? hoverColor;
  final Color? hoverForeground;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    waitDuration: const Duration(milliseconds: 600),
    child: InkWell(
      onTap: onPressed,
      hoverColor: hoverColor,
      child: SizedBox(
        width: 46,
        height: height,
        child: Icon(
          icon,
          size: 16,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ),
  );
}
