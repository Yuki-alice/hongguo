library;

import 'dart:io';
import '../support/engine_setup.dart';

import 'package:hoshi/data/engine_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// 缓存行为的端到端验证。
void main() {
  late EngineRepository repository;

  setUpAll(() async {
    // `initEngineForTest` 会把单例装配到系统临时目录；缓存文件就落在那里，
    // 不再单独指定缓存目录（Core-1 起缓存属于引擎配置的一部分）。
    await initEngineForTest();
    repository = EngineRepository(initialized: true);
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

  test('cache file is written under the engine data directory', () async {
    await repository.catalog('wuguo', category: '1');
    // 单例的数据目录以引擎诊断为准（`attached()` 不猜路径）。
    final diagnostics = await repository.diagnostics();
    final file = File(diagnostics.catalogFile);
    expect(file.existsSync(), isTrue, reason: '缓存应落在引擎数据目录');
    expect(file.lengthSync(), greaterThan(100));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
