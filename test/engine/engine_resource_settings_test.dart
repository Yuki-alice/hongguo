import 'package:hoshi/data/engine_repository.dart';
import 'package:hoshi/domain/resource_settings.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/engine_setup.dart';

/// 资源设置的引擎侧行为：默认值、夹取、落盘、跨实例读取。
///
/// 这些用例需要真实引擎动态库（`flutter test` 会经 native-assets 钩子准备），
/// 因此和其余引擎用例一样放在 `engine` 目录下，不打在线 tag。
void main() {
  setUpAll(() async {
    await initEngineForTest();
  });

  EngineRepository engine() => EngineRepository(initialized: true);

  test('默认设置与产品约定一致', () async {
    final settings = await engine().resourceSettings();
    expect(settings.proxyMode, 'auto');
    expect(settings.catalogConcurrency, 3);
    expect(settings.catalogIntervalMs, 250);
    expect(settings.downloadConcurrency, 2);
    expect(settings.downloadBySource, isFalse);
  });

  test('保存后可以读回', () async {
    final repo = engine();
    final saved = await repo.saveResourceSettings(
      const ResourceSettings(
        catalogConcurrency: 5,
        catalogIntervalMs: 900,
        downloadConcurrency: 4,
        proxyMode: 'manual',
        proxyUrl: 'http://127.0.0.1:7890',
      ),
    );
    expect(saved.catalogConcurrency, 5);
    expect(saved.catalogIntervalMs, 900);
    expect(saved.downloadConcurrency, 4);
    expect(saved.proxyMode, 'manual');

    final reloaded = await repo.resourceSettings();
    expect(reloaded.catalogConcurrency, 5);
    expect(reloaded.catalogIntervalMs, 900);
    expect(reloaded.downloadConcurrency, 4);
    expect(reloaded.proxyUrl, 'http://127.0.0.1:7890');
  });

  test('越界值被夹回合法范围而不是报错', () async {
    final saved = await engine().saveResourceSettings(
      const ResourceSettings(
        catalogConcurrency: 99,
        catalogIntervalMs: 999999,
        downloadConcurrency: 0,
      ),
    );
    // 与引擎侧的夹取范围一致（目录 1..8、间隔上限 5000、下载 1..6）。
    expect(saved.catalogConcurrency, 8);
    expect(saved.catalogIntervalMs, 5000);
    expect(saved.downloadConcurrency, 1);
  });

  test('切到非 manual 模式会清掉自定义代理地址', () async {
    final repo = engine();
    await repo.saveResourceSettings(
      const ResourceSettings(proxyMode: 'manual', proxyUrl: 'http://a:1'),
    );
    final saved = await repo.saveResourceSettings(
      const ResourceSettings(
        proxyMode: 'direct',
        proxyUrl: 'http://stale:9999',
      ),
    );
    expect(saved.proxyMode, 'direct');
    expect(saved.proxyUrl, isEmpty);
  });

  test('设置为空字符串的代理模式回落到 auto', () async {
    final saved = await engine().saveResourceSettings(
      const ResourceSettings(proxyMode: 'bogus'),
    );
    expect(saved.proxyMode, 'auto');
  });
}
