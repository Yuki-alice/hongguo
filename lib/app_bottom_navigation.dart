import 'package:flutter/material.dart';

/// MD3 底部导航栏。
///
/// 按 Material Design 3 navigation bar 规范实现：
/// - 每项目标含 64×32 的 pill 指示器，选中时填充 `secondaryContainer`；
/// - 图标与标签使用 `onSecondaryContainer` / `onSurfaceVariant` 配对；
/// - 整栏高度 80，命中区域不小于 48×48，并带顶部 `outlineVariant` 分隔线。
///
/// 没有直接用 `NavigationBar`：它的目标 slot 会重新包装 icon，
/// 调用方传入的 key 无法落到可测量、可点击的渲染节点上。
class AppBottomNavigation extends StatelessWidget {
  const AppBottomNavigation({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    this.destinationKeys = const [],
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<NavigationDestination> destinations;

  /// 与 [destinations] 等长的可选 key 列表，用于测量每项命中区域。
  /// 省略时自动使用 `bottom-nav-<index>`。
  final List<Key> destinationKeys;

  Key _keyFor(int index) => index < destinationKeys.length
      ? destinationKeys[index]
      : ValueKey('bottom-nav-$index');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Material(
      color: colors.surfaceContainer,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: colors.outlineVariant, width: 1),
          ),
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 80,
            child: Row(
              children: [
                for (final (index, destination) in destinations.indexed)
                  Expanded(
                    child: _Destination(
                      key: _keyFor(index),
                      destination: destination,
                      selected: index == selectedIndex,
                      onPressed: () => onDestinationSelected(index),
                      textScaler: MediaQuery.textScalerOf(context),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Destination extends StatelessWidget {
  const _Destination({
    super.key,
    required this.destination,
    required this.selected,
    required this.onPressed,
    required this.textScaler,
  });

  final NavigationDestination destination;
  final bool selected;
  final VoidCallback onPressed;
  final TextScaler textScaler;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final icon = selected ? destination.selectedIcon ?? destination.icon : destination.icon;
    final foreground = selected
        ? colors.onSecondaryContainer
        : colors.onSurfaceVariant;
    final labelStyle = (theme.textTheme.labelMedium ?? const TextStyle())
        .copyWith(
          color: selected ? colors.onSurface : colors.onSurfaceVariant,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          height: 1.33,
          letterSpacing: .4,
        );
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      enabled: destination.enabled,
      label: destination.label,
      excludeSemantics: true,
      child: Tooltip(
        message: destination.tooltip ?? destination.label,
        child: InkWell(
          onTap: destination.enabled ? onPressed : null,
          splashFactory: InkSparkle.splashFactory,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedContainer(
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  width: 64,
                  height: 32,
                  decoration: BoxDecoration(
                    color: selected ? colors.secondaryContainer : Colors.transparent,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: IconTheme(
                    data: IconThemeData(size: 24, color: foreground),
                    child: Center(child: icon),
                  ),
                ),
                const SizedBox(height: 4),
                Flexible(
                  child: Text(
                    destination.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textScaler: textScaler,
                    style: labelStyle,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
