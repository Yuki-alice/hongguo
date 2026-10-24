import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_new_shapes/material_new_shapes.dart';

import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/domain/follow_state.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/core/app_layout.dart';
import 'package:hoshi/ui/core/empty_state.dart' show ShapeBadgePainter;
import 'package:hoshi/ui/core/split_list.dart';
import 'package:hoshi/ui/routing/app_router.dart';
import 'package:hoshi/ui/theme/md3_tokens.dart';
import 'package:hoshi/ui/shell/window_chrome.dart';

/// 「我的」页。
///
/// 结构照参照应用 `my_space_view.dart`：
/// - 宽屏：标题 + 统计面板 → 规则磁贴 + 历史/下载磁贴 → 设置 + 用户/关于；
/// - 窄屏：统计面板 → 历史/下载两枚磁贴 → 两组列表入口。
///
/// 容器色照抄参照应用：统计 `primaryContainer`（宽屏 `surfaceContainerHigh`）、
/// 历史 `secondaryContainer`、下载 `tertiaryContainer`、规则 `primary`、
/// 入口组 `surfaceContainerLow`。
class MyScreen extends StatelessWidget {
  const MyScreen({super.key, required this.store});

  final LocalStore store;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final inset = Md3Spacing.contentInset(
          constraints.maxWidth,
          maxWidth: Md3Spacing.bentoMaxWidth,
        );
        final wide =
            constraints.maxWidth - inset * 2 >= 840 &&
            MediaQuery.textScalerOf(context).scale(16) <= 24;
        return SingleChildScrollView(
          key: const PageStorageKey('my-space'),
          padding: EdgeInsets.fromLTRB(
            inset,
            Md3Spacing.md + WindowSafeArea.top,
            inset,
            Md3Spacing.xxl,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: Md3Spacing.bentoMaxWidth,
              ),
              child: wide
                  ? _WideLayout(store: store, l10n: l10n)
                  : _CompactLayout(store: store, l10n: l10n),
            ),
          ),
        );
      },
    );
  }
}

class _WideLayout extends StatelessWidget {
  const _WideLayout({required this.store, required this.l10n});

  final LocalStore store;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _AdaptivePair(
          gap: 20,
          first: _Heading(l10n: l10n),
          second: _StatsPanel(store: store, l10n: l10n),
        ),
        const SizedBox(height: 28),
        _AdaptivePair(
          gap: 20,
          first: _RulesTile(
            title: l10n.sourceManagement,
            caption: l10n.mySourcesCaption,
            onTap: () => context.push(AppRoutes.sources),
          ),
          second: _AdaptivePair(
            gap: 12,
            first: _ToolTile(
              key: const ValueKey('my-history'),
              icon: Icons.history_rounded,
              title: l10n.recentlyWatched,
              caption: '${store.history.length} ${l10n.myItemsUnit}',
              color: Theme.of(context).colorScheme.secondaryContainer,
              foreground: Theme.of(context).colorScheme.onSecondaryContainer,
              onTap: () => context.push(AppRoutes.history),
            ),
            second: _ToolTile(
              key: const ValueKey('my-downloads'),
              icon: Icons.download_rounded,
              title: l10n.download,
              caption: l10n.myContentSection,
              color: Theme.of(context).colorScheme.tertiaryContainer,
              foreground: Theme.of(context).colorScheme.onTertiaryContainer,
              onTap: () => context.push(AppRoutes.downloads),
            ),
          ),
        ),
        const SizedBox(height: 12),
        _AdaptivePair(
          gap: 20,
          first: _SettingsTile(
            key: const ValueKey('my-settings'),
            title: l10n.settingsNav,
            caption: l10n.settingsTitle,
            onTap: () => context.push(AppRoutes.settings),
          ),
          second: _AdaptivePair(
            gap: 12,
            first: _EntryTile(
              key: const ValueKey('my-users'),
              icon: Icons.people_alt_rounded,
              title: l10n.userManagement,
              onTap: () => context.push(AppRoutes.profiles),
            ),
            second: _EntryTile(
              key: const ValueKey('my-about'),
              icon: Icons.info_outline_rounded,
              title: l10n.about,
              onTap: () => _showAbout(context, l10n),
            ),
          ),
        ),
      ],
    );
  }
}

