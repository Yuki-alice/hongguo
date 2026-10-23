import 'package:flutter/material.dart';

import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/core/app_bottom_navigation.dart';
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

  /// 稳定标识，用于 key（`rail-nav-<id>`、`bottom-nav-<index>`）。
  final String id;
  final IconData icon;
  final IconData selectedIcon;
  final String label;

  /// 角标数量，0 表示不显示。
  final int badge;
}

/// 外壳目的地清单。
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
      id: 'follows',
      icon: Icons.bookmark_border_rounded,
      selectedIcon: Icons.bookmark_rounded,
      label: l10n.follows,
      badge: updateCount,
    ),
    ShellDestination(
      id: 'history',
      icon: Icons.history_outlined,
      selectedIcon: Icons.history_rounded,
      label: l10n.recentlyWatched,
    ),
    if (canDownload)
      ShellDestination(
        id: 'downloads',
        icon: Icons.download_outlined,
        selectedIcon: Icons.download_rounded,
        label: l10n.download,
        badge: downloadCount,
      ),
  ];
}

/// 侧边导航栏（横屏）。
///
/// 直接对应 `NavigationRail` 的默认宽度，**固定不展开**：
/// - `groupAlignment: 1` 把目的地把沉到底部，顶部留白；
/// - `labelType: selected` 只有选中项在图标下显示文字；
/// - `leading` 放一颗搜索 FAB，其余位置不放任何东西。
///
/// 结构参考 Kazumi `lib/pages/menu/menu.dart` 的 `_sideMenu`。
class AppRail extends StatelessWidget {
  const AppRail({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
    required this.onSearch,
    required this.onSettings,
    this.settingsSelected = false,
  });

  final List<ShellDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final VoidCallback onSearch;
  final VoidCallback onSettings;
  final bool settingsSelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    // 设置是列表里的最后一项，位置固定在 destinations.length。
    final settingsIndex = destinations.length;
    return NavigationRail(
      backgroundColor: colors.surfaceContainer,
      selectedIndex: settingsSelected ? settingsIndex : selectedIndex,
      // NavigationRail 把所有目的（含设置）当成一个序列，因此索引可能
      // 等于 destinations.length；那个位置对应设置入口。
      onDestinationSelected: (index) => index == settingsIndex
          ? onSettings()
          : onSelected(index),
      // 目的地沉底：顶部那颗搜索按钮与列表之间留出大片呼吸区。
      groupAlignment: 1,
      leading: Padding(
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
      // 只有选中项显示文字，因此整条栏始终是一个图标的宽度。
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
        NavigationRailDestination(
          icon: const Icon(
            Icons.settings_outlined,
            key: ValueKey('rail-nav-settings'),
          ),
          selectedIcon: const Icon(
            Icons.settings_rounded,
            key: ValueKey('rail-nav-selected-settings'),
          ),
          label: Text(l10n.settingsTitle),
        ),
      ],
    );
  }
}

/// 底部导航（竖屏）。
///
/// 复用既有的 [AppBottomNavigation]：它的 key 约定（`bottom-nav-<index>`）
/// 被 5 个测试文件依赖。
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
  Widget build(BuildContext context) => AppBottomNavigation(
    selectedIndex: selectedIndex,
    onDestinationSelected: onSelected,
    destinations: [
      for (final destination in destinations)
        NavigationDestination(
          icon: Icon(destination.icon),
          selectedIcon: Icon(destination.selectedIcon),
          label: destination.label,
        ),
    ],
  );
}

/// 内容「书架」。
///
/// 内容区是浮在导航之上的圆角面：底色 `primaryContainer`，左侧两角
/// 16px 圆角，内容再 `ClipRRect` 裁到同一形状。横屏时能看到左上 / 左下
/// 各一条窄边，竖屏（底部导航）不加圆角。
class ContentShelf extends StatelessWidget {
  const ContentShelf({super.key, required this.child, this.rounded = true});

  final Widget child;
  final bool rounded;

  @override
  Widget build(BuildContext context) {
    if (!rounded) return child;
    const radius = BorderRadius.only(
      topLeft: Radius.circular(Md3Shape.large),
      bottomLeft: Radius.circular(Md3Shape.large),
    );
    final colors = Theme.of(context).colorScheme;
    // 用 `primaryContainer` 与 `surface` 混合而不是纯 `primaryContainer`：
    // 品牌色是橙红时，纯容器色在浅色模式下是一块明显的粉，压过内容；
    // 混到 45% 后既保留「彩色书架」的辨识度，又不抢海报。
    final shelf = Color.alphaBlend(
      colors.primaryContainer.withValues(alpha: .45),
      colors.surface,
    );
    return Container(
      decoration: BoxDecoration(color: shelf, borderRadius: radius),
      child: ClipRRect(borderRadius: radius, child: child),
    );
  }
}
