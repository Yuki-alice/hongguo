import 'engine_support.dart';

import 'package:duanju_app/src/rust/api.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证 Dart 可以真实驱动 Rust 引擎完成站源调度。
///
/// 这批用例需要网络。离线时会被 `skip` 标记，不影响本地回归。
void main() {
  setUpAll(() async {
    await initEngineForTest();
  });

  test('engine lists both rule source and code plugin', () async {
    final sources = await sourceCatalog();
    final ids = sources.map((site) => site.id).toList();
    expect(ids, contains('wuguo'));
    expect(ids, contains('maoguo'));

    final maoguo = sources.firstWhere((site) => site.id == 'maoguo');
    expect(maoguo.name, '猫果');
    expect(maoguo.capabilities, containsAll(['catalog', 'detail', 'search']));
  });

  test('unknown source fails with a clear message', () async {
    await expectLater(
      fetchCatalog(sourceId: 'does-not-exist', page: 1, category: ''),
      throwsA(isA<Object>()),
    );
  });

  test('declarative rule source parses real catalog', () async {
    final page = await fetchCatalog(sourceId: 'wuguo', page: 1, category: '1');
    expect(page.items.length, greaterThanOrEqualTo(10));

    final first = page.items.first;
    expect(first.source, 'wuguo');
    expect(first.id, startsWith('wuguo:'));
    expect(first.title, isNotEmpty);
    expect(first.sourceId, isNotEmpty);
    expect(first.cover, startsWith('http'));
    expect(first.title.contains('人在追'), isFalse);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('code plugin source parses real catalog', () async {
    final page = await fetchCatalog(sourceId: 'maoguo', page: 1, category: '0');
    expect(page.items.length, greaterThanOrEqualTo(10));

    final first = page.items.first;
    expect(first.source, 'maoguo');
    expect(first.episodes, greaterThan(0));
    expect(first.cover, startsWith('http'));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('code plugin resolves real detail with chapters', () async {
    final page = await fetchCatalog(sourceId: 'maoguo', page: 1, category: '0');
    final target = page.items.first;

    final detail = await fetchDetail(
      sourceId: 'maoguo',
      dramaSourceId: target.sourceId,
    );
    expect(detail.chapters, isNotEmpty);
    expect(detail.chapters.first.videoUrl, isNotEmpty);
    expect(detail.chapters.first.title, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
