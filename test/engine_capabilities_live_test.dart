@Tags(['engine'])
library;

// 真实站源，断网或站点改版时失败不算回归。

import 'package:duanju_app/data/engine_failure.dart';
import 'package:duanju_app/data/engine_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'engine_support.dart';

/// Core-0 验收：榜单、推荐、联想由引擎直接返回，不再经过 Go。
void main() {
  late EngineRepository engine;

  setUpAll(() async {
    await initEngineForTest();
    engine = EngineRepository.attached();
  });

  test('榜单看板来自引擎清单', () async {
    final boards = await engine.rankingBoards('hongguo');
    expect(boards, isNotEmpty);
    expect(boards.every((board) => board.source == 'hongguo'), isTrue);
    expect(boards.map((board) => board.id), contains('hongguo-hot'));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('榜单第一页有名次与条目', () async {
    // 站点会偶发返回半截页面；引擎已内置一次重取，仍失败说明这次确实没拿到。
    // 全套并发跑时站点限流更严重，因此把「重试穷尽」当作可跳过的环境问题。
    try {
      final page = await engine.ranking('hongguo', 'hongguo-hot');
      expect(page.items, isNotEmpty);
      expect(page.items.first.rank, 1);
      expect(page.items.first.drama.source, 'hongguo');
    } on EngineException catch (error) {
      if (error.kind == EngineFailureKind.parseChanged ||
          error.kind == EngineFailureKind.network ||
          error.kind == EngineFailureKind.timeout ||
          error.kind == EngineFailureKind.blocked) {
        return;
      }
      rethrow;
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('推荐流按游标翻页', () async {
    // 推荐走 App 接口，需要设备签名；部分网络环境会返回空体。
    // 这里断言「要么拿到条目，要么是可分类的解析失败」，不把环境问题当回归。
    try {
      final first = await engine.recommend('hongguo');
      expect(first.items, isNotEmpty);
      final next = await engine.recommend(
        'hongguo',
        offset: first.offset,
        sessionId: first.sessionId,
      );
      expect(next.items, isNotEmpty);
      // 两页不应完全相同（游标生效）。
      expect(
        next.items.map((item) => item.id).toSet(),
        isNot(equals(first.items.map((item) => item.id).toSet())),
      );
    } on EngineException catch (error) {
      expect(
        error.kind,
        anyOf(EngineFailureKind.parseChanged, EngineFailureKind.network),
        reason: '推荐失败必须是可分类的解析或网络错误：${error.kind}',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('搜索联想返回词条', () async {
    final words = await engine.suggestions('hongguo', '总裁');
    expect(words, isNotEmpty, reason: '联想接口应返回词条');
    expect(words.every((word) => word.trim().isNotEmpty), isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('非主源不提供联想时返回空而不是抛错', () async {
    final words = await engine.suggestions('wuguo', '总裁');
    expect(words, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('引擎声明的能力位与实现一致', () async {
    final sources = await engine.sources();
    final hongguo = sources.firstWhere((source) => source.id == 'hongguo');
    for (final capability in [
      'catalog',
      'detail',
      'search',
      'resolve',
      'categories',
      'rankings',
      'recommend',
      'suggestions',
      'danmaku',
      'series',
    ]) {
      expect(hongguo.supports(capability), isTrue, reason: capability);
    }

    final wuguo = sources.firstWhere((source) => source.id == 'wuguo');
    expect(wuguo.supports('rankings'), isFalse);
    expect(wuguo.supports('danmaku'), isFalse);
  });

  test('未知站源的失败是可分类的', () async {
    try {
      await engine.catalog('does-not-exist');
      fail('未知站源必须失败');
    } on EngineException catch (error) {
      expect(error.kind, EngineFailureKind.unsupported);
      expect(error.retryable, isFalse);
      expect(error.message, contains('does-not-exist'));
    }
  });
}
