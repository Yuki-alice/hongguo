import 'package:flutter/foundation.dart';

import 'package:duanju_app/data/core_bridge.dart';
import 'package:duanju_app/data/engine_failure.dart';
import 'package:duanju_app/data/repository_capabilities.dart';
import 'package:duanju_app/domain/danmaku_models.dart';
import 'package:duanju_app/domain/download_collections.dart';
import 'package:duanju_app/data/engine_repository.dart';
import 'package:duanju_app/data/local_store.dart';
import 'package:duanju_app/domain/models.dart';
import 'package:duanju_app/domain/ranking_models.dart';
import 'package:duanju_app/domain/resource_settings.dart';
import 'package:duanju_app/domain/source_status.dart';
import 'package:duanju_app/src/rust/api.dart' as rust;
import 'package:duanju_app/src/rust/api/error.dart' as rust_error;

/// 生产仓库：目录 / 详情 / 搜索 / 分类 / 取流由 Rust 引擎承担。
///
/// 不再有路由开关，也没有「引擎不支持就切 Go」的静默回落（Go 后端已停止演进）。
/// 引擎声明不支持的能力直接抛 [UnsupportedFailure]，由 [capabilities] 在渲染前
/// 让 UI 隐藏入口；下载、LAN、站源诊断等仍在迁移中的能力暂时委托给下层实现，
/// 并在 [capabilities] 中如实标注。
class EngineBackedRepository extends AppRepository {
  EngineBackedRepository({required this.delegate, required this.engine});

  /// 下层实现：承担尚未迁到引擎的本机能力（下载、媒体、LAN 等）。
  final AppRepository delegate;

  /// Rust 引擎访问层。
  final EngineRepository engine;

  /// 引擎下载任务的本地上下文。
  ///
  /// 引擎快照只带 `dramaId`，而 UI 需要完整的 `Drama`/`Episode`，
  /// 因此在这里保留登记时的模型引用。
  final _downloads = <String, _EngineDownload>{};

  /// 当前由引擎接管的下载任务数（供测试与诊断）。
  int get downloadContextCount => _downloads.length;

  /// 该站源是否交给引擎。
  bool handles(String source) => engine.initialized && source.isNotEmpty;

  @override
  RepositoryCapabilities get capabilities => RepositoryCapabilities(
    sourceManagement: false,
    downloads: delegate.supportsDownloads,
    danmaku: true,
    recommendations: true,
    rankings: true,
    suggestions: true,
    resourceSettings: false,
    localPlayback: delegate.supportsDownloads,
    lan: false,
  );

  @override
  LocalStore? get access => delegate.access;

  @override
  set access(LocalStore? value) => delegate.access = value;

  /// 启动顺序：先初始化下层（旧下载目录写在这里），再让引擎以只读方式
  /// 导入旧索引。迁移失败只记录、不抛错——旧数据不可读不该拦住启动。
  @override
  Future<void> initialize() async {
    await delegate.initialize();
    try {
      final info = await delegate.storage();
      final directory = info['directory'] as String? ?? '';
      if (directory.isNotEmpty) {
        _legacyMigration = await engine.importLegacyDownloads(directory);
      }
    } on Object catch (error) {
      debugPrint('旧下载索引导入跳过：$error');
    }
  }

