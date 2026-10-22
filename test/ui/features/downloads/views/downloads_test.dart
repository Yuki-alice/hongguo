import 'package:hoshi/data/app_contract.dart';
import 'package:hoshi/ui/features/detail/views/detail_screen.dart';
import 'package:hoshi/ui/features/downloads/views/downloads_screen.dart';
import 'package:hoshi/ui/features/home/views/home_screen.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/data/playback/playback_loader.dart';
import 'package:hoshi/ui/features/player/views/player_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hoshi/ui/routing/app_router.dart';
import 'package:hoshi/ui/routing/route_args.dart';

import '../../../../support/fixtures.dart';
import '../../../../support/player_fixtures.dart';
import '../../../../support/remote_helpers.dart';
import '../../../../support/router_harness.dart';

class DownloadRepository extends FixtureRepository {
  final commands = <String>[];
  List<DownloadJob> jobs = [];
  List<int> selected = [];
  int quality = 0;
  int added = 2;
  int localCalls = 0;
  int onlineCalls = 0;
  int alternateCalls = 0;
  bool missing = false;
  DramaDetail? detailOverride;

  Episode episode(int number) => Episode({
    'id': '$number',
    'currentEpisode': number,
    'vip': number == 3,
  }, number);

  DownloadJob job(int number, String state) => DownloadJob(
    id: '$number',
    drama: FixtureRepository.free,
    episode: episode(number),
    state: state,
    bytes: 1024,
    total: 2048,
    progress: .5,
    actualQuality: 1080,
  );

  @override
  bool get supportsDownloads => true;
  @override
  Future<List<DownloadJob>> downloads() async => List.of(jobs);
  @override
  Future<DramaDetail> detail(Drama drama) async {
    detailCalls++;
    if (detailOverride != null) return detailOverride!;
    return DramaDetail(drama, [episode(1), episode(2), episode(3)]);
  }

  @override
  Future<int> enqueueDownloads(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) async {
    selected = episodes.map((episode) => episode.number).toList();
    this.quality = quality;
    return added;
  }

  @override
  Future<void> controlDownloads(String command, {String id = ''}) async {
    commands.add('$command:$id');
    jobs = [
      for (final entry in jobs)
        if (command != 'remove' || entry.id != id)
          if (entry.id == id && (command == 'pause' || command == 'resume'))
            job(entry.episode.number, command == 'pause' ? 'paused' : 'queued')
          else
            entry,
    ];
  }

  @override
  Future<PlaybackPlan?> localPlayback(Drama drama, Episode episode) async {
    localCalls++;
    return missing
        ? null
        : const PlaybackPlan(url: '/synthetic/local.mp4', local: true);
  }

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async {
    final plan = await localPlayback(drama, episode);
    if (plan == null) throw AppFailure('本地文件缺失', code: 'local_media');
    return plan;
  }

  @override
  Future<PlaybackPlan> resolveOnline(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async {
    onlineCalls++;
    return const PlaybackPlan(url: 'https://synthetic.test/online.mp4');
  }

  @override
  Future<PlaybackPlan> fallback(PlaybackPlan current) async {
    alternateCalls++;
    throw AppFailure('本地视频不应该自动切线');
  }
}

Widget _app({
  required Widget home,
  TransitionBuilder? builder,
  ThemeData? theme,
}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: builder,
  theme: theme,
  home: home,
);

/// 下载页里的「本地播放」走 `context.push`，需要祖先中存在 `GoRouter`。
/// 这里只提供下载页与播放页两条路由，播放页由调用方注入的 `playerBuilder`
/// 接管，避免在测试里创建真实播放器。
Widget _routerHost({required Widget child, ThemeData? theme}) {
  final router = GoRouter(
    initialLocation: AppRoutes.downloads,
    routes: [
      GoRoute(path: AppRoutes.downloads, builder: (_, _) => child),
      GoRoute(
        path: AppRoutes.player,
        builder: (context, state) {
          final extra = state.extra;
          if (extra is! PlayerRouteExtra) return const SizedBox.shrink();
          final builder = extra.playerBuilder;
          if (builder == null) return const SizedBox.shrink();
          return builder(
            extra.detail,
            extra.initialIndex,
            extra.initialPosition,
          );
        },
      ),
    ],
  );
  return MaterialApp.router(
    routerConfig: router,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: theme,
  );
}

void main() {
  Future<LocalStore> makeStore() async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    return store;
  }

