import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:hoshi/ui/features/downloads/views/batch_download_screen.dart';
import 'package:hoshi/data/app_contract.dart';
import 'package:hoshi/ui/features/detail/views/detail_screen.dart';
import 'package:hoshi/ui/features/downloads/widgets/download_picker.dart';
import 'package:hoshi/domain/download_preferences.dart';
import 'package:hoshi/main.dart' show DuanjuBootstrap;
import 'package:hoshi/ui/features/downloads/views/downloads_screen.dart';
import 'package:hoshi/ui/features/home/views/history_screen.dart';
import 'package:hoshi/ui/features/home/views/home_screen.dart';
import 'package:hoshi/ui/features/my/views/my_screen.dart';
import 'package:hoshi/data/engine_backed_repository.dart';
import 'package:hoshi/data/local_profiles.dart';
import 'package:hoshi/ui/features/media/views/local_media_screen.dart';
import 'package:hoshi/data/media/media_library.dart';
import 'package:hoshi/ui/features/media/views/merge_queue_screen.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/ui/features/player/views/player_screen.dart';
import 'package:hoshi/ui/features/profiles/views/profiles_screen.dart';
import 'package:hoshi/ui/features/rankings/views/rankings_screen.dart';
import 'package:hoshi/ui/features/search/views/search_screen.dart';
import 'package:hoshi/ui/features/settings/views/resource_settings_screen.dart';
import 'package:hoshi/ui/features/settings/views/theme_settings_screen.dart';
import 'package:hoshi/ui/features/settings/views/engine_diagnostics_screen.dart';
import 'package:hoshi/ui/features/settings/views/settings_screen.dart';
import 'package:hoshi/ui/features/plugins/views/plugins_screen.dart';
import 'package:hoshi/ui/features/sources/views/sources_screen.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/providers/app_providers.dart';
import 'package:hoshi/ui/routing/route_args.dart';
import 'package:hoshi/ui/shell/app_shell.dart';

/// 全局导航 key，供局域网推送等非 Widget 场景发起跳转。
final appNavigatorKey = GlobalKey<NavigatorState>();

/// 路由路径常量。用常量避免改名时漏改。
///
/// 结构：外壳（shell）下有 4 个分支——发现 / 榜单 / 追剧 / 我的，每个
/// 分支有独立 Navigator，切分支不丢状态。
///
/// 历史与下载**不在外壳里**：它们是「我的」页的下级页面，进外壳会在
/// 宽窗口里给一个完整列表只留很窄的内容区、还挂着侧栏。详情、播放、
/// 选集弹层等沉浸或模态页面同样挂在根 Navigator 上，盖住外壳。
abstract final class AppRoutes {
  /// 启动入口。重定向到发现分支。
  static const home = '/';
  static const discover = '/discover';
  static const rankings = '/rankings';
  static const follows = '/follows';
  static const my = '/my';

  static const detail = '/detail/:source/:sourceId';
  static const player = '/player/:source/:sourceId';

  /// 历史与下载：根级全屏页，从「我的」进入。
  static const history = '/history';
  static const downloads = '/downloads';
  static const localMedia = '/downloads/local';
  static const mergeQueue = '/downloads/merge';

  /// 设置分支。设置页自身是两栏，其余是它的面板。
  static const settings = '/settings';
  static const settingsTheme = '/settings/theme';
  static const settingsDisplay = '/settings/display';
  static const resourceSettings = '/settings/resources';
  static const downloadPreferences = '/settings/downloads';
  static const storage = '/settings/storage';
  static const engineDiagnostics = '/settings/diagnostics';
  static const sources = '/settings/sources';
  static const plugins = '/settings/sources/plugins';
  static const profiles = '/settings/profiles';
  static const profileEditor = '/settings/profiles/editor';

  /// 锁屏。独立于外壳，避免未解锁时能操作导航。
  static const unlock = '/unlock';

  /// 独立搜索页。从 rail 顶部的搜索按钮进入。
  static const search = '/search';

  static const batchDownload = '/batch';
  static const downloadPicker = '/picker/:source/:sourceId';

