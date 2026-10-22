import 'package:hoshi/domain/download_collections.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/features/downloads/views/downloads_screen.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/ui/features/downloads/controllers/downloads_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../support/fixtures.dart';

class _DownloadsRepository extends FixtureRepository {
  _DownloadsRepository(this.jobs);

  List<DownloadJob> jobs;
  final calls = <String>[];

  @override
  Future<List<DownloadJob>> downloads() async => List.of(jobs);

  @override
  Future<DownloadBatchResult> controlDownloadBatch(
    String command,
    List<String> ids, {
    Map<String, String> expectedVersions = const {},
  }) async {
    calls.add('$command:${ids.join(',')}');
    if (command == 'remove') {
      jobs = [
        for (final job in jobs)
          if (!ids.contains(job.id)) job,
      ];
    }
    return DownloadBatchResult(completed: ids.toList());
  }
}

DownloadJob _job(String id, String state, {bool archived = false}) =>
    DownloadJob(
      id: id,
      drama: FixtureRepository.free,
      episode: Episode({
        'id': id,
        'currentEpisode': int.parse(id),
      }, int.parse(id)),
      state: state,
      archived: archived,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<LocalStore> createStore() async {
    SharedPreferences.setMockInitialValues({});
    return LocalStore(await SharedPreferences.getInstance());
  }

  Future<DownloadsController> create(
    _DownloadsRepository repository,
    LocalStore store,
  ) async {
    final controller = DownloadsController(
      repository: repository,
      store: store,
    );
    addTearDown(controller.dispose);
    await pumpEventQueue();
    return controller;
  }

  test('初始加载结束加载态并按剧集分组', () async {
    final store = await createStore();
    addTearDown(store.dispose);
    final controller = await create(
      _DownloadsRepository([_job('1', 'downloading'), _job('2', 'completed')]),
      store,
    );

    expect(controller.loading, isFalse);
    expect(controller.allowed, isTrue);
    expect(controller.jobs, hasLength(2));
    expect(controller.collections.single.jobs, hasLength(2));
    expect(controller.collections.single.completed, 1);
  });

  test('批量操作只处理可操作任务', () async {
    final store = await createStore();
    addTearDown(store.dispose);
    final repository = _DownloadsRepository([
      _job('1', 'downloading'),
      _job('2', 'paused'),
    ]);
    final controller = await create(repository, store);

    await controller.batch('pause', controller.jobs);

    expect(repository.calls, ['pause:1']);
    expect(controller.busy, isFalse);
    expect(controller.takeMessage(), '已处理 1 项');

    await controller.batch('resume', controller.jobs);
    expect(repository.calls.last, 'resume:2');
  });

  test('没有目标任务时给出提示且不请求仓库', () async {
    final store = await createStore();
    addTearDown(store.dispose);
    final repository = _DownloadsRepository([_job('1', 'paused')]);
    final controller = await create(repository, store);

    await controller.batch('pause', controller.jobs);

    expect(repository.calls, isEmpty);
    expect(controller.takeMessage(), '没有适合此操作的任务');
  });

  test('多选支持整组切换与退出', () async {
    final store = await createStore();
    addTearDown(store.dispose);
    final controller = await create(
      _DownloadsRepository([_job('1', 'paused'), _job('2', 'paused')]),
      store,
    );

    controller.select(controller.jobs);
    expect(controller.selecting, isTrue);
    expect(controller.selected, {'1', '2'});

    controller.select(controller.jobs);
    expect(controller.selected, isEmpty);

    controller.exitSelecting();
    expect(controller.selecting, isFalse);
    expect(controller.retryCommand, isNull);
  });

  test('搜索与归档筛选只影响合集列表', () async {
    final store = await createStore();
    addTearDown(store.dispose);
    final controller = await create(
      _DownloadsRepository([
        _job('1', 'completed'),
        _job('2', 'completed', archived: true),
      ]),
      store,
    );

    expect(controller.collections.single.jobs, hasLength(1));
    controller.applyFilters(filter: 'archived', release: '');
    expect(controller.collections.single.jobs.single.id, '2');

    controller.applyFilters(filter: 'all', release: '');
    controller.setQuery('不存在');
    expect(controller.collections, isEmpty);
    controller.setQuery('测试');
    expect(controller.collections.single.jobs, hasLength(1));
  });

  testWidgets('下载页加载合集并可展开分集', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: DownloadsScreen(
          repository: _DownloadsRepository([
            _job('1', 'paused'),
            _job('2', 'completed'),
          ]),
          store: store,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('测试短剧'), findsOneWidget);
    expect(find.textContaining('1/2 集已下载'), findsOneWidget);

    await tester.tap(find.text('测试短剧'));
    await tester.pump();
    expect(find.byKey(const ValueKey('download-task-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('download-task-2')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