  void size(WidgetTester tester, Size value) {
    tester.view.physicalSize = value;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> tick(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  Future<void> episodeAction(
    WidgetTester tester,
    int number,
    String label,
  ) async {
    final task = find.byKey(ValueKey('download-task-$number'));
    await tester.tap(
      find.descendant(of: task, matching: find.byType(PopupMenuButton<String>)),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(PopupMenuItem<String>),
        matching: find.text(label),
      ),
    );
    await tester.pumpAndSettle();
  }

  test(
    'local-only loader never falls through to online; explicit online bypasses it',
    () async {
      final repository = DownloadRepository()..missing = true;
      final loader = PlaybackLoader(repository);
      await expectLater(
        loader.load(
          FixtureRepository.free,
          repository.episode(1),
          localOnly: true,
        ),
        throwsA(
          isA<AppFailure>().having(
            (error) => error.code,
            'code',
            'local_media',
          ),
        ),
      );
      expect(repository.onlineCalls, 0);
      final plan = await loader.load(
        FixtureRepository.free,
        repository.episode(1),
        localOnly: true,
        online: true,
      );
      expect(plan!.local, isFalse);
      expect(repository.localCalls, 1);
      expect(repository.onlineCalls, 1);
      await loader.close();
    },
  );

  for (final added in [2, 0]) {
    testWidgets(
      'detail download picker handles VIP, quality and added=$added',
      (tester) async {
        size(tester, const Size(390, 844));
        final repository = DownloadRepository()..added = added;
        final store = await makeStore();
        // 用真实路由表打开详情页：选集入口现在通过 go_router 推入。
        await pumpRouterApp(
          tester,
          repository: repository,
          store: store,
          location: AppRoutes.detailOf(
            DramaRef.fromDramaId(FixtureRepository.free.id)!,
          ),
          extra: FixtureRepository.free,
        );
        await tester.tap(find.byTooltip('下载选集'));
        await tester.pumpAndSettle();
        expect(find.text('加入下载 · 2 集'), findsOneWidget);
        expect(find.text('已选 VIP 集可能只能下载试看内容。'), findsNothing);
        await tester.tap(find.text('取消全选'));
        await tester.pumpAndSettle();
        expect(find.text('加入下载 · 0 集'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('enqueue-downloads')),
              )
              .onPressed,
          isNull,
        );
        await tester.tap(find.text('全选'));
        await tester.pumpAndSettle();
        expect(find.text('已选 VIP 集可能只能下载试看内容。'), findsOneWidget);
        await tester.tap(find.text('仅非 VIP'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('download-quality')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('720P').last);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('enqueue-downloads')));
        await tester.pumpAndSettle();
        expect(repository.selected, [1, 2]);
        expect(repository.quality, 720);
        expect(
          find.text(added == 0 ? '所选集数已在下载列表中' : '已加入 2 集，已有任务自动跳过'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('mobile player moves download and follow into tabs', (
    tester,
  ) async {
    size(tester, const Size(390, 844));
    final repository = DownloadRepository();
    final player = ScriptedPlayer();
    final store = await makeStore();
    final detail = await repository.detail(FixtureRepository.free);
    await tester.pumpWidget(
      _app(
        theme: ThemeData.dark(),
        home: PlayerScreen(
          detail: detail,
          initialIndex: 0,
          repository: repository,
          store: store,
          playerFactory: () => Player(platformPlayer: player),
          videoBuilder: (controls) => controls,
        ),
      ),
    );
    await tick(tester);
    expect(find.byKey(const ValueKey('player-download')), findsNothing);
    expect(find.byKey(const ValueKey('player-favorite')), findsNothing);
    expect(find.byKey(const ValueKey('player-volume')), findsNothing);
    expect(find.text('选集'), findsOneWidget);
    expect(find.text('简介'), findsOneWidget);
    expect(find.text('下载'), findsOneWidget);
    expect(find.text('追剧'), findsNothing);
    expect(find.text('加入追剧'), findsNothing);
    expect(find.byKey(const ValueKey('player-follow-status')), findsNothing);
    await tester.tap(find.text('简介'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-follow-status')), findsOneWidget);
    expect(find.text('加入追剧'), findsOneWidget);
    await tester.tap(find.text('下载'));
    await tester.pumpAndSettle();
    expect(find.text('下载选集'), findsOneWidget);
    expect(find.byKey(const ValueKey('download-episode-1')), findsOneWidget);
    expect(find.text('清空'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('download-quality')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('720P').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('enqueue-downloads')));
    await tester.pumpAndSettle();
    expect(repository.selected, [1, 2]);
    expect(repository.quality, 720);
    await tester.pumpWidget(const SizedBox.shrink());
    await tick(tester);
    expect(player.disposed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('DSD VIP episodes open playback without a confirmation dialog', (
    tester,
  ) async {
    if (!SourceSite.isAvailable(SourceSite.dsd.id)) return;
    size(tester, const Size(390, 844));
    final repository = DownloadRepository();
    final store = await makeStore();
    final drama = const Drama(
      id: 'dsd:100',
      source: 'dsd',
      title: '帝果合成剧',
      episodes: 1,
    );
    repository.detailOverride = DramaDetail(drama, [
      Episode({'id': '1', 'currentEpisode': 1, 'vip': true}, 1),
    ]);
    // 详情页的播放走 `context.push`，必须有 GoRouter 祖先。
    // 播放页不需要真实渲染——这里只验证「没有弹 VIP 确认框」。
    final router = GoRouter(
      initialLocation: '/detail',
      routes: [
        GoRoute(
          path: '/detail',
          builder: (_, _) =>
              DetailScreen(drama: drama, repository: repository, store: store),
        ),
        GoRoute(
          path: AppRoutes.player,
          builder: (_, _) => const Scaffold(body: Text('正在准备播放')),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp.router(
        theme: ThemeData.dark(),
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    );
    await tester.pumpAndSettle();
    // 手机布局下分集区默认折叠，先展开选择器再点分集。
    await tester.tap(find.byIcon(Icons.grid_view_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('episode-1')));
    await tester.pumpAndSettle();
    // DSD 的 VIP 集不弹确认框，直接进入播放。
    expect(find.text('这是一集 VIP 内容'), findsNothing);
    expect(find.text('正在准备播放'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('queue controls, filtering and deletion work on a narrow phone', (
    tester,
  ) async {
    size(tester, const Size(360, 760));
    final repository = DownloadRepository();
    repository.jobs = [
      repository.job(1, 'downloading'),
      repository.job(2, 'completed'),
    ];
    await tester.pumpWidget(
      _app(
        theme: ThemeData.dark(),
        home: DownloadsScreen(repository: repository, store: await makeStore()),
      ),
    );
    await tick(tester);
    await tester.tap(find.text('测试短剧'));
    await tester.pumpAndSettle();
    await episodeAction(tester, 1, '暂停');
    await tick(tester);
    expect(repository.commands, ['pause:1']);
    await episodeAction(tester, 1, '继续 / 重试');
    await tick(tester);
    expect(repository.commands.last, 'resume:1');
    await tester.tap(find.byTooltip('筛选下载合集'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '进行中'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '应用'));
    await tick(tester);
    expect(find.byKey(const ValueKey('download-task-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('download-task-2')), findsNothing);
    await tester.tap(find.byTooltip('筛选下载合集'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '全部任务'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '应用'));
    await tick(tester);
    if (find.byKey(const ValueKey('download-task-2')).evaluate().isEmpty) {
      await tester.tap(find.text('测试短剧').first);
      await tester.pumpAndSettle();
    }
    await episodeAction(tester, 2, '删除视频');
    await tester.pumpAndSettle();
    await tester.tap(find.text('保留'));
    await tester.pumpAndSettle();
    expect(repository.commands, isNot(contains('remove:2')));
    await episodeAction(tester, 2, '删除视频');
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认删除'));
    await tester.pumpAndSettle();
    expect(repository.commands.last, 'remove:2');
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'downloaded episode playback uses saved metadata and progress without detail requests',
    (tester) async {
      final repository = DownloadRepository();
      repository.jobs = [
        repository.job(3, 'completed'),
        repository.job(2, 'paused'),
        repository.job(1, 'completed'),
      ];
      final store = await makeStore();
      await store.saveWatch(
        WatchEntry(
          drama: FixtureRepository.free,
          episode: 3,
          position: 28,
          duration: 100,
          updatedAt: DateTime.now(),
        ),
      );
      await tester.pumpWidget(
        _routerHost(
          theme: ThemeData.dark(),
          child: DownloadsScreen(
            repository: repository,
            store: store,
            playerBuilder: (detail, index, position) {
              expect(detail.episodes.map((episode) => episode.number), [1, 3]);
              expect(index, 1);
              expect(position, 28);
              return const Scaffold(body: Text('offline player'));
            },
          ),
        ),
      );
      await tick(tester);
      await tester.tap(find.text('测试短剧'));
      await tester.pumpAndSettle();
      await episodeAction(tester, 3, '本地播放');
      await tester.pumpAndSettle();
      expect(find.text('offline player'), findsOneWidget);
      expect(repository.detailCalls, 0);
      expect(repository.onlineCalls, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final localOnly in [true, false]) {
    testWidgets(
      'local failure requires manual online choice, retains progress; localOnly=$localOnly',
      (tester) async {
        size(tester, const Size(800, 720));
        final repository = DownloadRepository();
        final player = ScriptedPlayer();
        final detail = await repository.detail(FixtureRepository.free);
        await tester.pumpWidget(
          _app(
            theme: ThemeData.dark(),
            home: PlayerScreen(
              detail: detail,
              initialIndex: 0,
              initialPosition: 7,
              localOnly: localOnly,
              repository: repository,
              store: await makeStore(),
              playerFactory: () => Player(platformPlayer: player),
              videoBuilder: (controls) => controls,
            ),
          ),
        );
        await tick(tester);
        expect(player.opened.single.uri, contains('local.mp4'));
        await player.seek(const Duration(seconds: 28));
        await tester.pump();
        player.fail();
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tick(tester);
        expect(find.text('重试本地播放'), findsOneWidget);
        await tester.pump(const Duration(seconds: 25));
        expect(repository.onlineCalls, 0);
        expect(repository.alternateCalls, 0);
        expect(repository.localCalls, 1);
        await tester.ensureVisible(find.text('改为在线播放'));
        await tester.tap(find.text('改为在线播放'));
        await tick(tester);
        expect(repository.onlineCalls, 1);
        expect(player.opened.last.uri, contains('online.mp4'));
        expect(player.opened.last.start, const Duration(seconds: 28));
        await tester.tap(find.byTooltip('下一集').last);
        await tick(tester);
        expect(player.opened.last.uri, contains('local.mp4'));
        expect(repository.onlineCalls, 1);
        await tester.pumpWidget(const SizedBox.shrink());
        await tick(tester);
        expect(player.disposed, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'missing local media exposes online choice without contacting the source',
    (tester) async {
      final repository = DownloadRepository()..missing = true;
      final player = ScriptedPlayer();
      final detail = await repository.detail(FixtureRepository.free);
      await tester.pumpWidget(
        _app(
          theme: ThemeData.dark(),
          home: PlayerScreen(
            detail: detail,
            initialIndex: 0,
            repository: repository,
            store: await makeStore(),
            playerFactory: () => Player(platformPlayer: player),
            videoBuilder: (controls) => controls,
          ),
        ),
      );
      await tick(tester);
      expect(find.text('改为在线播放'), findsOneWidget);
      expect(player.opened, isEmpty);
      expect(repository.onlineCalls, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      await tick(tester);
    },
  );

  testWidgets(
    'TV download navigation and long queue remain usable with only the remote',
    (tester) async {
      size(tester, const Size(960, 540));
      final repository = DownloadRepository();
      repository.jobs = List.generate(
        20,
        (index) => repository.job(index + 1, 'paused'),
      );
      await tester.pumpWidget(
        televisionHost(
          child: HomeScreen(repository: repository, store: await makeStore()),
        ),
      );
      await tester.pumpAndSettle();
      focusRemote(tester, find.byKey(const ValueKey('tv-nav-3')));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      for (var i = 0; i < 14; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.text('第 13 集'), findsWidgets);
      await tester.tap(find.text('继续 / 重试').last);
      await tick(tester);
      expect(repository.commands.last, 'resume:13');
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
}