  // ---- 旧路径 ----
  //
  // 保留一年，供旧深链、旧备份里的记录、以及外部脚本使用。全部由
  // `_legacyRedirect` 处理，不要在新代码里引用。
  static const legacyProfiles = '/profiles';
  static const legacyProfileEditor = '/profiles/editor';
  static const legacyLocalMedia = '/local-media';
  static const legacyMergeQueue = '/merge-queue';
  static const legacySources = '/sources';
  static const legacyPlugins = '/sources/plugins';
  static const legacyBatchDownload = '/batch-download';
  static const legacyDownloadPicker = '/download-picker/:source/:sourceId';

  static String detailOf(DramaRef ref) =>
      '/detail/${Uri.encodeComponent(ref.source)}'
      '/${Uri.encodeComponent(ref.sourceId)}';

  static String playerOf(DramaRef ref) =>
      '/player/${Uri.encodeComponent(ref.source)}'
      '/${Uri.encodeComponent(ref.sourceId)}';

  /// 带查询参数的目标路径。
  ///
  /// 只拼非空参数，避免出现 `?resume=0` 这类无意义噪声。
  static String withQuery(String path, Map<String, Object?> query) {
    final pairs = <String>[
      for (final entry in query.entries)
        if (entry.value != null && entry.value != false)
          '${Uri.encodeComponent(entry.key)}='
              '${Uri.encodeComponent('${entry.value}')}',
    ];
    return pairs.isEmpty ? path : '$path?${pairs.join('&')}';
  }

  static String downloadPickerOf(DramaRef ref) =>
      '/picker/${Uri.encodeComponent(ref.source)}'
      '/${Uri.encodeComponent(ref.sourceId)}';

  static String rankingsOf(String group) =>
      withQuery(rankings, {'group': group});

  static String sourcesOf(String source) =>
      withQuery(sources, {'source': source});

  /// 用户页。`locked` 为真时走锁屏，否则进设置分支里的用户面板。
  static String profilesOf({bool locked = false}) => locked ? unlock : profiles;
}

/// 无法从 URL 重建的对象（完整剧集详情等）通过 `extra` 传递。
///
/// `extra` 不参与 URL，不能用于深链；冷启动深链时页面会回落到
/// 「按标识重新取数」，不会出现空白页。
@immutable
class PlayerRouteExtra {
  const PlayerRouteExtra({
    required this.detail,
    this.initialIndex = 0,
    this.initialPosition = 0,
    this.localOnly = false,
    this.allowOnlineFallback = true,
    this.mediaId,
    this.repository,
    this.playerBuilder,
  });

  final DramaDetail detail;
  final int initialIndex;
  final double initialPosition;
  final bool localOnly;
  final bool allowOnlineFallback;
  final String? mediaId;

  /// 覆盖默认仓库。
  ///
  /// 播放本地文件时需要一个把 `file://` 映射到本地路径的装饰器仓库，
  /// 它不是应用级单例，只能随导航一起传递。
  final AppRepository? repository;

  /// 用自定义组件替代真实播放器。
  ///
  /// 测试用它验证「离线播放时不再请求详情」，避免在单元测试里拉起
  /// 真实解码器；生产代码不会设置。
  final Widget Function(DramaDetail, int, double)? playerBuilder;
}

/// 批量下载入参。
@immutable
class BatchDownloadExtra {
  const BatchDownloadExtra(this.dramas);
  final List<Drama> dramas;
}

/// 选集弹层入参。
///
/// 需要完整 [DramaDetail] 与用户偏好，二者都无法从 URL 重建。
@immutable
class DownloadPickerExtra {
  const DownloadPickerExtra(this.detail, this.preferences);
  final DramaDetail detail;
  final DownloadPreferences preferences;
}

/// 用户编辑器入参。
///
/// 传 null 表示新建用户；编辑器内部用 `Navigator.pop` 关闭。
@immutable
class ProfileEditorExtra {
  const ProfileEditorExtra(this.profile);
  final LocalProfile? profile;
}

/// 合并队列入参。
///
/// 媒体库是运行期单例，从本地媒体页进入时还需要「打开即添加」的标记。
@immutable
class MergeQueueExtra {
  const MergeQueueExtra({required this.library, this.addOnOpen = false});
  final MediaLibrary library;
  final bool addOnOpen;
}

