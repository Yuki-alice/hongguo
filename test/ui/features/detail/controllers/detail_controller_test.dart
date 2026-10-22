import 'dart:async';

import 'package:duanju_app/data/core_bridge.dart';
import 'package:duanju_app/data/local_store.dart';
import 'package:duanju_app/domain/models.dart';
import 'package:duanju_app/ui/features/detail/controllers/detail_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../support/fixtures.dart';

class _DetailRepository extends FixtureRepository {
  _DetailRepository({this.failDetail = false, this.supplement});

  final bool failDetail;
  final Drama? supplement;

  @override
  Future<DramaDetail> detail(Drama drama) async {
    detailCalls++;
    if (failDetail) throw AppFailure('合成详情错误');
    return DramaDetail(drama, [
      for (var number = 1; number <= 120; number++)
        Episode({
          'id': '$number',
          'title': '第$number集',
          'currentEpisode': number,
        }, number),
    ]);
  }

  @override
  Future<Drama?> supplementMetadata(Drama drama) async => supplement;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<LocalStore> createStore() async {
    SharedPreferences.setMockInitialValues({});
    return LocalStore(await SharedPreferences.getInstance());
  }

  test('load 合并目录资料并按观看进度定位剧集页', () async {
    final store = await createStore();
    addTearDown(store.dispose);
    final repository = _DetailRepository();
    repository.catalogUpdates.publish(
      const Drama(
        id: 'hongguo:100',
        source: 'hongguo',
        title: '测试短剧',
        description: '缓存简介',
      ),
    );
    await store.saveWatch(
      WatchEntry(
        drama: FixtureRepository.free,
        episode: 60,
        position: 10,
        duration: 100,
        updatedAt: DateTime(2026),
      ),
    );
    final controller = DetailController(
      drama: FixtureRepository.free,
      repository: repository,
      store: store,
    );
    addTearDown(controller.dispose);

    expect(controller.loading, isTrue);
    final loaded = await controller.load();

    expect(loaded, isTrue);
    expect(controller.loading, isFalse);
    expect(controller.error, isNull);
    expect(controller.detail!.episodes, hasLength(120));
    expect(controller.detail!.drama.description, '缓存简介');
    expect(controller.episodePage, 1, reason: '第 60 集位于第 2 页（每页 50 集）');
    expect(controller.allowed, isTrue);
  });

  test('load 失败时记录错误并结束加载态', () async {
    final store = await createStore();
    addTearDown(store.dispose);
    final controller = DetailController(
      drama: FixtureRepository.free,
      repository: _DetailRepository(failDetail: true),
      store: store,
    );
    addTearDown(controller.dispose);

    final loaded = await controller.load();

    expect(loaded, isFalse);
    expect(controller.loading, isFalse);
    expect(controller.error, contains('合成详情错误'));
    expect(controller.detail, isNull);
  });

  test('补充元数据返回后合并到当前详情', () async {
    final store = await createStore();
    addTearDown(store.dispose);
    final controller = DetailController(
      drama: FixtureRepository.free,
      repository: _DetailRepository(
        supplement: const Drama(
          id: 'hongguo:100',
          source: 'hongguo',
          title: '补充标题',
          heat: '9999',
        ),
      ),
      store: store,
    );
    addTearDown(controller.dispose);

    await controller.load();
    await pumpEventQueue();

    expect(controller.currentDrama.title, '补充标题');
    expect(controller.currentDrama.heat, '9999');
    expect(controller.detail!.drama.title, '补充标题');
  });

  test('setEpisodePage 只在页码变化时通知', () async {
    final store = await createStore();
    addTearDown(store.dispose);
    final controller = DetailController(
      drama: FixtureRepository.free,
      repository: _DetailRepository(),
      store: store,
    );
    addTearDown(controller.dispose);

    var notifications = 0;
    controller.addListener(() => notifications++);

    controller.setEpisodePage(60);
    expect(controller.episodePage, 1);
    expect(notifications, 1);

    controller.setEpisodePage(99);
    expect(controller.episodePage, 1);
    expect(notifications, 1);
  });

  test('旧一轮 load 的结果在重新加载后不会覆盖新状态', () async {
    final store = await createStore();
    addTearDown(store.dispose);
    final repository = _SlowDetailRepository();
    final controller = DetailController(
      drama: FixtureRepository.free,
      repository: repository,
      store: store,
    );
    addTearDown(controller.dispose);

    final first = controller.load();
    final second = controller.load();
    repository.completeSecond();

    expect(await second, isTrue);
    repository.completeFirst();
    expect(await first, isFalse);
    expect(controller.detail!.episodes, hasLength(2));
    expect(controller.loading, isFalse);
  });
}

class _SlowDetailRepository extends FixtureRepository {
  final _first = Completer<DramaDetail>();
  final _second = Completer<DramaDetail>();

  @override
  Future<DramaDetail> detail(Drama drama) {
    detailCalls++;
    return detailCalls == 1 ? _first.future : _second.future;
  }

  void completeFirst() => _first.complete(_detail(drama: '旧结果', episodes: 1));
  void completeSecond() => _second.complete(_detail(drama: '新结果', episodes: 2));

  DramaDetail _detail({required String drama, required int episodes}) =>
      DramaDetail(Drama(id: 'hongguo:100', source: 'hongguo', title: drama), [
        for (var number = 1; number <= episodes; number++)
          Episode({'currentEpisode': number}, number),
      ]);
}
