import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:duanju_app/data/plugin_repository.dart';
import 'package:duanju_app/domain/models.dart';

/// 插件管理页的状态与动作。
///
/// 刻意不持有网络：仓库拉取与包下载在引擎侧完成（`installFromRepo`），
/// 这里只负责「发起 → 等待 → 刷新列表 → 报错」这条 UI 链路。
class PluginsController extends ChangeNotifier {
  PluginsController({required this.repository});

  final PluginRepository repository;

  final _installed = <PluginEntry>[];
  final _available = <PluginEntry>[];
  final _errors = <String, String>{};
  final _busy = <String>{};
  bool _loading = false;
  bool _disposed = false;

  List<PluginEntry> get installed => List.unmodifiable(_installed);
  List<PluginEntry> get available => List.unmodifiable(_available);
  bool get loading => _loading;
  String? errorOf(String id) => _errors[id];
  bool busy(String id) => _busy.contains(id);

  /// 是否有新版本可装（同 id 的仓库版本高于已装版本）。
  ///
  /// 只在 `loadRepository` 之后才有意义：仓库条目本身不带「本地版本」，
  /// 必须与 `_installed` 交叉比对。UI 侧应在载入仓库前后都调用 `refresh()`，
  /// 否则同 id 的更新会被误判成「未安装」。
  bool hasUpdate(PluginEntry entry) {
    final local = _installed.where((item) => item.id == entry.id);
    if (local.isEmpty) return false;
    return _compareVersion(entry.version, local.first.version) > 0;
  }

  Future<void> refresh() async {
    if (_disposed) return;
    _loading = true;
    _notify();
    try {
      _installed
        ..clear()
        ..addAll(await repository.installed());
    } finally {
      _loading = false;
      _notify();
    }
  }

  /// 拉取仓库可安装列表。`repoUrl` 是 `repo.toml` 的地址。
  Future<void> loadRepository(String repoUrl) async {
    _busy.add('repo:$repoUrl');
    _notify();
    try {
      final entries = await repository.listRepository(repoUrl);
      _available
        ..clear()
        ..addAll(entries);
      _errors.remove('repo:$repoUrl');
    } catch (error) {
      _errors['repo:$repoUrl'] = _describe(error);
    } finally {
      _busy.remove('repo:$repoUrl');
      _notify();
    }
  }

  /// 从仓库安装一个插件。
  Future<bool> install(PluginEntry entry, {String? repoUrl}) async {
    if (repoUrl == null) return false;
    _busy.add(entry.id);
    _notify();
    try {
      await repository.installFromRepo(
        repoUrl: repoUrl,
        pluginId: entry.id,
        repoId: 'official',
      );
      _errors.remove(entry.id);
      await refresh();
      return true;
    } catch (error) {
      _errors[entry.id] = _describe(error);
      return false;
    } finally {
      _busy.remove(entry.id);
      _notify();
    }
  }

  Future<void> uninstall(String pluginId) async {
    _busy.add(pluginId);
    _notify();
    try {
      await repository.uninstall(pluginId);
      SourceSite.clearReported();
      await refresh();
      await _syncSources();
    } catch (error) {
      _errors[pluginId] = _describe(error);
    } finally {
      _busy.remove(pluginId);
      _notify();
    }
  }

  Future<void> setEnabled(String pluginId, bool enabled) async {
    _busy.add(pluginId);
    _notify();
    try {
      await repository.setEnabled(pluginId, enabled);
      await refresh();
    } catch (error) {
      _errors[pluginId] = _describe(error);
    } finally {
      _busy.remove(pluginId);
      _notify();
    }
  }

  Future<void> rollback(PluginEntry entry, String version) async {
    _busy.add(entry.id);
    _notify();
    try {
      await repository.rollback(entry.id, version);
      await refresh();
    } catch (error) {
      _errors[entry.id] = _describe(error);
    } finally {
      _busy.remove(entry.id);
      _notify();
    }
  }

  /// 安装/卸载后把站源清单同步回 `SourceSite`，让站源页立刻反映变化。
  Future<void> _syncSources() async {
    // 引擎侧注册表在下次 `sourceCatalog()` 时重建，因此这里只要把
    // 已知的插件 id 登记为可用站源即可。
    SourceSite.reportFromEngine(
      _installed
          .where((plugin) => plugin.enabled)
          .map((plugin) => (id: plugin.id, name: plugin.name, group: 'duanju')),
    );
  }

  String _describe(Object error) {
    final text = error.toString();
    return text.length > 200 ? '${text.substring(0, 200)}…' : text;
  }

  /// 语义化版本比较：只比较数字段，够用且不引入依赖。
  static int _compareVersion(String left, String right) {
    List<int> parts(String value) => value
        .split(RegExp(r'[.+-]'))
        .map((part) => int.tryParse(part) ?? 0)
        .toList();
    final a = parts(left);
    final b = parts(right);
    for (var index = 0; index < 3; index++) {
      final x = index < a.length ? a[index] : 0;
      final y = index < b.length ? b[index] : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
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