/// 构造路由表。
///
/// 依赖在 builder 内用 `ref.read` 取，避免把 provider 生命周期绑到路由对象上。
/// 抽成独立函数是为了让测试也能拿到**同一份**路由表：页面里的
/// `context.push/go/replace` 要求祖先存在 `GoRouter`，测试若自行搭一个
/// 替代路由就会绕过真实行为。
/// 构造路由表。
///
/// 结构分两层：
///
/// - **外壳分支**（`StatefulShellRoute`）：发现 / 追剧 / 历史 / 下载 / 设置。
///   每个分支有自己的 Navigator，切分支时状态与滚动位置都保留。
/// - **根级页面**：详情、播放、选集弹层、批量下载、锁屏。它们盖住外壳，
///   返回时回到原分支的原位置。
///
/// 依赖在 builder 内用 `ref.read` 取，避免把 provider 生命周期绑到路由对象上。
/// 抽成独立函数是为了让测试也能拿到**同一份**路由表：页面里的
/// `context.push/go/replace` 要求祖先存在 `GoRouter`，测试若自行搭一个
/// 替代路由就会绕过真实行为。
GoRouter buildAppRouter(
  Ref ref, {
  String initialLocation = AppRoutes.home,
}) => GoRouter(
  initialLocation: initialLocation,
  navigatorKey: appNavigatorKey,
  // 刻意不接 `refreshListenable`：go_router 收到刷新通知后会**按 URL
  // 重新解析**当前路由，`extra` 随之丢失。用户数据就绪、锁定、切用户
  // 这些变化改由各路由 builder 内部用 Riverpod 响应式处理，
  // 路由对象因此保持稳定，`extra` 也能可靠传递。
  redirect: (context, state) => _redirect(ref, state),
  routes: [
    // ---- 外壳：4 个分支 ----
    StatefulShellRoute.indexedStack(
      builder: (context, state, shell) => _ShellRoute(shell: shell),
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: AppRoutes.discover,
              builder: (context, state) => _home(ref, tabIndex: 0),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: AppRoutes.rankings,
              builder: (context, state) {
                // 外壳分支的 URL 可能带 `?group=`（`rankingsOf` 生成），
                // 也可能不带（点 rail 进入）。缺省落到红果。
                final group = state.uri.queryParameters['group'];
                return RankingsScreen(
                  repository: ref.read(repositoryProvider),
                  store: ref.read(readyStoreProvider),
                  initialGroup: group ?? 'hongguo',
                );
              },
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: AppRoutes.follows,
              builder: (context, state) => _home(ref, tabIndex: 1),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: AppRoutes.my,
              builder: (context, state) =>
                  MyScreen(store: ref.read(readyStoreProvider)),
            ),
          ],
        ),
      ],
    ),

    // ---- 搜索：根级全屏，从 rail 顶部的搜索按钮进入 ----
    GoRoute(
      path: AppRoutes.search,
      builder: (context, state) => SearchScreen(
        repository: ref.read(repositoryProvider),
        store: ref.read(readyStoreProvider),
        initialQuery: state.uri.queryParameters['q'] ?? '',
      ),
    ),

    // ---- 历史与下载：根级全屏，从「我的」进入 ----
    GoRoute(
      path: AppRoutes.history,
      builder: (context, state) => HistoryScreen(
        repository: ref.read(repositoryProvider),
        store: ref.read(readyStoreProvider),
      ),
    ),
    GoRoute(
      path: AppRoutes.downloads,
      builder: (context, state) => DownloadsScreen(
        repository: ref.read(repositoryProvider),
        store: ref.read(readyStoreProvider),
      ),
      routes: [
        GoRoute(
          path: 'local',
          builder: (context, state) => LocalMediaScreen(
            repository: ref.read(repositoryProvider),
            store: ref.read(readyStoreProvider),
          ),
        ),
        GoRoute(
          path: 'merge',
          builder: (context, state) => _mergeQueue(ref, state),
        ),
      ],
    ),

    // ---- 设置与它的面板 ----
    // 除 4 个 tab 外的页面都不进外壳：独立全屏 + 顶部返回，避免
    // 「在大窗口里用一小块内容区看一个完整页面」的别扭感。
    GoRoute(
      path: AppRoutes.settings,
      builder: (context, state) => SettingsScreen(
        repository: ref.read(repositoryProvider),
        store: ref.read(readyStoreProvider),
      ),
      routes: [
        GoRoute(
          path: 'theme',
          pageBuilder: (context, state) => _fadeForwards(
            state.pageKey,
            ThemeSettingsScreen(store: ref.read(readyStoreProvider)),
          ),
        ),
        GoRoute(
          path: 'resources',
          pageBuilder: (context, state) => _fadeForwards(
            state.pageKey,
            ResourceSettingsScreen(
              repository: ref.read(repositoryProvider),
              store: ref.read(readyStoreProvider),
            ),
          ),
        ),
        GoRoute(
          path: 'downloads',
          pageBuilder: (context, state) => _fadeForwards(
            state.pageKey,
            DownloadPreferencesScreen(store: ref.read(readyStoreProvider)),
          ),
        ),
        GoRoute(
          path: 'storage',
          pageBuilder: (context, state) => _fadeForwards(
            state.pageKey,
            StorageScreen(
              repository: ref.read(repositoryProvider),
              store: ref.read(readyStoreProvider),
            ),
          ),
        ),
        GoRoute(
          path: 'diagnostics',
          pageBuilder: (context, state) =>
              _fadeForwards(state.pageKey, _diagnostics(ref, context)),
        ),
        GoRoute(
          path: 'sources',
          pageBuilder: (context, state) => _fadeForwards(
            state.pageKey,
            SourcesScreen(
              repository: ref.read(repositoryProvider),
              store: ref.read(readyStoreProvider),
              initialSource: state.uri.queryParameters['source'],
              // 从详情页进入「站源诊断」时带上剧集，用于播放检测；
              // 普通入口没有 extra，走默认行为。
              drama: state.extra is Drama ? state.extra as Drama : null,
            ),
          ),
          routes: [
            GoRoute(
              path: 'plugins',
              builder: (context, state) =>
                  PluginsScreen(repository: ref.read(pluginRepositoryProvider)),
            ),
          ],
        ),
        GoRoute(
          path: 'profiles',
          pageBuilder: (context, state) => _fadeForwards(
            state.pageKey,
            ProfilesScreen(store: ref.read(readyStoreProvider)),
          ),
          routes: [
            GoRoute(
              path: 'editor',
              builder: (context, state) {
                final extra = state.extra;
                return ProfileEditor(
                  store: ref.read(readyStoreProvider),
                  profile: extra is ProfileEditorExtra ? extra.profile : null,
                );
              },
            ),
          ],
        ),
      ],
    ),

    // ---- 根级页面 ----
    GoRoute(
      path: AppRoutes.unlock,
      builder: (context, state) =>
          ProfilesScreen(store: ref.read(readyStoreProvider), locked: true),
    ),
    GoRoute(
      path: AppRoutes.detail,
      builder: (context, state) {
        final target = _parseTarget(state);
        if (target == null) return const _InvalidRoute();
        // 应用内跳转时携带完整 `Drama`，避免只靠标识重建导致标题、
        // 封面等字段缺失；深链进入时 extra 为空，回落到标识重建。
        final extra = state.extra;
        final drama = extra is Drama ? extra : _drama(ref, target);
        return DetailScreen(
          // 同一路由模式在不同剧集间跳转（例如切换季）时，Flutter 会复用
          // 同一个 State；用剧集标识当 key 强制重建，`initState` 才会重新
          // 取数。否则页面会停留在上一部剧的内容。
          key: ValueKey('detail-${drama.id}'),
          drama: drama,
          repository: ref.read(repositoryProvider),
          store: ref.read(readyStoreProvider),
          resumeOnOpen: state.uri.queryParameters['resume'] == '1',
          downloadOnOpen: state.uri.queryParameters['download'] == '1',
        );
      },
    ),
    GoRoute(
      path: AppRoutes.player,
      builder: (context, state) {
        final target = _parseTarget(state);
        if (target == null) return const _InvalidRoute();
        final extra = state.extra;
        if (extra is! PlayerRouteExtra) {
          // 深链进入且没有详情对象：先落到详情页，由它负责取数。
          return DetailScreen(
            drama: _drama(ref, target),
            repository: ref.read(repositoryProvider),
            store: ref.read(readyStoreProvider),
          );
        }
        final builder = extra.playerBuilder;
        if (builder != null) {
          return builder(
            extra.detail,
            extra.initialIndex,
            extra.initialPosition,
          );
        }
        return PlayerScreen(
          detail: extra.detail,
          initialIndex: extra.initialIndex,
          initialPosition: extra.initialPosition,
          localOnly: extra.localOnly,
          allowOnlineFallback: extra.allowOnlineFallback,
          mediaId: extra.mediaId,
          repository: extra.repository ?? ref.read(repositoryProvider),
          store: ref.read(readyStoreProvider),
        );
      },
    ),
    GoRoute(
      path: AppRoutes.downloadPicker,
      builder: (context, state) {
        // 选集需要完整剧集详情，无法从 URL 重建；深链进入时无 extra，
        // 视为非法入口。用 `push` 打开，`Navigator.pop` 回传选择结果。
        final extra = state.extra;
        if (extra is! DownloadPickerExtra) {
          return _InvalidRoute(
            message: AppLocalizations.of(context).invalidEpisodeEntry,
          );
        }
        return DownloadPicker(
          detail: extra.detail,
          preferences: extra.preferences,
        );
      },
    ),
    GoRoute(
      path: AppRoutes.batchDownload,
      builder: (context, state) {
        final extra = state.extra;
        final dramas = extra is BatchDownloadExtra
            ? extra.dramas
            : const <Drama>[];
        if (dramas.isEmpty) {
          return _InvalidRoute(
            message: AppLocalizations.of(context).noBatchDramas,
          );
        }
        return BatchDownloadScreen(
          repository: ref.read(repositoryProvider),
          store: ref.read(readyStoreProvider),
          dramas: dramas,
        );
      },
    ),
  ],
);

