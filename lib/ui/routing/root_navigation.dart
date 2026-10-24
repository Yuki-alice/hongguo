import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'package:hoshi/ui/routing/app_router.dart';

/// 从**根 Navigator** 打开全屏页面。
///
/// 外壳的每个 tab 有自己的 Navigator。在分支里直接 `context.push` 会把
/// 页面压进那个分支的匹配栈，于是详情页、播放页这些本该全屏的页面会
/// 带着左侧 rail 出现。
///
/// go_router 的 `push` 以当前匹配栈为 base，因此换一个**根 Navigator 的
/// context** 发起就够了：base 变成根栈，页面被压到外壳之上而非之内，
/// 返回时 `pop` 也回得到原分支。
extension RootNavigation on BuildContext {
  Future<T?> pushFullscreen<T extends Object?>(
    String location, {
    Object? extra,
  }) {
    final root = appNavigatorKey.currentContext;
    if (root == null) return push<T>(location, extra: extra);
    return GoRouter.of(root).push<T>(location, extra: extra);
  }
}
