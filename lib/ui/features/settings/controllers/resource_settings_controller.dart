import 'package:flutter/foundation.dart';

import 'package:duanju_app/data/core_bridge.dart';
import 'package:duanju_app/data/local_store.dart';
import 'package:duanju_app/domain/resource_settings.dart';

/// 网络与资源设置的表单与保存状态。
class ResourceSettingsController extends ChangeNotifier {
  ResourceSettingsController({
    required this.repository,
    required this.store,
    required this.profileEpoch,
  });

  final AppRepository repository;
  final LocalStore store;
  final int profileEpoch;

  ResourceSettings? _settings;
  String _mode = 'auto';
  int _catalog = 3;
  int _interval = 250;
  int _downloads = 2;
  bool _folders = false;
  bool _busy = false;
  String? _error;
  bool _disposed = false;

  ResourceSettings? get settings => _settings;
  String get mode => _mode;
  int get catalog => _catalog;
  int get interval => _interval;
  int get downloads => _downloads;
  bool get folders => _folders;
  bool get busy => _busy;
  String? get error => _error;
  bool get allowed =>
      store.profileEpoch == profileEpoch &&
      !store.locked &&
      store.profile.admin;

  Future<void> load() async {
    try {
      final settings = await repository.resourceSettings();
      if (_disposed || !allowed) return;
      _settings = settings;
      _mode = settings.proxyMode;
      _catalog = settings.catalogConcurrency;
      _interval = settings.catalogIntervalMs;
      _downloads = settings.downloadConcurrency;
      _folders = settings.downloadBySource;
      _error = null;
    } catch (error) {
      if (_disposed) return;
      _error = error.toString();
    }
    _notify();
  }

  Future<bool> save({required String proxyUrl}) async {
    if (_busy || _disposed || !allowed) return false;
    _busy = true;
    _error = null;
    _notify();
    try {
      final settings = await repository.saveResourceSettings(
        ResourceSettings(
          proxyMode: _mode,
          proxyUrl: proxyUrl.trim(),
          catalogConcurrency: _catalog,
          catalogIntervalMs: _interval,
          downloadConcurrency: _downloads,
          downloadBySource: _folders,
        ),
      );
      if (_disposed || !allowed) return false;
      _settings = settings;
      return true;
    } catch (error) {
      if (_disposed) return false;
      _error = error.toString();
      return false;
    } finally {
      _busy = false;
      _notify();
    }
  }

  void setMode(String value) => _set(() => _mode = value);
  void setCatalog(int value) => _set(() => _catalog = value);
  void setInterval(int value) => _set(() => _interval = value);
  void setDownloads(int value) => _set(() => _downloads = value);
  void setFolders(bool value) => _set(() => _folders = value);

  void _set(VoidCallback update) {
    update();
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