/// 启动入口与旧路径的重定向。
///
/// 旧路径只在**首次解析**时改写；改写后 go_router 会以新路径重新匹配，
/// 因此不存在循环。全部旧路径集中在这里，页面里不要再引用。
String? _redirect(Ref ref, GoRouterState state) {
  final path = state.uri.path;
  final query = state.uri.queryParameters;

  // 启动入口：按锁定状态决定去外壳还是锁屏。
  if (path == AppRoutes.home) {
    final store = ref.read(storeProvider);
    if (store == null) return null;
    return store.locked ? AppRoutes.unlock : AppRoutes.discover;
  }

  // 旧路径 → 新路径。
  switch (path) {
    // S1：榜单从发现的下级提升为外壳分支。旧深链与备份里的路径仍可用。
    case '/discover/rankings':
      return AppRoutes.withQuery(AppRoutes.rankings, query);
    case AppRoutes.legacySources:
      return AppRoutes.withQuery(AppRoutes.sources, query);
    case AppRoutes.legacyPlugins:
      return AppRoutes.plugins;
    case AppRoutes.legacyLocalMedia:
      return AppRoutes.localMedia;
    case AppRoutes.legacyMergeQueue:
      return AppRoutes.mergeQueue;
    case AppRoutes.legacyBatchDownload:
      return AppRoutes.batchDownload;
    case AppRoutes.legacyProfiles:
      return query['locked'] == '1' ? AppRoutes.unlock : AppRoutes.profiles;
    case AppRoutes.legacyProfileEditor:
      return AppRoutes.profileEditor;
  }
  if (path.startsWith('/download-picker/')) {
    return path.replaceFirst('/download-picker/', '/picker/');
  }
  return null;
}

