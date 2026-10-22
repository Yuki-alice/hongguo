library;

import '../support/engine_setup.dart';

import 'package:duanju_app/data/engine_repository.dart';
import 'package:duanju_app/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 用真实 Rust 引擎驱动 `EngineRepository`，验证它产出应用既有模型。
void main() {
  late EngineRepository repository;

  setUpAll(() async {
    await initEngineForTest();
    repository = EngineRepository(initialized: true);
  });

  test('engine reports its sources', () async {
    final sources = await repository.sources();
    expect(sources, isNotEmpty);
    expect(sources.map((s) => s.id), containsAll(['wuguo', 'maoguo']));
    final maoguo = sources.firstWhere((s) => s.id == 'maoguo');
    expect(maoguo.supports('catalog'), isTrue);
    expect(maoguo.apiLevel, greaterThanOrEqualTo(1));
  });

  test('supports() reflects engine capability', () async {
    expect(await repository.supports('wuguo'), isTrue);
    // 红果是随包分发的主源（ARCHITECTURE.md §5），引擎实现它之后必须上报。
    expect(await repository.supports('hongguo'), isTrue);
    // 未安装的站源与空 id 仍应返回 false。
    expect(await repository.supports('huangdou'), isFalse);
    expect(await repository.supports(''), isFalse);
  });

  test('catalog returns the existing CatalogPage model', () async {
    final page = await repository.catalog('wuguo', category: '1');
    expect(page.items, isNotEmpty);
    expect(page.page, 1);

    final first = page.items.first;
    expect(first, isA<Drama>());
    expect(first.source, 'wuguo');
    expect(first.id, startsWith('wuguo:'));
    expect(first.title, isNotEmpty);
    expect(first.cover.startsWith('http'), isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('detail returns the existing DramaDetail model', () async {
    final page = await repository.catalog('maoguo', category: '0');
    final target = page.items.first;

    final detail = await repository.detail(target);
    expect(detail.drama.id, target.id);
    expect(detail.episodes, isNotEmpty);

    final episode = detail.episodes.first;
    expect(episode, isA<Episode>());
    expect(episode.id, isNotEmpty);
    expect(episode.title, isNotEmpty);
    expect(episode.number, greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('describeSources serialises to JSON', () async {
    final text = await repository.describeSources();
    expect(text, contains('"id":"wuguo"'));
    expect(text, contains('"apiLevel"'));
  });
}
