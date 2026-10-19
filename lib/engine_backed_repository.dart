import 'core_bridge.dart';
import 'danmaku_models.dart';
import 'download_collections.dart';
import 'engine_repository.dart';
import 'engine_routing.dart';
import 'local_store.dart';
import 'models.dart';
import 'ranking_models.dart';
import 'resource_settings.dart';
import 'source_status.dart';

/// 把 Rust 引擎装配到既有 `AppRepository` 之上。
///
/// 采用**装饰器**而非继承：只有引擎声明支持的站源与动作才切换实现，
/// 其余情况原样委托给下层（Go 核心），保证迁移过程中功能不缺失。
///
/// 未开启 `ENGINE_ROUTE` 时本类不会被使用。
class EngineBackedRepository extends AppRepository {
  EngineBackedRepository({
    required this.delegate,
    required this.engine,
    required this.route,
  });

  /// 下层仓库（当前为 Go 核心）。
  final AppRepository delegate;

  /// Rust 引擎访问层。
  final EngineRepository engine;

  /// 路由策略。
  final EngineRoute route;

  /// 引擎下载任务的本地上下文。
  ///
  /// 引擎快照只带 `dramaId`，而 UI 需要完整的 `Drama`/`Episode`，
  /// 因此在这里保留登记时的模型引用。
  final _downloads = <String, _EngineDownload>{};

  /// 当前由引擎接管的下载任务数（供测试与诊断）。
  int get downloadContextCount => _downloads.length;

  /// 该站源是否交给引擎。
  bool handles(String source) => engine.initialized && route.allows(source);

  /// 供诊断面板显示当前路由。
  String get description => EngineRouting.description;

  @override
  LocalStore? get access => delegate.access;

  @override
  set access(LocalStore? value) => delegate.access = value;