class _CompactLayout extends StatelessWidget {
  const _CompactLayout({required this.store, required this.l10n});

  final LocalStore store;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StatsPanel(store: store, l10n: l10n, compact: true),
        const SizedBox(height: 12),
        _AdaptivePair(
          first: _ToolTile(
            key: const ValueKey('my-history'),
            icon: Icons.history_rounded,
            title: l10n.recentlyWatched,
            caption: '${store.history.length} ${l10n.myItemsUnit}',
            color: colors.secondaryContainer,
            foreground: colors.onSecondaryContainer,
            compact: true,
            onTap: () => context.push(AppRoutes.history),
          ),
          second: _ToolTile(
            key: const ValueKey('my-downloads'),
            icon: Icons.download_rounded,
            title: l10n.download,
            caption: l10n.myContentSection,
            color: colors.secondaryContainer,
            foreground: colors.onSecondaryContainer,
            compact: true,
            onTap: () => context.push(AppRoutes.downloads),
          ),
        ),
        const SizedBox(height: 24),
        _ContentSection(
          title: l10n.myContentSection,
          children: [
            SplitListRow(
              key: const ValueKey('my-sources'),
              leading: Icons.extension_rounded,
              title: l10n.sourceManagement,
              description: l10n.mySourcesCaption,
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => context.push(AppRoutes.sources),
            ),
            SplitListRow(
              key: const ValueKey('my-settings'),
              leading: Icons.settings_rounded,
              title: l10n.settingsNav,
              description: l10n.settingsTitle,
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => context.push(AppRoutes.settings),
            ),
            SplitListRow(
              key: const ValueKey('my-users'),
              leading: Icons.people_alt_rounded,
              title: l10n.userManagement,
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => context.push(AppRoutes.profiles),
            ),
          ],
        ),
        const SizedBox(height: 24),
        _ContentSection(
          title: l10n.myAppSection,
          children: [
            SplitListRow(
              key: const ValueKey('my-about'),
              leading: Icons.info_outline_rounded,
              title: l10n.about,
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _showAbout(context, l10n),
            ),
          ],
        ),
      ],
    );
  }
}

void _showAbout(BuildContext context, AppLocalizations l10n) => showAboutDialog(
  context: context,
  applicationName: appName,
  applicationVersion: AppLayout.versionOf(context),
  children: [Text(l10n.appIntro)],
);

class _Heading extends StatelessWidget {
  const _Heading({required this.l10n});

  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: Text(
            l10n.mySpaceTitle,
            style: TextStyle(
              fontSize: Md3Type.displaySmall,
              fontWeight: FontWeight.w800,
              height: 1.2,
              color: colors.onSurface,
            ),
          ),
        ),
        const SizedBox(width: Md3Spacing.md),
        _ShapeIcon(
          shape: MaterialShapes.sunny,
          icon: Icons.sentiment_satisfied_alt_rounded,
          size: 64,
          color: colors.tertiaryContainer,
          foreground: colors.onTertiaryContainer,
        ),
      ],
    );
  }
}

/// 观看统计。宽屏 `surfaceContainerHigh` / 窄屏 `primaryContainer`。
class _StatsPanel extends StatelessWidget {
  const _StatsPanel({
    required this.store,
    required this.l10n,
    this.compact = false,
  });

