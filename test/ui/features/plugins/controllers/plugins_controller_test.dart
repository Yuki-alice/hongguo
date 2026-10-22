import 'package:flutter_test/flutter_test.dart';

import 'package:hoshi/data/plugin_repository.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/ui/features/plugins/controllers/plugins_controller.dart';

/// 记录调用的假插件仓库。
class FakePluginRepository extends PluginRepository {
  FakePluginRepository({
    this.installedEntries = const [],
    this.repoEntries = const [],
    this.failInstall = false,
    this.failList = false,
  });

  List<PluginEntry> installedEntries;
  List<PluginEntry> repoEntries;
  bool failInstall;
  bool failList;

  final List<String> calls = [];
  String? lastRepoUrl;
  String? lastPluginId;

  @override
  Future<List<PluginEntry>> installed() async => installedEntries;

  @override
  Future<List<PluginEntry>> listRepository(String repoUrl) async {
    calls.add('list:$repoUrl');
    lastRepoUrl = repoUrl;
    if (failList) throw StateError('仓库不可用');
    return repoEntries;
  }

  @override
  Future<PluginEntry> installFromRepo({
    required String repoUrl,
    required String pluginId,
    required String repoId,
  }) async {
    calls.add('install:$pluginId');
    lastPluginId = pluginId;
    if (failInstall) throw StateError('包哈希校验失败');
    final entry = repoEntries.firstWhere((item) => item.id == pluginId);
    installedEntries = [...installedEntries, entry.copyWith(installed: true)];
    return entry;
  }

  @override
  Future<bool> uninstall(String pluginId) async {
    calls.add('uninstall:$pluginId');
    installedEntries = installedEntries
        .where((item) => item.id != pluginId)
        .toList();
    return true;
  }

  @override
  Future<void> setEnabled(String pluginId, bool enabled) async {
    calls.add('enable:$pluginId=$enabled');
    installedEntries = [
      for (final item in installedEntries)
        if (item.id == pluginId) item.copyWith(enabled: enabled) else item,
    ];
  }

  @override
  Future<void> rollback(String pluginId, String version) async {
    calls.add('rollback:$pluginId=$version');
  }
}

PluginEntry entry(
  String id,
  String version, {
  bool enabled = true,
  String kind = 'declarative',
}) => PluginEntry(
  id: id,
  name: id,
  version: version,
  kind: kind,
  installed: false,
  enabled: enabled,
  signed: false,
);

