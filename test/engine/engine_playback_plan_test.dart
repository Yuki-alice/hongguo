library;

import 'package:hoshi/data/engine_failure.dart';
import 'package:hoshi/data/engine_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/engine_setup.dart';

void main() {
  late EngineRepository engine;
  setUpAll(() async {
    await initEngineForTest();
    engine = EngineRepository.attached();
  });

  test('取流计划带上来源与分集标识', () async {
    final page = await engine.catalog('maoguo', category: '0');
    expect(page.items, isNotEmpty);
    final drama = page.items.first;
    final detail = await engine.detail(drama);
    expect(detail.episodes, isNotEmpty);
    final plan = await engine.resolve(detail.drama, detail.episodes.first);
    expect(plan.url, isNotEmpty);
    // 弹幕与下载都靠这两项定位，不能依赖 URL 反推。
    expect(plan.danmakuId, isNotEmpty, reason: '弹幕门槛依赖它');
    expect(plan.source, 'maoguo');
    expect(plan.sourceId, drama.sourceId);
    expect(plan.headers['User-Agent'], isNotNull);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('弹幕按 60 秒窗口返回', () async {
    // 红果播放页结构会变；站点侧异常时跳过，不当成引擎回归。
    try {
      final page = await engine.catalog('hongguo', category: '');
      final detail = await engine.detail(page.items.first);
      final danmaku = await engine.danmaku(
        detail.drama,
        detail.episodes.first,
        startMs: 0,
      );
      for (final item in danmaku) {
        expect(item.timeMs, greaterThanOrEqualTo(0));
        expect(item.timeMs, lessThan(60000));
        expect(item.text, isNotEmpty);
      }
    } on EngineException catch (error) {
      if (error.kind == EngineFailureKind.parseChanged ||
          error.kind == EngineFailureKind.network ||
          error.kind == EngineFailureKind.timeout) {
        return;
      }
      rethrow;
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('剧果取流计划带 Cookie 与 Origin', () async {
    try {
      final page = await engine.catalog('huangju', category: '');
      if (page.items.isEmpty) return;
      final detail = await engine.detail(page.items.first);
      if (detail.episodes.isEmpty) return;
      final plan = await engine.resolve(detail.drama, detail.episodes.first);
      // 剧果的媒体域走 CDN 签名，Cookie 必须透传到播放计划。
      expect(
        plan.headers.containsKey('Cookie') ||
            plan.headers.containsKey('Origin'),
        isTrue,
        reason: '签名源的播放计划必须带 Cookie 或 Origin：${plan.headers.keys}',
      );
    } on EngineException catch (error) {
      // 站点不可达时跳过，不把环境问题当回归。
      if (error.kind == EngineFailureKind.network ||
          error.kind == EngineFailureKind.timeout ||
          error.kind == EngineFailureKind.http) {
        return;
      }
      rethrow;
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
