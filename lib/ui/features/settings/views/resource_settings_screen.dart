import 'package:flutter/material.dart';

import 'package:duanju_app/data/core_bridge.dart';
import 'package:duanju_app/domain/download_preferences.dart';
import 'package:duanju_app/l10n/generated/app_localizations.dart';
import 'package:duanju_app/data/local_store.dart';
import 'package:duanju_app/ui/core/remote_widgets.dart';
import 'package:duanju_app/ui/features/settings/controllers/resource_settings_controller.dart';
import 'package:duanju_app/ui/core/widgets.dart';

class DownloadPreferencesScreen extends StatelessWidget {
  const DownloadPreferencesScreen({super.key, required this.store});
  final LocalStore store;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: store,
    builder: (context, _) {
      final l10n = AppLocalizations.of(context);
      final preferences = store.downloadPreferences;
      return Scaffold(
        appBar: AppBar(title: Text(l10n.downloadPrefsTitle)),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                ListTile(
                  title: Text(l10n.defaultQuality),
                  subtitle: Text(l10n.defaultQualityHint),
                ),
                DropdownButtonFormField<int>(
                  initialValue: preferences.quality,
                  decoration: InputDecoration(labelText: l10n.downloadQuality),
                  items: [
                    for (final value in DownloadPreferences.qualities)
                      DropdownMenuItem(
                        value: value,
                        child: Text(
                          value == 0 ? l10n.autoHighPriority : '${value}P',
                        ),
                      ),
                  ],
                  onChanged: !store.canDownload
                      ? null
                      : (value) {
                          if (value != null) {
                            saveUserChange(
                              context,
                              () => store.setDownloadPreferences(
                                preferences.copyWith(quality: value),
                              ),
                            );
                          }
                        },
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  value: preferences.includeVip,
                  title: Text(l10n.includeVipDefault),
                  subtitle: Text(l10n.includeVipHint),
                  onChanged: !store.canDownload
                      ? null
                      : (value) => saveUserChange(
                          context,
                          () => store.setDownloadPreferences(
                            preferences.copyWith(includeVip: value),
                          ),
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(l10n.prefsSavedHint),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class ResourceSettingsScreen extends StatefulWidget {
  const ResourceSettingsScreen({
    super.key,
    required this.repository,
    required this.store,
  });
  final AppRepository repository;
  final LocalStore store;
  @override
  State<ResourceSettingsScreen> createState() => _ResourceSettingsScreenState();
}

class _ResourceSettingsScreenState extends State<ResourceSettingsScreen> {
  final _proxy = TextEditingController();
  late final ResourceSettingsController _controller;
  bool _showProxy = false;

  @override
  void initState() {
    super.initState();
    _controller = ResourceSettingsController(
      repository: widget.repository,
      store: widget.store,
      profileEpoch: widget.store.profileEpoch,
    );
    ensureTelevisionFocus(context);
    _load();
  }

  @override
  void dispose() {
    _proxy.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    await _controller.load();
    if (mounted && _controller.settings != null) {
      _proxy.text = _controller.settings!.proxyUrl;
    }
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    final saved = await _controller.save(proxyUrl: _proxy.text);
    if (saved && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.settingsSaved)));
    }
  }

  Widget _count(String title, int value, ValueChanged<int> change) =>
      DropdownButtonFormField<int>(
        initialValue: value,
        decoration: InputDecoration(labelText: title),
        items: [
          for (var i = 1; i <= 6; i++)
            DropdownMenuItem(value: i, child: Text('$i')),
        ],
        onChanged: _controller.busy
            ? null
            : (value) {
                if (value != null) change(value);
              },
      );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      final l10n = AppLocalizations.of(context);
      return Scaffold(
        appBar: AppBar(
          title: Text(l10n.resourceSettingsTitle),
          actions: [
            TextButton(
              onPressed:
                  _controller.busy ||
                      _controller.settings == null ||
                      !_controller.allowed
                  ? null
                  : _save,
              child: Text(l10n.save),
            ),
          ],
        ),
        body: !_controller.allowed
            ? StatusPanel(
                title: l10n.adminRequired,
                message: l10n.switchToAdmin,
              )
            : _controller.settings == null
            ? _controller.error == null
                  ? const Center(child: CircularProgressIndicator())
                  : StatusPanel(
                      title: l10n.settingsReadFailed,
                      message: _controller.error!,
                      onRetry: _load,
                    )
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      if (_controller.busy) const LinearProgressIndicator(),
                      if (_controller.settings!.warning.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: Text(_controller.settings!.warning),
                        ),
                      DropdownButtonFormField<String>(
                        initialValue: _controller.mode,
                        decoration: InputDecoration(
                          labelText: l10n.connectionMode,
                        ),
                        items: [
                          DropdownMenuItem(
                            value: 'auto',
                            child: Text(l10n.proxyAuto),
                          ),
                          DropdownMenuItem(
                            value: 'direct',
                            child: Text(l10n.proxyDirect),
                          ),
                          DropdownMenuItem(
                            value: 'manual',
                            child: Text(l10n.proxyManual),
                          ),
                        ],
                        onChanged: _controller.busy
                            ? null
                            : (value) => _controller.setMode(value ?? 'auto'),
                      ),
                      if (_controller.mode == 'auto')
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(
                            _controller.settings!.systemProxyStatus.isEmpty
                                ? l10n.systemProxyHint
                                : _controller.settings!.systemProxyStatus,
                          ),
                        ),
                      if (_controller.mode == 'manual')
                        Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: TextField(
                            controller: _proxy,
                            obscureText: !_showProxy,
                            enableSuggestions: false,
                            autocorrect: false,
                            decoration: InputDecoration(
                              labelText: l10n.proxyAddress,
                              hintText: 'http://127.0.0.1:7890',
                              helperText: l10n.proxyHint,
                              helperMaxLines: 3,
                              suffixIcon: IconButton(
                                tooltip: _showProxy
                                    ? l10n.hideProxy
                                    : l10n.showProxy,
                                onPressed: () =>
                                    setState(() => _showProxy = !_showProxy),
                                icon: Icon(
                                  _showProxy
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                ),
                              ),
                            ),
                          ),
                        ),
                      const SizedBox(height: 28),
                      _count(
                        l10n.catalogConcurrency,
                        _controller.catalog,
                        _controller.setCatalog,
                      ),
                      const SizedBox(height: 16),
                      Text(l10n.catalogInterval(_controller.interval)),
                      Slider(
                        value: _controller.interval.toDouble(),
                        min: 0,
                        max: 5000,
                        divisions: 100,
                        label: l10n.intervalMs(_controller.interval),
                        onChanged: _controller.busy
                            ? null
                            : (value) => _controller.setInterval(value.round()),
                      ),
                      const SizedBox(height: 16),
                      _count(
                        l10n.downloadConcurrency,
                        _controller.downloads,
                        _controller.setDownloads,
                      ),
                      const SizedBox(height: 12),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _controller.folders,
                        title: Text(l10n.downloadBySource),
                        subtitle: Text(l10n.downloadBySourceHint),
                        onChanged: _controller.busy
                            ? null
                            : (value) => _controller.setFolders(value),
                      ),
                      if (_controller.error != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(
                            _controller.error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
      );
    },
  );
}
