import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/domain/window_bounds.dart';

/// 桌面窗口状态持久化。
///
/// 窗口尺寸与关闭行为是设备属性（不属于某个用户档案），因此不受档案
/// 切换影响；这两条是 `DesktopWindow` 恢复窗口时的前提。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<LocalStore> create([Map<String, Object> initial = const {}]) async {
    SharedPreferences.setMockInitialValues(initial);
    return LocalStore(await SharedPreferences.getInstance());
  }

  group('窗口边界', () {
    test('默认没有保存过', () async {
      final store = await create();
      addTearDown(store.dispose);
      expect(store.windowBounds, isNull);
    });

    test('保存后重启仍能读回', () async {
      final store = await create();
      addTearDown(store.dispose);
      const bounds = WindowBounds(
        left: 120,
        top: 80,
        width: 1440,
        height: 900,
      );
      await store.setWindowBounds(bounds);

      final restored = LocalStore(store.preferences);
      addTearDown(restored.dispose);
      expect(restored.windowBounds, bounds);
    });

    test('损坏的 JSON 不会让启动失败', () async {
      final store = await create({'windowBounds': '{not json'});
      addTearDown(store.dispose);
      expect(store.windowBounds, isNull);
    });

    test('字段缺失时按损坏处理', () async {
      final store = await create({'windowBounds': '{"left": 10}'});
      addTearDown(store.dispose);
      expect(store.windowBounds, isNull);
    });

    test('窗口边界不随用户档案切换', () async {
      final store = await create();
      addTearDown(store.dispose);
      const bounds = WindowBounds(
        left: 0,
        top: 0,
        width: 1280,
        height: 860,
      );
      await store.setWindowBounds(bounds);
      // 档案命名空间只作用于用户数据；窗口尺寸是设备级设置。
      expect(store.windowBounds, bounds);
    });
  });

  group('关闭行为', () {
    test('默认每次询问', () async {
      final store = await create();
      addTearDown(store.dispose);
      expect(store.closeBehavior, CloseBehavior.ask);
    });

    test('三种行为都能保存与读回', () async {
      final store = await create();
      addTearDown(store.dispose);
      for (final behavior in CloseBehavior.values) {
        await store.setCloseBehavior(behavior);
        expect(store.closeBehavior, behavior);
      }
    });

    test('非法值回落到询问', () async {
      final store = await create({'closeBehavior': 'destroyEverything'});
      addTearDown(store.dispose);
      expect(store.closeBehavior, CloseBehavior.ask);
    });
  });

  group('备份兼容', () {
    test('导出备份包含窗口设置，且旧备份仍可导入', () async {
      final store = await create();
      addTearDown(store.dispose);
      await store.setCloseBehavior(CloseBehavior.minimizeToTray);
      final backup = await store.exportBackup();

      // 旧备份里没有这两个键，导入时不应报错。
      final older = backup.replaceAll(
        RegExp(r'"windowBounds":\{[^}]*\},?'),
        '',
      ).replaceAll(RegExp(r'"closeBehavior":"[^"]*",?'), '');
      final restored = LocalStore(store.preferences);
      addTearDown(restored.dispose);
      await restored.importBackup(older);
      expect(restored.closeBehavior, CloseBehavior.ask);
    });
  });
}
