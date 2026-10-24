import 'package:flutter/material.dart';

import 'package:hoshi/ui/theme/md3_tokens.dart';

/// 表面卡片：本应用的「标准面板」。
///
/// 参照应用的 `TonalCard`——`surfaceContainerLow` 填充 + 24 圆角 + 无阴影，
/// 层级靠表面明度差表达。设置分组、信息块、空态容器都用它，不要各自写
/// `Card(color: …, shape: …)`：那会让圆角与底色散落在十几个文件里，
/// 改一次要改十几处。
class TonalCard extends StatelessWidget {
  const TonalCard({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.radius = Md3Shape.tonalRadius,
    this.color,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  /// 圆角。默认 24；需要与相邻面板拼成一体时传更小的内圆角。
  final double radius;

  /// 覆盖填充色。null 时用 `surfaceContainerLow`。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: color ?? colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(radius),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding, child: child),
    );
  }
}

/// 主操作按钮：按压时圆角从 28 收到 16。
///
/// 这是参照应用 `StateActionButton` 的形变语言——「按下时收紧」比改变
/// 底色更有触感，也比缩放更不容易引起布局抖动。宽度变化靠 [reserveText]
/// 补齐：图标与文字长度会在加载态变化，不预留就会左右横跳。
class StateActionButton extends StatelessWidget {
  const StateActionButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.tonal = false,
    this.reserveText,
    this.minimumSize = const Size(64, 48),
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  /// 用 `FilledButton.tonalIcon` 而非 `FilledButton.icon`。
  final bool tonal;

  /// 宽度预留的文本。加载态把 label 换成短词时传原始文本，避免跳宽。
  final String? reserveText;

  final Size minimumSize;

  @override
  Widget build(BuildContext context) {
    final style = _styleOf(context);
    final child = _content(context);
    return tonal
        ? FilledButton.tonalIcon(
            onPressed: onPressed,
            style: style,
            icon: icon == null ? null : Icon(icon, size: 20),
            label: child,
          )
        : FilledButton.icon(
            onPressed: onPressed,
            style: style,
            icon: icon == null ? null : Icon(icon, size: 20),
            label: child,
          );
  }

  Widget _content(BuildContext context) {
    final reserve = reserveText;
    if (reserve == null) return Text(label);
    // 用不可见的原始文本占位，保持宽度稳定。
    return Stack(
      alignment: Alignment.center,
      children: [
        Opacity(opacity: 0, child: Text(reserve)),
        Text(label, textAlign: TextAlign.center),
      ],
    );
  }

  ButtonStyle _styleOf(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final disabled = onPressed == null;
    return ButtonStyle(
      minimumSize: WidgetStatePropertyAll(minimumSize),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(
          horizontal: Md3Spacing.xl,
          vertical: Md3Spacing.md,
        ),
      ),
      shape: WidgetStateProperty.resolveWith(
        (states) => RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(
            states.contains(WidgetState.pressed)
                ? Md3Shape.pressedRadius
                : Md3Shape.extraLarge,
          ),
        ),
      ),
      animationDuration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : Md3Motion.standardAccelerate,
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (disabled) return colors.onSurface.withValues(alpha: .38);
        return tonal ? colors.onSecondaryContainer : colors.onPrimary;
      }),
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (disabled) return colors.onSurface.withValues(alpha: .12);
        return tonal ? colors.secondaryContainer : colors.primary;
      }),
    );
  }
}

/// 连体分段控件：相邻的段之间只有 2px 缝，两端是胶囊、中间是方角。
///
/// 与 `SegmentedButton` 的区别在于选中指示是**连续插值**的：它跟着
/// `TabController.animation` 走，切换时指示块在段之间平滑滑动，而不是
/// 一节一节跳。这是参照应用的分段 tab 手感来源。
class ConnectedTabs extends StatelessWidget {
  const ConnectedTabs({
    super.key,
    required this.labels,
    required this.controller,
    this.onChanged,
    this.height = 40,
  });

