import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// 桌面窗口 chrome 的平台判定。
///
/// 只用 [defaultTargetPlatform]：它可以在测试里覆盖，`dart:io` 的
/// `Platform` 不能。真实运行时两者一致。
abstract final class WindowChrome {
  static bool get _macOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  static bool get _windows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  /// 是否启用自绘标题栏。
  ///
  /// macOS 隐藏系统标题栏、内容延伸到红绿灯下方；Windows 隐藏标题栏
  /// 并自绘最小化 / 关闭。Linux 保持系统标题栏——`window_manager` 在
  /// Wayland 下的 `setTitleBarStyle` 行为不稳定。
  static bool get enabled => _macOS || _windows;

  /// 自绘标题栏高度（仅 Windows）。
  static double get titleBarHeight => _windows ? 36 : 0;

  /// 是否需要在 Flutter 侧绘制窗口按钮。
  ///
  /// macOS 用系统交通灯（只把标题栏隐藏），Windows 需要自己画。
  static bool get drawsWindowButtons => _windows;

  /// 仅测试用：非 null 时不真正调用窗口管理器。
  @visibleForTesting
  static bool? debugOverride;

  /// 测试环境下不真正调用窗口管理器。
  static bool get _interactive => debugOverride == null;
}

/// 桌面窗口的安全边距。
///
/// **为什么需要它**：`window_manager` 的 `TitleBarStyle.hidden` 会给窗口
/// 加 `.fullSizeContentView`，系统于是认为内容已延伸到标题栏下方，
/// `MediaQuery.padding.top` 恒为 0 —— 全应用的 `SafeArea` 在 macOS 上
/// 都是空操作，红绿灯会直接压在标题上。参照应用用的是同一套窗口方案，
/// 因此它在 `SysAppBar` 里硬编码 22px 让开。
///
/// 改动这里的数值要同时检查所有使用点：`AppRail` 的搜索按钮、
/// `SavedLibrary` 的标题行、`MyScreen` 的首段内边距，以及发现页折叠头的
/// 定位计算。
abstract final class WindowSafeArea {
  static bool get _macOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  /// 交通灯占用的顶部高度。
  static double get top => _macOS ? 22 : 0;

  /// 交通灯占用的左侧宽度。
  static double get leading => _macOS ? 78 : 0;
}

/// 桌面平台的 AppBar。
///
/// 机制与参照应用的 `SysAppBar` 一致：**bar 高度加 [WindowSafeArea.top]，
/// 内部 title / leading / actions 各自加同样的顶距**。两者抵消，于是
/// 控件被推到交通灯下方，而 bar 背景仍铺到窗口最顶部。
///
/// 页面主体不要再加安全区：内容区已经由 bar 让开，重复偏移会让首屏
/// 少一排海报。
class DesktopAppBar extends StatelessWidget implements PreferredSizeWidget {
  const DesktopAppBar({
    super.key,
    this.title,
    this.actions,
    this.leading,
    this.bottom,
    this.toolbarHeight,
    this.titleSpacing,
    this.centerTitle = false,
    this.backgroundColor,
    this.automaticallyImplyLeading = true,
    this.scrolledUnderElevation = 0,
  });

  final Widget? title;
  final List<Widget>? actions;
  final Widget? leading;
  final PreferredSizeWidget? bottom;
  final double? toolbarHeight;
  final double? titleSpacing;
  final bool centerTitle;
  final Color? backgroundColor;
  final bool automaticallyImplyLeading;
  final double scrolledUnderElevation;

  double get _toolbar => toolbarHeight ?? kToolbarHeight;

  @override
  Size get preferredSize {
    final base = bottom?.preferredSize.height ?? 0;
    return Size.fromHeight(_toolbar + WindowSafeArea.top + base);
  }

  @override
  Widget build(BuildContext context) {
    final inset = WindowSafeArea.top;
    Widget push(Widget child) => inset == 0
        ? child
        : Padding(
            padding: EdgeInsets.only(top: inset),
            child: child,
          );
    final impliesDismissal =
        Navigator.of(context).canPop() ||
        ModalRoute.of(context)?.impliesAppBarDismissal == true;
    final effectiveLeading =
        leading ??
        (automaticallyImplyLeading && impliesDismissal
            ? const BackButton()
            : null);
    return AppBar(
      toolbarHeight: _toolbar + inset,
      titleSpacing: titleSpacing,
      centerTitle: centerTitle,
      backgroundColor: backgroundColor,
      scrolledUnderElevation: scrolledUnderElevation,
      automaticallyImplyLeading: false,
      leading: effectiveLeading == null ? null : push(effectiveLeading),
      title: title == null ? null : push(title!),
      actions: actions?.map(push).toList(),
      bottom: bottom,
    );
  }
}

/// 可拖拽区域。
///
/// 桌面窗口隐藏标题栏后需要自己提供拖动区。用 `onPanStart` 一次性把
/// 拖拽交给操作系统，而不是在 Flutter 里跟踪偏移——后者会与窗口管理器
/// 打架（窗口先跳一下再跟上）。
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
      child: MouseRegion(cursor: SystemMouseCursors.grab, child: child),
    );
  }
}

/// 自绘窗口按钮（Windows）。
///
/// macOS 交给系统交通灯，移动端不渲染。
class WindowButtons extends StatelessWidget {
  const WindowButtons({super.key});

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
          onPressed: () {
            if (WindowChrome._interactive) windowManager.minimize();
          },
        ),
        _WindowButton(
          icon: Icons.close_rounded,
          tooltip: '关闭',
          hoverColor: colors.error,
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
    required this.onPressed,
    this.hoverColor,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final Color? hoverColor;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    waitDuration: const Duration(milliseconds: 600),
    child: InkWell(
      onTap: onPressed,
      hoverColor: hoverColor,
      child: SizedBox(
        width: 46,
        height: WindowChrome.titleBarHeight,
        child: Icon(
          icon,
          size: 16,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ),
  );
}
