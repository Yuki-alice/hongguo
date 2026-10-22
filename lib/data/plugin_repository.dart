import 'package:flutter/foundation.dart';

import 'package:hoshi/domain/models.dart';
import 'package:hoshi/src/rust/api.dart' as api;
import 'package:hoshi/src/rust/api/plugins.dart' as rust;
import 'package:hoshi/src/rust/frb_generated.dart';

/// 插件仓库与安装结果，映射自引擎的 [rust.PluginSummary] / [rust.RepoSummary]。
class PluginEntry {
  const PluginEntry({
    required this.id,
    required this.name,
    required this.version,
    required this.kind,
    required this.installed,
    required this.enabled,
    required this.signed,
  });

  final String id;
  final String name;
  final String version;

  /// `declarative` 或 `component`。
  final String kind;
  final bool installed;
  final bool enabled;

  /// 来源仓库是否签名（未签名仓库每次升级都要用户确认）。
  final bool signed;

  bool get isCode => kind == 'component';

  PluginEntry copyWith({bool? installed, bool? enabled}) => PluginEntry(
    id: id,
    name: name,
    version: version,
    kind: kind,
    installed: installed ?? this.installed,
    enabled: enabled ?? this.enabled,
    signed: signed,
  );
}

/// 仓库摘要。
class RepoEntry {
  const RepoEntry({
    required this.id,
    required this.name,
    required this.index,
    required this.signed,
    required this.fingerprint,
  });

  final String id;
  final String name;
  final String index;
  final bool signed;
  final String fingerprint;
}

/// 插件管理的 Dart 侧入口。
///
/// 这里只做「字节与结构」的搬运：网络下载由调用方负责，引擎负责校验、
/// 解包与落盘。这样在离线测试里也能完整驱动安装流程。
class PluginRepository {
  PluginRepository({this.initialized = false});

  bool initialized;

  static Future<PluginRepository> create() async {
    await RustLib.init();
    return PluginRepository(initialized: true);
  }

  /// 解析 `repo.toml`。失败抛出带原因的异常，供 UI 直接展示。
  Future<RepoEntry> parseRepository(String text) async {
    final repo = await rust.parseRepository(text: text);
    return RepoEntry(
      id: repo.id,
      name: repo.name,
      index: repo.index,
      signed: repo.signed,
      fingerprint: repo.fingerprint,
    );
  }

  /// 解析 `index.json`，返回可安装条目。
  Future<List<PluginEntry>> parseIndex(String text) async {
    final entries = await rust.parseRepositoryIndex(text: text);
    return [for (final entry in entries) _fromSummary(entry)];
  }

  /// 已安装插件。未初始化时返回空列表，避免启动期抛异常。
  Future<List<PluginEntry>> installed() async {
    if (!initialized) return const [];
    try {
      final entries = await rust.installedPlugins();
      return [for (final entry in entries) _fromSummary(entry)];
    } catch (error) {
      debugPrint('读取已安装插件失败：$error');
      return const [];
    }
  }

  /// 安装已下载的包。`archive` 是 zip 原始字节。
  Future<PluginEntry> install({
    required String indexJson,
    required String pluginId,
    required String version,
    required String repoId,
    required bool repoSigned,
    required List<int> archive,
  }) async {
    final entry = await rust.installPlugin(
      indexJson: indexJson,
      pluginId: pluginId,
      version: version,
      repoId: repoId,
      repoSigned: repoSigned,
      archive: archive,
    );
    return _fromSummary(entry);
  }

  /// 列出仓库里可安装的插件（需要网络）。
  Future<List<PluginEntry>> listRepository(String repoUrl) async {
    final entries = await rust.listRepoPlugins(repoUrl: repoUrl);
    return [for (final entry in entries) _fromSummary(entry)];
  }

  /// 从仓库完整安装：引擎内部拉清单 → 索引 → 包并校验后落盘。
  Future<PluginEntry> installFromRepo({
    required String repoUrl,
    required String pluginId,
    required String repoId,
  }) async {
    final entry = await rust.installFromRepo(
      repoUrl: repoUrl,
      pluginId: pluginId,
      repoId: repoId,
      repoSigned: false,
    );
    return _fromSummary(entry);
  }

  /// 卸载。返回是否真的移除了内容。
  Future<bool> uninstall(String pluginId) async {
    if (!initialized) return false;
    return rust.uninstallPlugin(pluginId: pluginId);
  }

  Future<void> setEnabled(String pluginId, bool enabled) async {
    if (!initialized) return;
    await rust.setPluginEnabled(pluginId: pluginId, enabled: enabled);
  }

  /// 回滚到上一个版本。
  Future<void> rollback(String pluginId, String version) async {
    if (!initialized) return;
    await rust.rollbackPlugin(pluginId: pluginId, version: version);
  }

  /// 记录仓库，返回指纹是否发生变化。
  ///
  /// 变化时必须由 UI 提示用户重新确认，不能自动接受（防止仓库被掉包）。
  Future<bool> rememberRepository({
    required String repoId,
    required String url,
    required String publicKey,
  }) async {
    if (!initialized) return false;
    return rust.rememberRepository(
      repoId: repoId,
      url: url,
      publicKey: publicKey,
    );
  }

  /// 重建引擎注册表。安装 / 卸载 / 启停 / 回滚之后必须调用，
  /// 否则站源清单仍是旧快照。会话、缓存与下载任务不受影响。
  Future<int> reloadSources() async {
    if (!initialized) return 0;
    return api.reloadSources();
  }

  /// 读取引擎当前的站源清单并写回 `SourceSite`。
  Future<int> syncSourceCatalog() async {
    if (!initialized) return 0;
    final catalog = await api.sourceCatalog();
    SourceSite.reportFromEngine(
      catalog.map((site) => (id: site.id, name: site.name, group: site.group)),
    );
    return catalog.length;
  }

  PluginEntry _fromSummary(api.PluginSummary summary) => PluginEntry(
    id: summary.id,
    name: summary.name,
    version: summary.version,
    kind: summary.kind,
    installed: summary.installed,
    enabled: summary.enabled,
    signed: summary.signed,
  );
}