  /// 上一次旧索引迁移的结果，供诊断页展示。
  LegacyMigrationInfo? get legacyMigration => _legacyMigration;
  LegacyMigrationInfo? _legacyMigration;

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) async {
    if (!handles(source)) return delegate.catalog(source, page: page, query: query, category: category, force: force);
    try {
      return await engine.catalog(
        source,
        page: page,
        query: query,
        category: category,
      );
    } on EngineException catch (error) {
      throw await _translate(error, source);
    }
  }

  @override
  Future<DramaDetail> detail(Drama drama) async {
    if (!handles(drama.source)) return delegate.detail(drama);
    try {
      return await engine.detail(drama);
    } on EngineException catch (error) {
      throw await _translate(error, drama.source);
    }
  }

  @override
  Future<CatalogPage> cached(String source, {String category = ''}) async {
    if (!handles(source)) return delegate.cached(source, category: category);
    final page = await engine.cachedCatalog(source, category: category);
    // 引擎缓存为空时读下层缓存，避免切换后端瞬间出现空列表。
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
    } on EngineException catch (error) {
      // 站源未声明分类能力：返回「全部」即可，不当作错误。
      if (error.isUnsupported || error.kind == EngineFailureKind.parseChanged) {
        return const [CatalogCategory.all];
      }
      rethrow;
    }
  }

  /// 封面：引擎有 URL 时自己下载并缓存；没有 URL 时交给下层（旧记录）。
  @override
  Future<String> cover(Drama drama, {bool force = false}) async {
    if (drama.cover.isEmpty) return delegate.cover(drama, force: force);
    // 失败直接抛出：`CachedCoverImage` 的 FutureBuilder 会渲染占位与重试，
    // 静默回退下层只会让同一张图被下载两次。
    final result = await engine.cover(drama, force: force);
    return result.path;
  }

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
    } on EngineException catch (error) {
      throw await _translate(error, drama.source);
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

  /// 预加载：引擎取流本身无副作用，提前 resolve 一次即可。
  ///
  /// 失败返回 `null`（预加载是优化，不该把错误抛给正在浏览的用户）。
  @override
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) async {
    if (!handles(drama.source)) {
      return delegate.preload(drama, episode, quality: quality, online: online);
    }
    try {
      return await engine.resolve(drama, episode);
    } on EngineException {
      return null;
    }
  }

  @override
  Future<PlaybackPlan?> prepareHandoff(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) => delegate.prepareHandoff(drama, episode, quality: quality);

  /// 离线播放优先走引擎的下载索引；没有完成任务时交给下层（旧 Go 记录）。
  @override
  Future<PlaybackPlan?> localPlayback(Drama drama, Episode episode) async {
    try {
      final plan = await engine.localPlayback(
        dramaId: drama.id,
        episodeId: episode.id,
        source: drama.source,
        sourceId: drama.sourceId,
      );
      if (plan != null) return plan;
    } on EngineException catch (error) {
      // 未下载完成是常态，回退到下层旧记录；其它错误照常上报。
      if (!error.isUnsupported) rethrow;
    }
    return delegate.localPlayback(drama, episode);
  }

  /// 弹幕：引擎按 `startMs` 返回该窗口内的条目，这里补上分页语义。
  ///
  /// 引擎的分段粒度是 60 秒（与 Go 版一致），因此窗口固定为
  /// `[startMs, startMs + 60s)`，且不越过本集时长。
  @override
  Future<DanmakuPage> danmaku(
    PlaybackPlan plan, {
    required int startMs,
    required int durationMs,
  }) async {
    if (plan.local || plan.danmakuId.isEmpty || plan.source.isEmpty) {
      throw UnsupportedFailure('弹幕');
    }
    final next = _min(startMs + 60000, durationMs);
    if (next <= startMs) throw UnsupportedFailure('弹幕');
    final items = await engine.danmaku(
      Drama(
        id: '${plan.source}:${plan.danmakuId}',
        source: plan.source,
        sourceId: plan.sourceId,
        title: '',
      ),
      Episode({'id': plan.danmakuId}, 1),
      startMs: startMs,
    );
    return DanmakuPage(
      episodeId: plan.danmakuId,
      startMs: startMs,
      nextMs: next,
      items: [
        for (final item in items)
          if (item.timeMs >= startMs && item.timeMs < next)
            DanmakuItem(
              id: '${item.timeMs}:${item.text.hashCode}',
              text: item.text,
              timeMs: item.timeMs.toInt(),
            ),
      ],
    );
  }

  static int _min(int a, int b) => a < b ? a : b;

  /// 元数据补全：只对「引擎详情能补的字段」生效。
  ///
  /// 红果目录页不带上线日期，详情页带；其余源目录与详情字段一致，
  /// 因此这里直接复用详情结果，不再为补元数据单发一次请求。
  @override
  Future<Drama?> supplementMetadata(Drama drama) async {
    if (drama.source != SourceSite.hongguo.id) return null;
    if (drama.onlineDate.isNotEmpty) return null;
    try {
      final detail = await engine.detail(drama);
      final fresh = detail.drama;
      return fresh.onlineDate.isEmpty ? null : fresh;
    } on EngineException catch (error) {
      // 补元数据失败不应影响详情页主流程。
      if (error.isUnsupported) return null;
      rethrow;
    }
  }

  /// 推荐流由主源直接返回；引擎没有该能力时显式不支持。
  @override
  Future<CatalogPage> recommendations(
    String genre, {
    bool more = false,
    bool force = false,
  }) async {
    try {
      final page = await engine.recommend(
        SourceSite.hongguo.id,
        offset: more ? _recommendOffsets[genre] ?? 0 : 0,
        sessionId: _recommendSessions[genre] ?? '',
        genre: genre,
      );
      _recommendOffsets[genre] = page.offset;
      _recommendSessions[genre] = page.sessionId;
      // 推荐页整页替换而不是追加，因此这里必须返回累积结果；
      // 只返回增量会让「加载更多」把已有条目冲掉。
      final merged = more
          ? {...{for (final drama in _recommendItems[genre] ?? const <Drama>[]) drama.id: drama},
             for (final drama in page.items) drama.id: drama}
          : {for (final drama in page.items) drama.id: drama};
      _recommendItems[genre] = merged.values.toList();
      return CatalogPage(
        _recommendItems[genre]!,
        hasMore: page.hasMore,
        page: 1,
        fresh: false,
      );
    } on EngineException catch (error) {
      _recommendOffsets.remove(genre);
      _recommendSessions.remove(genre);
      if (!more) _recommendItems.remove(genre);
      if (error.isUnsupported) throw UnsupportedFailure('推荐流');
      throw await _translate(error, SourceSite.hongguo.id);
    }
  }

  /// 推荐游标。引擎用 `(offset, sessionId)` 翻页，Dart 侧按 genre 记住上一页。
  final _recommendOffsets = <String, int>{};
  final _recommendSessions = <String, String>{};

  /// 已加载的推荐条目，按 genre 累积。
  final _recommendItems = <String, List<Drama>>{};

  /// 榜单看板由引擎返回，`source` 取自引擎清单而不是 Dart 硬编码表。
  @override
  Future<List<RankingBoard>> rankingBoards() async {
    final boards = <RankingBoard>[];
    for (final source in await engine.sources()) {
      if (!source.supports('rankings')) continue;
      try {
        boards.addAll(await engine.rankingBoards(source.id));
      } on EngineException catch (error) {
        // 单个源没有榜单不是错误，跳过即可；其它失败照常上报。
        if (!error.isUnsupported) rethrow;
      }
    }
    return boards;
  }

  @override
  Future<RankingPage> rankings(
    String board, {
    int page = 1,
    bool force = false,
  }) async {
    final source = RankingBoard.sourceForID(board);
    if (source.isEmpty) return delegate.rankings(board, page: page, force: force);
    try {
      return await engine.ranking(source, board, page: page);
    } on EngineException catch (error) {
      throw await _translate(error, source);
    }
  }

  /// 联想只有主源提供；引擎没有该能力时返回空，不回落 Go。
  @override
  Future<List<String>> suggestions(String query) async {
    if (query.trim().isEmpty) return const [];
    try {
      return await engine.suggestions(SourceSite.hongguo.id, query);
    } on EngineException catch (error) {
      if (error.isUnsupported) return const [];
      rethrow;
    }
  }

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
          dramaId: detail.drama.id,
          episodeId: episode.id,
          dramaTitle: detail.drama.title,
          episodeIndex: episode.number,
          coverUrl: detail.drama.cover,
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
      } on Object {
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

  /// 下载任务列表：引擎索引 + 下层旧记录。
  ///
  /// 引擎任务在重启后仍然存在（索引落盘），但快照只带 id；上下文
  /// （`Drama` / `Episode`）由登记时缓存在这里，重启后为空，
  /// 因此这类任务只能靠 `downloadProgress` 流补齐展示字段。
  @override
  Future<List<DownloadJob>> downloads() async {
    final rows = await engine.downloads();
    if (rows.isEmpty) {
      // 引擎没有任何任务时才回落到下层，避免两套队列同时出现在 UI。
      return delegate.downloads();
    }
    final jobs = <DownloadJob>[];
    for (final row in rows) {
      final context = _downloads[row.id] ?? _contextFromSnapshot(row);
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

  /// 重启后从索引里的展示字段重建上下文。
  ///
  /// 索引现在带剧名 / 集号 / 封面，因此进程重启后任务不会在列表里消失。
  /// 旧索引没有这些字段时返回 `null`，任务由下次下载操作重新登记。
  _EngineDownload? _contextFromSnapshot(DownloadSnapshotInfo row) {
    if (row.dramaId.isEmpty) return null;
    final drama = Drama(
      id: row.dramaId,
      source: row.dramaId.split(':').first,
      sourceId: row.dramaId.split(':').length > 1
          ? row.dramaId.split(':')[1]
          : '',
      title: row.dramaTitle.isEmpty ? row.dramaId : row.dramaTitle,
      cover: row.coverUrl,
    );
    final episode = Episode({
      'id': row.episodeId,
      'title': row.title,
    }, row.episodeIndex == 0 ? 1 : row.episodeIndex);
    return _EngineDownload(
      drama: drama,
      episode: episode,
      index: row.episodeIndex,
    );
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

  /// 批量控制：引擎任务走引擎，其余（旧 Go 记录）交给下层。
  ///
  /// 分流依据是本进程登记过的任务 id。`expectedVersions` 是「合并完成后
  /// 清理原分集」的版本闸门：值与引擎 `revision` 不一致的任务会被跳过，
  /// 而不是误删已被替换的文件。
  @override
  Future<DownloadBatchResult> controlDownloadBatch(
    String command,
    List<String> ids, {
    Map<String, String> expectedVersions = const {},
  }) async {
    final engineIds = <String>[];
    final legacyIds = <String>[];
    for (final id in ids.toSet()) {
      if (_downloads.containsKey(id)) {
        engineIds.add(id);
      } else {
        legacyIds.add(id);
      }
    }
    if (engineIds.isEmpty) {
      return delegate.controlDownloadBatch(
        command,
        legacyIds,
        expectedVersions: expectedVersions,
      );
    }

    final versions = <rust.DownloadVersion>[
      for (final id in engineIds)
        if (expectedVersions[id] != null)
          rust.DownloadVersion(
            id: id,
            revision: BigInt.from(int.tryParse(expectedVersions[id]!) ?? 0),
          ),
    ];
    final rust.DownloadBatchOutcome outcome;
    try {
      outcome = await rust.controlDownloadBatch(
        command: command,
        ids: engineIds,
        expectedVersions: versions,
      );
    } on rust_error.EngineFailure catch (failure) {
      throw EngineException.fromRust(failure);
    }
    final completed = <String>[...outcome.completed];
    final failures = <String, String>{
      for (final failure in outcome.failures) failure.id: failure.detail,
    };
    if (legacyIds.isNotEmpty) {
      final legacy = await delegate.controlDownloadBatch(
        command,
        legacyIds,
        expectedVersions: {
          for (final entry in expectedVersions.entries)
            if (legacyIds.contains(entry.key)) entry.key: entry.value,
        },
      );
      completed.addAll(legacy.completed);
      failures.addAll(legacy.failures);
    }
    if (command == 'delete' || command == 'remove') {
      for (final id in completed) {
        _downloads.remove(id);
      }
    }
    return DownloadBatchResult(completed: completed, failures: failures);
  }

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

  /// 站源诊断 / 健康检查仍在下层实现（Core-2 之后迁入引擎）。
  @override
  bool get supportsSourceManagement => capabilities.sourceManagement;

  /// 下载能力以能力矩阵为唯一真相，避免「按钮可见但底层不支持」。
  @override
  bool get supportsDownloads => capabilities.downloads;

  /// 引擎失败补上站源上下文后原样抛出。
  ///
  /// 只做归一，不做「换源重试」：退避策略由 UI 按 `kind` 决定，
  /// 在这里偷偷重试会让用户看到两次网络请求却无法解释。
  Future<EngineException> _translate(
    EngineException error,
    String source,
  ) async => error.sourceId.isEmpty
      ? EngineException(
          kind: error.kind,
          message: error.message,
          sourceId: source,
          requestId: error.requestId,
          retryable: error.retryable,
          httpStatus: error.httpStatus,
          retryAtMs: error.retryAtMs,
        )
      : error;
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
