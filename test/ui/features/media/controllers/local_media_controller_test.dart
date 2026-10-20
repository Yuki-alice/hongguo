import 'package:duanju_app/data/core_bridge.dart';
import 'package:duanju_app/data/local_store.dart';
import 'package:duanju_app/data/media/media_library.dart';
import 'package:duanju_app/domain/models.dart';
import 'package:duanju_app/ui/features/media/controllers/local_media_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../fixtures.dart';

class _MediaRepository extends FixtureRepository {
  _MediaRepository(this.jobs);

  List<DownloadJob> jobs;
  bool failDownloads = false;

  @override
  Future<List<DownloadJob>> downloads() async {
    if (failDownloads) throw AppFailure('合成下载记录错误');
    return List.of(jobs);
  }
}

class _FakeOperations implements LocalMediaOperations {
  bool fail = false;
  int reloads = 0;
  List<DownloadJob>? exported;
  LocalMediaItem? removed;
  LocalMediaItem? exportedMerged;

  @override
  Future<void> reload() async {
    if (fail) throw AppFailure('合成媒体目录错误');
    reloads++;
  }

  @override
  Future<void> exportJobs(List<DownloadJob> selected) async {
    if (fail) throw AppFailure('合成导出错误');
    exported = selected;
  }

  @override
  Future<LocalMediaItem> exportMerged(LocalMediaItem selected) async {
    if (fail) throw AppFailure('合成特别篇导出错误');
    exportedMerged = selected;
    return selected;
  }

  @override
  Future<void> remove(LocalMediaItem selected) async {
    if (fail) throw AppFailure('合成删除错误');
    removed = selected;
  }
}

DownloadJob _job(String id, String state) => DownloadJob(
  id: id,
  drama: FixtureRepository.free,
  episode: Episode({'id': id, 'currentEpisode': 1}, 1),
  state: state,
);

LocalMediaItem _item() => LocalMediaItem(
  id: 'item-1',
  drama: FixtureRepository.free,
  file: 'media/item-1.mp4',
  kind: 'merged',
  episodes: const [1, 2],
  duration: 60,
  bytes: 1024,
  created: DateTime(2026),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(LocalStore, _MediaRepository, MediaLibrary, _FakeOperations)>
  create() async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    final repository = _MediaRepository([_job('1', 'completed')]);
    final library = MediaLibrary(repository, store);
    final operations = _FakeOperations();
    return (store, repository, library, operations);
  }

  LocalMediaController createController(
    _MediaRepository repository,
    MediaLibrary library,
    _FakeOperations operations,
  ) {
    final controller = LocalMediaController(
      repository: repository,
      library: library,
      operations: operations,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  test('加载已下载分集并刷新媒体库', () async {
    final (store, repository, library, operations) = await create();
    addTearDown(store.dispose);
    addTearDown(library.dispose);
    repository.jobs = [
      _job('1', 'completed'),
      _job('2', 'paused'),
      _job('3', 'completed'),
    ];
    final controller = createController(repository, library, operations);

    await controller.load();

    expect(controller.loading, isFalse);
    expect(controller.jobs.map((job) => job.id), ['1', '3']);
    expect(operations.reloads, 1);
    expect(controller.error, isNull);
  });

  test('加载失败保留错误并结束加载态', () async {
    final (store, repository, library, operations) = await create();
    addTearDown(store.dispose);
    addTearDown(library.dispose);
    operations.fail = true;
    final controller = createController(repository, library, operations);

    await controller.load();

    expect(controller.loading, isFalse);
    expect(controller.error, contains('合成媒体目录错误'));
  });

  test('合并 / 导出切换只通知一次', () async {
    final (store, repository, library, operations) = await create();
    addTearDown(store.dispose);
    addTearDown(library.dispose);
    final controller = createController(repository, library, operations);
    var notifications = 0;
    controller.addListener(() => notifications++);

    controller.showMerged(false);
    controller.showMerged(false);

    expect(controller.merged, isFalse);
    expect(notifications, 1);
  });

  test('导出分集后切到导出视图并刷新', () async {
    final (store, repository, library, operations) = await create();
    addTearDown(store.dispose);
    addTearDown(library.dispose);
    final jobs = [_job('1', 'completed')];
    final controller = createController(repository, library, operations);

    final exported = await controller.exportJobs(jobs);

    expect(exported, isTrue);
    expect(controller.merged, isFalse);
    expect(operations.exported, jobs);
    expect(operations.reloads, 1);
    expect(controller.error, isNull);
  });

  test('导出失败保留错误与当前视图', () async {
    final (store, repository, library, operations) = await create();
    addTearDown(store.dispose);
    addTearDown(library.dispose);
    operations.fail = true;
    final controller = createController(repository, library, operations);

    final exported = await controller.exportJobs([_job('1', 'completed')]);

    expect(exported, isFalse);
    expect(controller.merged, isFalse);
    expect(controller.error, contains('合成导出错误'));
  });

  test('特别篇导出与删除委托给媒体库', () async {
    final (store, repository, library, operations) = await create();
    addTearDown(store.dispose);
    addTearDown(library.dispose);
    final item = _item();
    final controller = createController(repository, library, operations);

    expect(
      await controller.exportMerged(item),
      isTrue,
      reason: controller.error,
    );
    expect(operations.exportedMerged, same(item));
    expect(controller.merged, isFalse);

    expect(await controller.remove(item), isTrue);
    expect(operations.removed, same(item));
  });
}
