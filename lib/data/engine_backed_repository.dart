import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:hoshi/data/app_contract.dart';
import 'package:hoshi/data/engine_failure.dart';
import 'package:hoshi/data/repository_capabilities.dart';
import 'package:hoshi/domain/danmaku_models.dart';
import 'package:hoshi/domain/download_collections.dart';
import 'package:hoshi/data/engine_repository.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/domain/ranking_models.dart';
import 'package:hoshi/domain/resource_settings.dart';
import 'package:hoshi/domain/source_status.dart';
import 'package:hoshi/src/rust/api.dart' as rust;
import 'package:hoshi/src/rust/api/error.dart' as rust_error;

/// 生产仓库：目录 / 详情 / 搜索 / 分类 / 取流由 Rust 引擎承担。
///
/// 不再有路由开关，也没有「引擎不支持就切 Go」的静默回落（Go 后端已停止演进）。
/// 引擎声明不支持的能力直接抛 [UnsupportedFailure]，由 [capabilities] 在渲染前
/// 让 UI 隐藏入口；下载、LAN、站源诊断等仍在迁移中的能力暂时委托给下层实现，
/// 并在 [capabilities] 中如实标注。
class EngineBackedRepository extends AppRepository {
  EngineBackedRepository({required this.engine});

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

  /// 正在进行的站源检测（source → 阶段）。
  final _sourceJobs = <String, _SourceJobState>{};

  /// 最近一次站源健康报告（source → 报告）。
  final _sourceHealth = <String, SourceHealth>{};

  @override
  RepositoryCapabilities get capabilities => const RepositoryCapabilities(
    sourceManagement: true,
    downloads: true,
    danmaku: true,
    recommendations: true,
    rankings: true,
    suggestions: true,
    resourceSettings: true,
    localPlayback: true,
    lan: false,
  );

  @override
  LocalStore? get access => _access;

  @override
  set access(LocalStore? value) => _access = value;

  LocalStore? _access;

