import 'package:duanju_app/data/core_bridge.dart';
import 'package:duanju_app/data/local_store.dart';
import 'package:duanju_app/domain/models.dart';
import 'package:duanju_app/domain/source_status.dart';
import 'package:duanju_app/ui/features/sources/controllers/sources_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../fixtures.dart';

class _SourceRepository extends FixtureRepository {
  final statuses = <String, SourceStatus>{};
  final calls = <String>[];
  String? dramaId;
  bool failStatus = false;
  bool failJob = false;

  @override
  bool get supportsSourceManagement => true;

  @override
  Future<SourceStatus> sourceStatus(String source) async {
    if (failStatus) throw AppFailure('合成状态错误');
    return statuses[source] ?? SourceStatus.fromJson({'source': source});
  }

  @override
  Future<SourceStatus> startSourceJob(
    String source,
    String operation, {
    Drama? drama,
  }) async {
    if (failJob) throw AppFailure('合成任务错误');
    calls.add('$operation:$source');
    dramaId = drama?.id;
    if (operation == 'cancel') return _status(source, running: false);
    return _status(source, running: true);
  }

  @override
  Future<SourceStatus> cancelSourceJob(String source) async {
    if (failJob) throw AppFailure('合成取消失败');
    calls.add('cancel:$source');
    return _status(source, running: false);
  }

  SourceStatus _status(String source, {bool running = false}) {
    final status = SourceStatus.fromJson({
      'source': source,
      'running': running,
      'stage': running ? '更新中' : '',
    });
    statuses[source] = status;
    return status;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(LocalStore, _SourceRepository)> createStore() async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    return (store, _SourceRepository());
  }

  SourcesController createController(
    LocalStore store,
    _SourceRepository repository, {
    Drama? drama,
  }) {
    final controller = SourcesController(
      repository: repository,
      store: store,
      drama: drama,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  test('刷新填充站源状态并清除旧错误', () async {
    final (store, repository) = await createStore();
    addTearDown(store.dispose);
    final source = store.sources.first.id;
    repository.statuses[source] = SourceStatus.fromJson({
      'source': source,
      'count': 3,
    });
    final controller = createController(store, repository);

    await controller.refresh();

    expect(controller.statusOf(source)?.count, 3);
    expect(controller.errorOf(source), isEmpty);
    expect(controller.pending(source), isFalse);
  });

  test('刷新失败写入该站源错误', () async {
    final (store, repository) = await createStore();
    addTearDown(store.dispose);
    repository.failStatus = true;
    final controller = createController(store, repository);

    await controller.refresh();

    expect(controller.errorOf(store.sources.first.id), contains('合成状态错误'));
  });

  test('执行任务时传递当前剧集并跟踪运行状态', () async {
    final (store, repository) = await createStore();
    addTearDown(store.dispose);
    final source = store.sources.first.id;
    final drama = Drama(id: '$source:1', source: source, title: '合成剧');
    final controller = createController(store, repository, drama: drama);

    await controller.run(SourceSite.byId(source), 'update');

    expect(repository.calls, ['update:$source']);
    expect(repository.dramaId, drama.id);
    expect(controller.statusOf(source)?.running, isTrue);
    expect(controller.pending(source), isFalse);
  });

  test('任务失败保留错误并结束等待态', () async {
    final (store, repository) = await createStore();
    addTearDown(store.dispose);
    repository.failJob = true;
    final source = store.sources.first.id;
    final controller = createController(store, repository);

    await controller.run(SourceSite.byId(source), 'update');

    expect(controller.errorOf(source), contains('合成任务错误'));
    expect(controller.pending(source), isFalse);
  });

  test('检测任务自动展开健康详情', () async {
    final (store, repository) = await createStore();
    addTearDown(store.dispose);
    final source = store.sources.first.id;
    final controller = createController(store, repository);

    await controller.run(SourceSite.byId(source), 'check');

    expect(controller.healthExpanded(source), isTrue);
    controller.toggleHealth(source);
    expect(controller.healthExpanded(source), isFalse);
  });
}
