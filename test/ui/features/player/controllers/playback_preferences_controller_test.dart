import 'package:duanju_app/data/local_store.dart';
import 'package:duanju_app/domain/playback_preferences.dart';
import 'package:duanju_app/ui/features/player/controllers/playback_preferences_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<LocalStore> createStore() async {
    SharedPreferences.setMockInitialValues({});
    return LocalStore(await SharedPreferences.getInstance());
  }

  test('初始值来自偏好，自动连播与预加载固定开启', () async {
    final store = await createStore();
    addTearDown(store.dispose);
    await store.setPlaybackPreferences(
      const PlaybackPreferences(speed: 1.5, danmaku: false),
    );
    final controller = PlaybackPreferencesController(
      store: store,
      profileEpoch: store.profileEpoch,
      initial: store.playbackPreferences,
    );
    addTearDown(controller.dispose);

    expect(controller.speed, 1.5);
    expect(controller.danmakuEnabled, isFalse);
    expect(controller.autoAdvance, isTrue);
    expect(controller.preloadEnabled, isTrue);
  });

  test('保存偏好写入存储并通知页面', () async {
    final store = await createStore();
    addTearDown(store.dispose);
    final controller = PlaybackPreferencesController(
      store: store,
      profileEpoch: store.profileEpoch,
      initial: store.playbackPreferences,
    );
    addTearDown(controller.dispose);
    var notifications = 0;
    controller.addListener(() => notifications++);

    final saved = await controller.save(
      const PlaybackPreferences(
        speed: 2,
        quality: 1080,
        autoAdvance: false,
        danmaku: false,
        preload: false,
      ),
    );

    expect(saved, isTrue);
    expect(controller.speed, 2);
    expect(controller.danmakuEnabled, isFalse);
    expect(controller.autoAdvance, isTrue);
    expect(controller.preloadEnabled, isTrue);
    expect(notifications, 1);
    final stored = store.playbackPreferences;
    expect(stored.speed, 2);
    expect(stored.quality, 1080);
    expect(stored.danmaku, isFalse);
    expect(stored.autoAdvance, isTrue);
    expect(stored.preload, isTrue);
  });

  test('用户不一致时不更新内存状态', () async {
    final store = await createStore();
    addTearDown(store.dispose);
    final controller = PlaybackPreferencesController(
      store: store,
      profileEpoch: store.profileEpoch + 1,
      initial: store.playbackPreferences,
    );
    addTearDown(controller.dispose);
    var notifications = 0;
    controller.addListener(() => notifications++);

    final saved = await controller.save(
      const PlaybackPreferences(speed: 2, danmaku: false),
    );

    expect(saved, isFalse);
    expect(controller.speed, 1);
    expect(controller.danmakuEnabled, isTrue);
    expect(notifications, 0);
  });
}