  /// 启动时把旧 Go 下载记录以只读方式导入引擎索引。
  ///
  /// Go 后端已在 Core-4 物理移除，这里没有「先初始化下层」这一步；
  /// 迁移失败只记录、不抛错——旧数据不可读不该拦住启动。
  @override
  Future<void> initialize() async {
    try {
      final directory = await downloadDirectory();
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
    if (!handles(source)) throw UnsupportedFailure('目录');
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
    if (!handles(drama.source)) throw UnsupportedFailure('详情');
    try {
      return await engine.detail(drama);
    } on EngineException catch (error) {
      throw await _translate(error, drama.source);
    }
  }

  @override
  Future<CatalogPage> cached(String source, {String category = ''}) async {
    if (!handles(source)) return CatalogPage([]);
    final page = await engine.cachedCatalog(source, category: category);
    return page;
  }

  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async {
    if (!handles(source)) return const [CatalogCategory.all];
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
    if (drama.cover.isEmpty) return '';
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
    if (!handles(drama.source)) throw UnsupportedFailure('取流');
    try {
      return await engine.resolve(drama, episode);
    } on EngineException catch (error) {
      throw await _translate(error, drama.source);
    }
  }

  @override
  Future<PlaybackPlan> fallback(PlaybackPlan current) async => current;

  @override
  Future<void> cancelPlayback() async {}

  @override
  Future<void> release(String session) async {}

  @override
  Future<void> cancelCatalog() async {}

  @override
  Future<void> cancelPreload() async {}

  @override
  Future<void> cancelDanmaku() async {}

  @override
  Future<void> cancelSuggestions() async {}

  @override
  Future<void> cancelRecommendations() async {}

  @override
  Future<void> cancelHandoff() async {}

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
    if (!handles(drama.source)) return null;
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
  }) async => null;

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
    return null;
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
    if (durationMs <= startMs) throw UnsupportedFailure('弹幕');
    // `danmakuId` 携带的是源侧的分集定位符（红果是 `hongguo-cenc://<vid>`，
    // 规则源是分集页地址）。引擎按 `Chapter.video_url` 找这一集的弹幕，
    // 因此必须原样回传——用 id 重新拼 Drama 会丢掉定位符，弹幕必然报
    // 「章节 ID 无效」。
    final page = await engine.danmaku(
      Drama(
        id: plan.sourceId.isEmpty
            ? '${plan.source}:${plan.danmakuId}'
            : '${plan.source}:${plan.sourceId}',
        source: plan.source,
        sourceId: plan.sourceId,
        title: '',
      ),
      Episode({'id': plan.danmakuId, 'videoUrl': plan.danmakuId}, 1),
      startMs: startMs,
    );
    // 窗口结束以服务端游标为准（红果按 30s 分段），并夹到本集时长内。
    final next = _min(page.endMs, durationMs);
    if (next <= startMs) throw UnsupportedFailure('弹幕');
    return DanmakuPage(
      episodeId: plan.danmakuId,
      startMs: startMs,
      nextMs: next,
      items: [
        for (final item in page.items)
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
          ? {
              ...{
                for (final drama in _recommendItems[genre] ?? const <Drama>[])
                  drama.id: drama,
              },
              for (final drama in page.items) drama.id: drama,
            }
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
    if (source.isEmpty) throw UnsupportedFailure('榜单');
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
  Future<Map<String, dynamic>> storage() async => {
    'directory': await downloadDirectory(),
  };

  /// 下载目录：引擎数据目录下的 `downloads/`。
  ///
  /// 旧 Go 版把任务放在 `<app support>/downloads`，这里的只读导入仍指向
  /// 同一位置，因此升级后已下载的文件继续可播。
  @override
  Future<String> downloadDirectory() async {
    final root = engine.dataDirectory;
    return root.isEmpty ? '' : '$root/downloads';
  }

  @override
  Future<void> moveDownloads(String directory) async =>
      throw UnsupportedFailure('迁移下载目录');

  @override
  Future<int> workLease(String id, String command) async => 0;

  @override
  Future<int> enqueueDownloads(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) async {
    if (!handles(detail.drama.source)) throw UnsupportedFailure('下载');
    // 两阶段：先逐集取流并登记（取流必须联网，可能失败，失败的分集跳过），
    // 再把已登记的任务**在后台**跑起来。以前这里串行 await 每一集下载到
    // 完成，「加入下载」会卡到整部剧下完；现在返回登记数，进度由下载页
    // 的快照轮询承担，引擎的并发闸门负责限速。
    final registered = <(String, _EngineDownload)>[];
    for (final episode in episodes) {
      try {
        final plan = await engine.resolve(detail.drama, episode);
        final id = '${detail.drama.id}:${episode.id}';
        final target = await _downloadTarget(
          detail.drama,
          episode,
          hls: plan.segments.isNotEmpty,
        );
        await engine.registerDownload(
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
        registered.add((
          id,
          _EngineDownload(
            drama: detail.drama,
            episode: episode,
            index: episode.number,
          ),
        ));
      } on Object {
        // 单个分集取流失败不影响其余分集，列表里看不到它即代表失败。
      }
    }
    for (final (id, context) in registered) {
      _downloads[id] = context;
      // 执行由引擎 worker 接管：`enqueue_download` 内部已 pump，
      // 这里再调 `runDownload` 会双跑同一任务（从断点续传重入、字节跳变）。
    }
    return registered.length;
  }

  /// 计算下载目标路径。
  ///
  /// 扩展名不能省：mpv / ffmpeg / 系统都按扩展名挑解复用器，HLS 拼接产物
  /// 是 MPEG-TS，单文件按 mp4 处理。没有扩展名的文件在「本地媒体」和
  /// 外部播放器里都不可识别。
  Future<String> _downloadTarget(
    Drama drama,
    Episode episode, {
    bool hls = false,
  }) async {
    final directory = await downloadDirectory();
    final safeDrama = drama.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final safeEpisode = episode.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final extension = hls ? '.ts' : '.mp4';
    return '$directory/$safeDrama/${episode.id}_$safeEpisode$extension';
  }

  /// 下载任务列表：引擎索引 + 下层旧记录。
  ///
  /// 引擎任务在重启后仍然存在（索引落盘），但快照只带 id；上下文
  /// （`Drama` / `Episode`）由登记时缓存在这里，重启后为空，
  /// 因此这类任务只能靠 `downloadProgress` 流补齐展示字段。
  @override
  Future<List<DownloadJob>> downloads() async {
    final rows = await engine.downloads();
    if (rows.isEmpty) return const [];
    final archivedIds = await archivedJobIds();
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
          revision: row.revision,
          archived: archivedIds.contains(row.id),
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
    // 「暂停全部」是通知栏 / iOS 后台的命令：引擎按单任务控制，这里展开。
    if (command == 'pauseAll') {
      final ids = [for (final job in await engine.downloads()) job.id];
      if (ids.isNotEmpty) await engine.controlDownloads('pause', ids);
      return;
    }
    if (command == 'archive' || command == 'restore') {
      final target = id.isEmpty
          ? [for (final job in await engine.downloads()) job.id]
          : [id];
      await _setArchived(target, archived: command == 'archive');
      return;
    }
    final engineCommand = _engineCommand(command);
    if (id.isEmpty) {
      final ids = [for (final job in await engine.downloads()) job.id];
      if (ids.isNotEmpty) {
        await engine.controlDownloads(engineCommand, ids);
        if (engineCommand == 'delete') _downloads.clear();
      }
      return;
    }
    await engine.controlDownload(engineCommand, id);
    if (engineCommand == 'delete') _downloads.remove(id);
  }

  /// UI 命令名 → 引擎命令名。引擎只认 `pause` / `resume` / `retry` /
  /// `delete`；「删除」在 UI 里叫 `remove`，不映射就是全部静默失败。
  String _engineCommand(String command) => switch (command) {
    'remove' || 'delete' => 'delete',
    'resume' || 'retry' => 'resume',
    _ => command,
  };

  /// 已归档任务集合。引擎没有「归档」状态，这是 UI 层的展示旗标，
  /// 落在 LocalStore 里跨启动保留（下载任务本身是全局的，不随用户切换）。
  Future<Set<String>> archivedJobIds() async {
    final store = access;
    if (store == null) return const {};
    return {
      for (final id in store.archivedDownloadIds)
        if (id.isNotEmpty) id,
    };
  }

  Future<void> _setArchived(
    Iterable<String> ids, {
    required bool archived,
  }) async {
    final store = access;
    if (store == null) return;
    final current = {...store.archivedDownloadIds};
    archived ? current.addAll(ids) : current.removeAll(ids);
    store.archivedDownloadIds = current.toList();
  }

  /// 批量控制：引擎任务走引擎，其余（旧 Go 记录）交给下层。
  ///
  /// 分流依据是本进程登记过的任务 id。`expectedVersions` 是「合并完成后
  /// 清理原分集」的版本闸门：值与引擎 `revision` 不一致的任务会被跳过，
  /// 而不是误删已被替换的文件。这里必须传整数 `revision`，不能再传
  /// `created-bytes-quality` 这类复合串——解析失败会恒为 0，闸门永远拒绝。
  @override
  Future<DownloadBatchResult> controlDownloadBatch(
    String command,
    List<String> ids, {
    Map<String, int> expectedVersions = const {},
  }) async {
    final engineIds = ids.toSet().toList();
    if (engineIds.isEmpty) {
      return const DownloadBatchResult(completed: [], failures: {});
    }

    // 归档是 UI 旗标，在本地完成，不进引擎。
    if (command == 'archive' || command == 'restore') {
      await _setArchived(engineIds, archived: command == 'archive');
      return DownloadBatchResult(completed: engineIds, failures: {});
    }
    final versions = <rust.DownloadVersion>[
      for (final id in engineIds)
        if (expectedVersions[id] != null)
          rust.DownloadVersion(
            id: id,
            revision: BigInt.from(expectedVersions[id]!),
          ),
    ];
    final rust.DownloadBatchOutcome outcome;
    try {
      outcome = await rust.controlDownloadBatch(
        command: _engineCommand(command),
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
    if (_engineCommand(command) == 'delete') {
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
  }) async => throw UnsupportedFailure('下载合集');

  @override
  Future<Map<String, dynamic>> lan(
    String command,
    Map<String, dynamic> payload,
  ) async => throw UnsupportedFailure('局域网互联');

  @override
  Future<SourceStatus> sourceStatus(String source) async {
    final job = _sourceJobs[source];
    final health = _sourceHealth[source];
    // 目录数取本地缓存（不打网络），让「缓存了多少部剧」始终可见。
    var count = 0;
    try {
      final cached = await engine.cachedCatalog(source);
      count = cached.items.length;
    } on Object {
      // 缓存读不到就按 0 显示。
    }
    if (job != null) {
      return SourceStatus(
        source: source,
        count: count,
        running: true,
        operation: job.operation,
        stage: job.stage,
        completed: job.completed,
        total: job.total,
        startedAt: job.startedAt,
        health: health,
      );
    }
    if (health == null) {
      return SourceStatus(source: source, count: count);
    }
    return SourceStatus(
      source: source,
      count: count,
      updatedAt: health.checkedAt,
      finishedAt: health.checkedAt,
      error: health.state == 'failed' ? _failedStep(health).message : '',
      health: health,
    );
  }

  /// 启动一次站源检测。`check` 走全链路（含取流），`checkCatalog` 只测目录。
  ///
  /// 检测在后台 Future 里跑；`sourceStatus` 的轮询负责把阶段与结果
  /// 反映到 UI，因此这里立即返回「运行中」的状态即可。
  @override
  Future<SourceStatus> startSourceJob(
    String source,
    String operation, {
    Drama? drama,
  }) async {
    if (operation != 'check' && operation != 'checkCatalog') {
      throw UnsupportedFailure('站源任务 $operation');
    }
    if (_sourceJobs.containsKey(source)) {
      return sourceStatus(source);
    }
    final playback = operation == 'check';
    final job = _SourceJobState(
      operation: operation,
      stage: '入口与目录',
      total: playback ? 4 : 2,
    );
    _sourceJobs[source] = job;
    unawaited(() async {
      try {
        final health = await engine.checkSource(source, playback: playback);
        _sourceHealth[source] = health;
      } on Object {
        // 检测失败也要落地，否则 UI 会一直显示「检测中」。
        _sourceHealth[source] = SourceHealth(
          checkedAt: DateTime.now(),
          state: 'failed',
          sample: '',
          steps: const [],
        );
      } finally {
        _sourceJobs.remove(source);
      }
    }());
    return sourceStatus(source);
  }

  @override
  Future<SourceStatus> cancelSourceJob(String source) async {
    try {
      await engine.cancelSourceCheck(source);
    } on Object {
      // 会话不存在（检测已结束）不算错误。
    }
    return sourceStatus(source);
  }

  SourceHealthStep _failedStep(SourceHealth? health) =>
      health?.steps.firstWhere(
        (step) => step.state == 'failed',
        orElse: () => SourceHealthStep(
          name: '',
          state: 'failed',
          message: '检测未通过',
          elapsedMs: 0,
        ),
      ) ??
      SourceHealthStep(name: '', state: 'failed', message: '', elapsedMs: 0);

  @override
  Future<ResourceSettings> resourceSettings() => engine.resourceSettings();

  @override
  Future<ResourceSettings> saveResourceSettings(ResourceSettings settings) =>
      engine.saveResourceSettings(settings);

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

/// 一次站源检测的进行中状态。
class _SourceJobState {
  _SourceJobState({
    required this.operation,
    required this.stage,
    required this.total,
  }) : startedAt = DateTime.now(),
       completed = 0;

  final String operation;
  final String stage;
  final int total;
  final DateTime startedAt;
  final int completed;
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