  final List<String> labels;
  final TabController controller;
  final ValueChanged<int>? onChanged;
  final double height;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    const gap = 2.0;
    final radius = height / 2;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width =
            (constraints.maxWidth - gap * (labels.length - 1)) / labels.length;
        return AnimatedBuilder(
          animation: controller.animation ?? controller,
          builder: (context, _) {
            final position =
                controller.animation?.value ?? controller.index.toDouble();
            return Row(
              children: [
                for (var i = 0; i < labels.length; i++) ...[
                  if (i > 0) const SizedBox(width: gap),
                  _Segment(
                    width: width,
                    height: height,
                    radius: radius,
                    label: labels[i],
                    // 指示块的「接近度」：完全选中为 1，其余按距离衰减。
                    selectedness: (1 - (position - i).abs()).clamp(0.0, 1.0),
                    onTap: () {
                      controller.animateTo(i);
                      onChanged?.call(i);
                    },
                    colors: colors,
                  ),
                ],
              ],
            );
          },
        );
      },
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.width,
    required this.height,
    required this.radius,
    required this.label,
    required this.selectedness,
    required this.onTap,
    required this.colors,
  });

  final double width;
  final double height;
  final double radius;
  final String label;
  final double selectedness;
  final VoidCallback onTap;
  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    final background = Color.lerp(
      colors.surfaceContainer,
      colors.secondaryContainer,
      selectedness,
    )!;
    final foreground = Color.lerp(
      colors.onSurfaceVariant,
      colors.onSecondaryContainer,
      selectedness,
    )!;
    return SizedBox(
      width: width,
      height: height,
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(radius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          splashColor: colors.primary.withValues(alpha: Md3State.hover),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: Md3Type.labelLarge,
                fontWeight: selectedness > .5
                    ? FontWeight.w700
                    : FontWeight.w500,
                color: foreground,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 菜单按钮：把 `MenuAnchor` 的样板收成一处。
///
/// 统一三件事：条目最小 144×48、点击外部即关、菜单项按选中/危险语义
/// 染色。各处再写裸 `PopupMenuButton` 就会让菜单尺寸与间距各不相同。
class AppMenuButton extends StatelessWidget {
  const AppMenuButton({
    super.key,
    required this.builder,
    required this.menuChildren,
    this.enabled = true,
    this.animated = false,
    this.maxSize,
    this.controller,
  });

  final Widget Function(BuildContext context, VoidCallback? toggle, bool open)
  builder;
  final List<Widget> menuChildren;
  final bool enabled;

  /// 只在原本就有动画的菜单上开启——动画会让首次打开慢一帧。
  final bool animated;

  final Size? maxSize;

  /// 外部持有 [MenuController]，供右键等非按钮触发的打开场景
  /// （列表项 `onSecondaryTap` → `controller.open()`）。
  final MenuController? controller;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return MenuButtonTheme(
      data: MenuButtonThemeData(
        style: _itemStyle.merge(MenuButtonTheme.of(context).style),
      ),
      child: MenuAnchor(
        controller: controller,
        consumeOutsideTap: true,
        animated: animated && !reduceMotion,
        style: maxSize == null
            ? null
            : MenuStyle(maximumSize: WidgetStatePropertyAll(maxSize)),
        menuChildren: menuChildren,
        builder: (context, controller, _) => builder(
          context,
          enabled && menuChildren.isNotEmpty
              ? () => controller.isOpen ? controller.close() : controller.open()
              : null,
          controller.isOpen,
        ),
      ),
    );
  }
}

/// 菜单分隔线。
///
/// `MenuAnchor` 体系没有专门的 divider 组件，这里统一样式：上下 4px、
/// 两端 8px 缩进，与菜单条目的内边距对齐。
class AppMenuDivider extends StatelessWidget {
  const AppMenuDivider({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 4),
    child: Divider(height: 1, indent: 8, endIndent: 8),
  );
}

const _itemStyle = ButtonStyle(
  minimumSize: WidgetStatePropertyAll(Size(144, 48)),
  padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16)),
  alignment: AlignmentDirectional.centerStart,
  visualDensity: VisualDensity.standard,
);

/// 菜单条目。
///
/// [selected] 为 null 表示普通动作；给布尔值则暴露单选语义（读屏会念
/// 「已选中」）。[destructive] 用错误色，用于删除/清空。
class AppMenuItem extends StatelessWidget {
  const AppMenuItem({
    super.key,
    required this.label,
    required this.onPressed,
    this.leadingIcon,
    this.selected,
    this.destructive = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final Widget? leadingIcon;
  final bool? selected;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = destructive
        ? colors.error
        : selected == true
        ? colors.primary
        : null;
    final foreground = color == null
        ? null
        : WidgetStateProperty.resolveWith<Color?>(
            (states) => states.contains(WidgetState.disabled) ? null : color,
          );
    return MenuItemButton(
      onPressed: onPressed,
      style: ButtonStyle(foregroundColor: foreground, iconColor: foreground),
      leadingIcon: leadingIcon,
      child: Semantics(
        selected: selected,
        inMutuallyExclusiveGroup: selected == null ? null : true,
        child: Text(label, textAlign: TextAlign.start),
      ),
    );
  }
}
