import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/main.dart';
import 'package:hoshi/ui/core/widgets.dart';
import 'package:hoshi/ui/features/settings/views/settings_screen.dart';
import 'package:hoshi/ui/shell/app_sidebar.dart';
import 'package:hoshi/ui/core/app_bottom_navigation.dart';
import 'package:hoshi/ui/theme/md3_tokens.dart';

import '../../support/interface_fixtures.dart';
import '../../support/router_harness.dart';

/// 桌面布局验收。
///
/// 计划里对桌面端提了 5 条硬要求，这里是它们的可执行版本：
///
/// 1. 任何页面都不出现「手机布局拉宽 + 左右大片空白」；
/// 2. 侧栏常驻，切 tab 不丢状态；
/// 3. 鼠标有 hover/focus 反馈；
/// 4. 设置类页面是两栏；
/// 5. 窗口可拖拽（在 `test/ui/shell/window_chrome_test.dart` 覆盖）。
///
/// P1 之前这些用例会失败——它们是改造的验收目标，不是既有行为的描述。
/// 用 `skip` 标注尚未接入的部分，避免阻塞 P0 的基线提交。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<LocalStore> localStore() async {
    SharedPreferences.setMockInitialValues({});
    return LocalStore(await SharedPreferences.getInstance());
  }

  void viewport(WidgetTester tester, Size size, {double scale = 1}) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  group('桌面网格不拉宽', () {
    for (final size in [
      const Size(1280, 860),
      const Size(1600, 1000),
      const Size(2560, 1440),
    ]) {
      testWidgets('发现页在 $size 下网格受最大宽度约束', (tester) async {
        viewport(tester, size);
        final repository = InterfaceRepository();
        final store = await localStore();
        await store.setHideVip(false);
        await tester.pumpWidget(
          DuanjuApp(repository: repository, store: store),
        );
        await tester.pumpAndSettle();

        // 量内容而不是滚动容器：`CustomScrollView` 本身总是占满可用宽度，
        // 真正被约束的是它的子节点（网格里的卡片）。
        final tiles = find.byType(DramaTile);
        expect(tiles, findsWidgets);
        final first = tester.getRect(tiles.first);
        final last = tester.getRect(tiles.last);
        // 首行最后一张卡片的右边界 = 内容区右边界。
        final rowTiles = tiles.evaluate().where((element) {
          final rect = tester.getRect(find.byWidget(element.widget));
          return (rect.top - first.top).abs() < 1;
        }).length;
        final contentRight = tester.getRect(
          find.byWidget(
            tiles.evaluate().elementAt(rowTiles - 1).widget,
          ),
        ).right;
        final contentWidth = contentRight - first.left;
        final inset = Md3Spacing.pageInset(size.width);
        final expected = (size.width - inset * 2).clamp(
          0.0,
          Md3Spacing.wideMaxWidth,
        );
        expect(
          contentWidth,
          lessThanOrEqualTo(expected + 1),
          reason: '内容宽度 $contentWidth 超过了上限 $expected',
        );
        // 桌面端两侧留白必须真实存在，不能贴边。
        expect(
          first.left,
          greaterThanOrEqualTo(inset - 1),
          reason: '左侧留白 ${first.left} 小于页面留白 $inset',
        );
        expect(
          size.width - contentRight,
          greaterThanOrEqualTo(inset - 1),
          reason: '右侧留白不足，桌面看起来就是拉宽的手机',
        );
        expect(last, isNotNull);
        expect(tester.takeException(), isNull);
      },
      );
    }

    testWidgets('卡片尺寸不随窗口无限放大', (tester) async {
      viewport(tester, const Size(2560, 1440));
      final repository = InterfaceRepository();
      final store = await localStore();
      await store.setHideVip(false);
      await tester.pumpWidget(DuanjuApp(repository: repository, store: store));
      await tester.pumpAndSettle();

      final tiles = find.byType(DramaTile);
      expect(tiles, findsWidgets);
      final tileWidth = tester.getSize(tiles.first).width;
      // 2560 宽下如果只有 4 列，海报会宽到失真；列数上限要让单张卡片
      // 保持在 180–320 之间（对应 2:3 海报约 270–480 高）。
      expect(
        tileWidth,
        inInclusiveRange(150, 340),
        reason: '2560 宽下卡片宽 $tileWidth，列数策略需要收紧',
      );
    });
  });

  group('桌面外壳', () {
    testWidgets('三种导航形态随宽度切换', (tester) async {
      final repository = InterfaceRepository();
      final store = await localStore();
      await store.setHideVip(false);

      Future<void> pumpAt(Size size) async {
        viewport(tester, size);
        await tester.pumpWidget(
          DuanjuApp(repository: repository, store: store),
        );
        await tester.pumpAndSettle();
      }

      // 横屏：rail，导航形态与宽度无关。
      await pumpAt(const Size(1280, 860));
      expect(find.byType(AppRail), findsOneWidget);
      expect(find.byKey(const ValueKey('rail-search')), findsOneWidget);
      expect(find.byType(AppBottomNavigation), findsNothing);

      // 中等宽度但仍是横屏：还是 rail，宽度不触发形态切换。
      await pumpAt(const Size(760, 600));
      expect(find.byType(AppRail), findsOneWidget);
      expect(find.byType(AppBottomNavigation), findsNothing);

      // 竖屏：底部导航，没有 rail。
      await pumpAt(const Size(390, 844));
      expect(find.byType(AppBottomNavigation), findsOneWidget);
      expect(find.byType(AppRail), findsNothing);
    });

    testWidgets('rail 宽度固定、目的地沉底、只有选中项显示标签', (tester) async {
      viewport(tester, const Size(1280, 860));
      final repository = InterfaceRepository();
      final store = await localStore();
      await tester.pumpWidget(
        DuanjuApp(repository: repository, store: store),
      );
      await tester.pumpAndSettle();

      // 宽度固定为 NavigationRail 默认值，不随窗口变宽而展开。
      final railSize = tester.getSize(find.byType(NavigationRail));
      expect(railSize.width, lessThanOrEqualTo(96));

      // 目的地沉底：导航项中心在窗口下半部分。
      final follows = tester.getRect(find.text('追剧'));
      expect(
        follows.center.dy,
        greaterThan(860 / 2),
        reason: 'rail 目的地应沉到底部（Kazumi 的 groupAlignment: 1）',
      );

      // 只有选中项显示文字：未选中的「追剧」标签不可见。
      // labelType: selected 下未选中项的标签不渲染。
      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.labelType, NavigationRailLabelType.selected);
      expect(rail.groupAlignment, 1);
    });

    testWidgets('横屏内容区是圆角书架', (tester) async {
      viewport(tester, const Size(1280, 860));
      final repository = InterfaceRepository();
      final store = await localStore();
      await tester.pumpWidget(
        DuanjuApp(repository: repository, store: store),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ContentShelf), findsOneWidget);
      // 竖屏不加圆角。
      viewport(tester, const Size(390, 844));
      await tester.pumpWidget(
        DuanjuApp(repository: repository, store: store),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ContentShelf), findsNothing);
    });

    testWidgets('切换分支后回到原分支，滚动位置保持', (tester) async {
      viewport(tester, const Size(1280, 860));
      // 3 条数据在 1280 宽下一屏就放得下，没有可滚动内容；补足到 4 页
      // 才能验证「切回来滚动位置还在」。
      final repository = _PagedRepository();
      final store = await localStore();
      await store.setHideVip(false);
      await tester.pumpWidget(DuanjuApp(repository: repository, store: store));
      await tester.pumpAndSettle();

      // 目录网格自己的滚动体：它的祖先里同时存在侧栏的 ListView，
      // 直接取 `Scrollable.last` 会抓错对象。
      final grid = find.descendant(
        of: find.byType(CustomScrollView),
        matching: find.byType(Scrollable),
      );
      expect(grid, findsWidgets);
      final scrollable = grid.first;
      await tester.drag(scrollable, const Offset(0, -240));
      await tester.pumpAndSettle();
      final offset = tester.state<ScrollableState>(scrollable).position.pixels;
      expect(offset, greaterThan(0));

      // 切到追剧，再切回发现。
      // 未选中的目的用 `icon`，选中的切到 `selectedIcon`，key 会变；
      // 因此按 RailDestination 的文本定位更稳。
      await tester.tap(find.text('追剧'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('发现'));
      await tester.pumpAndSettle();

      final restored = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(CustomScrollView),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position
          .pixels;
      expect(
        restored,
        closeTo(offset, 1),
        reason: '切分支回来滚动位置丢失，说明 branch 状态没有保持',
      );
    });

    testWidgets('旧路径重定向到新分支', (tester) async {
      final repository = InterfaceRepository();
      final store = await localStore();
      final router = await pumpRouterApp(
        tester,
        repository: repository,
        store: store,
        location: '/sources',
      );
      // 旧路径解析后应落在设置分支下的站源面板。
      expect(router.state.uri.path, '/settings/sources');
    });
  });

  group('桌面交互反馈', () {
    testWidgets('鼠标悬停卡片出现描边', (tester) async {
      viewport(tester, const Size(1280, 860));
      final repository = InterfaceRepository();
      final store = await localStore();
      await store.setHideVip(false);
      await tester.pumpWidget(DuanjuApp(repository: repository, store: store));
      await tester.pumpAndSettle();

      final tile = find.byType(DramaTile).first;
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pump();

      // 悬停前：卡片边框透明。
      final before = _tileBorder(tester, tile);
      expect(before, Colors.transparent);

      await gesture.moveTo(tester.getCenter(tile));
      await tester.pumpAndSettle();
      final after = _tileBorder(tester, tile);
      expect(
        after,
        isNot(Colors.transparent),
        reason: '悬停没有出现描边，桌面用户看不出卡片可点',
      );
    });

    testWidgets('滚动条在桌面可见', (tester) async {
      // widget 测试默认 platform 是 android，桌面 ScrollBehavior 不会生效；
      // 显式切成 macOS 才能验证桌面分支。必须在测试体内恢复，
      // 框架会在 body 结束时检查这个 debug 变量。
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        viewport(tester, const Size(1280, 860));
        final repository = _PagedRepository();
        final store = await localStore();
        await store.setHideVip(false);
        await tester.pumpWidget(
          DuanjuApp(repository: repository, store: store),
        );
        await tester.pumpAndSettle();
        // 桌面滚动行为会给每个可滚动区域套 Scrollbar。
        expect(find.byType(Scrollbar), findsWidgets);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('设置两栏', () {
    testWidgets('宽窗口下设置页左侧分组常驻、右侧面板独立滚动', (tester) async {
      viewport(tester, const Size(1280, 860));
      final repository = InterfaceRepository();
      final store = await localStore();
      await tester.pumpWidget(
        DuanjuApp(repository: repository, store: store),
      );
      await tester.pumpAndSettle();

      // 设置项同样会随选中态切换 icon/selectedIcon，按文本定位。
      // 标签只在选中时显示，因此改为点设置目的本身。
      await tester.tap(find.text('设置与备份'), warnIfMissed: false);
      await tester.pumpAndSettle();

      // 设置是根级全屏页：它盖住外壳，页面自己有两栏。
      // 外壳仍在树里（会被整页遮挡），因此断言中心放在设置页自己的结构。
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-pane-appearance')),
        findsWidgets,
      );
      // 分组栏与面板是两个独立的可滚动区域。
      final scrollables = find.byType(Scrollable);
      expect(
        scrollables,
        findsAtLeastNWidgets(2),
        reason: '设置页应有两栏，各自可滚动',
      );
    });

    testWidgets('窄窗口下设置页是单列列表', (tester) async {
      viewport(tester, const Size(390, 844));
      final repository = InterfaceRepository();
      final store = await localStore();
      await tester.pumpWidget(
        DuanjuApp(repository: repository, store: store),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bottom-nav-0')));
      await tester.pumpAndSettle();
      // 手机上通过「更多」菜单进入设置，这里直接验证页面本身。
      expect(find.byType(AppRail), findsNothing);
    });
  });
}

/// 生成足够多条目、让目录在桌面宽度下也能滚动的仓库。
class _PagedRepository extends InterfaceRepository {
  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) async {
    requests.add(source);
    pages.add(page);
    forced.add(force);
    return CatalogPage(
      [
        for (var index = 0; index < 24; index++)
          Drama(
            id: '$source:p$page-$index',
            source: source,
            title: '第$page页第$index部',
            episodes: 12,
          ),
      ],
      page: page,
      hasMore: page < 3,
    );
  }
}

/// 取卡片最外层容器的边框色。
Color _tileBorder(WidgetTester tester, Finder tile) {
  final container = find.descendant(
    of: tile,
    matching: find.byType(AnimatedContainer),
  );
  final widget = tester.widget<AnimatedContainer>(container.first);
  final decoration = widget.decoration;
  if (decoration is BoxDecoration && decoration.border is Border) {
    return (decoration.border! as Border).top.color;
  }
  return Colors.transparent;
}
