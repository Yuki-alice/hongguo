import 'dart:async';

import 'package:duanju_app/ui/core/app_theme.dart';
import 'package:duanju_app/app_build.dart';
import 'package:duanju_app/data/core_bridge.dart';
import 'package:duanju_app/ui/features/downloads/views/downloads_screen.dart';
import 'package:duanju_app/data/local_store.dart';
import 'package:duanju_app/main.dart';
import 'package:duanju_app/domain/models.dart';
import 'package:duanju_app/ui/core/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:duanju_app/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'interface_fixtures.dart';

void main() {
  Future<LocalStore> localStore() async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    return store;
  }

  void viewport(WidgetTester tester, Size size, [double scale = 1]) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  testWidgets(
    'refresh rotates during a request and stops after success or failure',
    (tester) async {
      // 刷新按钮在窄屏（< 400）被刻意隐藏，换成底部下拉刷新；
      // 这条测试验的是按钮态，因此用平板宽度。
      viewport(tester, const Size(800, 900));
      final repository = InterfaceRepository();
      await tester.pumpWidget(
        DuanjuApp(repository: repository, store: await localStore()),
      );
      await tester.pumpAndSettle();
      final refresh = find.byKey(const ValueKey('catalog-refresh'));
      final rotation = find.descendant(
        of: refresh,
        matching: find.byType(RotationTransition),
      );
      final button = find.descendant(
        of: refresh,
        matching: find.byType(IconButton),
      );
      for (final fails in [false, true]) {
        final pending = Completer<CatalogPage>();
        repository.pendingCatalog = pending;
        final requests = repository.requests.length;
        await tester.tap(refresh);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        final firstAngle = tester
            .widget<RotationTransition>(rotation)
            .turns
            .value;
        await tester.pump(const Duration(milliseconds: 250));
        expect(
          tester.widget<RotationTransition>(rotation).turns.value,
          isNot(firstAngle),
        );
        expect(tester.widget<IconButton>(button).onPressed, isNull);
        expect(find.text('短标题'), findsOneWidget);
        await tester.tap(refresh);
        expect(repository.requests.length, requests + 1);
        repository.pendingCatalog = null;
        if (fails) {
          pending.completeError(AppFailure('合成更新失败'));
        } else {
          pending.complete(CatalogPage(repository.dramas('hongguo')));
        }
        await tester.pumpAndSettle();
        expect(tester.widget<RotationTransition>(rotation).turns.value, 0);
        expect(tester.widget<IconButton>(button).onPressed, isNotNull);
        // 刷新失败时列表里已有旧数据，按设计不覆盖成全屏错误页；
        // 只有空列表才显示 `StatusPanel`。这里断言旧内容仍在、且没有抛异常。
        expect(find.text('短标题'), findsOneWidget);
        if (fails) {
          expect(
            find.byType(StatusPanel),
            findsNothing,
            reason: '有旧数据时不覆盖成全屏错误页',
          );
        }
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('only Huangdou exposes and applies the persistent VIP filter', (
    tester,
  ) async {
    viewport(tester, const Size(390, 844));
    final repository = InterfaceRepository();
    final store = await localStore();
    await tester.pumpWidget(DuanjuApp(repository: repository, store: store));
    await tester.pumpAndSettle();
    Future<void> select(String name) async {
      if (SourceGroup.fromSources(SourceSite.values).length <= 1) return;
      await tester.tap(find.byKey(const ValueKey('source-switch')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(name).last);
      await tester.pumpAndSettle();
    }

    for (final group in SourceGroup.fromSources(SourceSite.values)) {
      await select(group.name);
      if (group.id == 'huangdou') {
        expect(find.text('会员合成剧'), findsNothing);
        await tester.tap(find.byTooltip('VIP：隐藏'));
        await tester.pumpAndSettle();
        expect(find.text('会员合成剧'), findsOneWidget);
      } else {
        expect(find.byTooltip('VIP：隐藏'), findsNothing);
        expect(find.byTooltip('VIP：显示'), findsNothing);
        expect(find.text('会员合成剧'), findsWidgets);
      }
    }
    if (!allSourcesEnabled) {
      for (final source in SourceSite.knownValues.skip(1)) {
        expect(find.widgetWithText(ChoiceChip, source.name), findsNothing);
      }
      return;
    }
    await select('黄豆');
    expect(find.byTooltip('VIP：显示'), findsOneWidget);
    await tester.tap(find.byTooltip('VIP：显示'));
    await tester.pumpAndSettle();
    expect(store.hideVip, isTrue);
    await select('红果');
    expect(find.text('会员合成剧'), findsOneWidget);
    expect(find.textContaining('VIP：'), findsNothing);
  });

  for (final layout in [
    (const Size(390, 844), 1.0, false),
    (const Size(320, 844), 2.0, false),
    (const Size(1280, 800), 1.0, false),
    (const Size(960, 540), 1.0, true),
  ]) {
    testWidgets('posters align across catalog and saved pages at $layout', (
      tester,
    ) async {
      viewport(tester, layout.$1, layout.$2);
      final repository = InterfaceRepository();
      final store = await localStore();
      for (final drama in repository.dramas('hongguo')) {
        await store.toggleFavorite(drama);
        await store.saveWatch(
          WatchEntry(
            drama: drama,
            episode: 1,
            position: 15,
            duration: 60,
            updatedAt: DateTime.now(),
          ),
        );
      }
      await tester.pumpWidget(
        DuanjuApp(repository: repository, store: store, television: layout.$3),
      );
      await tester.pumpAndSettle();
      Size? catalogSize;
      for (var tab = 0; tab < 3; tab++) {
        if (tab > 0) {
          final destination = layout.$3
              ? find.byKey(ValueKey('tv-nav-$tab'))
              : layout.$1.width < 840
              ? find.byKey(ValueKey('bottom-nav-$tab'))
              : find.descendant(
                  of: find.byType(NavigationRail),
                  matching: find.text(tab == 1 ? '追剧' : '最近观看'),
                );
          await tester.tap(destination);
          await tester.pumpAndSettle();
        }
        final covers = find.byType(DramaCover);
        final tiles = find.byType(DramaTile);
        expect(covers, findsNWidgets(3));
        final first = tester.getRect(covers.first);
        catalogSize ??= first.size;
        expect(first.width, closeTo(catalogSize.width, .01));
        expect(first.height, closeTo(catalogSize.height, .01));
        for (var index = 0; index < 3; index++) {
          final rect = tester.getRect(covers.at(index));
          expect(rect.width / rect.height, closeTo(2 / 3, .001));
          expect(rect.width, closeTo(first.width, .01));
          expect(rect.bottom, closeTo(first.bottom, .01));
          expect(
            tester.getSize(tiles.at(index)).height,
            tester.getSize(tiles.first).height,
          );
        }
        expect(tester.takeException(), isNull);
      }
    });
  }

  for (final layout in [
    (const Size(360, 760), 1.0),
    (const Size(320, 844), 2.0),
    (const Size(1280, 800), 1.0),
  ]) {
    testWidgets(
      'download actions stay above filters and control the whole queue at $layout',
      (tester) async {
        viewport(tester, layout.$1, layout.$2);
        final repository = InterfaceRepository();
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light,
            // 页面里到处用 `AppLocalizations.of(context)`；没有 delegates 时
            // 它返回 null，所有页面都会在 build 阶段抛空断言。
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: DownloadsScreen(
              repository: repository,
              store: await localStore(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        // 标题文案随 l10n 变化，硬编码中文会让测试在改文案时莫名失败。
        final l10n = AppLocalizations.of(
          tester.element(find.byType(DownloadsScreen)),
        );
        final menu = find.byKey(const ValueKey('download-queue-actions'));
        final local = find.byKey(const ValueKey('download-local-media'));
        // 筛选入口现在是 AppBar 上的图标按钮（点开弹窗选条件），
        // 不再是内联的筛选条，因此按 tooltip 定位。
        final filters = find.byTooltip(l10n.filterDownloads);
        expect(
          tester.getCenter(menu).dy,
          closeTo(tester.getCenter(find.text(l10n.downloadsTitle)).dy, .01),
        );
        // 三个入口现在同在 AppBar 的一行里：菜单靠右，筛选与本地媒体在其左侧。
        expect(tester.getRect(menu).left, greaterThan(layout.$1.width / 2));
        expect(
          tester.getRect(menu).center.dy,
          closeTo(tester.getRect(filters).center.dy, 1),
          reason: '队列操作与筛选入口必须在同一行',
        );
        expect(
          tester.getRect(menu).left,
          greaterThan(tester.getRect(filters).left),
          reason: '队列操作菜单在最右',
        );
        expect(
          tester.getRect(local).center.dy,
          closeTo(tester.getRect(filters).center.dy, 1),
        );
        // 筛选条件在弹窗里，先打开再选「已下载」。
        await tester.tap(filters);
        await tester.pumpAndSettle();
        final completed = find.widgetWithText(ChoiceChip, l10n.downloadedState);
        expect(completed, findsOneWidget);
        await tester.tap(completed);
        await tester.pumpAndSettle();
        await tester.tap(find.text(l10n.apply));
        await tester.pumpAndSettle();
        // 任务按剧集分组展示，默认折叠：先展开分组才能看到分集卡片。
        final group = find.text(repository.jobs.first.drama.title).first;
        await tester.tap(group);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('download-task-task-0')),
          findsNothing,
          reason: '进行中的任务已被「已下载」筛选排除',
        );
        expect(
          find.byKey(const ValueKey('download-task-task-2')),
          findsOneWidget,
        );
        await tester.tap(menu);
        await tester.pumpAndSettle();
        final pauseAll = find.text(l10n.pauseAll);
        expect(pauseAll, findsOneWidget, reason: '队列菜单里应只有一个「全部暂停」');
        // 弹层可能盖住按钮：直接对菜单项本身求值再点，避免命中单条任务菜单。
        await tester.tap(pauseAll, warnIfMissed: true);
        await tester.pumpAndSettle();
        // 批量接口的命令名是 `pause`（旧实现的 `pauseAll` 已不再使用）。
        expect(repository.commands, ['pause:']);
        expect(repository.jobs.where((job) => job.active), isEmpty);
        await tester.tap(menu);
        await tester.pumpAndSettle();
        await tester.tap(find.text(l10n.resumeAll));
        await tester.pumpAndSettle();
        expect(repository.commands.last, 'resume:');
        expect(repository.jobs.where((job) => job.active).length, 2);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
