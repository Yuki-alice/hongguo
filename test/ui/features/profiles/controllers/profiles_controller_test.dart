import 'dart:async';

import 'package:hoshi/data/local_profiles.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/ui/features/profiles/controllers/profile_editor_controller.dart';
import 'package:hoshi/ui/features/profiles/controllers/profiles_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ProfileStore extends LocalStore {
  _ProfileStore(super.preferences);

  bool fail = false;
  Completer<void>? gate;
  String? switched;
  String? pinUsed;
  bool? forceLoginValue;
  bool deleted = false;
  Map<String, Object?>? saved;

  @override
  Future<void> switchProfile(String id, {String pin = ''}) async {
    await gate?.future;
    if (fail) throw StateError('密码错误');
    switched = id;
    pinUsed = pin;
  }

  @override
  Future<void> setForceLogin(bool value) async {
    if (fail) throw StateError('保存失败');
    forceLoginValue = value;
  }

  @override
  Future<void> reload() async {
    if (fail) throw StateError('读取失败');
  }

  @override
  Future<void> saveProfile({
    String? id,
    required String name,
    required List<String> sources,
    required bool download,
    String? pin,
  }) async {
    if (fail) throw StateError('保存用户失败');
    saved = {
      'id': id,
      'name': name,
      'sources': sources,
      'download': download,
      'pin': pin,
    };
  }

  @override
  Future<void> deleteProfile(String id) async {
    if (fail) throw StateError('删除失败');
    deleted = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<_ProfileStore> createStore() async {
    SharedPreferences.setMockInitialValues({});
    return _ProfileStore(await SharedPreferences.getInstance());
  }

  const child = LocalProfile(
    id: 'child',
    name: '儿童',
    sources: ['hongguo'],
    download: false,
  );

  group('ProfilesController', () {
    test('切换用户成功并传递密码', () async {
      final store = await createStore();
      addTearDown(store.dispose);
      final controller = ProfilesController(store);
      addTearDown(controller.dispose);
      var notifications = 0;
      controller.addListener(() => notifications++);

      final switched = await controller.switchProfile(child, pin: '123456');

      expect(switched, isTrue);
      expect(store.switched, 'child');
      expect(store.pinUsed, '123456');
      expect(controller.busy, isFalse);
      expect(controller.error, isNull);
      expect(notifications, 2);
    });

    test('切换失败保留错误并结束忙碌态', () async {
      final store = await createStore()
        ..fail = true;
      addTearDown(store.dispose);
      final controller = ProfilesController(store);
      addTearDown(controller.dispose);

      final switched = await controller.switchProfile(child);

      expect(switched, isFalse);
      expect(controller.busy, isFalse);
      expect(controller.error, contains('密码错误'));
    });

    test('操作进行中拒绝并发调用', () async {
      final store = await createStore();
      addTearDown(store.dispose);
      store.gate = Completer<void>();
      final controller = ProfilesController(store);
      addTearDown(controller.dispose);

      final pending = controller.switchProfile(child);
      expect(controller.busy, isTrue);
      final ignored = await controller.setForceLogin(true);
      expect(ignored, isFalse);
      expect(store.forceLoginValue, isNull);

      store.gate!.complete();
      expect(await pending, isTrue);
      expect(controller.busy, isFalse);
    });

    test('重新读取与强制登录走同一错误通道', () async {
      final store = await createStore()
        ..fail = true;
      addTearDown(store.dispose);
      final controller = ProfilesController(store);
      addTearDown(controller.dispose);

      expect(await controller.reload(), isFalse);
      expect(controller.error, contains('读取失败'));

      store.fail = false;
      expect(await controller.setForceLogin(true), isTrue);
      expect(store.forceLoginValue, isTrue);
      expect(controller.error, isNull);
    });

    test('外部文件错误可通过 report 展示', () async {
      final store = await createStore();
      addTearDown(store.dispose);
      final controller = ProfilesController(store);
      addTearDown(controller.dispose);

      controller.report(const FormatException('备份文件过大或无法读取'));

      expect(controller.error, contains('备份文件过大或无法读取'));
    });
  });

  group('ProfileEditorController', () {
    test('保存时传递表单字段并清除密码', () async {
      final store = await createStore();
      addTearDown(store.dispose);
      final controller = ProfileEditorController(store: store, profile: child);
      addTearDown(controller.dispose);

      final saved = await controller.save(
        name: '儿童模式',
        sources: const ['hongguo', 'huaguo'],
        download: true,
        pin: '123456',
        confirmPin: '123456',
        clearPin: true,
      );

      expect(saved, isTrue);
      expect(store.saved!['id'], 'child');
      expect(store.saved!['name'], '儿童模式');
      expect(store.saved!['download'], true);
      expect(store.saved!['pin'], '');
      expect(controller.busy, isFalse);
    });

    test('两次密码不一致时不请求仓库', () async {
      final store = await createStore();
      addTearDown(store.dispose);
      final controller = ProfileEditorController(store: store);
      addTearDown(controller.dispose);

      final saved = await controller.save(
        name: '新用户',
        sources: const [],
        download: false,
        pin: '123456',
        confirmPin: '654321',
        clearPin: false,
      );

      expect(saved, isFalse);
      expect(store.saved, isNull);
      expect(controller.error, contains('两次输入的密码不一致'));
    });

    test('保存失败保留错误', () async {
      final store = await createStore()
        ..fail = true;
      addTearDown(store.dispose);
      final controller = ProfileEditorController(store: store);
      addTearDown(controller.dispose);

      final saved = await controller.save(
        name: '新用户',
        sources: const [],
        download: false,
        pin: '',
        confirmPin: '',
        clearPin: false,
      );

      expect(saved, isFalse);
      expect(controller.error, contains('保存用户失败'));
      expect(controller.busy, isFalse);
    });

    test('删除用户成功后结束忙碌态', () async {
      final store = await createStore();
      addTearDown(store.dispose);
      final controller = ProfileEditorController(store: store, profile: child);
      addTearDown(controller.dispose);

      expect(await controller.delete(), isTrue);
      expect(store.deleted, isTrue);
      expect(controller.error, isNull);
    });
  });
}
