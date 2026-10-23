import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/main.dart';
import 'package:hoshi/ui/routing/app_router.dart';
import 'package:hoshi/ui/routing/route_args.dart';

import '../../support/interface_fixtures.dart';
import '../../support/library_fixtures.dart';
import '../../support/router_harness.dart';

/// 渲染各视口的界面为 PNG，供人工比对。
///
/// 这不是断言型测试：它只出图，不做通过/失败判断，因此不进入 CI 的
/// 阻断路径（用 `--tags capture` 单独跑）。渲染前加载系统中文与图标
/// 字体，否则测试环境里的方块字会让截图失去参考价值。
///
/// ```sh
/// flutter test test/ui/shell/capture_screens_test.dart \
///   --dart-define=CAPTURE_SCREENS=true --update-goldens
/// ```
///
/// 输出在 `test/ui/shell/captures/`。默认套件会跳过本文件。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 默认套件跳过：这些用例只出图、不做断言，且依赖宿主系统字体。
  const enabled = bool.fromEnvironment('CAPTURE_SCREENS');

  setUpAll(() async {
    // 只注册中文字体，**不注册 Roboto**：同一族里如果既有 Roboto 又有
    // 中文字体，w400 / w500 会精确命中 Roboto 而拿不到中文字形，截图里
    // 就出现「粗体是中文、常规体是方块」的怪状。只留中文字体后，各字重
    // 都由它合成，画面才和真机一致。
    await _loadFonts('Roboto', [
      '/System/Library/Fonts/Hiragino Sans GB.ttc',
      '/System/Library/Fonts/STHeiti Medium.ttc',
    ]);
    await _loadFonts('MaterialIcons', [
      '${_flutterRoot()}/bin/cache/artifacts/material_fonts/'
          'MaterialIcons-Regular.otf',
    ]);
  });

  for (final (name, size, scale) in const [
    ('phone', Size(390, 844), 1.0),
    ('rail', Size(760, 860), 1.0),
    ('tablet', Size(900, 900), 1.0),
    ('desktop', Size(1280, 860), 1.0),
    ('wide', Size(1600, 1000), 1.0),
    ('desktop-large-text', Size(1280, 860), 1.3),
  ]) {
    testWidgets('discover @ $name', (tester) async {
      await _pump(tester, size, scale);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('captures/discover-$name.png'),
      );
    }, tags: 'capture', skip: !enabled);

    testWidgets('settings @ $name', (tester) async {
      await _pump(tester, size, scale);
      await _openSettings(tester);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('captures/settings-$name.png'),
      );
    }, tags: 'capture', skip: !enabled);


    testWidgets('downloads @ $name', (tester) async {
      await _pump(tester, size, scale);
      // 下载分支：宽窗口应显示主从两栏。
      // 横屏走 rail，竖屏走底部导航。
      final rail = find.byKey(const ValueKey('rail-nav-downloads'));
      if (rail.evaluate().isNotEmpty) {
        await tester.tap(rail);
      } else {
        await tester.tap(find.byKey(const ValueKey('bottom-nav-3')));
      }
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('captures/downloads-$name.png'),
      );
    }, tags: 'capture', skip: !enabled);

    testWidgets('sources @ $name', (tester) async {
      // 站源页要求仓库支持站源管理；InterfaceRepository 不支持，
      // 因此单独用 LibraryFeatureRepository 起一屏。
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      final repository = LibraryFeatureRepository();
      await pumpRouterApp(
        tester,
        repository: repository,
        store: store,
        location: AppRoutes.sources,
      );
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('captures/sources-$name.png'),
      );
    }, tags: 'capture', skip: !enabled);

    testWidgets('detail @ $name', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      await store.setHideVip(false);

      // 直接落到详情路由：点卡片会先起播放器，测试环境没有 MediaKit。
      final repository = InterfaceRepository();
      final drama = InterfaceRepository().dramas('hongguo').first;
      final ref = DramaRef.fromDramaId(drama.id)!;
      await pumpRouterApp(
        tester,
        repository: repository,
        store: store,
        location: AppRoutes.detailOf(ref),
        extra: drama,
      );
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('captures/detail-$name.png'),
      );
    }, tags: 'capture', skip: !enabled);

    testWidgets('theme settings @ $name', (tester) async {
      await _pump(tester, size, scale);
      await _openSettings(tester);
      await tester.tap(find.byKey(const ValueKey('theme-setting')));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('captures/theme-$name.png'),
      );
    }, tags: 'capture', skip: !enabled);
  }
}

Future<void> _pump(WidgetTester tester, Size size, double scale) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  SharedPreferences.setMockInitialValues({});
  final store = LocalStore(await SharedPreferences.getInstance());
  addTearDown(store.dispose);
  await store.setHideVip(false);

  final repository = InterfaceRepository();
  await tester.pumpWidget(DuanjuApp(repository: repository, store: store));
  await tester.pumpAndSettle();
}

/// 打开设置。三种导航形态的入口不同：侧栏 / 图标轨 / 「更多」菜单。
Future<void> _openSettings(WidgetTester tester) async {
  final sidebar = find.byKey(const ValueKey('rail-nav-settings'));
  if (sidebar.evaluate().isNotEmpty) {
    await tester.tap(sidebar);
    await tester.pumpAndSettle();
    return;
  }
  final rail = find.byKey(const ValueKey('rail-settings'));
  if (rail.evaluate().isNotEmpty) {
    await tester.tap(rail);
    await tester.pumpAndSettle();
    return;
  }
  await tester.tap(find.byTooltip('更多'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('设置与备份'));
  await tester.pumpAndSettle();
}

Future<void> _loadFonts(String family, List<String> paths) async {
  final loader = FontLoader(family);
  var loaded = 0;
  for (final path in paths) {
    final file = File(path);
    if (!file.existsSync()) continue;
    loader.addFont(
      Future.value(ByteData.sublistView(file.readAsBytesSync())),
    );
    loaded++;
  }
  if (loaded > 0) await loader.load();
}

String _flutterRoot() =>
    Platform.environment['FLUTTER_ROOT'] ?? '/Users/kurisu/devtools/flutter';
