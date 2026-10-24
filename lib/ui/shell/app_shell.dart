import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/ui/shell/app_sidebar.dart';
import 'package:hoshi/ui/shell/window_chrome.dart';
import 'package:hoshi/ui/theme/md3_tokens.dart';

/// 应用外壳。
///
/// 导航形态按**窗口方向**决定，与设备类型无关：
///
/// | 窗口 | 形态 |
/// | --- | --- |
/// | 竖屏（高 > 宽） | 底部导航 |
/// | 横屏（宽 ≥ 高） | 左侧 72px rail，目的地沉底，只有选中项显示文字 |
///
/// 用方向而不是宽度阈值：Flutter 应用跑在可调整大小的窗口里，
/// 「宽还是高」才是决定导航放下边还是左边的真实依据。桌面窗口通常
/// 横屏，因此总是 rail；手机竖屏用底部导航；手机横屏也能用 rail。
/// 与 Kazumi 的 `OrientationBuilder` 一致。
class AppShell extends StatelessWidget {
  const AppShell({
    super.key,
    required this.shell,
    required this.store,
    required this.onOpenSearch,
  });

  final StatefulNavigationShell shell;
  final LocalStore store;

  /// 打开搜索。rail 顶部的 FAB 与 `⌘K` 都走这里。
  final VoidCallback onOpenSearch;

  @override
  Widget build(BuildContext context) {
    final destinations = shellDestinations(
      context,
      canDownload: store.canDownload,
    );
    final index = shell.currentIndex.clamp(0, destinations.length - 1);

    return LayoutBuilder(
      builder: (context, constraints) {
        final portrait = constraints.maxHeight > constraints.maxWidth;
        if (portrait) {
          return _chrome(
            context,
            child: ContentShelf(rounded: false, child: shell),
            bottomBar: AppBottomBar(
              destinations: destinations,
              selectedIndex: index,
              onSelected: (next) => _goBranch(shell, next),
            ),
          );
        }

        // 横屏：rail + 圆角内容书架。
        //
        // 层次是「染色内容 + 素净导航」（参照应用 2.4.2 的 ScaffoldMenu）：
        // 左 rail 用 `surfaceContainer`，右侧书架混 15% `primaryContainer`
        // 并裁左侧两角，于是左上 / 左下各露出一条窄边。
        //
        // 15% 是折中值：参照应用把内容整片染满，这里压到 15%，避免整片
        // 染色让封面颜色失真。
        return _chrome(
          context,
          child: Row(
            children: [
              AppRail(
                destinations: destinations,
                selectedIndex: index,
                onSelected: (next) => _goBranch(shell, next),
                onSearch: onOpenSearch,
              ),
              Expanded(child: ContentShelf(child: shell)),
            ],
          ),
        );
      },
    );
  }

  /// 切换分支。
  ///
  /// `initialLocation: false` 让每个分支记住自己上次的位置——这是
  /// `StatefulShellRoute` 相对扁平路由的核心收益，切回来不丢滚动与筛选。
  void _goBranch(StatefulNavigationShell shell, int index) {
    shell.goBranch(index, initialLocation: shell.currentIndex == index);
  }

  /// 桌面窗口 chrome：标题栏拖拽区 + 自绘按钮。
  ///
  /// 移动端直接返回 [child]，不引入任何额外层级。
  Widget _chrome(
    BuildContext context, {
    required Widget child,
    Widget? bottomBar,
  }) {
    final body = bottomBar == null
        ? child
        : Column(
            children: [
              Expanded(child: child),
              bottomBar,
            ],
          );
    if (!WindowChrome.enabled) return body;
    if (WindowChrome.drawsWindowButtons) {
      return Column(
        children: [
          const _TitleBar(),
          Expanded(child: body),
        ],
      );
    }
    // macOS：交通灯由系统绘制并浮在内容上，只需要让出顶部高度。
    return body;
  }
}

/// Windows 自绘标题栏。高度 36，整条可拖拽，右侧是自绘按钮。
class _TitleBar extends StatelessWidget {
  const _TitleBar();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.shelf,
      child: SizedBox(
        height: WindowChrome.titleBarHeight,
        child: const Row(
          children: [
            Expanded(child: DragArea(child: SizedBox.expand())),
            WindowButtons(),
          ],
        ),
      ),
    );
  }
}
