import 'package:flutter/material.dart';

import 'package:hoshi/domain/models.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/theme/md3_tokens.dart';

/// 选集按钮。
///
/// - 交互反馈用「表面色 + 主色描边」；
/// - 支持鼠标悬停与键盘 Tab 聚焦，两者视觉一致；
/// - 当前集用主色填充，选中态（批量下载）用次色填充，二者不会混淆。
class EpisodeButton extends StatefulWidget {
  const EpisodeButton({
    super.key,
    required this.number,
    required this.onPressed,
    this.vip = false,
    this.current = false,
    this.selected = false,
    this.compact = false,
  });

  final int number;
  final VoidCallback onPressed;
  final bool vip;

  /// 正在观看 / 上次看到的那一集。
  final bool current;

  /// 是否被选中（批量下载场景）。
  final bool selected;

  final bool compact;

  @override
  State<EpisodeButton> createState() => _EpisodeButtonState();
}

class _EpisodeButtonState extends State<EpisodeButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final highlighted = widget.current || widget.selected;

    final background = switch ((highlighted, _hovered)) {
      (true, _) =>
        widget.selected ? colors.secondaryContainer : colors.primaryContainer,
      (false, true) => Md3State.layer(
        colors.surface,
        colors.onSurface,
        Md3State.hover,
      ),
      _ => colors.surfaceContainerLow,
    };
    final foreground = switch ((highlighted, widget.selected)) {
      (true, true) => colors.onSecondaryContainer,
      (true, false) => colors.onPrimaryContainer,
      _ => colors.onSurface,
    };
    final borderColor = _focused
        ? colors.primary
        : widget.current
        ? colors.primary
        : _hovered
        ? colors.outline
        : colors.outlineVariant;

    return Semantics(
      button: true,
      selected: highlighted,
      label: widget.vip
          ? l10n.episodeTitleVip(widget.number)
          : l10n.episodeTitle(widget.number),
      excludeSemantics: true,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: FocusableActionDetector(
          onShowFocusHighlight: (value) => setState(() => _focused = value),
          child: Material(
            color: background,
            borderRadius: BorderRadius.circular(
              widget.compact ? Md3Shape.small : Md3Shape.medium,
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(
                widget.compact ? Md3Shape.small : Md3Shape.medium,
              ),
              onTap: widget.onPressed,
              child: AnimatedContainer(
                duration: Md3Motion.of(context, Md3Motion.shape),
                curve: Md3Motion.standardCurve,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(
                    widget.compact ? Md3Shape.small : Md3Shape.medium,
                  ),
                  border: Border.all(
                    color: borderColor,
                    width: _focused ? 2 : 1,
                  ),
                ),
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          '${widget.number}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: widget.compact
                                ? Md3Type.bodyMedium
                                : Md3Type.titleMedium,
                            fontWeight: highlighted
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: foreground,
                          ),
                        ),
                      ),
                      if (widget.vip) ...[
                        SizedBox(width: widget.compact ? 2 : 4),
                        Icon(
                          Icons.workspace_premium_rounded,
                          color: colors.tertiary,
                          size: widget.compact ? 14 : 17,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 选集网格。
///
/// 普通 `GridView`，悬停、滚轮、键盘 Tab 都能正常工作。
class EpisodeGrid extends StatelessWidget {
  const EpisodeGrid({
    super.key,
    required this.episodes,
    required this.onSelected,
    this.currentNumber,
    this.selectedNumbers,
    this.keyPrefix = 'episode',
    this.compact = false,
    this.padding = const EdgeInsets.fromLTRB(18, 2, 18, 18),
    this.controller,
  });

  final List<Episode> episodes;
  final ValueChanged<int> onSelected;
  final int? currentNumber;
  final Set<int>? selectedNumbers;
  final String keyPrefix;
  final bool compact;
  final EdgeInsets padding;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context);
    final digits = episodes.fold<int>(
      1,
      (value, episode) => episode.number.toString().length > value
          ? episode.number.toString().length
          : value,
    );
    final minTile = compact
        ? 44.0
        : (scale.scale(16) * digits * .65 + 34).clamp(56.0, 110.0);
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth - padding.horizontal;
        final columns = (available / minTile).floor().clamp(
          compact ? 5 : 2,
          compact ? 12 : 9,
        );
        final extent = compact
            ? (scale.scale(14) + 20).clamp(36.0, 64.0)
            : (scale.scale(16) + 30).clamp(52.0, 84.0);
        return GridView.builder(
          controller: controller,
          padding: padding,
          physics: const AlwaysScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: compact ? 6 : 8,
            crossAxisSpacing: compact ? 6 : 8,
            mainAxisExtent: extent,
          ),
          itemCount: episodes.length,
          itemBuilder: (context, index) {
            final episode = episodes[index];
            return EpisodeButton(
              key: ValueKey('$keyPrefix-${episode.number}'),
              number: episode.number,
              vip: episode.vip,
              compact: compact,
              current:
                  selectedNumbers?.contains(episode.number) ??
                  episode.number == currentNumber,
              selected: selectedNumbers?.contains(episode.number) ?? false,
              onPressed: () => onSelected(index),
            );
          },
        );
      },
    );
  }
}
