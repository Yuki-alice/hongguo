import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:hoshi/ui/features/downloads/views/batch_download_screen.dart';
import 'package:hoshi/data/core_bridge.dart';
import 'package:hoshi/ui/features/detail/views/detail_screen.dart';
import 'package:hoshi/ui/features/downloads/widgets/download_picker.dart';
import 'package:hoshi/domain/download_preferences.dart';
import 'package:hoshi/main.dart' show DuanjuBootstrap;
import 'package:hoshi/ui/features/downloads/views/downloads_screen.dart';
import 'package:hoshi/ui/features/home/views/home_screen.dart';
import 'package:hoshi/data/engine_backed_repository.dart';
import 'package:hoshi/data/lan/lan_controller.dart';
import 'package:hoshi/ui/features/lan/views/lan_screen.dart';
import 'package:hoshi/data/local_profiles.dart';
import 'package:hoshi/ui/features/media/views/local_media_screen.dart';
import 'package:hoshi/data/media/media_library.dart';
import 'package:hoshi/ui/features/media/views/merge_queue_screen.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/ui/features/player/views/player_screen.dart';
import 'package:hoshi/ui/features/profiles/views/profiles_screen.dart';
import 'package:hoshi/ui/features/rankings/views/rankings_screen.dart';
import 'package:hoshi/ui/features/settings/views/resource_settings_screen.dart';
import 'package:hoshi/ui/features/settings/views/engine_diagnostics_screen.dart';
import 'package:hoshi/ui/features/settings/views/settings_screen.dart';
import 'package:hoshi/ui/features/plugins/views/plugins_screen.dart';
import 'package:hoshi/ui/features/sources/views/sources_screen.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/providers/app_providers.dart';
import 'package:hoshi/ui/routing/route_args.dart';

/// 全局导航 key，供局域网推送等非 Widget 场景发起跳转。
final appNavigatorKey = GlobalKey<NavigatorState>();

/// 路由路径常量。用常量避免改名时漏改。
abstract final class AppRoutes {
  static const home = '/';
  static const profiles = '/profiles';
  static const detail = '/detail/:source/:sourceId';
  static const player = '/player/:source/:sourceId';
  static const downloads = '/downloads';
  static const localMedia = '/local-media';
  static const mergeQueue = '/merge-queue';
  static const settings = '/settings';
  static const resourceSettings = '/settings/resources';
  static const sources = '/sources';
  static const plugins = '/sources/plugins';
  static const rankings = '/rankings';
  static const lanSync = '/lan';
  static const batchDownload = '/batch-download';
  static const lanConflicts = '/lan/conflicts';
  static const downloadPreferences = '/settings/downloads';
  static const storage = '/settings/storage';
  static const engineDiagnostics = '/settings/diagnostics';
  static const downloadPicker = '/download-picker/:source/:sourceId';
  static const profileEditor = '/profiles/editor';

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
      '/download-picker/${Uri.encodeComponent(ref.source)}'
      '/${Uri.encodeComponent(ref.sourceId)}';

  static String rankingsOf(String group) =>
      withQuery(rankings, {'group': group});

  static String sourcesOf(String source) =>
      withQuery(sources, {'source': source});

