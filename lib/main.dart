import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'package:hoshi/data/bundled_plugins.dart';
import 'package:hoshi/data/core_bridge.dart';
import 'package:hoshi/data/engine_repository.dart';
import 'package:hoshi/data/engine_backed_repository.dart';
import 'package:hoshi/ui/core/app_layout.dart';
import 'package:hoshi/ui/core/app_orientation.dart';
import 'package:hoshi/ui/core/app_theme.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/core/app_l10n.dart';
import 'package:hoshi/data/media/media_library.dart';
import 'package:hoshi/package_smoke.dart';
import 'package:hoshi/data/lan/lan_controller.dart';
import 'package:hoshi/ui/providers/app_providers.dart';
import 'package:hoshi/ui/routing/route_args.dart';
import 'package:hoshi/ui/routing/app_router.dart';
import 'package:hoshi/data/video_enhancement/video_enhancement_assets.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid) {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(AppTheme.systemBars(Brightness.dark));
  }
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
  }
  MediaKit.ensureInitialized();
  VideoEnhancementAssets.registerLicenses();
  if (Platform.isWindows && arguments.firstOrNull == '--package-smoke') {
    await runPackageSmoke(arguments);
    return;
  }
  final device = await AppDevice.detect();
  runApp(AppBootstrap(device: device));
}

/// 启动装配。
///
/// 只负责「准备好根依赖」并把它们注入 `ProviderScope`；
/// 之后的界面切换、路由与状态都由 Riverpod 与 go_router 承担。
class AppBootstrap extends StatefulWidget {
  const AppBootstrap({super.key, this.device = const AppDevice()});
  final AppDevice device;
  @override
  State<AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends State<AppBootstrap>
    with WidgetsBindingObserver {
  AppRepository? _repository;
  LocalStore? _store;
  Object? _error;
  late AppDevice _device = widget.device;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    LanController.current?.dispose();
    LanController.current = null;
    MediaLibrary.current?.dispose();
    MediaLibrary.current = null;
    _store?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && Platform.isAndroid) {
      unawaited(_refreshDevice());
    }
    if (!Platform.isIOS) return;
    final library = MediaLibrary.current;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (library != null) {
        library.suspended = true;
        unawaited(library.cancel());
      }
      // 走仓库契约而不是直接构造后端：下载队列仍在迁移中（Core-2），
      // 由实现方决定能否暂停，入口这里不感知具体后端。
      unawaited(
        _repository?.controlDownloads('pauseAll').catchError((Object _) {}) ??
            Future<void>.value(),
      );
    } else if (state == AppLifecycleState.resumed) {
      if (library != null) library.suspended = false;
    }
  }

  /// 装配仓库。
  ///
  /// 引擎是唯一后端：初始化失败不会回退到 Go（已移除），而是把错误交给
  /// 启动页展示并提供重试，避免「静默降级成功能不全」的假象。
  Future<AppRepository> _buildRepository() async {
    final core = NativeRepository();
    final support = await getApplicationSupportDirectory();
    // 随包官方插件在初始化时预装；读取失败只记日志，不拦启动。
    final bundled = await BundledPlugins.load(warn: debugPrint);
    final engine = await EngineRepository.create(
      dataDirectory: '${support.path}/engine',
      bundled: bundled,
    );
    // 把引擎上报的站源（含已安装插件）并入 SourceSite，供 UI 列表使用。
    await engine.syncSourceCatalog();
    return EngineBackedRepository(delegate: core, engine: engine);
  }

  Future<void> _refreshDevice() async {
    final detected = await AppDevice.detect(fallback: _device);
    if (!mounted ||
        (_device.television == detected.television &&
            _device.version == detected.version)) {
      return;
    }
    setState(() => _device = detected);
  }

  Future<void> _initialize() async {
    setState(() => _error = null);
    try {
      final preferences = await SharedPreferences.getInstance();
      await _refreshDevice();
      final repository = await _buildRepository();
      await repository.initialize();
      if (!mounted) return;
      final store = LocalStore(preferences);
      repository.access = store;
      MediaLibrary.attach(repository, store);
      LanController.current?.dispose();
      final link = LanController(
        repository,
        store,
        kind: _device.television
            ? 'tv'
            : Platform.isWindows
            ? 'computer'
            : 'phone',
      );
      LanController.current = link;
      link.openPlayback = _handoffPlayback(link, store, repository);
      setState(() {
        _repository = repository;
        _store = store;
      });
    } catch (failure) {
      if (mounted) setState(() => _error = failure);
    }
  }

  /// 局域网推送播放的接收逻辑。
  ///
  /// 播放页需要完整的 `DramaDetail`，无法只靠 URL 重建，因此通过
  /// go_router 的 `extra` 传递；路径本身仍带标识，便于日志与深链兜底。
  Future<void> Function(LanIncomingPlayback) _handoffPlayback(
    LanController link,
    LocalStore store,
    AppRepository repository,
  ) {
    return (LanIncomingPlayback request) async {
      final epoch = request.profileEpoch;
      if (request.cancelled ||
          !mounted ||
          store.locked ||
          !link.receiving ||
          store.profileEpoch != epoch ||
          !store.allowsSource(request.detail.drama.source)) {
        throw StateError('当前用户不能接收播放');
      }
      await link.playbackHost?.stop();
      if (request.cancelled ||
          !mounted ||
          store.locked ||
          store.profileEpoch != epoch ||
          !link.receiving) {
        throw StateError('播放接收已取消');
      }
      final context = appNavigatorKey.currentContext;
      if (context == null || !context.mounted) {
        throw StateError('接收设备界面尚未就绪');
      }
      final ref = DramaRef.fromDramaId(request.detail.drama.id);
      if (ref == null) throw StateError('接收到的剧集标识无效');
      final location = AppRoutes.playerOf(ref);
      context.go(
        location,
        extra: PlayerRouteExtra(
          detail: request.detail,
          initialIndex: request.index,
          initialPosition: request.position,
        ),
      );
    };
  }

  @override
  Widget build(BuildContext context) {
    final repository = _repository;
    final store = _store;
    if (repository == null || store == null) {
      return MaterialApp(
        title: appName,
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        home: DuanjuBootstrap(error: _error, onRetry: _initialize),
      );
    }
    return ProviderScope(
      overrides: [
        repositoryProvider.overrideWithValue(repository),
        storeProvider.overrideWith(() => StoreHolder(store)),
        deviceProvider.overrideWithValue(_device),
      ],
      child: DuanjuApp(repository: repository, store: store, wrapScope: false),
    );
  }
}

