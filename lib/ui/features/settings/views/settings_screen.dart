import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';

import 'package:duanju_app/data/core_bridge.dart';
import 'package:duanju_app/l10n/generated/app_localizations.dart';
import 'package:duanju_app/ui/core/app_theme.dart';
import 'package:duanju_app/ui/core/app_layout.dart';
import 'package:duanju_app/data/local_store.dart';
import 'package:duanju_app/ui/core/remote_widgets.dart';
import 'package:duanju_app/ui/core/widgets.dart';
import 'package:duanju_app/ui/features/lan/views/lan_screen.dart';
import 'package:duanju_app/ui/features/settings/controllers/settings_controller.dart';
import 'package:duanju_app/ui/features/settings/controllers/storage_controller.dart';
import 'package:duanju_app/ui/routing/app_router.dart';

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
    // 局域网互联当前不提供（PLAN.md §5），入口按能力矩阵隐藏。
    if (widget.repository.capabilities.lan)
      (
        id: 'lan',
        icon: Icons.devices_rounded,
        title: l10n.deviceInterop,
        subtitle: l10n.lanAutoSyncHint,
        onPressed: () => openLanSync(context),
      ),
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
      return Scaffold(
        appBar: AppBar(title: Text(l10n.settingsTitle)),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: AppLayout.isTelevision(context)
                ? Builder(
                    builder: (_) {
                      final entries = _televisionEntries(l10n);
                      return RemoteList(
                        key: _listKey,
                        itemKeys: [for (final entry in entries) entry.id],
                        itemExtent: RemoteListTile.extent,
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                        autofocus: true,
                        itemBuilder: (_, index, node, onFocus) =>
                            RemoteListTile(
                              title: entries[index].title,
                              subtitle: entries[index].subtitle,
                              leading: Icon(entries[index].icon, size: 26),
                              focusNode: node,
                              onFocus: onFocus,
                              onPressed: entries[index].onPressed,
                            ),
                      );
                    },
                  )
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (widget.repository.capabilities.lan)
                        ListTile(
                          key: const ValueKey('lan-settings'),
                          leading: const Icon(Icons.devices_rounded),
                          title: Text(l10n.deviceInterop),
                          subtitle: Text(l10n.lanAutoSyncHint),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => openLanSync(context),
                        ),
                      if (widget.repository.supportsSourceManagement)
                        ListTile(
                          leading: const Icon(Icons.dns_outlined),
                          title: Text(l10n.sourceManagement),
                          subtitle: Text(l10n.sourceManageHint),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => context.push(AppRoutes.sources),
                        ),
                      ListTile(
                        key: const ValueKey('theme-setting'),
                        leading: const Icon(Icons.palette_outlined),
                        title: Text(l10n.appearanceTheme),
                        subtitle: Text(
                          AppTheme.label(widget.store.themeMode, l10n),
                        ),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: _chooseTheme,
                      ),
                      ListTile(
                        leading: const Icon(Icons.people_outline),
                        title: Text(l10n.userManagement),
                        subtitle: Text(
                          l10n.currentProfile(widget.store.profile.name),
                        ),
                        onTap: () => context.push(AppRoutes.profiles),
                      ),
                      if (widget.store.canDownload)
                        ListTile(
                          leading: const Icon(Icons.download_outlined),
                          title: Text(l10n.downloadPrefsTitle),
                          subtitle: Text(
                            widget.store.downloadPreferences.qualityLabel,
                          ),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () =>
                              context.push(AppRoutes.downloadPreferences),
                        ),
                      if (widget.store.canDownload)
                        ListTile(
                          leading: const Icon(Icons.folder_outlined),
                          title: Text(l10n.storageTitle),
                          subtitle: Text(l10n.storageEntryHint),
                          onTap: () => context.push(AppRoutes.storage),
                        ),
                      ListTile(
                        key: const ValueKey('engine-diagnostics-settings'),
                        leading: const Icon(Icons.monitor_heart_outlined),
                        title: Text(l10n.engineDiagnosticsEntry),
                        subtitle: Text(l10n.engineDiagnosticsRuntime),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => context.push(AppRoutes.engineDiagnostics),
                      ),
                      if (widget.store.profile.admin) ...[
                        if (widget.repository.capabilities.resourceSettings)
                          ListTile(
                            leading: const Icon(
                              Icons.settings_ethernet_rounded,
                            ),
                            title: Text(l10n.resourceSettingsTitle),
                            subtitle: Text(l10n.networkResourcesHint),
                            trailing: const Icon(Icons.chevron_right_rounded),
                            onTap: () =>
                                context.push(AppRoutes.resourceSettings),
                          ),
                        SwitchListTile(
                          value: widget.store.autoExport,
                          title: Text(l10n.autoExportEmby),
                          subtitle: Text(l10n.autoExportHint),
                          onChanged: _controller.busy
                              ? null
                              : _controller.setAutoExport,
                        ),
                        SwitchListTile(
                          value: widget.store.exportPosters,
                          title: Text(l10n.exportPostersTogether),
                          subtitle: Text(l10n.exportPostersHint),
                          onChanged: _controller.busy
                              ? null
                              : (value) => saveUserChange(
                                  context,
                                  () => widget.store.setExportPosters(value),
                                ),
                        ),
                        ListTile(
                          leading: const Icon(Icons.backup_outlined),
                          title: Text(l10n.exportBackupTitle),
                          subtitle: Text(l10n.exportBackupHint),
                          onTap: _controller.busy ? null : () => _backup(false),
                        ),
                        ListTile(
                          leading: const Icon(Icons.restore),
                          title: Text(l10n.restoreBackupTitle),
                          onTap: _controller.busy ? null : () => _backup(true),
                        ),
                      ],
                      if (Platform.isIOS)
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(l10n.iosForegroundHint),
                        ),
                      if (_controller.busy) const LinearProgressIndicator(),
                      if (_controller.message != null)
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: SelectableText(_controller.message!),
                        ),
                    ],
                  ),
          ),
        ),
      );
    },
  );
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
              constraints: const BoxConstraints(maxWidth: 720),
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
