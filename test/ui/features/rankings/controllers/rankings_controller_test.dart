import 'package:hoshi/data/app_contract.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/domain/ranking_models.dart';
import 'package:hoshi/ui/features/rankings/controllers/rankings_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../support/fixtures.dart';

class _RankingRepository extends FixtureRepository {
  List<RankingBoard> boards = const [];
  final responses = <String, RankingPage>{};
  final calls = <String>[];
  bool failRankings = false;

  @override
  Future<List<RankingBoard>> rankingBoards() async {
    if (failRankings) throw AppFailure('合成榜单目录错误');
    return boards;
  }

  @override
  Future<RankingPage> rankings(
    String board, {
    int page = 1,
    bool force = false,
  }) async {
    if (failRankings) throw AppFailure('合成榜单错误');
    calls.add('$board:$page:$force');
    return responses['$board:$page'] ?? const RankingPage(items: []);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(LocalStore, _RankingRepository, String)> create() async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    final repository = _RankingRepository();
    final source = store.sources.first.id;
    repository.boards = [
      RankingBoard(id: 'b1', source: source, name: '榜一'),
      RankingBoard(id: 'b2', source: source, name: '榜二'),
    ];
    return (store, repository, SourceSite.byId(source).groupId);
  }

  RankingsController createController(
    LocalStore store,
    _RankingRepository repository,
    String group,
  ) {
    final controller = RankingsController(
      repository: repository,
      store: store,
      initialGroup: group,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  test('初始化选择分组榜单并加载第一页', () async {
    final (store, repository, group) = await create();
    addTearDown(store.dispose);
    repository.responses['b1:1'] = RankingPage(
      items: [
        RankingItem(1, const Drama(id: 'x:1', source: 'x', title: '第一')),
        RankingItem(2, const Drama(id: 'x:2', source: 'x', title: '第二')),
      ],
      page: 1,
      hasMore: true,
      updatedText: '刚刚更新',
    );
    final controller = createController(store, repository, group);

    await controller.initialize();

    expect(controller.board?.id, 'b1');
    expect(controller.loading, isFalse);
    expect(controller.items, hasLength(2));
    expect(controller.hasMore, isTrue);
    expect(controller.updated, '刚刚更新');
    expect(repository.calls, ['b1:1:false']);
  });

  test('加载更多合并条目并按名次排序', () async {
    final (store, repository, group) = await create();
    addTearDown(store.dispose);
    repository.responses['b1:1'] = RankingPage(
      items: [RankingItem(1, const Drama(id: 'x:1', source: 'x', title: '一'))],
      page: 1,
      hasMore: true,
    );
    repository.responses['b1:2'] = RankingPage(
      items: [
        RankingItem(3, const Drama(id: 'x:3', source: 'x', title: '三')),
        RankingItem(2, const Drama(id: 'x:2', source: 'x', title: '二')),
      ],
      page: 2,
    );
    final controller = createController(store, repository, group);
    await controller.initialize();

    await controller.load(more: true);

    expect(controller.items.map((item) => item.rank), [1, 2, 3]);
    expect(controller.hasMore, isFalse);
    expect(repository.calls, ['b1:1:false', 'b1:2:false']);
  });

  test('切换榜单清空旧条目并加载新榜', () async {
    final (store, repository, group) = await create();
    addTearDown(store.dispose);
    repository.responses['b1:1'] = RankingPage(
      items: [RankingItem(1, const Drama(id: 'x:1', source: 'x', title: '一'))],
      page: 1,
    );
    repository.responses['b2:1'] = RankingPage(
      items: [RankingItem(1, const Drama(id: 'y:1', source: 'y', title: '新'))],
      page: 1,
    );
    final controller = createController(store, repository, group);
    await controller.initialize();

    controller.select(repository.boards[1]);
    await pumpEventQueue();

    expect(controller.board?.id, 'b2');
    expect(controller.items.single.drama.id, 'y:1');
    expect(repository.calls.last, 'b2:1:false');
  });

  test('加载失败保留错误与重试标记', () async {
    final (store, repository, group) = await create();
    addTearDown(store.dispose);
    repository.responses['b1:1'] = const RankingPage(
      items: [],
      page: 1,
      hasMore: true,
    );
    final controller = createController(store, repository, group);
    await controller.initialize();
    repository.failRankings = true;

    await controller.load(more: true);

    expect(controller.error, contains('合成榜单错误'));
    expect(controller.failedMore, isTrue);
    expect(controller.loading, isFalse);
    expect(controller.more, isFalse);
  });

  test('目录资料更新会通知视图', () async {
    final (store, repository, group) = await create();
    addTearDown(store.dispose);
    final controller = createController(store, repository, group);
    var notifications = 0;
    controller.addListener(() => notifications++);

    repository.catalogUpdates.publish(
      const Drama(id: 'x:1', source: 'x', title: '更新'),
    );

    expect(notifications, 1);
  });
}
