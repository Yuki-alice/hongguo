library;

import '../support/engine_setup.dart';

import 'package:hoshi/data/engine_repository.dart';
import 'package:hoshi/domain/models.dart';
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
