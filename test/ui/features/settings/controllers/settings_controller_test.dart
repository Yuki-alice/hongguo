import 'package:hoshi/data/app_contract.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/ui/features/settings/controllers/settings_controller.dart';
import 'package:hoshi/ui/features/settings/controllers/storage_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../support/fixtures.dart';

class _SettingsStore extends LocalStore {
  _SettingsStore(super.preferences);

  bool failImport = false;
  bool failAuto = false;
  String? imported;
  bool? autoExportValue;

  @override
  Future<void> importBackup(String content) async {
    if (failImport) throw AppFailure('合成恢复失败');
    imported = content;
  }

  @override
  Future<void> setAutoExport(bool value) async {
    if (failAuto) throw AppFailure('合成自动导出失败');
    autoExportValue = value;
  }
}

class _StorageRepository extends FixtureRepository {
  Map<String, dynamic> info = {
    'directory': '/media',
    'bytes': 1024,
    'free': 2048,
    'files': 2,
  };
  bool failStorage = false;
  String? moved;

  @override
  Future<Map<String, dynamic>> storage() async {
    if (failStorage) throw AppFailure('合成空间读取失败');
    return info;
  }

  @override
  Future<void> moveDownloads(String directory) async {
    if (failStorage) throw AppFailure('合成迁移失败');
    moved = directory;
    info = {...info, 'directory': directory};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<_SettingsStore> createStore() async {
    SharedPreferences.setMockInitialValues({});
    return _SettingsStore(await SharedPreferences.getInstance());
  }

  group('SettingsController', () {
    test('恢复备份成功后结束忙碌态', () async {
      final store = await createStore();
      addTearDown(store.dispose);
      final controller = SettingsController(store);
      addTearDown(controller.dispose);

      final restored = await controller.restoreBackup('{"backup":true}');

      expect(restored, isTrue);
      expect(store.imported, '{"backup":true}');
      expect(controller.busy, isFalse);
      expect(controller.message, isNull);
    });

    test('恢复失败通过消息展示', () async {
      final store = await createStore()
        ..failImport = true;
      addTearDown(store.dispose);
      final controller = SettingsController(store);
      addTearDown(controller.dispose);

      final restored = await controller.restoreBackup('{}');

      expect(restored, isFalse);
      expect(controller.message, contains('合成恢复失败'));
      expect(controller.busy, isFalse);
    });

    test('自动导出开关写入仓库', () async {
      final store = await createStore();
      addTearDown(store.dispose);
      final controller = SettingsController(store);
      addTearDown(controller.dispose);

      expect(await controller.setAutoExport(true), isTrue);
      expect(store.autoExportValue, isTrue);

      store.failAuto = true;
      expect(await controller.setAutoExport(false), isFalse);
      expect(controller.message, contains('合成自动导出失败'));
    });
  });

  group('StorageController', () {
    test('刷新读取目录用量', () async {
      final repository = _StorageRepository();
      final controller = StorageController(repository);
      addTearDown(controller.dispose);

      await controller.refresh();

      expect(controller.info?['directory'], '/media');
      expect(controller.error, isNull);
      expect(controller.busy, isFalse);
    });

    test('刷新失败保留错误', () async {
      final repository = _StorageRepository()..failStorage = true;
      final controller = StorageController(repository);
      addTearDown(controller.dispose);

      await controller.refresh();

      expect(controller.error, contains('合成空间读取失败'));
      expect(controller.info, isNull);
    });

    test('迁移目录后刷新用量', () async {
      final repository = _StorageRepository();
      final controller = StorageController(repository);
      addTearDown(controller.dispose);
      var notifications = 0;
      controller.addListener(() => notifications++);

      final moved = await controller.move('/new-media');

      expect(moved, isTrue);
      expect(repository.moved, '/new-media');
      expect(controller.info?['directory'], '/new-media');
      expect(controller.busy, isFalse);
      expect(notifications, greaterThanOrEqualTo(3));
    });

    test('迁移失败保留错误并结束忙碌态', () async {
      final repository = _StorageRepository()..failStorage = true;
      final controller = StorageController(repository);
      addTearDown(controller.dispose);

      final moved = await controller.move('/new-media');

      expect(moved, isFalse);
      expect(controller.error, contains('合成迁移失败'));
      expect(controller.busy, isFalse);
    });
  });
}
