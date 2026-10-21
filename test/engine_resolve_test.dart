// 这些用例会请求真实站源，断网或站点改版时失败不算回归。
// 默认运行会排除本 tag，需要时用 `flutter test --tags engine` 显式打开。
@Tags(['engine'])
library;

import 'engine_support.dart';

import 'package:duanju_app/data/engine_repository.dart';
import 'package:duanju_app/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 用真实 Rust 引擎验证取流链路。
void main() {
  late EngineRepository repository;

  setUpAll(() async {
    await initEngineForTest();
    repository = EngineRepository(initialized: true);
  });

  test('resolves a real chapter to a playable url', () async {
    final page = await repository.catalog('maoguo', category: '0');
    final target = page.items.first;
    final detail = await repository.detail(target);
    final episode = detail.episodes.first;

    final plan = await repository.resolve(target, episode);
    expect(plan.url, isNotEmpty);
    expect(plan.url.startsWith('http'), isTrue);
    expect(plan.headers['Referer'], isNotNull);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('resolve keeps the source referer for CDN playback', () async {
    final page = await repository.catalog('maoguo', category: '0');
    final target = page.items.first;
    final detail = await repository.detail(target);

    final plan = await repository.resolve(target, detail.episodes.first);
    final referer = plan.headers['Referer'] ?? '';
    expect(referer, isNotEmpty);
    expect(Uri.tryParse(referer)?.hasScheme, isTrue);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('resolve on an empty chapter fails loudly', () async {
    final drama = Drama(
      id: 'maoguo:0',
      source: 'maoguo',
      sourceId: '0',
      title: '空',
    );
    final episode = Episode({'id': 'x', 'title': 'x'}, 1);
    await expectLater(
      repository.resolve(drama, episode),
      throwsA(isA<Object>()),
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}
