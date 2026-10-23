import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';

import 'package:hoshi/data/app_contract.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/core/app_theme.dart';
import 'package:hoshi/ui/core/app_layout.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/ui/core/remote_widgets.dart';
import 'package:hoshi/ui/core/widgets.dart';
import 'package:hoshi/ui/core/app_page.dart';
import 'package:hoshi/ui/core/split_list.dart';
import 'package:hoshi/domain/window_bounds.dart';
import 'package:hoshi/ui/shell/window_chrome.dart';
import 'package:hoshi/ui/theme/md3_tokens.dart';
import 'package:hoshi/ui/features/settings/controllers/settings_controller.dart';
import 'package:hoshi/ui/features/settings/controllers/storage_controller.dart';
import 'package:hoshi/ui/routing/app_router.dart';

String storageSize(int bytes, AppLocalizations l10n) {
  if (bytes < 0) return l10n.storageUnavailable;
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.repository,
    required this.store,
  });
  final AppRepository repository;
  final LocalStore store;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _listKey = GlobalKey<RemoteListState>();
  late final SettingsController _controller;

  /// 桌面两栏当前选中的分组下标。
  int _pane = 0;

  @override
  void initState() {
    super.initState();
    _controller = SettingsController(widget.store);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _closeBehaviorLabel(CloseBehavior behavior, AppLocalizations l10n) =>
      switch (behavior) {
        CloseBehavior.exit => l10n.closeBehaviorExit,
        CloseBehavior.minimizeToTray => l10n.closeBehaviorTray,
        CloseBehavior.ask => l10n.closeBehaviorAsk,
      };

  Future<void> _chooseCloseBehavior() async {
    final l10n = AppLocalizations.of(context);
    final selected = await showDialog<CloseBehavior>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(l10n.closeBehaviorTitle),
        children: [
          RadioGroup<CloseBehavior>(
            groupValue: widget.store.closeBehavior,
            onChanged: (value) => Navigator.pop(context, value),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final behavior in CloseBehavior.values)
                  RadioListTile<CloseBehavior>(
                    value: behavior,
                    title: Text(_closeBehaviorLabel(behavior, l10n)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (selected != null && mounted) {
      await saveUserChange(
        context,
        () => widget.store.setCloseBehavior(selected),
      );
    }
  }

  Future<void> _chooseTheme() async {
    final l10n = AppLocalizations.of(context);
    if (AppLayout.isTelevision(context)) {
      final selected = await showDialog<String>(
        context: context,
        builder: (_) => TelevisionActionDialog(
          title: l10n.appearanceTheme,
          options: [
            for (final mode in ['light', 'dark', 'system'])
              TelevisionAction(
                value: mode,
                label: AppTheme.label(mode, l10n),
                description: mode == 'system' ? l10n.followSystemTheme : null,
                icon: Icons.brightness_6_rounded,
              ),
          ],
        ),
      );
      if (selected != null && mounted) {
        await saveUserChange(
          context,
          () => widget.store.setThemeMode(selected),
        );
      }
      return;
    }
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(l10n.appearanceTheme),
        children: [
          RadioGroup<String>(
            groupValue: widget.store.themeMode,
            onChanged: (value) => Navigator.pop(context, value),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final mode in ['light', 'dark', 'system'])
                  RadioListTile<String>(
                    value: mode,
                    title: Text(AppTheme.label(mode, l10n)),
                    subtitle: mode == 'system'
                        ? Text(l10n.followSystemTheme)
                        : null,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (selected != null && mounted) {
      await saveUserChange(context, () => widget.store.setThemeMode(selected));
    }
  }

  Future<void> _backup(bool restore) async {
    final l10n = AppLocalizations.of(context);
    if (!restore) {
      await _controller.exportBackup();
      return;
    }
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (file == null || !mounted) return;
      final size = await file.length();
      if (size == null || size > 8 * 1024 * 1024) {
        throw FormatException(l10n.backupTooLarge);
      }
      final content = utf8.decode(await file.readAsBytes());
      final data = widget.store.validateBackup(content);
      if (!mounted) return;
      final summary = l10n.backupProfilesSummary(
        (data['profiles'] as List).length,
      );
      final bool accepted;
      if (AppLayout.isTelevision(context)) {
        accepted =
            await showDialog<String>(
              context: context,
              builder: (_) => TelevisionActionDialog(
                title: l10n.restoreConfirmTitle,
                options: [
                  TelevisionAction(
                    value: 'restore',
                    label: l10n.restoreThisBackup,
                    description: summary,
                    icon: Icons.restore_rounded,
                  ),
                ],
              ),
            ) ==
            'restore';
      } else {
        accepted =
            await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: Text(l10n.restoreConfirmTitle),
                content: Text(summary),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: Text(l10n.cancel),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(l10n.restore),
                  ),
                ],
              ),
            ) ??
            false;
      }
      if (!accepted || !mounted) return;
      final restored = await _controller.restoreBackup(content);
      if (restored && mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } catch (error) {
      _controller.report(error);
    }
  }

  Future<void> _toggleAutoExport() =>
      _controller.setAutoExport(!widget.store.autoExport);

  Future<void> _toggleExportPosters() => saveUserChange(
    context,
    () => widget.store.setExportPosters(!widget.store.exportPosters),
  );

  List<
    ({
      String id,
      IconData icon,
      String title,
      String subtitle,
      VoidCallback? onPressed,
    })
  >
  _televisionEntries(AppLocalizations l10n) => [
    if (widget.repository.supportsSourceManagement)
      (
        id: 'sources',
        icon: Icons.dns_outlined,
        title: l10n.sourceManagement,
        subtitle: l10n.sourceManageHint,
        onPressed: () => context.push(AppRoutes.sources),
      ),
    (
      id: 'theme',
      icon: Icons.palette_outlined,
      title: l10n.appearanceTheme,
      subtitle: AppTheme.label(widget.store.themeMode, l10n),
      onPressed: _chooseTheme,
    ),
    (
      id: 'profiles',
      icon: Icons.people_outline,
      title: l10n.userManagement,
      subtitle: l10n.currentProfile(widget.store.profile.name),
      onPressed: () => context.push(AppRoutes.profiles),
    ),
    if (widget.store.canDownload)
      (
        id: 'download-preferences',
        icon: Icons.download_outlined,
        title: l10n.downloadPrefsTitle,
        subtitle: widget.store.downloadPreferences.qualityLabel,
        onPressed: () => context.push(AppRoutes.downloadPreferences),
      ),
    if (widget.store.canDownload)
      (
        id: 'storage',
        icon: Icons.folder_outlined,
        title: l10n.storageTitle,
        subtitle: l10n.storageEntryHint,
        onPressed: () => context.push(AppRoutes.storage),
      ),
    // 诊断页始终可达：它同时承担「未支持能力可见」的职责。
    (
      id: 'diagnostics',
      icon: Icons.monitor_heart_outlined,
      title: l10n.engineDiagnosticsEntry,
      subtitle: l10n.engineDiagnosticsRuntime,
      onPressed: () => context.push(AppRoutes.engineDiagnostics),
    ),
    if (widget.store.profile.admin) ...[
      // 代理 / DNS / CDN 属于首发不做的高级网络设置（PLAN.md §5）。
      if (widget.repository.capabilities.resourceSettings)
        (
          id: 'resources',
          icon: Icons.settings_ethernet_rounded,
          title: l10n.resourceSettingsTitle,
          subtitle: l10n.networkResourcesHint,
          onPressed: () => context.push(AppRoutes.resourceSettings),
        ),
      (
        id: 'auto-export',
        icon: Icons.movie_filter_outlined,
        title: l10n.autoExportEmbyShort,
        subtitle: widget.store.autoExport
            ? l10n.autoExportOn
            : l10n.autoExportOff,
        onPressed: _controller.busy ? null : _toggleAutoExport,
      ),
      (
        id: 'export-posters',
        icon: Icons.image_outlined,
        title: l10n.exportPosters,
        subtitle: widget.store.exportPosters
            ? l10n.exportPostersOn
            : l10n.exportPostersOff,
        onPressed: _controller.busy ? null : _toggleExportPosters,
      ),
      (
        id: 'backup',
        icon: Icons.backup_outlined,
        title: l10n.exportBackupTitle,
        subtitle: l10n.exportBackupHint,
        onPressed: _controller.busy ? null : () => _backup(false),
      ),
      (
        id: 'restore',
        icon: Icons.restore,
        title: l10n.restoreBackupTitle,
        subtitle: l10n.restoreBackupHint,
        onPressed: _controller.busy ? null : () => _backup(true),
      ),
    ],
  ];

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([widget.store, _controller]),
    builder: (context, _) {
      final l10n = AppLocalizations.of(context);
      final television = AppLayout.isTelevision(context);
      return LayoutBuilder(
        builder: (context, constraints) {
          final wide =
              !television && Md3WindowClass.usesTwoPane(constraints.maxWidth);
          return Scaffold(
            // 设置现在是独立全屏页（不进外壳），两种形态都要 AppBar，
            // 否则宽屏两栏模式下没有返回入口。
            appBar: AppBar(title: Text(l10n.settingsTitle)),
            body: wide
                ? _wideBody(l10n)
                : Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: Md3Spacing.contentMaxWidth,
                      ),
                      child: television
                          ? _televisionBody(l10n)
                          : _listBody(l10n),
                    ),
                  ),
          );
        },
      );
    },
  );

  /// 桌面两栏：左侧分组导航，右侧只显示当前分组。
  ///
  /// 选中态由 [_pane] 记录（默认第一组）。右侧不再是全部设置的放大版：
  /// 那样左侧导航就失去意义了。
  Widget _wideBody(AppLocalizations l10n) {
    final sections = _sections(l10n);
    final index = _pane.clamp(0, sections.length - 1);
    final current = sections[index];
    // 设置已移出外壳、成为独立全屏页，需要自己提供页面留白。
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: Md3Spacing.pageInset(MediaQuery.sizeOf(context).width),
        vertical: Md3Spacing.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: Md3Spacing.settingsPaneWidth,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                Md3Spacing.md,
                Md3Spacing.md,
                Md3Spacing.md,
                Md3Spacing.xl,
              ),
              children: [
                for (final (position, section) in sections.indexed)
                  _PaneEntry(
                    key: ValueKey('settings-pane-${section.id}'),
                    entry: SettingsEntry(
                      id: section.id,
                      icon: section.icon,
                      title: section.title,
                      subtitle: '',
                      onPressed: () => setState(() => _pane = position),
                    ),
                    selected: position == index,
                    onPressed: () => setState(() => _pane = position),
                  ),
              ],
            ),
          ),
          VerticalDivider(
            width: 1,
            thickness: 1,
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          Expanded(
            child: AppPage(
              child: ListView(
                // 切分组时回到顶部，否则会停在上一组的位置。
                key: PageStorageKey('settings-pane-${current.id}'),
                padding: const EdgeInsets.symmetric(vertical: Md3Spacing.lg),
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Md3Spacing.md,
                    ),
                    child: Text(
                      current.title,
                      style: TextStyle(
                        fontSize: Md3Type.headlineSmall,
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ),
                  const SizedBox(height: Md3Spacing.md),
                  ...current.children,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _televisionBody(AppLocalizations l10n) {
    final entries = _televisionEntries(l10n);
    return RemoteList(
      key: _listKey,
      itemKeys: [for (final entry in entries) entry.id],
      itemExtent: RemoteListTile.extent,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      autofocus: true,
      itemBuilder: (_, index, node, onFocus) => RemoteListTile(
        title: entries[index].title,
        subtitle: entries[index].subtitle,
        leading: Icon(entries[index].icon, size: 26),
        focusNode: node,
        onFocus: onFocus,
        onPressed: entries[index].onPressed,
      ),
    );
  }

  Widget _listBody(AppLocalizations l10n) => ListView(
    padding: const EdgeInsets.all(Md3Spacing.lg),
    children: [
      for (final section in _sections(l10n))
        if (section.title.isNotEmpty) ...[
          SectionHeader(title: section.title),
          ...section.children,
        ] else
          ...section.children,
    ],
  );

  /// 桌面两栏的分组。每项自带图标与内容，左侧导航与右侧面板都由它生成。
  List<_SettingsSection> _sections(AppLocalizations l10n) => [
    if (widget.repository.supportsSourceManagement)
      _SettingsSection(
        id: 'sources',
        icon: Icons.dns_outlined,
        title: l10n.sourceManagement,
        children: [
          SplitListGroup(
            children: [
              SplitListRow(
                leading: Icons.dns_outlined,
                title: l10n.sourceManagement,
                description: l10n.sourceManageHint,
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => context.push(AppRoutes.sources),
              ),
            ],
          ),
        ],
      ),
    _SettingsSection(
      id: 'appearance',
      icon: Icons.palette_outlined,
      title: l10n.themeSettingsTitle,
      children: [
        // 明暗模式与两个开关直接改，不跳页面。
        SplitListGroup(
          children: [
            for (final mode in const ['light', 'dark', 'system'])
              SplitListRow(
                key: ValueKey('theme-mode-$mode'),
                leading: switch (mode) {
                  'light' => Icons.light_mode_outlined,
                  'dark' => Icons.dark_mode_outlined,
                  _ => Icons.brightness_auto_outlined,
                },
                title: AppTheme.label(mode, l10n),
                selected: widget.store.themeMode == mode,
                trailing: widget.store.themeMode == mode
                    ? Icon(
                        Icons.check_rounded,
                        color: Theme.of(context).colorScheme.primary,
                      )
                    : null,
                onTap: () => saveUserChange(
                  context,
                  () => widget.store.setThemeMode(mode),
                ),
              ),
          ],
        ),
        const SizedBox(height: Md3Spacing.lg),
        SplitListGroup(
          children: [
            SplitSwitchRow(
              key: const ValueKey('theme-oled'),
              leading: Icons.dark_mode_rounded,
              title: l10n.themeOledTitle,
              description: l10n.themeOledHint,
              value: widget.store.oledEnhance,
              onChanged: (value) => saveUserChange(
                context,
                () => widget.store.setOledEnhance(value),
              ),
            ),
            SplitSwitchRow(
              key: const ValueKey('theme-system-font'),
              leading: Icons.text_fields_rounded,
              title: l10n.themeSystemFontTitle,
              description: l10n.themeSystemFontHint,
              value: widget.store.useSystemFont,
              onChanged: (value) => saveUserChange(
                context,
                () => widget.store.setUseSystemFont(value),
              ),
            ),
          ],
        ),
        const SizedBox(height: Md3Spacing.lg),
        // 调色板是视觉内容，单独一页铺开更好看。
        SplitListGroup(
          children: [
            SplitListRow(
              key: const ValueKey('theme-setting'),
              leading: Icons.palette_outlined,
              title: l10n.themeColorTitle,
              description: l10n.themeColorHint,
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => context.push(AppRoutes.settingsTheme),
            ),
          ],
        ),
      ],
    ),
    _SettingsSection(
      id: 'users',
      icon: Icons.people_outline,
      title: l10n.userManagement,
      children: [
        SplitListGroup(
          children: [
            SplitListRow(
              leading: Icons.people_outline,
              title: l10n.userManagement,
              description: l10n.currentProfile(widget.store.profile.name),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => context.push(AppRoutes.profiles),
            ),
          ],
        ),
      ],
    ),
    if (widget.store.canDownload)
      _SettingsSection(
        id: 'downloads',
        icon: Icons.download_outlined,
        title: l10n.downloadsTitle,
        children: [
          SplitListGroup(
            children: [
              SplitListRow(
                leading: Icons.download_outlined,
                title: l10n.downloadPrefsTitle,
                description: widget.store.downloadPreferences.qualityLabel,
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => context.push(AppRoutes.downloadPreferences),
              ),
              SplitListRow(
                leading: Icons.folder_outlined,
                title: l10n.storageTitle,
                description: l10n.storageEntryHint,
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => context.push(AppRoutes.storage),
              ),
            ],
          ),
        ],
      ),
    _SettingsSection(
      id: 'diagnostics',
      icon: Icons.monitor_heart_outlined,
      title: l10n.engineDiagnosticsEntry,
      children: [
        SplitListGroup(
          children: [
            SplitListRow(
              key: const ValueKey('engine-diagnostics-settings'),
              leading: Icons.monitor_heart_outlined,
              title: l10n.engineDiagnosticsEntry,
              description: l10n.engineDiagnosticsRuntime,
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => context.push(AppRoutes.engineDiagnostics),
            ),
          ],
        ),
      ],
    ),
    if (widget.store.profile.admin)
      _SettingsSection(
        id: 'advanced',
        icon: Icons.tune_rounded,
        title: l10n.settingsAdvanced,
        children: [
          SplitListGroup(
            children: [
              if (widget.repository.capabilities.resourceSettings)
                SplitListRow(
                  leading: Icons.settings_ethernet_rounded,
                  title: l10n.resourceSettingsTitle,
                  description: l10n.networkResourcesHint,
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => context.push(AppRoutes.resourceSettings),
                ),
              SplitSwitchRow(
                leading: Icons.movie_filter_outlined,
                title: l10n.autoExportEmby,
                description: l10n.autoExportHint,
                value: widget.store.autoExport,
                onChanged: _controller.busy ? null : (_) => _toggleAutoExport(),
              ),
              SplitSwitchRow(
                leading: Icons.image_outlined,
                title: l10n.exportPostersTogether,
                description: l10n.exportPostersHint,
                value: widget.store.exportPosters,
                onChanged: _controller.busy
                    ? null
                    : (_) => _toggleExportPosters(),
              ),
              SplitListRow(
                leading: Icons.backup_outlined,
                title: l10n.exportBackupTitle,
                description: l10n.exportBackupHint,
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _controller.busy ? null : () => _backup(false),
              ),
              SplitListRow(
                leading: Icons.restore,
                title: l10n.restoreBackupTitle,
                description: l10n.restoreBackupHint,
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _controller.busy ? null : () => _backup(true),
              ),
              if (WindowChrome.enabled)
                SplitListRow(
                  key: const ValueKey('close-behavior'),
                  leading: Icons.close_fullscreen_rounded,
                  title: l10n.closeBehaviorTitle,
                  description: _closeBehaviorLabel(
                    widget.store.closeBehavior,
                    l10n,
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: _chooseCloseBehavior,
                ),
            ],
          ),
          if (Platform.isIOS)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Md3Spacing.lg),
              child: Text(l10n.iosForegroundHint),
            ),
          if (_controller.message != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Md3Spacing.lg),
              child: SelectableText(_controller.message!),
            ),
        ],
      ),
    if (_controller.busy)
      _SettingsSection(
        id: 'busy',
        icon: Icons.hourglass_empty_rounded,
        title: '',
        children: const [LinearProgressIndicator()],
      ),
  ];
}

/// 桌面两栏的一个分组：左侧导航项 + 右侧内容。
class _SettingsSection {
  const _SettingsSection({
    required this.id,
    required this.icon,
    required this.title,
    required this.children,
  });

  final String id;
  final IconData icon;
  final String title;
  final List<Widget> children;
}

/// 设置分组侧栏里的一行。
class _PaneEntry extends StatefulWidget {
  const _PaneEntry({
    super.key,
    required this.entry,
    required this.selected,
    required this.onPressed,
  });

  final SettingsEntry entry;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  State<_PaneEntry> createState() => _PaneEntryState();
}

class _PaneEntryState extends State<_PaneEntry> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final enabled = widget.onPressed != null;
    final selected = widget.selected;
    final foreground = !enabled
        ? colors.onSurface.withValues(alpha: Md3State.disabled)
        : selected
        ? colors.onSecondaryContainer
        : colors.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Md3Spacing.xxs),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Material(
          color: selected
              ? colors.secondaryContainer
              : _hovered
              ? Md3State.layer(colors.surface, colors.onSurface, Md3State.hover)
              : Colors.transparent,
          borderRadius: Md3Shape.pill,
          child: InkWell(
            borderRadius: Md3Shape.pill,
            onTap: widget.onPressed,
            child: SizedBox(
              height: 44,
              child: Row(
                children: [
                  const SizedBox(width: Md3Spacing.md),
                  Icon(widget.entry.icon, size: 20, color: foreground),
                  const SizedBox(width: Md3Spacing.md),
                  Expanded(
                    child: Text(
                      widget.entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: Md3Type.bodyMedium,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w400,
                        color: foreground,
                      ),
                    ),
                  ),
                  const SizedBox(width: Md3Spacing.sm),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 设置入口。移动端列表、桌面分组栏、电视列表都由它生成。
class SettingsEntry {
  const SettingsEntry({
    required this.id,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onPressed,
  });

  final String id;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onPressed;
}

class SettingsGroup {
  const SettingsGroup({required this.title, required this.entries});
  final String title;
  final List<SettingsEntry> entries;
}

/// 设置入口分组。
///
/// 这里是设置项的唯一清单：桌面分组栏与移动端列表都从它派生，
/// 避免加一项设置要改两处（改造前正是如此）。
List<SettingsGroup> settingsGroups(
  BuildContext context, {
  required LocalStore store,
  required AppRepository repository,
  required ValueChanged<String> onNavigate,
}) {
  final l10n = AppLocalizations.of(context);
  return [
    if (repository.supportsSourceManagement)
      SettingsGroup(
        title: l10n.sourceManagement,
        entries: [
          SettingsEntry(
            id: 'sources',
            icon: Icons.dns_outlined,
            title: l10n.sourceManagement,
            subtitle: l10n.sourceManageHint,
            onPressed: () => onNavigate(AppRoutes.sources),
          ),
        ],
      ),
    SettingsGroup(
      title: l10n.appearanceTheme,
      entries: [
        SettingsEntry(
          id: 'theme',
          icon: Icons.palette_outlined,
          title: l10n.appearanceTheme,
          subtitle: AppTheme.label(store.themeMode, l10n),
          onPressed: () => onNavigate(AppRoutes.settingsTheme),
        ),
      ],
    ),
    SettingsGroup(
      title: l10n.userManagement,
      entries: [
        SettingsEntry(
          id: 'profiles',
          icon: Icons.people_outline,
          title: l10n.userManagement,
          subtitle: l10n.currentProfile(store.profile.name),
          onPressed: () => onNavigate(AppRoutes.profiles),
        ),
      ],
    ),
    if (store.canDownload)
      SettingsGroup(
        title: l10n.downloadsTitle,
        entries: [
          SettingsEntry(
            id: 'download-preferences',
            icon: Icons.download_outlined,
            title: l10n.downloadPrefsTitle,
            subtitle: store.downloadPreferences.qualityLabel,
            onPressed: () => onNavigate(AppRoutes.downloadPreferences),
          ),
          SettingsEntry(
            id: 'storage',
            icon: Icons.folder_outlined,
            title: l10n.storageTitle,
            subtitle: l10n.storageEntryHint,
            onPressed: () => onNavigate(AppRoutes.storage),
          ),
        ],
      ),
    SettingsGroup(
      title: l10n.engineDiagnosticsEntry,
      entries: [
        SettingsEntry(
          id: 'diagnostics',
          icon: Icons.monitor_heart_outlined,
          title: l10n.engineDiagnosticsEntry,
          subtitle: l10n.engineDiagnosticsRuntime,
          onPressed: () => onNavigate(AppRoutes.engineDiagnostics),
        ),
      ],
    ),
    if (store.profile.admin)
      SettingsGroup(
        title: l10n.settingsAdvanced,
        entries: [
          if (repository.capabilities.resourceSettings)
            SettingsEntry(
              id: 'resources',
              icon: Icons.settings_ethernet_rounded,
              title: l10n.resourceSettingsTitle,
              subtitle: l10n.networkResourcesHint,
              onPressed: () => onNavigate(AppRoutes.resourceSettings),
            ),
        ],
      ),
  ];
}

class StorageScreen extends StatefulWidget {
  const StorageScreen({
    super.key,
    required this.repository,
    required this.store,
  });
  final AppRepository repository;
  final LocalStore store;
  @override
  State<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends State<StorageScreen> {
  late final StorageController _controller;

  @override
  void initState() {
    super.initState();
    _controller = StorageController(widget.repository);
    _controller.refresh();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _refresh() => _controller.refresh();

  Future<void> _move() async {
    final l10n = AppLocalizations.of(context);
    String? parent;
    if (Platform.isAndroid || Platform.isIOS) {
      final support = await getApplicationSupportDirectory();
      final directories = <String, String>{support.path: l10n.storageInternal};
      if (Platform.isAndroid) {
        final external = await getExternalStorageDirectories() ?? [];
        for (var i = 0; i < external.length; i++) {
          directories[external[i].path] = i == 0
              ? l10n.storageShared
              : l10n.storageSdCard(i + 1);
        }
      } else {
        final documents = await getApplicationDocumentsDirectory();
        directories[documents.path] = l10n.storageDocuments;
      }
      if (!mounted) return;
      parent = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text(l10n.storageChooseDirectory),
          children: [
            for (final entry in directories.entries)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, entry.key),
                child: Text(entry.value),
              ),
          ],
        ),
      );
    } else {
      parent = await FilePicker.getDirectoryPath(
        dialogTitle: l10n.storageChooseDirectory,
      );
    }
    if (parent == null || !mounted) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.storageMigrateTitle),
        content: Text(l10n.storageMigrateMessage(parent!)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.migrate),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    await _controller.move(parent);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => PopScope(
        canPop: !_controller.busy,
        child: Scaffold(
          appBar: AppBar(title: Text(l10n.storageTitle)),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: Md3Spacing.contentMaxWidth,
              ),
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  if (_controller.info != null) ...[
                    Text(
                      l10n.storageUsed(
                        storageSize(
                          (_controller.info!['bytes'] as num?)?.toInt() ?? 0,
                          l10n,
                        ),
                      ),
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.storageFree(
                        storageSize(
                          (_controller.info!['free'] as num?)?.toInt() ?? -1,
                          l10n,
                        ),
                        (_controller.info!['files'] as num?)?.toInt() ?? 0,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(l10n.storageCurrentDirectory),
                    const SizedBox(height: 8),
                    SelectableText(
                      _controller.info!['directory'] as String? ?? '',
                    ),
                    TextButton.icon(
                      onPressed: () => Clipboard.setData(
                        ClipboardData(
                          text: _controller.info!['directory'] as String? ?? '',
                        ),
                      ),
                      icon: const Icon(Icons.copy),
                      label: Text(l10n.copyPath),
                    ),
                    const SizedBox(height: 20),
                    Text(l10n.storageCleanupHint),
                  ],
                  if (_controller.busy ||
                      (_controller.info == null && _controller.error == null))
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 20),
                      child: LinearProgressIndicator(),
                    ),
                  if (_controller.busy) Text(l10n.storageMigrating),
                  if (_controller.error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(_controller.error!),
                    ),
                  if (widget.store.profile.admin)
                    FilledButton.icon(
                      onPressed: _controller.busy ? null : _move,
                      icon: const Icon(Icons.drive_file_move_outline),
                      label: Text(l10n.storageChangeDirectory),
                    ),
                  TextButton(
                    onPressed: _controller.busy ? null : _refresh,
                    child: Text(l10n.storageRefresh),
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