  @override
  Future<void> initialize() => delegate.initialize();

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) async {
    if (!handles(source)) {
      return delegate.catalog(
        source,
        page: page,
        query: query,
        category: category,
        force: force,
      );
    }
    return engine.catalog(source, page: page, query: query, category: category);
  }

  @override
  Future<DramaDetail> detail(Drama drama) async {
    if (!handles(drama.source)) return delegate.detail(drama);
    return engine.detail(drama);
  }

  @override
  Future<CatalogPage> cached(String source, {String category = ''}) async {
    if (!handles(source)) return delegate.cached(source, category: category);
    final page = await engine.cachedCatalog(source, category: category);
    // 引擎缓存为空时回落到下层，避免切换后端瞬间出现空列表。
    if (page.items.isEmpty) return delegate.cached(source, category: category);
    return page;
  }

  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async {
    if (!handles(source)) return delegate.categories(source, force: force);
    try {
      return await engine.categories(source);
    } catch (_) {
      // 站源未声明分类能力时交给 Go 核心。
      return delegate.categories(source, force: force);
    }
  }

  @override
  Future<String> cover(Drama drama, {bool force = false}) =>
      delegate.cover(drama, force: force);

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async {
    if (!handles(drama.source)) {
      return delegate.resolve(drama, episode, quality: quality);
    }
    try {
      return await engine.resolve(drama, episode);
    } catch (_) {
      // 取流失败时回退到 Go 核心，避免因引擎覆盖不全导致无法播放。
      return delegate.resolve(drama, episode, quality: quality);
    }
  }

  @override
  Future<PlaybackPlan> fallback(PlaybackPlan current) =>
      delegate.fallback(current);

  @override
  Future<void> cancelPlayback() => delegate.cancelPlayback();

  @override
  Future<void> release(String session) => delegate.release(session);

  @override
  Future<void> cancelCatalog() => delegate.cancelCatalog();

  @override
  Future<void> cancelPreload() => delegate.cancelPreload();

  @override
  Future<void> cancelDanmaku() => delegate.cancelDanmaku();

  @override
  Future<void> cancelSuggestions() => delegate.cancelSuggestions();

  @override
  Future<void> cancelRecommendations() => delegate.cancelRecommendations();

  @override
  Future<void> cancelHandoff() => delegate.cancelHandoff();

  @override
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) => delegate.preload(drama, episode, quality: quality, online: online);

  @override
  Future<PlaybackPlan?> prepareHandoff(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) => delegate.prepareHandoff(drama, episode, quality: quality);

  @override
  Future<PlaybackPlan?> localPlayback(Drama drama, Episode episode) =>
      delegate.localPlayback(drama, episode);

  @override
  Future<DanmakuPage> danmaku(
    PlaybackPlan plan, {
    required int startMs,
    required int durationMs,
  }) => delegate.danmaku(plan, startMs: startMs, durationMs: durationMs);

  @override
  Future<Drama?> supplementMetadata(Drama drama) =>
      delegate.supplementMetadata(drama);

  @override
  Future<CatalogPage> recommendations(
    String genre, {
    bool more = false,
    bool force = false,
  }) => delegate.recommendations(genre, more: more, force: force);

  @override
  Future<List<RankingBoard>> rankingBoards() => delegate.rankingBoards();

  @override
  Future<RankingPage> rankings(
    String board, {
    int page = 1,
    bool force = false,
  }) => delegate.rankings(board, page: page, force: force);

  @override
  Future<List<String>> suggestions(String query) => delegate.suggestions(query);

  @override
  Future<Map<String, dynamic>> storage() => delegate.storage();

  @override
  Future<String> downloadDirectory() => delegate.downloadDirectory();

  @override
  Future<void> moveDownloads(String directory) =>
      delegate.moveDownloads(directory);

  @override
  Future<int> workLease(String id, String command) =>
      delegate.workLease(id, command);

  @override
  Future<int> enqueueDownloads(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) async {
    if (!handles(detail.drama.source)) {
      return delegate.enqueueDownloads(detail, episodes, quality: quality);
    }
    var accepted = 0;
    for (final episode in episodes) {
      try {
        final plan = await engine.resolve(detail.drama, episode);
        final id = '${detail.drama.id}:${episode.id}';
        final target = await _downloadTarget(detail.drama, episode);
        await engine.download(
          id: id,
          url: plan.url,
          target: target,
          referer: plan.headers['Referer'] ?? '',
          title: episode.title,
          segments: plan.segments,
          keyUri: plan.keyUri,
          keyIv: plan.keyIv,
        );
        _downloads[id] = _EngineDownload(
          drama: detail.drama,
          episode: episode,
          index: episode.number,
        );
        accepted += 1;
      } catch (_) {
        // 单个分集失败不影响其余分集，交给上层重试。
      }
    }
    return accepted;
  }

  /// 计算下载目标路径（不含扩展名）。
  Future<String> _downloadTarget(Drama drama, Episode episode) async {
    final directory = await delegate.downloadDirectory();
    final safeDrama = drama.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final safeEpisode = episode.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return '$directory/$safeDrama/${episode.id}_$safeEpisode';
  }

  @override
  Future<List<DownloadJob>> downloads() async {
    if (_downloads.isEmpty) return delegate.downloads();
    final rows = await engine.downloads();
    final jobs = <DownloadJob>[];
    for (final row in rows) {
      final context = _downloads[row.id];
      if (context == null) continue;
      jobs.add(
        DownloadJob(
          id: row.id,
          drama: context.drama,
          episode: context.episode,
          state: row.state,
          bytes: row.bytes,
          total: row.total,
          progress: row.progress,
          error: row.error,
        ),
      );
    }
    return jobs;
  }

  @override
  Future<void> controlDownloads(String command, {String id = ''}) async {
    if (id.isEmpty) return delegate.controlDownloads(command, id: id);
    final handled = await engine.controlDownload(command, id);
    if (!handled) {
      await delegate.controlDownloads(command, id: id);
    }
    if (command == 'delete') _downloads.remove(id);
  }

  @override
  Future<DownloadBatchResult> controlDownloadBatch(
    String command,
    List<String> ids, {
    Map<String, String> expectedVersions = const {},
  }) => delegate.controlDownloadBatch(
    command,
    ids,
    expectedVersions: expectedVersions,
  );

  @override
  Future<int> updateDownloadCollection(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) => delegate.updateDownloadCollection(detail, episodes, quality: quality);

  @override
  Future<Map<String, dynamic>> lan(
    String command,
    Map<String, dynamic> payload,
  ) => delegate.lan(command, payload);

  @override
  Future<SourceStatus> sourceStatus(String source) =>
      delegate.sourceStatus(source);

  @override
  Future<SourceStatus> startSourceJob(
    String source,
    String operation, {
    Drama? drama,
  }) => delegate.startSourceJob(source, operation, drama: drama);

  @override
  Future<SourceStatus> cancelSourceJob(String source) =>
      delegate.cancelSourceJob(source);

  @override
  Future<ResourceSettings> resourceSettings() => delegate.resourceSettings();

  @override
  Future<ResourceSettings> saveResourceSettings(ResourceSettings settings) =>
      delegate.saveResourceSettings(settings);

  @override
  bool get supportsSourceManagement => delegate.supportsSourceManagement;

  @override
  bool get supportsDownloads => delegate.supportsDownloads;
}

/// 引擎下载任务在 Dart 侧的上下文。
class _EngineDownload {
  const _EngineDownload({
    required this.drama,
    required this.episode,
    required this.index,
  });

  final Drama drama;
  final Episode episode;
  final int index;
}
