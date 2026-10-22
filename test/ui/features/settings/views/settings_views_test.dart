import 'package:duanju_app/data/local_store.dart';
import 'package:duanju_app/domain/resource_settings.dart';
import 'package:duanju_app/l10n/generated/app_localizations.dart';
import 'package:duanju_app/ui/features/settings/views/resource_settings_screen.dart';
import 'package:duanju_app/ui/features/settings/views/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../support/fixtures.dart';

class _SettingsRepository extends FixtureRepository {
  ResourceSettings settings = const ResourceSettings(
    catalogConcurrency: 4,
    catalogIntervalMs: 500,
    downloadConcurrency: 2,
  );
  ResourceSettings? saved;
  Map<String, dynamic> storageInfo = {
    'directory': '/media',
    'bytes': 1024,
    'free': 2048,
    'files': 2,
  };

  @override
  Future<ResourceSettings> resourceSettings() async => settings;

  @override
  Future<ResourceSettings> saveResourceSettings(
    ResourceSettings settings,
  ) async {
    saved = settings;
    return settings;
  }

  @override
  Future<Map<String, dynamic>> storage() async => storageInfo;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<LocalStore> createStore() async {
    SharedPreferences.setMockInitialValues({});
    return LocalStore(await SharedPreferences.getInstance());
  }

  Widget app(Widget home) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: home,
  );

  testWidgets('资源设置加载显示并保存', (tester) async {
    final store = await createStore();
    addTearDown(store.dispose);
    final repository = _SettingsRepository();
    await tester.pumpWidget(
      app(ResourceSettingsScreen(repository: repository, store: store)),
    );
    await tester.pumpAndSettle();

    expect(find.text('网络与资源'), findsOneWidget);
    expect(find.text('目录请求并发'), findsOneWidget);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(repository.saved, isNotNull);
    expect(repository.saved?.catalogConcurrency, 4);
    expect(repository.saved?.catalogIntervalMs, 500);
    expect(find.text('设置已保存，将用于后续请求和下载任务'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('存储页展示用量与目录', (tester) async {
    final store = await createStore();
    addTearDown(store.dispose);
    final repository = _SettingsRepository();
    await tester.pumpWidget(
      app(StorageScreen(repository: repository, store: store)),
    );
    await tester.pumpAndSettle();

    expect(find.text('下载目录与空间'), findsOneWidget);
    expect(find.text('已使用 1.0 KB'), findsOneWidget);
    expect(find.text('当前下载目录'), findsOneWidget);
    expect(find.text('/media'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
