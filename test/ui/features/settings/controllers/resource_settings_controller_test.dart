import 'package:duanju_app/data/core_bridge.dart';
import 'package:duanju_app/data/local_store.dart';
import 'package:duanju_app/domain/resource_settings.dart';
import 'package:duanju_app/ui/features/settings/controllers/resource_settings_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../fixtures.dart';

class _ResourceRepository extends FixtureRepository {
  ResourceSettings settings = const ResourceSettings();
  bool failLoad = false;
  bool failSave = false;
  ResourceSettings? saved;

  @override
  Future<ResourceSettings> resourceSettings() async {
    if (failLoad) throw AppFailure('合成资源设置错误');
    return settings;
  }

  @override
  Future<ResourceSettings> saveResourceSettings(
    ResourceSettings settings,
  ) async {
    if (failSave) throw AppFailure('合成保存错误');
    saved = settings;
    this.settings = settings;
    return settings;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(LocalStore, _ResourceRepository)> create() async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    return (store, _ResourceRepository());
  }

  ResourceSettingsController createController(
    LocalStore store,
    _ResourceRepository repository, {
    int? profileEpoch,
  }) {
    final controller = ResourceSettingsController(
      repository: repository,
      store: store,
      profileEpoch: profileEpoch ?? store.profileEpoch,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  test('加载设置并填充表单字段', () async {
    final (store, repository) = await create();
    addTearDown(store.dispose);
    repository.settings = const ResourceSettings(
      proxyMode: 'manual',
      proxyUrl: 'http://127.0.0.1:7890',
      catalogConcurrency: 5,
      catalogIntervalMs: 500,
      downloadConcurrency: 3,
      downloadBySource: true,
      warning: '合成警告',
    );
    final controller = createController(store, repository);

    await controller.load();

    expect(controller.settings, isNotNull);
    expect(controller.mode, 'manual');
    expect(controller.catalog, 5);
    expect(controller.interval, 500);
    expect(controller.downloads, 3);
    expect(controller.folders, isTrue);
    expect(controller.settings?.warning, '合成警告');
    expect(controller.allowed, isTrue);
  });

  test('保存使用表单值并去除代理首尾空格', () async {
    final (store, repository) = await create();
    addTearDown(store.dispose);
    final controller = createController(store, repository);
    await controller.load();
    controller.setMode('manual');
    controller.setCatalog(4);
    controller.setInterval(1000);
    controller.setDownloads(6);
    controller.setFolders(true);

    final saved = await controller.save(proxyUrl: '  http://127.0.0.1:7891  ');

    expect(saved, isTrue);
    expect(repository.saved?.proxyMode, 'manual');
    expect(repository.saved?.proxyUrl, 'http://127.0.0.1:7891');
    expect(repository.saved?.catalogConcurrency, 4);
    expect(repository.saved?.catalogIntervalMs, 1000);
    expect(repository.saved?.downloadConcurrency, 6);
    expect(repository.saved?.downloadBySource, isTrue);
    expect(controller.busy, isFalse);
  });

  test('加载与保存失败写入错误', () async {
    final (store, repository) = await create();
    addTearDown(store.dispose);
    repository.failLoad = true;
    final controller = createController(store, repository);

    await controller.load();
    expect(controller.error, contains('合成资源设置错误'));

    repository.failLoad = false;
    await controller.load();
    repository.failSave = true;
    final saved = await controller.save(proxyUrl: '');
    expect(saved, isFalse);
    expect(controller.error, contains('合成保存错误'));
  });

  test('用户代次不一致时拒绝加载与保存', () async {
    final (store, repository) = await create();
    addTearDown(store.dispose);
    final controller = createController(
      store,
      repository,
      profileEpoch: store.profileEpoch + 1,
    );

    await controller.load();
    final saved = await controller.save(proxyUrl: '');

    expect(controller.allowed, isFalse);
    expect(controller.settings, isNull);
    expect(saved, isFalse);
    expect(repository.saved, isNull);
  });

  test('表单 setter 只在调用时通知', () async {
    final (store, repository) = await create();
    addTearDown(store.dispose);
    final controller = createController(store, repository);
    var notifications = 0;
    controller.addListener(() => notifications++);

    controller.setCatalog(4);
    controller.setFolders(true);

    expect(controller.catalog, 4);
    expect(controller.folders, isTrue);
    expect(notifications, 2);
  });
}
