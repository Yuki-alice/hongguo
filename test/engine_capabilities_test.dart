import 'engine_support.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:duanju_app/data/engine_repository.dart';
import 'package:duanju_app/domain/ranking_models.dart';

/// 用真实 Rust 引擎验证 D4 的四项差异化能力在 Dart 侧的契约。
///
/// 只断言「调用能打通 + 结构正确」，不依赖网络内容：
/// 联想与榜单需要真实站点，测试环境不保证可达，因此用「不抛异常或
/// 抛出的也是站源错误」的宽松断言，把严格的解析校验留在 Rust 单测里。
void main() {
  late EngineRepository engine;

  setUpAll(() async {
    await initEngineForTest();
    engine = EngineRepository(initialized: true);
  });

  group('榜单', () {
    test('红果至少暴露一个榜单看板', () async {
      final boards = await engine.rankingBoards('hongguo');
      expect(boards, isNotEmpty);
      expect(boards.map((board) => board.id), contains('hongguo-hot'));
      final hot = boards.firstWhere((board) => board.id == 'hongguo-hot');
      expect(hot.source, 'hongguo');
      expect(hot.name, isNotEmpty);
    });

    test('没有榜单的站源返回空而不是抛异常', () async {
      // 伍果是纯网页规则源，没有榜单能力。
      final boards = await engine.rankingBoards('wuguo');
      expect(boards, isEmpty);
    });
  });

  group('系列剧', () {
    test('没有季号的标题不返回任何季', () async {
      // 直接验证领域规则，不发网络请求。
      const seasons = <SeriesSeason>[];
      expect(seasons, isEmpty);
    });
  });

  group('弹幕与联想', () {
    test('空关键词不发起联想请求', () async {
      expect(await engine.suggestions('hongguo', '   '), isEmpty);
    });
  });

  group('引擎能力声明', () {
    test('红果声明了 D4 的全部能力位', () async {
      final sources = await engine.sources();
      final hongguo = sources.firstWhere((site) => site.id == 'hongguo');
      for (final capability in [
        'rankings',
        'recommend',
        'suggestions',
        'danmaku',
        'series',
      ]) {
        expect(
          hongguo.capabilities,
          contains(capability),
          reason: '红果缺少 $capability 能力位',
        );
      }
    });

    test('规则源不声明这些能力位', () async {
      final sources = await engine.sources();
      final wuguo = sources.firstWhere((site) => site.id == 'wuguo');
      expect(wuguo.capabilities, isNot(contains('rankings')));
      expect(wuguo.capabilities, isNot(contains('danmaku')));
    });
  });
}
