import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/ui/features/player/controllers/playback_progress_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../support/fixtures.dart';

class _FailingStore extends LocalStore {
  _FailingStore(super.preferences);

  @override
  Future<void> saveWatch(WatchEntry entry) async {
    throw StateError('合成存储失败');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<LocalStore> createStore() async {
    SharedPreferences.setMockInitialValues({});
    return LocalStore(await SharedPreferences.getInstance());
  }

  List<Episode> episodes() => [
    for (var number = 1; number <= 3; number++)
      Episode({'id': '$number', 'currentEpisode': number}, number),
  ];

  PlaybackProgressController create(
    LocalStore store, {
    String? mediaId,
    int? profileEpoch,
    void Function()? onFlush,
  }) => PlaybackProgressController(
    repository: FixtureRepository(),
    store: store,
    drama: FixtureRepository.free,
    episodes: episodes(),
    profileEpoch: profileEpoch ?? store.profileEpoch,
    mediaId: mediaId,
    onFlush: onFlush,
  );

  test('保存观看进度并记录当前分集', () async {
    final store = await createStore();
    addTearDown(store.dispose);
    final controller = create(store);
    addTearDown(controller.dispose);

    controller.markOpened(1);
    await controller.save(
      position: const Duration(seconds: 30),
      duration: const Duration(seconds: 100),
    );

    final watch = store.watched(FixtureRepository.free.id);
    expect(watch, isNotNull);
    expect(watch!.episode, 2);
    expect(watch.position, 30);
    expect(watch.duration, 100);
    expect(controller.warning, isNull);
  });

  test('相同进度去重，flush 仍会通知局域网', () async {
    final store = await createStore();
    addTearDown(store.dispose);
    var flushes = 0;
    final controller = create(store, onFlush: () => flushes++);
    addTearDown(controller.dispose);

    controller.markOpened(0);
    await controller.save(
      position: const Duration(seconds: 30),
      duration: const Duration(seconds: 100),
    );
    expect(flushes, 0);

    await controller.save(
      position: const Duration(seconds: 30),
      duration: const Duration(seconds: 100),
      flush: true,
    );
    expect(flushes, 1);

    await controller.save(
      position: const Duration(seconds: 31),
      duration: const Duration(seconds: 100),
    );
    expect(store.watched(FixtureRepository.free.id)!.position, 31);
  });

  test('媒体播放写入独立进度，不污染剧集历史', () async {
    final store = await createStore();
    addTearDown(store.dispose);
    final controller = create(store, mediaId: 'media-1');
    addTearDown(controller.dispose);

    controller.markOpened(0);
    await controller.save(
      position: const Duration(seconds: 12),
      duration: const Duration(seconds: 80),
    );

    expect(store.mediaWatched('media-1')!.position, 12);
    expect(store.watched(FixtureRepository.free.id), isNull);
  });

  test('保存失败给出提示且只通知一次', () async {
    SharedPreferences.setMockInitialValues({});
    final store = _FailingStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    final controller = create(store);
    addTearDown(controller.dispose);
    var notifications = 0;
    controller.addListener(() => notifications++);

    controller.markOpened(0);
    await controller.save(
      position: const Duration(seconds: 12),
      duration: const Duration(seconds: 80),
    );

    expect(controller.warning, '观看进度尚未保存，请检查存储空间后重试。');
    expect(notifications, 1);
  });

  test('关闭分集或用户不一致时不写进度', () async {
    final store = await createStore();
    addTearDown(store.dispose);
    final closed = create(store);
    addTearDown(closed.dispose);
    closed.markOpened(0);
    closed.close();
    await closed.save(
      position: const Duration(seconds: 30),
      duration: const Duration(seconds: 100),
    );
    expect(store.watched(FixtureRepository.free.id), isNull);

    final stale = create(store, profileEpoch: store.profileEpoch + 1);
    addTearDown(stale.dispose);
    stale.markOpened(0);
    await stale.save(
      position: const Duration(seconds: 30),
      duration: const Duration(seconds: 100),
    );
    expect(store.watched(FixtureRepository.free.id), isNull);
  });

  test('只有当前打开分集的位置更新续播点', () async {
    final store = await createStore();
    addTearDown(store.dispose);
    final controller = create(store);
    addTearDown(controller.dispose);

    controller.markOpened(1);
    controller.notePosition(const Duration(seconds: 12), 1);
    expect(controller.resumePosition, 12);
    controller.notePosition(const Duration(seconds: 20), 0);
    expect(controller.resumePosition, 12);
  });
}
