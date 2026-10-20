import 'package:flutter_test/flutter_test.dart';

import 'package:duanju_app/data/plugin_repository.dart';
import 'package:duanju_app/domain/models.dart';

void main() {
  group('PluginEntry', () {
    test('code plugins are distinguishable from declarative ones', () {
      const declarative = PluginEntry(
        id: 'guo.fanguo',
        name: '饭果',
        version: '1.0.0',
        kind: 'declarative',
        installed: false,
        enabled: false,
        signed: true,
      );
      const code = PluginEntry(
        id: 'guo.maoguo',
        name: '猫果',
        version: '1.0.0',
        kind: 'component',
        installed: true,
        enabled: true,
        signed: false,
      );
      expect(declarative.isCode, isFalse);
      expect(code.isCode, isTrue);
    });

    test('copyWith keeps identity and only flips the given flags', () {
      const entry = PluginEntry(
        id: 'guo.fanguo',
        name: '饭果',
        version: '1.0.0',
        kind: 'declarative',
        installed: false,
        enabled: true,
        signed: true,
      );
      final installed = entry.copyWith(installed: true);
      expect(installed.id, entry.id);
      expect(installed.version, entry.version);
      expect(installed.enabled, isTrue);
      expect(installed.installed, isTrue);
    });
  });

  group('PluginRepository 未初始化', () {
    test('已安装列表返回空而不是抛异常', () async {
      final repository = PluginRepository();
      expect(await repository.installed(), isEmpty);
    });

    test('卸载与启用在未初始化时是安全的空操作', () async {
      final repository = PluginRepository();
      expect(await repository.uninstall('guo.fanguo'), isFalse);
      await repository.setEnabled('guo.fanguo', false);
      await repository.rollback('guo.fanguo', '1.0.0');
      expect(
        await repository.rememberRepository(
          repoId: 'official',
          url: 'https://example.test/repo.toml',
          publicKey: '',
        ),
        isFalse,
      );
    });
  });

  group('SourceSite 引擎上报', () {
    tearDown(SourceSite.clearReported);

    test('内置站源不依赖引擎上报', () {
      SourceSite.clearReported();
      expect(SourceSite.isAvailable(SourceSite.hongguo.id), isTrue);
      expect(SourceSite.values, isNotEmpty);
    });

    test('引擎上报的插件站源会追加到列表', () {
      SourceSite.clearReported();
      final before = SourceSite.values.length;
      SourceSite.reportFromEngine(const [
        (id: 'guo.newguo', name: '新果', group: 'duanju'),
      ]);
      expect(SourceSite.values.length, before + 1);
      expect(SourceSite.isAvailable('guo.newguo'), isTrue);
      expect(
        SourceSite.values.firstWhere((site) => site.id == 'guo.newguo').name,
        '新果',
      );
    });

    test('内置 id 不会被引擎上报覆盖名称', () {
      SourceSite.clearReported();
      SourceSite.reportFromEngine(const [
        (id: 'hongguo', name: '被覆盖', group: 'duanju'),
      ]);
      final hongguo = SourceSite.values.firstWhere(
        (site) => site.id == SourceSite.hongguo.id,
      );
      expect(hongguo.name, SourceSite.hongguo.name);
    });

    test('重复上报是幂等的', () {
      SourceSite.clearReported();
      const entries = [(id: 'guo.newguo', name: '新果', group: 'duanju')];
      SourceSite.reportFromEngine(entries);
      final once = SourceSite.values.length;
      SourceSite.reportFromEngine(entries);
      expect(SourceSite.values.length, once);
    });

    test('清空上报后插件站源不再可用', () {
      SourceSite.reportFromEngine(const [
        (id: 'guo.temp', name: '临时', group: 'duanju'),
      ]);
      expect(SourceSite.isAvailable('guo.temp'), isTrue);
      SourceSite.clearReported();
      expect(SourceSite.isAvailable('guo.temp'), isFalse);
    });
  });
}