/// 外壳下的分支页面。
///
/// 5 个分支共用 `HomeScreen`：它按 `tabIndex` 渲染目录 / 追剧 / 历史，
/// 下载分支是独立页面。这样切分支时 `CatalogController` 只创建一次，
/// 目录数据与筛选不会因为换 tab 而重取。
Widget _home(Ref ref, {required int tabIndex}) {
  final store = ref.watch(storeProvider);
  if (store == null) return const DuanjuBootstrap();
  return HomeScreen(
    key: ValueKey('profile-${store.profile.id}-${store.profileEpoch}'),
    repository: ref.read(repositoryProvider),
    store: store,
    tabIndex: tabIndex,
  );
}

Widget _mergeQueue(Ref ref, GoRouterState state) {
  // 媒体库是运行期单例；本地媒体页进入时会带上「打开即添加」标记。
  final extra = state.extra;
  final library = extra is MergeQueueExtra
      ? extra.library
      : MediaLibrary.current;
  if (library == null) {
    return const _InvalidRoute(message: null);
  }
  return MergeQueueScreen(
    library: library,
    repository: ref.read(repositoryProvider),
    store: ref.read(readyStoreProvider),
    addOnOpen: extra is MergeQueueExtra && extra.addOnOpen,
  );
}

Widget _diagnostics(Ref ref, BuildContext context) {
  final repository = ref.read(repositoryProvider);
  final engine = repository is EngineBackedRepository
      ? repository.engine
      : null;
  if (engine == null) {
    return _InvalidRoute(
      message: AppLocalizations.of(context).engineDiagnosticsUnsupported,
    );
  }
  return EngineDiagnosticsScreen(
    engine: engine,
    capabilities: repository.capabilities,
  );
}

