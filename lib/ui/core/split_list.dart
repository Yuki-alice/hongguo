import 'package:flutter/material.dart';

import 'package:hoshi/ui/theme/md3_tokens.dart';

/// M3 分组列表。
///
/// 把若干行组织成一个视觉整体：首尾行用大圆角，中间行用小圆角，行间留
/// 4px 缝隙。按压时整行圆角变大，看起来像从组里「摘」出来——这是 M3
/// Expressive 的列表语汇，比单纯的 `Card` + `ListTile` 更有层次。
///
/// 改造前设置页是裸 `ListTile` 平铺，没有分组也没有按压反馈。
class SplitListGroup extends StatelessWidget {
  const SplitListGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (index, child) in children.indexed) ...[
          if (index > 0) const SizedBox(height: Md3Shape.groupGap),
          _GroupRow(
            first: index == 0,
            last: index == children.length - 1,
            child: child,
          ),
        ],
      ],
    );
  }
}

class _GroupRow extends StatefulWidget {
  const _GroupRow({
    required this.first,
    required this.last,
    required this.child,
  });

  final bool first;
  final bool last;
  final Widget child;

  @override
  State<_GroupRow> createState() => _GroupRowState();
}

class _GroupRowState extends State<_GroupRow> {
  bool _pressed = false;

  BorderRadius get _rest {
    const outer = Radius.circular(Md3Shape.groupRadius);
    const inner = Radius.circular(Md3Shape.groupInnerRadius);
    return BorderRadius.only(
      topLeft: widget.first ? outer : inner,
      topRight: widget.first ? outer : inner,
      bottomLeft: widget.last ? outer : inner,
      bottomRight: widget.last ? outer : inner,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final target = _pressed
        ? BorderRadius.circular(Md3Shape.groupRadius)
        : _rest;
    return AnimatedContainer(
      duration: Md3Motion.of(context, Md3Motion.shape),
      curve: Md3Motion.standardCurve,
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: target,
      ),
      clipBehavior: Clip.antiAlias,
      child: Listener(
        onPointerDown: (_) => setState(() => _pressed = true),
        onPointerUp: (_) => setState(() => _pressed = false),
        onPointerCancel: (_) => setState(() => _pressed = false),
        child: widget.child,
      ),
    );
  }
}

/// 分组标题。
///
/// 用主色 + `titleSmall`，与正文拉开层级；`Semantics(header)` 让读屏
/// 能按标题跳转。
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.description,
    this.trailing,
  });

  final String title;
  final String? description;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      // 上边距大于下边距：标题属于下面那组内容，需要和上一组拉开距离。
      padding: const EdgeInsets.fromLTRB(
        Md3Spacing.md,
        Md3Spacing.xxl,
        Md3Spacing.md,
        Md3Spacing.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: Md3Type.labelLarge,
                      fontWeight: FontWeight.w700,
                      color: colors.primary,
                      letterSpacing: .2,
                    ),
                  ),
                ),
                if (description != null) ...[
                  const SizedBox(height: Md3Spacing.xxs),
                  Text(
                    description!,
                    style: TextStyle(
                      fontSize: Md3Type.bodySmall,
                      color: colors.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// 分组列表里的一行。
///
/// 统一 `leading` 图标尺寸、标题/说明的字体层级与最小高度，避免各页面
/// 自己拼 `ListTile` 导致行高不一致。
class SplitListRow extends StatelessWidget {
  const SplitListRow({
    super.key,
    this.leading,
    required this.title,
    this.description,
    this.trailing,
    this.onTap,
    this.enabled = true,
    this.selected = false,
  });

  final IconData? leading;
  final String title;
  final String? description;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool enabled;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = enabled
        ? colors.onSurface
        : colors.onSurface.withValues(alpha: Md3State.disabled);
    final secondary = enabled
        ? colors.onSurfaceVariant
        : colors.onSurfaceVariant.withValues(alpha: Md3State.disabled);
    return InkWell(
      onTap: enabled ? onTap : null,
      hoverColor: colors.onSurface.withValues(alpha: Md3State.hover),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Md3Spacing.lg,
            vertical: Md3Spacing.md,
          ),
          child: Row(
            children: [
              if (leading != null) ...[
                Icon(leading, size: 22, color: secondary),
                const SizedBox(width: Md3Spacing.lg),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: Md3Type.bodyLarge,
                        color: foreground,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                      ),
                    ),
                    if (description != null) ...[
                      const SizedBox(height: Md3Spacing.xxs),
                      Text(
                        description!,
                        style: TextStyle(
                          fontSize: Md3Type.bodySmall,
                          color: secondary,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: Md3Spacing.md),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 分组里的开关行。
class SplitSwitchRow extends StatelessWidget {
  const SplitSwitchRow({
    super.key,
    this.leading,
    required this.title,
    this.description,
    required this.value,
    required this.onChanged,
  });

  final IconData? leading;
  final String title;
  final String? description;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => SplitListRow(
    leading: leading,
    title: title,
    description: description,
    trailing: Switch(value: value, onChanged: onChanged),
    onTap: onChanged == null ? null : () => onChanged!(!value),
  );
}
