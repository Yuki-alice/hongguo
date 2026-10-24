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
import 'package:hoshi/ui/core/app_page.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/ui/core/widgets.dart';
import 'package:hoshi/ui/core/split_list.dart';
import 'package:hoshi/domain/window_bounds.dart';
import 'package:hoshi/ui/theme/md3_tokens.dart';
import 'package:hoshi/ui/features/settings/controllers/settings_controller.dart';
import 'package:hoshi/ui/features/settings/controllers/storage_controller.dart';
import 'package:hoshi/ui/routing/app_router.dart';
import 'package:hoshi/ui/shell/window_chrome.dart';

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
  late final SettingsController _controller;

  /// 窄屏当前打开的分组；null 表示停留在分组索引页。
  String? _opened;
  String _selected = 'appearance';

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
      final accepted =
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

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([widget.store, _controller]),
    builder: (context, _) {
      final l10n = AppLocalizations.of(context);
      final sections = _sections(
        l10n,
      ).where((section) => section.title.isNotEmpty).toList();
      final wide = MediaQuery.sizeOf(context).width >= Md3WindowClass.expanded;
      final current = sections.firstWhere(
        (section) => section.id == _selected,
        orElse: () => sections.first,
      );
      // 与参照应用一致：窄屏是「设置索引 → 分组页」二级列表；宽屏左栏
      // 是分组导航，右栏只显示当前分组。
      if (wide) {
        return Scaffold(
          appBar: DesktopAppBar(
            title: Text(l10n.settingsNav),
            leading: BackButton(
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
          body: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 280,
                child: _SettingsRail(
                  sections: sections,
                  selected: current.id,
                  onSelected: (id) => setState(() => _selected = id),
                ),
              ),
              VerticalDivider(
                width: 1,
                thickness: 1,
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              Expanded(child: _CategoryList(section: current, embedded: true)),
            ],
          ),
        );
      }
      final opened = _opened == null
          ? null
          : sections.firstWhere(
              (section) => section.id == _opened,
              orElse: () => current,
            );
      if (opened != null) {
        return Scaffold(
          appBar: DesktopAppBar(
            title: Text(opened.title),
            leading: BackButton(
              onPressed: () => setState(() => _opened = null),
            ),
          ),
          body: _CategoryList(section: opened),
        );
      }
      return Scaffold(
        appBar: DesktopAppBar(title: Text(l10n.settingsTitle)),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(
            Md3Spacing.lg,
            Md3Spacing.sm,
            Md3Spacing.lg,
            Md3Spacing.xl,
          ),
          children: [
            SectionHeader(title: l10n.settingsTitle),
            const SizedBox(height: Md3Spacing.sm),
            SplitListGroup(
              children: [
                for (final section in sections)
                  SplitListRow(
                    key: ValueKey('settings-category-${section.id}'),
                    leading: section.icon,
                    title: section.title,
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => setState(() => _opened = section.id),
                  ),
              ],
            ),
          ],
        ),
      );
    },
  );

  /// 窄屏分组页。
  /// 桌面两栏的分组。每项自带图标与内容，左侧导航与右侧面板都由它生成。
  List<_SettingsSection> _sections(AppLocalizations l10n) => [
    _SettingsSection(
      id: 'resources',
      icon: Icons.extension_outlined,
      title: l10n.settingsResourceSection,
      children: [
        SplitListGroup(
          children: [
            if (widget.repository.supportsSourceManagement)
              SplitListRow(
                leading: Icons.dns_outlined,
                title: l10n.sourceManagement,
                description: l10n.sourceManageHint,
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => context.push(AppRoutes.sources),
              ),
            SplitListRow(
              leading: Icons.extension_outlined,
              title: l10n.pluginsManageTitle,
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => context.push(AppRoutes.plugins),
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

/// 桌面左栏：分组导航。
class _SettingsRail extends StatelessWidget {
  const _SettingsRail({
    required this.sections,
    required this.selected,
    required this.onSelected,
  });

  final List<_SettingsSection> sections;
  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(4, 0, 0, 12),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 16, 28, 8),
          child: SectionHeader(title: AppLocalizations.of(context).settingsNav),
        ),
        for (final section in sections)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            child: Material(
              color: section.id == selected
                  ? colors.secondaryContainer
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(Md3Shape.extraLarge),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => onSelected(section.id),
                child: SizedBox(
                  height: 56,
                  child: Row(
                    children: [
                      const SizedBox(width: Md3Spacing.md),
                      Icon(
                        section.icon,
                        size: 24,
                        color: section.id == selected
                            ? colors.onSecondaryContainer
                            : colors.onSurfaceVariant,
                      ),
                      const SizedBox(width: Md3Spacing.md),
                      Expanded(
                        child: Text(
                          section.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: Md3Type.labelLarge,
                            fontWeight: section.id == selected
                                ? FontWeight.w700
                                : FontWeight.w400,
                            color: section.id == selected
                                ? colors.onSecondaryContainer
                                : colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 分组页内容（宽屏右栏 / 窄屏二级页共用）。
class _CategoryList extends StatelessWidget {
  const _CategoryList({required this.section, this.embedded = false});

  final _SettingsSection section;

  /// 宽屏右栏：标题画在内容里（参照应用 `SettingsDetailScaffold` 的嵌入
  /// AppBar：透明、64 高、标题 `headlineSmall`、左边距 24）。窄屏由外层
  /// AppBar 承担标题，这里不再重复。
  final bool embedded;

  @override
  Widget build(BuildContext context) => AppPage(
    vertical: Md3Spacing.md,
    child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.only(bottom: Md3Spacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (embedded)
              Padding(
                padding: const EdgeInsets.only(left: 8, bottom: Md3Spacing.sm),
                child: SizedBox(
                  height: 64,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      section.title,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                ),
              ),
            ...section.children,
          ],
        ),
      ),
    ),
  );
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
          appBar: DesktopAppBar(title: Text(l10n.storageTitle)),
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
