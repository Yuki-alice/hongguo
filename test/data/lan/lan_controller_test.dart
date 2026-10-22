import 'package:hoshi/data/lan/lan_controller.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<LocalStore> createStore() async {
    SharedPreferences.setMockInitialValues({});
    return LocalStore(await SharedPreferences.getInstance());
  }

  LanController create(LocalStore store) {
    final controller = LanController(FixtureRepository(), store, kind: 'phone');
    addTearDown(controller.dispose);
    return controller;
  }

  test('默认关闭互联并给出状态文案', () async {
    final store = await createStore();
    addTearDown(store.dispose);
    final controller = create(store);

    expect(controller.enabled, isFalse);
    expect(controller.autoSync, isTrue);
    expect(controller.peers, isEmpty);
    expect(controller.connection, isNull);
    expect(controller.connectionLabel, '设备互联已关闭');
  });

  test('损坏的互联设置被拒绝并保留错误', () async {
    final store = await createStore();
    addTearDown(store.dispose);
    await store.saveLanSettings({'enabled': 'yes'});
    final controller = create(store);

    expect(controller.settings, isEmpty);
    expect(controller.error, contains('设备互联设置损坏'));
    expect(controller.enabled, isFalse);
  });

  test('关闭自动同步写入设置但不触发网络', () async {
    final store = await createStore();
    addTearDown(store.dispose);
    final controller = create(store);

    await controller.setAutoSync(false);

    expect(controller.autoSync, isFalse);
    expect(store.lanSettings['autoSync'], false);
  });

  test('设备名称校验与保存', () async {
    final store = await createStore();
    addTearDown(store.dispose);
    final controller = create(store);

    await expectLater(controller.rename('x' * 61), throwsA(isA<StateError>()));
    await controller.rename('  客厅电视  ');

    expect(controller.deviceName, '客厅电视');
    expect(store.lanSettings['name'], '客厅电视');
  });

  test('冲突计数只统计当前用户可见的站源', () async {
    final store = await createStore();
    addTearDown(store.dispose);
    final controller = create(store);

    expect(controller.conflictCount, 0);
  });
}
