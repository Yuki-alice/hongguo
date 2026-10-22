import 'package:hoshi/data/lan/lan_controller.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/ui/features/lan/controllers/lan_sync_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../support/fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(LanController, LanSyncController)> create() async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    final link = LanController(FixtureRepository(), store, kind: 'phone');
    addTearDown(link.dispose);
    final controller = LanSyncController(link: link);
    addTearDown(controller.dispose);
    return (link, controller);
  }

  test('初始状态允许操作且没有错误', () async {
    final (_, controller) = await create();
    expect(controller.busy, isFalse);
    expect(controller.cancelling, isFalse);
    expect(controller.error, isNull);
    expect(controller.controlsEnabled, isTrue);
  });

  test('执行期间置忙并只通知一次开始与一次结束', () async {
    final (_, controller) = await create();
    var notifications = 0;
    controller.addListener(() => notifications++);
    final started = <bool>[];
    await controller.perform(() async => started.add(controller.busy));

    expect(started, [true]);
    expect(controller.busy, isFalse);
    expect(notifications, 2);
  });

  test('并发调用在忙碌时被忽略', () async {
    final (_, controller) = await create();
    var runs = 0;
    final first = controller.perform(() async {
      runs++;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await controller.perform(() async => runs++);
    await first;

    expect(runs, 1);
  });

  test('动作失败保留错误文案，下一次动作前清除', () async {
    final (_, controller) = await create();
    await controller.perform(() async => throw StateError('设备不可达'));
    expect(controller.error, contains('设备不可达'));
    expect(controller.busy, isFalse);

    await controller.perform(() async {});
    expect(controller.error, isNull);
  });

  test('clearError 只在有错误时通知', () async {
    final (_, controller) = await create();
    var notifications = 0;
    controller.addListener(() => notifications++);

    controller.clearError();
    expect(notifications, 0);

    await controller.perform(() async => throw StateError('失败'));
    notifications = 0;
    controller.clearError();
    expect(controller.error, isNull);
    expect(notifications, 1);
  });

  test('取消动作标记取消状态并在结束后复位', () async {
    final (link, controller) = await create();
    final cancelling = <bool>[];
    await controller.cancelSync();
    cancelling.add(controller.cancelling);

    expect(cancelling, [false]);
    expect(controller.error, isNull);
    expect(link.enabled, isFalse);
  });

  test('取消同步失败时保留错误文案', () async {
    final (_, controller) = await create();
    await controller.cancelSync();
    expect(controller.cancelling, isFalse);
    expect(controller.error, isNull);
  });
}