  final LocalStore store;
  final AppLocalizations l10n;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final favorites = store.favorites;
    final watching = favorites
        .where(
          (drama) => store.following(drama.id)?.status == FollowStatus.watching,
        )
        .length;
    final episodes = store.history.fold<int>(
      0,
      (sum, entry) => sum + math.max(1, entry.episode),
    );
    final foreground = compact ? colors.onPrimaryContainer : colors.onSurface;
    return Material(
      color: compact ? colors.primaryContainer : colors.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(
        compact ? Md3Shape.extraLarge : Md3Shape.extraExtraLarge,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (compact)
              Row(
                children: [
                  _ShapeIcon(
                    shape: MaterialShapes.sunny,
                    icon: Icons.sentiment_satisfied_alt_rounded,
                    size: 32,
                    color: colors.primary,
                    foreground: colors.onPrimary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      l10n.myStatsTitle,
                      style: TextStyle(
                        fontSize: Md3Type.titleSmall,
                        fontWeight: FontWeight.w700,
                        color: foreground,
                      ),
                    ),
                  ),
                ],
              )
            else
              Text(
                l10n.myStatsTitle,
                style: TextStyle(
                  fontSize: Md3Type.labelMedium,
                  color: colors.onSurfaceVariant,
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _StatCount(
                    value: watching,
                    label: l10n.follows,
                    foreground: compact ? foreground : null,
                  ),
                ),
                if (compact)
                  SizedBox(
                    height: 32,
                    child: VerticalDivider(
                      width: 24,
                      color: foreground.withValues(alpha: .16),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Icon(
                      Icons.auto_awesome_rounded,
                      color: colors.primary,
                      size: 20,
                    ),
                  ),
                Expanded(
                  child: _StatCount(
                    value: episodes,
                    label: l10n.myEpisodesUnit,
                    foreground: compact ? foreground : null,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatCount extends StatelessWidget {
  const _StatCount({required this.value, required this.label, this.foreground});

  final int value;
  final String label;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            '$value',
            style: TextStyle(
              fontSize: Md3Type.displaySmall,
              color: foreground ?? theme.colorScheme.onSurface,
              fontWeight: FontWeight.w800,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: Md3Type.labelMedium,
            color: foreground ?? theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// 规则（站源）磁贴：主色 + 右上角 64 圆角，照 `_RulesTile`。
class _RulesTile extends StatelessWidget {
  const _RulesTile({
    required this.title,
    required this.caption,
    required this.onTap,
  });

  final String title;
  final String caption;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _ExpressiveAction(
      color: colors.primary,
      foreground: colors.onPrimary,
      radius: const BorderRadius.only(
        topLeft: Radius.circular(28),
        topRight: Radius.circular(64),
        bottomLeft: Radius.circular(28),
        bottomRight: Radius.circular(28),
      ),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: Md3Type.headlineSmall,
                      fontWeight: FontWeight.w700,
                      color: colors.onPrimary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    caption,
                    style: TextStyle(
                      fontSize: Md3Type.bodyMedium,
                      color: colors.onPrimary,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    width: 52,
                    height: 32,
                    decoration: BoxDecoration(
                      color: colors.onPrimary,
                      borderRadius: BorderRadius.circular(
                        Md3Shape.largeIncreased,
                      ),
                    ),
                    child: Icon(
                      Icons.arrow_forward_rounded,
                      color: colors.primary,
                      size: 20,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            _ShapeIcon(
              shape: MaterialShapes.clover4Leaf,
              icon: Icons.extension_rounded,
              size: 80,
              color: colors.primaryContainer,
              foreground: colors.onPrimaryContainer,
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolTile extends StatelessWidget {
  const _ToolTile({
    super.key,
    required this.icon,
    required this.title,
    required this.caption,
    required this.color,
    required this.foreground,
    required this.onTap,
    this.compact = false,
  });

  final IconData icon;
  final String title;
  final String caption;
  final Color color;
  final Color foreground;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return _ExpressiveAction(
      color: color,
      foreground: foreground,
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.all(compact ? 16 : 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              children: [
                Icon(icon, size: compact ? 24 : 30),
                const Spacer(),
                const Icon(Icons.arrow_forward_rounded, size: 20),
              ],
            ),
            SizedBox(height: compact ? 12 : 26),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: Md3Type.titleMedium,
                fontWeight: FontWeight.w700,
                color: foreground,
              ),
            ),
            SizedBox(height: compact ? 4 : 6),
            Text(
              caption,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: Md3Type.bodySmall,
                color: foreground,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    super.key,
    required this.title,
    required this.caption,
    required this.onTap,
  });

  final String title;
  final String caption;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _ExpressiveAction(
      color: colors.surfaceContainerLow,
      foreground: colors.onSurface,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Icon(Icons.settings_rounded, size: 28, color: colors.primary),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: Md3Type.titleMedium,
                      fontWeight: FontWeight.w700,
                      color: colors.onSurface,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: Md3Type.bodySmall,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, size: 20),
          ],
        ),
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _ExpressiveAction(
      color: colors.surfaceContainerLow,
      foreground: colors.onSurface,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        child: Row(
          children: [
            Icon(icon, size: 24, color: colors.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: Md3Type.bodyLarge,
                  color: colors.onSurface,
                ),
              ),
            ),
            const Icon(Icons.chevron_right_rounded, size: 20),
          ],
        ),
      ),
    );
  }
}

class _ContentSection extends StatelessWidget {
  const _ContentSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: SectionHeader(title: title),
      ),
      SplitListGroup(children: children),
    ],
  );
}

class _AdaptivePair extends StatelessWidget {
  const _AdaptivePair({
    required this.first,
    required this.second,
    this.gap = 12,
  });

  final Widget first;
  final Widget second;
  final double gap;

  @override
  Widget build(BuildContext context) => IntrinsicHeight(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: first),
        SizedBox(width: gap),
        Expanded(child: second),
      ],
    ),
  );
}