/// 应用外壳。
///
/// 保留 `repository` / `store` 参数是为了让测试可以直接构造；
/// 传入时用它们覆盖 Provider，未传入时依赖外层 `ProviderScope`。
class DuanjuApp extends StatelessWidget {
  const DuanjuApp({
    super.key,
    required this.repository,
    this.store,
    this.bootstrapError,
    this.onRetry,
    this.television = false,
    this.version = appVersion,
    this.navigatorKey,
    this.wrapScope = true,
  });

  final AppRepository repository;
  final LocalStore? store;
  final String? bootstrapError;
  final VoidCallback? onRetry;
  final bool television;
  final String version;
  final GlobalKey<NavigatorState>? navigatorKey;

  /// 是否由本组件建立 `ProviderScope`。
  ///
  /// `AppBootstrap` 已建立外层 scope 并注入真实依赖，此时传 false，
  /// 避免嵌套两层 scope 导致依赖被覆盖两次。
  final bool wrapScope;

  @override
  Widget build(BuildContext context) {
    final shell = _AppShell(version: version);
    if (!wrapScope) return shell;
    // override 数量必须恒定：Riverpod 不允许同一个 ProviderScope
    // 在重建时增删 override，因此用 `overrideWithValue(null)` 表达缺省。
    //
    // 注意：`overrideWithValue` 变化不会通知下游，所以路由不能靠它刷新。
    // 用 `key` 让 store 身份变化时重建整棵 scope，从而重新解析首屏；
    // 同一用户的重建（例如主题变化）不会触发，因为 key 保持不变。
    return ProviderScope(
      // store 身份变化时必须换一个全新的 scope：override 只替换 notifier
      // 工厂，不会重新执行已存在 provider 的 `build()`，旧 scope 会一直
      // 停留在「用户数据未就绪」。换 key 让容器连同路由一起重建。
      key: ValueKey<LocalStore?>(store),
      overrides: [
        repositoryProvider.overrideWithValue(repository),
        storeProvider.overrideWith(() => StoreHolder(store)),
        deviceProvider.overrideWithValue(
          television ? const AppDevice(television: true) : const AppDevice(),
        ),
      ],
      child: shell,
    );
  }
}

class _AppShell extends ConsumerWidget {
  const _AppShell({required this.version});

  final String version;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final device = ref.watch(deviceProvider);
    final router = ref.watch(routerProvider);
    final television = ref.watch(televisionProvider);
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp.router(
      routerConfig: router,
      title: appName,
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: AppTheme.mode(themeMode),
      builder: (context, child) {
        AppL10n.current = AppLocalizations.of(context);
        final theme = Theme.of(context);
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: AppTheme.systemBars(theme.brightness),
          child: ColoredBox(
            color: theme.scaffoldBackgroundColor,
            child: AppOrientationScope(
              television: television,
              child: AppLayout(
                television: television,
                version: version.isEmpty ? device.version : version,
                child: Theme(
                  data: television ? televisionTheme(theme) : theme,
                  child: Shortcuts(
                    shortcuts: const {
                      SingleActivator(
                        LogicalKeyboardKey.select,
                        includeRepeats: false,
                      ): ActivateIntent(),
                      SingleActivator(
                        LogicalKeyboardKey.gameButtonA,
                        includeRepeats: false,
                      ): ActivateIntent(),
                      SingleActivator(LogicalKeyboardKey.goBack):
                          DismissIntent(),
                    },
                    child: FocusTraversalGroup(child: child!),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 启动阶段的加载与错误页。
///
/// 只返回页面内容，不自己包 `MaterialApp`：它既可能出现在路由内部
/// （用户尚未加载完成），也可能出现在应用外壳之外（启动失败）。
/// 外壳由调用方提供，避免嵌套两个 MaterialApp。
class DuanjuBootstrap extends StatelessWidget {
  const DuanjuBootstrap({super.key, this.error, this.onRetry});

  final Object? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.play_circle_fill_rounded,
                color: colors.primary,
                size: 72,
              ),
              const SizedBox(height: 24),
              Text(
                error?.toString() ?? '正在打开$appName',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18),
              ),
              const SizedBox(height: 24),
              if (error == null)
                const CircularProgressIndicator()
              else
                FilledButton(onPressed: onRetry, child: const Text('重新打开')),
            ],
          ),
        ),
      ),
    );
  }
}