  static String profilesOf({bool locked = false}) =>
      withQuery(profiles, {'locked': locked ? 1 : null});
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
GoRouter buildAppRouter(Ref ref, {String initialLocation = AppRoutes.home}) =>
    GoRouter(
      initialLocation: initialLocation,
      navigatorKey: appNavigatorKey,
      // 刻意不接 `refreshListenable`：go_router 收到刷新通知后会**按 URL
      // 重新解析**当前路由，`extra` 随之丢失。用户数据就绪、锁定、切用户
      // 这些变化改由各路由 builder 内部用 Riverpod 响应式处理，
      // 路由对象因此保持稳定，`extra` 也能可靠传递。
      routes: [
        GoRoute(
          path: AppRoutes.home,
          builder: (context, state) => const _HomeRoute(),
        ),
        GoRoute(
          path: AppRoutes.profiles,
          builder: (context, state) => ProfilesScreen(
            store: ref.read(readyStoreProvider),
            locked: state.uri.queryParameters['locked'] == '1',
          ),
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
          path: AppRoutes.downloads,
          builder: (context, state) => DownloadsScreen(
            repository: ref.read(repositoryProvider),
            store: ref.read(readyStoreProvider),
          ),
        ),
        GoRoute(
          path: AppRoutes.localMedia,
          builder: (context, state) => LocalMediaScreen(
            repository: ref.read(repositoryProvider),
            store: ref.read(readyStoreProvider),
          ),
        ),
        GoRoute(
          path: AppRoutes.mergeQueue,
          builder: (context, state) {
            // 媒体库是运行期单例；本地媒体页进入时会带上「打开即添加」标记。
            final extra = state.extra;
            final library = extra is MergeQueueExtra
                ? extra.library
                : MediaLibrary.current;
            if (library == null) {
              return _InvalidRoute(
                message: AppLocalizations.of(context).mediaLibraryNotReady,
              );
            }
            return MergeQueueScreen(
              library: library,
              repository: ref.read(repositoryProvider),
              store: ref.read(readyStoreProvider),
              addOnOpen: extra is MergeQueueExtra && extra.addOnOpen,
            );
          },
        ),
        GoRoute(
          path: AppRoutes.settings,
          builder: (context, state) => SettingsScreen(
            repository: ref.read(repositoryProvider),
            store: ref.read(readyStoreProvider),
          ),
        ),
        GoRoute(
          path: AppRoutes.resourceSettings,
          builder: (context, state) => ResourceSettingsScreen(
            repository: ref.read(repositoryProvider),
            store: ref.read(readyStoreProvider),
          ),
        ),
        GoRoute(
          path: AppRoutes.sources,
          builder: (context, state) {
            final extra = state.extra;
            return SourcesScreen(
              repository: ref.read(repositoryProvider),
              store: ref.read(readyStoreProvider),
              initialSource: state.uri.queryParameters['source'],
              // 从详情页进入「站源诊断」时带上剧集，用于播放检测；
              // 普通入口没有 extra，走默认行为。
              drama: extra is Drama ? extra : null,
            );
          },
        ),
        GoRoute(
          path: AppRoutes.plugins,
          builder: (context, state) =>
              PluginsScreen(repository: ref.read(pluginRepositoryProvider)),
        ),
        GoRoute(
          path: AppRoutes.rankings,
          builder: (context, state) => RankingsScreen(
            repository: ref.read(repositoryProvider),
            store: ref.read(readyStoreProvider),
            initialGroup: state.uri.queryParameters['group'] ?? 'hongguo',
          ),
        ),
        GoRoute(
          path: AppRoutes.lanSync,
          builder: (context, state) {
            final controller = LanController.current;
            if (controller == null) {
              return _InvalidRoute(
                message: AppLocalizations.of(context).lanNotReadyShort,
              );
            }
            return LanSyncScreen(controller: controller);
          },
        ),
        GoRoute(
          path: AppRoutes.downloadPreferences,
          builder: (context, state) =>
              DownloadPreferencesScreen(store: ref.read(readyStoreProvider)),
        ),
        GoRoute(
          path: AppRoutes.engineDiagnostics,
          builder: (context, state) {
            final repository = ref.read(repositoryProvider);
            final engine = repository is EngineBackedRepository
                ? repository.engine
                : null;
            if (engine == null) {
              return _InvalidRoute(
                message: AppLocalizations.of(
                  context,
                ).engineDiagnosticsUnsupported,
              );
            }
            return EngineDiagnosticsScreen(
              engine: engine,
              capabilities: repository.capabilities,
            );
          },
        ),
        GoRoute(
          path: AppRoutes.storage,
          builder: (context, state) => StorageScreen(
            repository: ref.read(repositoryProvider),
            store: ref.read(readyStoreProvider),
          ),
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
          path: AppRoutes.profileEditor,
          builder: (context, state) {
            final extra = state.extra;
            return ProfileEditor(
              store: ref.read(readyStoreProvider),
              profile: extra is ProfileEditorExtra ? extra.profile : null,
            );
          },
        ),
        GoRoute(
          path: AppRoutes.lanConflicts,
          builder: (context, state) {
            final controller = state.extra;
            if (controller is! LanController) {
              return _InvalidRoute(
                message: AppLocalizations.of(context).lanNotReadyShort,
              );
            }
            return LanConflictsScreen(controller: controller);
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

/// 路由实例。
///
/// 通过 provider 暴露，测试可直接读取同一份配置。
final routerProvider = Provider<GoRouter>((ref) {
  final router = buildAppRouter(ref);
  ref.onDispose(router.dispose);
  return router;
});

/// 首页入口。
///
/// go_router 不接 `refreshListenable`（刷新会按 URL 重新解析并丢失 extra），
/// 所以用户就绪、切换用户、锁定这些原地变化必须在这里 watch，才能重新
/// 选择加载页、用户页或首页。
class _HomeRoute extends ConsumerWidget {
  const _HomeRoute();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(storeProvider);
    if (store == null) return const DuanjuBootstrap();
    // LocalStore 通过 ChangeNotifier 原地修改字段，watch 计数才会重建。
    ref.watch(storeRevisionProvider);
    if (store.locked) {
      return ProfilesScreen(store: store, locked: true);
    }
    return HomeScreen(
      key: ValueKey('profile-${store.profile.id}-${store.profileEpoch}'),
      repository: ref.read(repositoryProvider),
      store: store,
    );
  }
}

DramaRef? _parseTarget(GoRouterState state) => DramaRef.tryParse(
  state.pathParameters['source'],
  state.pathParameters['sourceId'],
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
