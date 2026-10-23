import 'package:flutter/material.dart';

import 'package:hoshi/data/plugin_repository.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/features/plugins/controllers/plugins_controller.dart';
import 'package:hoshi/ui/theme/md3_tokens.dart';

/// 插件仓库管理页。
///
/// 与站源管理页的分工：站源页看「当前能用什么」，这里管「从哪装、装哪个版本」。
class PluginsScreen extends StatefulWidget {
  const PluginsScreen({super.key, required this.repository});

  final PluginRepository repository;

  @override
  State<PluginsScreen> createState() => _PluginsScreenState();
}

class _PluginsScreenState extends State<PluginsScreen> {
  late final PluginsController _controller;
  final _repoField = TextEditingController(
    text: 'https://raw.githubusercontent.com/guoapp-rules/repo/main/repo.toml',
  );

  @override
  void initState() {
    super.initState();
    _controller = PluginsController(repository: widget.repository);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller.refresh();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _repoField.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: Text(l10n.pluginsTitle),
            actions: [
              IconButton(
                tooltip: l10n.pluginsRefresh,
                onPressed: _controller.loading ? null : _controller.refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: Md3Spacing.contentMaxWidth),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(l10n.pluginsIntro),
                  ),
                  _repoSection(l10n),
                  const SizedBox(height: 24),
                  Text(
                    l10n.pluginsInstalled,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  if (_controller.installed.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(l10n.pluginsEmpty),
                    )
                  else
                    for (final entry in _controller.installed)
                      _installedCard(entry, l10n),
                  if (_controller.available.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Text(
                      l10n.pluginsAvailable,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    for (final entry in _controller.available)
                      _availableCard(entry, l10n),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _repoSection(AppLocalizations l10n) {
    final repoKey = 'repo:${_repoField.text.trim()}';
    final busy = _controller.busy(repoKey);
    final error = _controller.errorOf(repoKey);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.pluginsRepoSection),
            const SizedBox(height: 8),
            TextField(
              controller: _repoField,
              decoration: InputDecoration(
                labelText: l10n.pluginsRepoUrl,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: busy
                      ? null
                      : () =>
                            _controller.loadRepository(_repoField.text.trim()),
                  icon: const Icon(Icons.cloud_download_outlined),
                  label: Text(l10n.pluginsLoadRepo),
                ),
                const SizedBox(width: 12),
                if (busy)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _installedCard(PluginEntry entry, AppLocalizations l10n) {
    final busy = _controller.busy(entry.id);
    final error = _controller.errorOf(entry.id);
    return Card(
      child: ListTile(
        title: Text(entry.name),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.pluginsVersionLine(
                entry.version,
                entry.isCode
                    ? l10n.pluginsKindCode
                    : l10n.pluginsKindDeclarative,
                entry.signed ? l10n.pluginsSigned : l10n.pluginsUnsigned,
              ),
            ),
            if (error != null)
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
        trailing: busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Switch(
                    value: entry.enabled,
                    onChanged: (value) =>
                        _controller.setEnabled(entry.id, value),
                  ),
                  IconButton(
                    tooltip: l10n.pluginsUninstall,
                    onPressed: () => _confirmUninstall(entry, l10n),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _availableCard(PluginEntry entry, AppLocalizations l10n) {
    final busy = _controller.busy(entry.id);
    final update = _controller.hasUpdate(entry);
    final installed = _controller.installed.any((item) => item.id == entry.id);
    return Card(
      child: ListTile(
        title: Text(entry.name),
        subtitle: Text(
          l10n.pluginsVersionLine(
            entry.version,
            entry.isCode ? l10n.pluginsKindCode : l10n.pluginsKindDeclarative,
            entry.signed ? l10n.pluginsSigned : l10n.pluginsUnsigned,
          ),
        ),
        trailing: busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : TextButton(
                onPressed: installed && !update ? null : () => _install(entry),
                child: Text(
                  update
                      ? l10n.pluginsUpdate
                      : installed
                      ? l10n.pluginsInstalledAction
                      : l10n.pluginsInstall,
                ),
              ),
      ),
    );
  }

  Future<void> _install(PluginEntry entry) async {
    final ok = await _controller.install(
      entry,
      repoUrl: _repoField.text.trim(),
    );
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? l10n.pluginsInstalledDone(entry.name)
              : l10n.pluginsInstallFailed,
        ),
      ),
    );
  }

  Future<void> _confirmUninstall(
    PluginEntry entry,
    AppLocalizations l10n,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.pluginsUninstall),
        content: Text(l10n.pluginsUninstallConfirm(entry.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.pluginsUninstall),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _controller.uninstall(entry.id);
    }
  }
}
