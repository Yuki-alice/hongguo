// 这些用例会请求真实站源，断网或站点改版时失败不算回归。
// 默认运行会排除本 tag，需要时用 `flutter test --tags engine` 显式打开。
@Tags(['engine'])
library;

import 'dart:io';
import 'engine_support.dart';

import 'package:duanju_app/data/engine_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// 缓存行为的端到端验证。
void main() {
  late EngineRepository repository;
  late Directory cacheDir;

  setUpAll(() async {
    await initEngineForTest();
    repository = EngineRepository(initialized: true);
    cacheDir = Directory.systemTemp.createTempSync('guo-cache-dart');
    await repository.setCacheDirectory(cacheDir.path);
  });

  tearDownAll(() {
    if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
  });

  test('catalog write populates the cache', () async {
    final live = await repository.catalog('wuguo', category: '1');
    expect(live.items, isNotEmpty);

    final cached = await repository.cachedCatalog('wuguo', category: '1');
    expect(cached.items.length, live.items.length);
    expect(cached.items.first.id, live.items.first.id);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('freshness reflects the TTL window', () async {
    expect(await repository.catalogIsFresh('wuguo', category: '1'), isTrue);
    expect(
      await repository.catalogIsFresh('wuguo', category: 'never-loaded'),
      isFalse,
    );
  });

  test('cached read is far cheaper than a live request', () async {
    final stopwatch = Stopwatch()..start();
    final page = await repository.cachedCatalog('wuguo', category: '1');
    stopwatch.stop();

    expect(page.items, isNotEmpty);
    expect(
      stopwatch.elapsedMilliseconds,
      lessThan(200),
      reason: '缓存读取不应触发网络，实际 ${stopwatch.elapsedMilliseconds}ms',
    );
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('clearing removes the entry', () async {
    await repository.clearCatalog('wuguo', category: '1');
    final page = await repository.cachedCatalog('wuguo', category: '1');
    expect(page.items, isEmpty);
    expect(await repository.catalogIsFresh('wuguo', category: '1'), isFalse);
  });

  test('cache file is written to the configured directory', () async {
    await repository.catalog('wuguo', category: '1');
    final file = File('${cacheDir.path}/catalogs.json');
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), greaterThan(100));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
