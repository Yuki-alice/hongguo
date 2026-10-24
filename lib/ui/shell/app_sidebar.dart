import 'package:flutter/material.dart';

import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/theme/md3_tokens.dart';

/// 外壳的一个导航目的地。
@immutable
class ShellDestination {
  const ShellDestination({
    required this.id,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.badge = 0,
  });

  /// 稳定标识，用于 key（`rail-nav-<id>`、`bottom-nav-<id>`）。
  final String id;
  final IconData icon;
  final IconData selectedIcon;
  final String label;

  /// 角标数量，0 表示不显示。
  final int badge;
}

/// 外壳目的地清单。
///
/// 四个目的地，与参照应用的四 tab 模型一致：发现 / 榜单 / 追剧 / 我的。
/// 历史与下载不再是目的地——它们从「我的」进入，因此不再占用导航位。
List<ShellDestination> shellDestinations(
  BuildContext context, {
  required bool canDownload,
  int downloadCount = 0,
  int updateCount = 0,
}) {
  final l10n = AppLocalizations.of(context);
  return [
    ShellDestination(
      id: 'discover',
      icon: Icons.explore_outlined,
      selectedIcon: Icons.explore_rounded,
      label: l10n.discoverTitle,
    ),
    ShellDestination(
      id: 'rankings',
      icon: Icons.leaderboard_outlined,
      selectedIcon: Icons.leaderboard_rounded,
      label: l10n.rankingsTitle,
    ),
    ShellDestination(
      id: 'follows',
      icon: Icons.bookmark_border_rounded,
      selectedIcon: Icons.bookmark_rounded,
      label: l10n.follows,
      badge: updateCount,
    ),
    ShellDestination(
      id: 'my',
      icon: Icons.person_outline_rounded,
      selectedIcon: Icons.person_rounded,
      label: l10n.mySpaceTitle,
      badge: downloadCount,
    ),
  ];
}

/// 侧边导航栏（横屏）。
///
/// 照参照应用 2.4.2 的 `ScaffoldMenu`：
/// - 宽 72，**固定不展开**；底色是素净的 [Md3ColorRoles.shelf]
///   （`surfaceContainer`），内容书架才是染色面；
/// - `leading` 放一颗搜索 FAB；
/// - 目的地 `groupAlignment: 1` 沉底，`labelType: selected` 只给选中项
///   显示文字，rail 因此窄而安静。
///
/// 设置不再是 rail 的一项：它被收进「我的」页，作为那里的主行动磁贴。
/// 导航位上放一个「设置」图标，会让用户以为它和另外四个目的地同级。
class AppRail extends StatelessWidget {
  const AppRail({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
    required this.onSearch,
  });

  final List<ShellDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    return Container(
      width: Md3Spacing.railWidth,
      color: colors.shelf,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(top: Md3Spacing.md),
            child: FloatingActionButton(
              key: const ValueKey('rail-search'),
              elevation: 0,
              heroTag: null,
              tooltip: l10n.search,
              onPressed: onSearch,
              child: const Icon(Icons.search_rounded),
            ),
          ),
          // 目的地沉底：Expanded 吃掉剩余空间，`groupAlignment: 1` 把
          // 导航组推到顶部 FAB 的对侧——与参照应用一致。
          Expanded(
            child: NavigationRail(
              backgroundColor: Colors.transparent,
              selectedIndex: selectedIndex,
              onDestinationSelected: onSelected,
              groupAlignment: 1,
              // 只给选中项显示标签：72 宽装不下四行文字，也避免 rail
              // 比内容还热闹。
              labelType: NavigationRailLabelType.selected,
              destinations: [
                for (final destination in destinations)
                  NavigationRailDestination(
                    icon: Icon(
                      destination.icon,
                      key: ValueKey('rail-nav-${destination.id}'),
                    ),
                    selectedIcon: Icon(
                      destination.selectedIcon,
                      key: ValueKey('rail-nav-selected-${destination.id}'),
                    ),
                    label: Text(destination.label),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 底部导航（竖屏）。
///
/// 直接使用官方 [NavigationBar]：样式由主题的 `navigationBarTheme` 统一
/// 提供（80 高、stadium 指示器、选中 w700），不再自绘。角标用 [Badge]
/// 挂在图标上，key 约定为 `bottom-nav-<id>`。
class AppBottomBar extends StatelessWidget {
  const AppBottomBar({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<ShellDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) => NavigationBar(
    selectedIndex: selectedIndex,
    onDestinationSelected: onSelected,
    destinations: [
      for (final destination in destinations)
        NavigationDestination(
          icon: _icon(destination, selected: false),
          selectedIcon: _icon(destination, selected: true),
          label: destination.label,
        ),
    ],
  );

  Widget _icon(ShellDestination destination, {required bool selected}) {
    final icon = Icon(
      selected ? destination.selectedIcon : destination.icon,
      key: ValueKey(
        'bottom-nav-${destination.id}${selected ? '-selected' : ''}',
      ),
    );
    if (destination.badge <= 0) return icon;
    return Badge.count(count: destination.badge, child: icon);
  }
}

/// 内容「书架」。
///
/// 内容区是浮在导航之上的圆角面：`surface` 混 15% `primaryContainer`，
/// 左侧两角 16px 圆角，内容再 `ClipRRect` 裁到同一形状。横屏时能看到
/// 左上 / 左下各一条窄边，竖屏（底部导航）不加圆角。
///
/// 只染 15% 是刻意的：内容区承载海报网格，染满会让封面颜色失真；
/// 压到 15% 既保留「彩色内容 / 素净导航」的层次，又不至于隔一层滤色片。
class ContentShelf extends StatelessWidget {
  const ContentShelf({super.key, required this.child, this.rounded = true});

  final Widget child;
  final bool rounded;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // 书架必须提供 `Material`：分支里的页面不一定自带 `Scaffold`（「我的」页
    // 就是一层滚动视图）。少了它，`Text` 会退回 Flutter 的缺省错误样式
    // （黄色双下划线），看起来像满屏报错。
    final content = Material(type: MaterialType.transparency, child: child);
    if (!rounded) {
      // 竖屏（底部导航）不加圆角，但仍要铺书架底色。
      return ColoredBox(color: colors.contentShelf, child: content);
    }
    const radius = BorderRadius.only(
      topLeft: Radius.circular(Md3Shape.large),
      bottomLeft: Radius.circular(Md3Shape.large),
    );
    return Container(
      decoration: BoxDecoration(
        color: colors.contentShelf,
        borderRadius: radius,
      ),
      child: ClipRRect(borderRadius: radius, child: content),
    );
  }
}