void main() {
  group('版本比较', () {
    test('识别仓库版本高于本地', () async {
      final repo = FakePluginRepository(
        installedEntries: [entry('guo.a', '1.0.0')],
        repoEntries: [entry('guo.a', '1.2.0')],
      );
      final controller = PluginsController(repository: repo);
      addTearDown(controller.dispose);
      await controller.refresh();
      expect(controller.hasUpdate(entry('guo.a', '1.2.0')), isTrue);
      expect(controller.hasUpdate(entry('guo.a', '1.0.0')), isFalse);
      expect(controller.hasUpdate(entry('guo.a', '0.9.0')), isFalse);
    });

    test('未安装的插件不提示更新', () {
      final repo = FakePluginRepository(repoEntries: [entry('guo.a', '2.0.0')]);
      final controller = PluginsController(repository: repo);
      addTearDown(controller.dispose);
      expect(controller.hasUpdate(entry('guo.a', '2.0.0')), isFalse);
    });

    test('多段版本号按数字比较而不是字符串', () async {
      final repo = FakePluginRepository(
        installedEntries: [entry('guo.a', '1.9.0')],
        repoEntries: [entry('guo.a', '1.10.0')],
      );
      final controller = PluginsController(repository: repo);
      addTearDown(controller.dispose);
      await controller.refresh();
      // 字符串比较会认为 "1.9.0" > "1.10.0"，这里必须相反。
      expect(controller.hasUpdate(entry('guo.a', '1.10.0')), isTrue);
    });
  });

  group('仓库与安装', () {
    test('载入仓库后暴露可安装列表', () async {
      final repo = FakePluginRepository(
        repoEntries: [entry('guo.a', '1.0.0'), entry('guo.b', '2.0.0')],
      );
      final controller = PluginsController(repository: repo);
      addTearDown(controller.dispose);
      await controller.loadRepository('https://repo.test/repo.toml');
      expect(controller.available.map((e) => e.id), ['guo.a', 'guo.b']);
      expect(repo.lastRepoUrl, 'https://repo.test/repo.toml');
      expect(controller.errorOf('repo:https://repo.test/repo.toml'), isNull);
    });

    test('仓库不可用时记录错误且不崩溃', () async {
      final repo = FakePluginRepository(failList: true);
      final controller = PluginsController(repository: repo);
      addTearDown(controller.dispose);
      await controller.loadRepository('https://repo.test/repo.toml');
      expect(controller.available, isEmpty);
      expect(
        controller.errorOf('repo:https://repo.test/repo.toml'),
        contains('仓库不可用'),
      );
    });

    test('安装成功后刷新已安装列表', () async {
      final repo = FakePluginRepository(repoEntries: [entry('guo.a', '1.0.0')]);
      final controller = PluginsController(repository: repo);
      addTearDown(controller.dispose);
      await controller.loadRepository('https://repo.test/repo.toml');
      final ok = await controller.install(
        controller.available.first,
        repoUrl: 'https://repo.test/repo.toml',
      );
      expect(ok, isTrue);
      expect(controller.installed.map((e) => e.id), ['guo.a']);
      expect(repo.calls, contains('install:guo.a'));
    });

    test('安装失败时记录原因且不加入已安装', () async {
      final repo = FakePluginRepository(
        repoEntries: [entry('guo.a', '1.0.0')],
        failInstall: true,
      );
      final controller = PluginsController(repository: repo);
      addTearDown(controller.dispose);
      await controller.loadRepository('https://repo.test/repo.toml');
      final ok = await controller.install(
        controller.available.first,
        repoUrl: 'https://repo.test/repo.toml',
      );
      expect(ok, isFalse);
      expect(controller.installed, isEmpty);
      expect(controller.errorOf('guo.a'), contains('包哈希'));
    });

    test('没有仓库地址时安装直接失败', () async {
      final repo = FakePluginRepository(repoEntries: [entry('guo.a', '1.0.0')]);
      final controller = PluginsController(repository: repo);
      addTearDown(controller.dispose);
      expect(await controller.install(entry('guo.a', '1.0.0')), isFalse);
    });
  });

  group('卸载与启停', () {
    test('卸载后从已安装列表移除', () async {
      final repo = FakePluginRepository(
        installedEntries: [entry('guo.a', '1.0.0')],
      );
      final controller = PluginsController(repository: repo);
      addTearDown(controller.dispose);
      await controller.refresh();
      expect(controller.installed, hasLength(1));
      await controller.uninstall('guo.a');
      expect(controller.installed, isEmpty);
      expect(repo.calls, contains('uninstall:guo.a'));
    });

    test('启用状态切换会反映到列表', () async {
      final repo = FakePluginRepository(
        installedEntries: [entry('guo.a', '1.0.0')],
      );
      final controller = PluginsController(repository: repo);
      addTearDown(controller.dispose);
      await controller.refresh();
      await controller.setEnabled('guo.a', false);
      expect(controller.installed.first.enabled, isFalse);
      expect(repo.calls, contains('enable:guo.a=false'));
    });

    test('回滚调用透传到仓库层', () async {
      final repo = FakePluginRepository(
        installedEntries: [entry('guo.a', '2.0.0')],
      );
      final controller = PluginsController(repository: repo);
      addTearDown(controller.dispose);
      await controller.refresh();
      await controller.rollback(controller.installed.first, '1.0.0');
      expect(repo.calls, contains('rollback:guo.a=1.0.0'));
    });
  });

  group('站源同步', () {
    tearDown(SourceSite.clearReported);

    test('卸载插件后其站源不再可用', () async {
      SourceSite.clearReported();
      final repo = FakePluginRepository(
        installedEntries: [
          PluginEntry(
            id: 'guo.plugin',
            name: '插件源',
            version: '1.0.0',
            kind: 'declarative',
            installed: true,
            enabled: true,
            signed: false,
          ),
        ],
      );
      final controller = PluginsController(repository: repo);
      addTearDown(controller.dispose);
      await controller.refresh();
      await controller.uninstall('guo.plugin');
      expect(SourceSite.isAvailable('guo.plugin'), isFalse);
    });
  });
}