/// 路由实例。
///
/// 通过 provider 暴露，测试可直接读取同一份配置。
final routerProvider = Provider<GoRouter>((ref) {
  final router = buildAppRouter(ref);
  ref.onDispose(router.dispose);
  return router;
});

/// 外壳分支的宿主。
///
/// 只负责把 `StatefulNavigationShell` 与用户数据交给 `AppShell`；
/// 锁定状态在这里拦一道——未解锁时不渲染任何分支内容。
class _ShellRoute extends ConsumerWidget {
  const _ShellRoute({required this.shell});

  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(storeProvider);
    if (store == null) return const DuanjuBootstrap();
    // LocalStore 通过 ChangeNotifier 原地修改字段，watch 计数才会重建。
    ref.watch(storeRevisionProvider);
    if (store.locked) {
      return ProfilesScreen(store: store, locked: true);
    }
    return AppShell(
      shell: shell,
      store: store,
      // 打开独立搜索页（参照应用也是 `context.pushNamed('/search/')`），
      // 而不是切到发现分支再展开内联搜索框。
      onOpenSearch: () => context.push(AppRoutes.search),
    );
  }
}

DramaRef? _parseTarget(GoRouterState state) => DramaRef.tryParse(
  state.pathParameters['source'],
  state.pathParameters['sourceId'],
);

/// 设置子页统一用 FadeForwards。
///
/// 设置是「就地换一层」的信息结构，横移会让用户误以为换到了另一个板块；
/// 淡入前进只改变前后层级，不暗示横向位置变化（V1-2）。
Page<void> _fadeForwards(LocalKey key, Widget child) =>
    CustomTransitionPage<void>(
      key: key,
      child: child,
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        final route = ModalRoute.of(context);
        if (route is! PageRoute) {
          return FadeTransition(opacity: animation, child: child);
        }
        return const FadeForwardsPageTransitionsBuilder().buildTransitions(
          route,
          context,
          animation,
          secondaryAnimation,
          child,
        );
      },
    );

/// 用标识重建一个最小 `Drama`；详情页会用它去取完整资料。
///
/// 先从全局目录更新流里取已知资料（深链进入时通常为空），取不到就构造
/// 只带标识的占位对象，标题留空由详情页补齐。
Drama _drama(Ref ref, DramaRef target) {
  final placeholder = Drama(
    id: target.dramaId,
    source: target.source,
    title: '',
    sourceId: target.sourceId,
  );
  return ref.read(repositoryProvider).catalogUpdates.current(placeholder);
}

/// 深链参数非法或前置条件缺失时的占位页。
class _InvalidRoute extends StatelessWidget {
  const _InvalidRoute({this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.link_off_rounded,
                size: 48,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 16),
              Text(message ?? l10n.invalidLink, textAlign: TextAlign.center),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => context.go(AppRoutes.home),
                child: Text(l10n.returnHome),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