class _ShapeIcon extends StatelessWidget {
  const _ShapeIcon({
    required this.shape,
    required this.icon,
    required this.size,
    required this.color,
    required this.foreground,
  });

  final RoundedPolygon shape;
  final IconData icon;
  final double size;
  final Color color;
  final Color foreground;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: CustomPaint(
      painter: ShapeBadgePainter(color: color, shape: shape),
      child: SizedBox.square(
        dimension: size,
        child: Icon(icon, color: foreground, size: size * .44),
      ),
    ),
  );
}

class _ExpressiveAction extends StatefulWidget {
  const _ExpressiveAction({
    required this.color,
    required this.foreground,
    required this.onTap,
    required this.child,
    this.radius = const BorderRadius.all(Radius.circular(28)),
  });

  final Color color;
  final Color foreground;
  final VoidCallback onTap;
  final Widget child;
  final BorderRadius radius;

  @override
  State<_ExpressiveAction> createState() => _ExpressiveActionState();
}

class _ExpressiveActionState extends State<_ExpressiveAction> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final duration = reducedMotion
        ? Duration.zero
        : Duration(milliseconds: _pressed ? 150 : 300);
    return Semantics(
      button: true,
      child: AnimatedScale(
        scale: _pressed && !reducedMotion ? .97 : 1,
        duration: duration,
        curve: _pressed ? Curves.easeOutCubic : Curves.easeOutBack,
        child: AnimatedContainer(
          duration: duration,
          curve: Curves.easeOutCubic,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: widget.color,
            borderRadius: _pressed
                ? BorderRadius.circular(Md3Shape.pressedRadius)
                : widget.radius,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: widget.onTap,
              onHighlightChanged: (value) => setState(() => _pressed = value),
              overlayColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.pressed)) {
                  return widget.foreground.withValues(alpha: .10);
                }
                if (states.contains(WidgetState.focused)) {
                  return widget.foreground.withValues(alpha: .12);
                }
                if (states.contains(WidgetState.hovered)) {
                  return widget.foreground.withValues(alpha: .08);
                }
                return null;
              }),
              child: IconTheme.merge(
                data: IconThemeData(color: widget.foreground),
                child: DefaultTextStyle.merge(
                  style: TextStyle(color: widget.foreground),
                  child: widget.child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
