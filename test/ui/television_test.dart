// 重集成套件：单个文件 10–30 秒，且不在桌面视觉改造面上，默认套件跳过（见根目录 dart_test.yaml）。
// 需要时：flutter test --tags slow --run-skipped
@Tags(['slow'])
library;

import 'package:hoshi/ui/core/app_layout.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/main.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/ui/core/remote_widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fixtures.dart';
import '../support/remote_helpers.dart';

class TelevisionRepository extends FixtureRepository {
  @override
  Future<DramaDetail> detail(Drama drama) async {
    detailCalls++;
    return DramaDetail(
      drama,
      List.generate(
        100,
        (index) => Episode({
          'id': '${index + 1}',
          'currentEpisode': index + 1,
          'vip': true,
        }, index + 1),
      ),
    );
  }
}

void main() {
  Future<LocalStore> makeStore() async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    return store;
  }

  void size(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    if (key == LogicalKeyboardKey.goBack) {
      await tester.binding.handlePopRoute();
    } else {
      await tester.sendKeyEvent(key);
    }
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Android TV detection falls back safely when the platform channel is unavailable',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(
        () => messenger.setMockMethodCallHandler(AppDevice.channel, null),
      );
      messenger.setMockMethodCallHandler(AppDevice.channel, (call) async {
        expect(call.method, 'deviceInfo');
        return {'television': true, 'version': appVersion};
      });
      final detected = await AppDevice.detect();
      expect(detected.television, isTrue);
      expect(detected.version, appVersion);
      messenger.setMockMethodCallHandler(
        AppDevice.channel,
        (call) async => throw MissingPluginException(),
      );
      expect((await AppDevice.detect()).television, isFalse);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'manual interface preference overrides device detection and survives restart',
    (tester) async {
      size(tester, const Size(960, 540));
      final store = await makeStore();
      final repository = FixtureRepository();
      await tester.pumpWidget(
        DuanjuApp(repository: repository, store: store, television: true),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tv-nav-0')), findsOneWidget);
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('界面模式'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('手机 / 电脑'));
      await tester.pumpAndSettle();
      expect(store.displayMode, 'standard');
      expect(find.byKey(const ValueKey('tv-nav-0')), findsNothing);
      expect(LocalStore(store.preferences).displayMode, 'standard');
      await store.setDisplayMode('television');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tv-nav-0')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final dimensions in [const Size(960, 540), const Size(1280, 720)]) {
    testWidgets(
      'TV sources, direct playback, VIP confirmation and back retain remote focus at $dimensions',
      (tester) async {
        size(tester, dimensions);
        final store = await makeStore();
        final repository = TelevisionRepository();
        await tester.pumpWidget(
          DuanjuApp(repository: repository, store: store, television: true),
        );
        await tester.pumpAndSettle();
        if (SourceSite.values.length > 1) {
          // 用「短剧」分组的名字点选，不依赖菜单项顺序或按键次数。
          // 分组列表随站源迁移变化，索引式选择会静默选错分组。
          final target = SourceGroup.fromSources(
            SourceSite.values,
          ).firstWhere((group) => group.id != SourceSite.hongguo.groupId);
          final switcher = find.byKey(const ValueKey('source-switch'));
          await tester.tap(switcher);
          await tester.pumpAndSettle();
          await tester.tap(find.text(target.name).last);
          await tester.pumpAndSettle();
        }
        expect(
          repository.requests.last,
          SourceSite.values.length > 1 ? isNot('hongguo') : 'hongguo',
        );
        focusRemote(tester, find.byKey(ValueKey(FixtureRepository.free.id)));
        await tester.pumpAndSettle();
        await press(tester, LogicalKeyboardKey.select);
        await tester.pumpAndSettle();
        expect(repository.detailCalls, 1);
        expect(find.text('这是一集 VIP 内容'), findsOneWidget);
        await press(tester, LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('这是一集 VIP 内容'), findsNothing);
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'remote-${FixtureRepository.free.id}',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'remote grid reaches unbuilt rows, partial last row and pagination without touch',
    (tester) async {
      size(tester, const Size(960, 540));
      var loaded = 0;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: RemoteGrid(
              itemKeys: List.generate(59, (index) => '$index'),
              columns: 4,
              itemExtent: 100,
              autofocus: true,
              footer: Center(
                child: RemoteButton(label: '加载更多', onPressed: () => loaded++),
              ),
              itemBuilder: (_, index, node, onFocus) => RemoteEpisodeButton(
                number: index,
                focusNode: node,
                onFocus: onFocus,
                onPressed: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'remote-0');
      for (var index = 0; index < 3; index++) {
        await press(tester, LogicalKeyboardKey.arrowRight);
      }
      for (var row = 0; row < 14; row++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'remote-58');
      await press(tester, LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.select);
      expect(loaded, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('episode grid initially focuses an offscreen saved episode', (
    tester,
  ) async {
    size(tester, const Size(960, 540));
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: RemoteGrid(
            itemKeys: List.generate(160, (index) => '$index'),
            columns: 6,
            itemExtent: 64,
            initialIndex: 131,
            autofocus: true,
            itemBuilder: (_, index, node, onFocus) => RemoteEpisodeButton(
              number: index,
              focusNode: node,
              onFocus: onFocus,
              onPressed: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'remote-131');
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'remote-125');
    expect(tester.takeException(), isNull);
  });
}
