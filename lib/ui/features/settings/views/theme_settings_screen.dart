import 'dart:io';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';

import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/core/app_page.dart';
import 'package:hoshi/ui/core/app_theme.dart';
import 'package:hoshi/ui/core/split_list.dart';
import 'package:hoshi/ui/core/widgets.dart';
import 'package:hoshi/ui/theme/md3_tokens.dart';
import 'package:hoshi/ui/shell/window_chrome.dart';

/// 外观设置面板。
///
/// 四组选项：
/// 1. 明暗模式（浅色 / 深色 / 跟随系统）；
/// 2. 主题色（9 个预设色 + 跟随系统取色）；
/// 3. OLED 纯黑（仅深色模式有效）；
/// 4. 字体（系统字体 / 内置中文字体）。
///
/// 所有改动立即生效并落盘，不需要重启（窗口标题栏除外，那属于系统层）。
class ThemeSettingsScreen extends StatelessWidget {
  const ThemeSettingsScreen({super.key, required this.store});

  final LocalStore store;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: store,
    builder: (context, _) {
      final l10n = AppLocalizations.of(context);
      return Scaffold(
        appBar: DesktopAppBar(title: Text(l10n.themeSettingsTitle)),
        body: AppPage(
          child: ListView(
            padding: const EdgeInsets.only(bottom: Md3Spacing.xxl),
            children: [
              SectionHeader(
                title: l10n.themeColorTitle,
                description: l10n.themeColorHint,
              ),
              _PaletteGrid(store: store),
              if (_supportsDynamicColor) ...[
                SectionHeader(title: l10n.themeDynamicTitle),
                SplitListGroup(
                  children: [
                    SplitSwitchRow(
                      key: const ValueKey('theme-dynamic'),
                      leading: Icons.palette_rounded,
                      title: l10n.themeDynamicTitle,
                      description: l10n.themeDynamicHint,
                      value: store.useDynamicColor,
                      onChanged: (value) => saveUserChange(
                        context,
                        () => store.setUseDynamicColor(value),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      );
    },
  );

  /// 动态取色只在支持系统取色的平台上有意义。
  bool get _supportsDynamicColor => Platform.isAndroid || Platform.isMacOS;
}

/// 主题色调色板。
///
/// 每个色块是一个圆形，选中时加一圈描边与勾。色块用真实主题色渲染：
/// 取种子色生成一个 mini `ColorScheme`，画四个角色，而不是只画纯色——
/// 用户看到的是「选完之后大致长什么样」。
class _PaletteGrid extends StatelessWidget {
  const _PaletteGrid({required this.store});

  final LocalStore store;

  @override
  Widget build(BuildContext context) {
    final selected = store.themeSeed;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Md3Spacing.md),
      child: Wrap(
        spacing: Md3Spacing.md,
        runSpacing: Md3Spacing.md,
        children: [
          for (final seed in AppTheme.palette)
            _Swatch(
              seed: seed,
              selected:
                  (selected == null && seed == AppTheme.seed) ||
                  selected == _hex(seed),
              onTap: () => saveUserChange(
                context,
                () => store.setThemeSeed(
                  seed == AppTheme.seed ? null : _hex(seed),
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _hex(Color color) =>
      color.toARGB32().toRadixString(16).padLeft(8, '0');
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.seed,
    required this.selected,
    required this.onTap,
  });

  final Color seed;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final scheme = ColorScheme.fromSeed(seedColor: seed);
    return Semantics(
      button: true,
      selected: selected,
      label: '主题色',
      child: Tooltip(
        message: selected ? '当前主题色' : '使用此主题色',
        child: InkWell(
          borderRadius: BorderRadius.circular(Md3Shape.extraLargeIncreased),
          onTap: onTap,
          child: Container(
            width: 56,
            height: 56,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? colors.primary : Colors.transparent,
                width: 2,
              ),
            ),
            child: ClipOval(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // 四个角色拼成一块：主色 / 主容器 / 次色 / 表面。
                  Column(
                    children: [
                      Expanded(
                        flex: 3,
                        child: ColoredBox(color: scheme.primary),
                      ),
                      Expanded(
                        flex: 2,
                        child: Row(
                          children: [
                            Expanded(
                              child: ColoredBox(color: scheme.primaryContainer),
                            ),
                            Expanded(child: ColoredBox(color: scheme.tertiary)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (selected)
                    Center(
                      child: Icon(
                        Icons.check_rounded,
                        size: 20,
                        color: scheme.onPrimary,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 让 `dynamic_color` 的依赖在未启用时不产生未使用告警。
///
/// 真正的系统取色在 `main.dart` 的 `DynamicColorBuilder` 里接入；
/// 这里保留引用，确保该包在主题设置页编译期内可达。
Widget dynamicColorHost(Widget Function(ColorScheme?, ColorScheme?) builder) =>
    DynamicColorBuilder(builder: builder);
