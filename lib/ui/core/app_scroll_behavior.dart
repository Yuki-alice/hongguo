import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:hoshi/ui/theme/md3_tokens.dart';

/// 全应用滚动行为。
///
/// 桌面端默认的 Flutter 滚动条只在滚动时闪一下，鼠标用户很难判断「还能
/// 不能继续滚」。这里给每个可滚动区域套一个常显的 `Scrollbar`，并把
/// 滚动条的样式交给主题（见 `AppTheme.scrollbarTheme`）。
///
/// 移动端不做改动：手机上常显滚动条是噪声。
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  static bool get _desktop => switch (defaultTargetPlatform) {
    TargetPlatform.macOS ||
    TargetPlatform.windows ||
    TargetPlatform.linux => true,
    _ => false,
  };

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    if (!_desktop) return super.buildScrollbar(context, child, details);
    return Scrollbar(
      controller: details.controller,
      thumbVisibility: false,
      interactive: true,
      child: child,
    );
  }

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) => _desktop
      ? const ClampingScrollPhysics()
      : super.getScrollPhysics(context);

  @override
  Set<PointerDeviceKind> get dragDevices => {
    ...super.dragDevices,
    // 桌面端允许鼠标拖拽滚动：触控板用户习惯「按住拖」。
    PointerDeviceKind.mouse,
  };
}

/// 让滚动条在桌面常显的包装。
///
/// `ScrollBehavior` 只负责样式，是否常显由 `Scrollbar` 的
/// `thumbVisibility` 决定。侧栏、设置面板这类「一眼能看出有更多内容」
/// 的区域用这个包装。
class AlwaysVisibleScrollbar extends StatelessWidget {
  const AlwaysVisibleScrollbar({
    super.key,
    required this.controller,
    required this.child,
  });

  final ScrollController? controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final desktop = switch (defaultTargetPlatform) {
      TargetPlatform.macOS ||
      TargetPlatform.windows ||
      TargetPlatform.linux => true,
      _ => false,
    };
    if (!desktop) return child;
    return Scrollbar(
      controller: controller,
      thumbVisibility: true,
      interactive: true,
      thickness: 6,
      radius: const Radius.circular(Md3Shape.small),
      child: child,
    );
  }
}
