import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;

import 'package:hoshi/data/engine_failure.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/domain/ranking_models.dart';
import 'package:hoshi/domain/resource_settings.dart';
import 'package:hoshi/domain/source_status.dart';
import 'package:hoshi/src/rust/api.dart' as rust;
import 'package:hoshi/src/rust/api/error.dart' as rust_error;
import 'package:hoshi/src/rust/frb_generated.dart';

/// Rust 引擎访问层。
///
/// 把引擎的返回结构映射为应用既有的 Dart 模型，并把 FRB 抛出的
/// `EngineFailure` 统一转成 [EngineException]。所有状态都挂在 Rust 侧的
/// 进程级单例上，这里不持有任何会话或缓存。
class EngineRepository {
  EngineRepository({this.initialized = false});

  /// 是否已完成 `RustLib.init()` 并初始化引擎。测试里由调用方预先初始化。
  bool initialized;

  /// 引擎数据目录（单例装配时确定）。
  String dataDirectory = '';

  /// 插件目录。
  String pluginDirectory = '';

  /// 启动引擎。重复调用只做一次实际初始化。
  ///
  /// [dataDirectory] 为应用数据目录；插件默认放在其下的 `plugins/`。
  static Future<EngineRepository> create({
    required String dataDirectory,
    String? pluginDirectory,
    List<rust.BundledPlugin> bundled = const [],
    ExternalLibrary? engineLibrary,
  }) async {
    // engineLibrary 只给测试/桌面开发用：打包后的移动端由 Flutter 的代码
    // 资产映射加载，传 null 即沿用生成代码的默认解析。
    await RustLib.init(externalLibrary: engineLibrary);
    await rust.initEngine();
    final result = await _guard(
      () => rust.initEngineWithDirectory(
        dataDirectory: dataDirectory,
        pluginDirectory: pluginDirectory ?? '',
        bundled: bundled,
      ),
    );
    return EngineRepository(initialized: true)
      ..dataDirectory = result.dataDirectory
      ..pluginDirectory = result.pluginDirectory
      ..bundledInstalled = result.bundledInstalled
      ..bundledSkipped = result.bundledSkipped;
  }

  /// 本次启动预装的随包插件 id。
  List<String> bundledInstalled = const [];

  /// 因已有同版本或更新版本而跳过的随包插件 id。
  List<String> bundledSkipped = const [];

  /// 仅用于测试：假定 Rust 侧已初始化。
  static EngineRepository attached() => EngineRepository(initialized: true);

  /// 引擎是否声明支持该站源。
  Future<bool> supports(String source) async {
    if (source.isEmpty) return false;
    final catalog = await _guard(rust.sourceCatalog);
    return catalog.any((site) => site.id == source);
  }

  /// 把引擎的站源清单同步到 [SourceSite]。
  ///
  /// 引擎清单是源列表的唯一来源：Go-only 源（黄豆 / 野果 / 皮果）不在清单里，
  /// 因此在 UI 中自然消失。
  Future<int> syncSourceCatalog() async {
    if (!initialized) return 0;
    final catalog = await _guard(rust.sourceCatalog);
    SourceSite.reportFromEngine(
      catalog.map((site) => (id: site.id, name: site.name, group: site.group)),
    );
    return catalog.length;
  }

  Future<List<SourceSummary>> sources() async {
    final catalog = await _guard(rust.sourceCatalog);
    return [
      for (final site in catalog)
        SourceSummary(
          id: site.id,
          name: site.name,
          group: site.group,
          apiLevel: site.apiLevel,
          capabilities: site.capabilities,
        ),
    ];
  }

  /// 榜单看板列表。站源不支持时返回空。
  Future<List<RankingBoard>> rankingBoards(String source) async {
    final boards = await _guard(
      () => rust.fetchRankingBoards(sourceId: source, requestId: _nextId()),
    );
    return [
      for (final board in boards)
        RankingBoard(
          id: board.id,
          source: source,
          name: board.name,
          description: board.group,
        ),
    ];
  }

  /// 榜单的一页。
  Future<RankingPage> ranking(
    String source,
    String boardId, {
    int page = 1,
  }) async {
    final result = await _guard(
      () => rust.fetchRanking(
        sourceId: source,
        boardId: boardId,
        page: page,
        requestId: _nextId(),
      ),
    );
    return RankingPage(
      items: [
        for (final entry in result.items)
          RankingItem(entry.rank, _drama(entry.drama), metric: entry.metric),
      ],
      hasMore: result.hasMore,
      page: result.page,
      updatedText: result.updatedText,
      stale: result.stale,
      warning: result.warning,
    );
  }

  /// 推荐流的一页。`offset`/`sessionId` 由上一页结果原样回传。
  Future<RecommendPage> recommend(
    String source, {
    int offset = 0,
    String sessionId = '',
    String genre = '',
  }) async {
    final result = await _guard(
      () => rust.fetchRecommend(
        sourceId: source,
        offset: offset,
        sessionId: sessionId,
        genre: genre,
        requestId: _nextId(),
      ),
    );
    return RecommendPage(
      items: [for (final item in result.items) _drama(item)],
      offset: result.offset,
      sessionId: result.sessionId,
      hasMore: result.hasMore,
    );
  }

  /// 搜索联想词。联想是锦上添花，失败返回空而不是抛错。
  Future<List<String>> suggestions(String source, String keyword) async {
    if (keyword.trim().isEmpty) return const [];
    try {
      return await rust.fetchSuggestions(
        sourceId: source,
        keyword: keyword,
        requestId: _nextId(),
      );
    } on rust_error.EngineFailure catch (error) {
      debugPrint('联想词获取失败：${error.message}');
      return const [];
    }
  }

  /// 一集的弹幕（从 `startMs` 起 60 秒）。
  /// 返回一页弹幕与服务端窗口游标（`endMs`）。
  ///
  /// 服务端按 30s 或 60s 分段，调用方必须用 `endMs` 推进窗口；
  /// 自己按 60s 估算会整段跳过 30s 分段里的弹幕。
  Future<DomainDanmakuPage> danmaku(
    Drama drama,
    Episode episode, {
    int startMs = 0,
  }) async {
    final page = await _guard(
      () => rust.fetchDanmaku(
        sourceId: drama.source,
        chapter: _chapterInput(drama, episode),
        startMs: startMs,
        requestId: _nextId(),
      ),
    );
    return DomainDanmakuPage(
      items: [
        for (final item in page.items)
          DomainDanmaku(
            timeMs: item.timeMs.toInt(),
            text: item.text,
            color: item.color,
          ),
      ],
      endMs: page.endMs,
    );
  }

  /// 同一部剧的其它季。没有系列信息时返回空。
  Future<List<SeriesSeason>> seasons(Drama drama) async {
    try {
      final rows = await rust.fetchSeasons(
        sourceId: drama.source,
        drama: rust.DramaInput(
          id: drama.id,
          source: drama.source,
          sourceId: drama.sourceId,
          title: drama.title,
        ),
        requestId: _nextId(),
      );
      return [
        for (final row in rows)
          SeriesSeason(
            season: row.season,
            title: row.title,
            sourceId: row.sourceId,
          ),
      ];
    } on rust_error.EngineFailure catch (error) {
      debugPrint('系列剧查询失败：${error.message}');
      return const [];
    }
  }

  /// 读取站源分类，首项为引擎给出的「全部」。
  Future<List<CatalogCategory>> categories(String source) async {
    final rows = await _guard(
      () => rust.fetchCategories(sourceId: source, requestId: _nextId()),
    );
    return [for (final row in rows) CatalogCategory(row.id, row.name)];
  }

  /// 读取目录，返回应用既有的 `CatalogPage`。
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
  }) async {
    final result = query.trim().isEmpty
        ? await _guard(
            () => rust.fetchCatalog(
              sourceId: source,
              page: page,
              category: category,
              requestId: _nextId('catalog'),
              session: 'catalog-$source',
            ),
          )
        : await _guard(
            () => rust.fetchSearch(
              sourceId: source,
              query: query.trim(),
              page: page,
              requestId: _nextId('search'),
            ),
          );

    return CatalogPage(
      [for (final item in result.items) _drama(item)],
      hasMore: result.hasMore,
      warning: result.warning,
      page: result.page,
      fresh: false,
    );
  }

  /// 读取缓存中的目录，不联网。
  Future<CatalogPage> cachedCatalog(
    String source, {
    String category = '',
  }) async {
    final page = await _guard(
      () => rust.cachedCatalog(sourceId: source, category: category),
    );
    return CatalogPage(
      [for (final item in page.items) _drama(item)],
      hasMore: page.hasMore,
      warning: page.warning,
      page: page.page,
      fresh: false,
    );
  }

  /// 缓存是否仍在有效期内。
  Future<bool> catalogIsFresh(String source, {String category = ''}) =>
      _guard(() => rust.catalogIsFresh(sourceId: source, category: category));

  /// 清空指定键的缓存。
  Future<void> clearCatalog(String source, {String category = ''}) =>
      _guard(() => rust.clearCatalog(sourceId: source, category: category));

  /// 取消某个会话的在途目录请求。
  Future<bool> cancelCatalog(String source) =>
      _guard(() => rust.cancelRequest(session: 'catalog-$source'));

  /// 读取详情，返回应用既有的 `DramaDetail`。
  Future<DramaDetail> detail(Drama drama) async {
    final result = await _guard(
      () => rust.fetchDetail(
        sourceId: drama.source,
        dramaSourceId: drama.sourceId,
        requestId: _nextId('detail'),
      ),
    );
    final fresh = _drama(result.drama);
    return DramaDetail(fresh.merge(drama), [
      for (var i = 0; i < result.chapters.length; i++)
        Episode({
          'id': result.chapters[i].id,
          'title': result.chapters[i].title,
          'source': result.chapters[i].source,
          'videoUrl': result.chapters[i].videoUrl,
          'pageUrl': result.chapters[i].pageUrl,
          'referer': result.chapters[i].referer,
          'vip': result.chapters[i].vip,
          'currentEpisode': i + 1,
        }, i + 1),
    ]);
  }

  /// 取流：把分集解析为可播放地址。
  ///
  /// HLS 会带回分片清单，播放器可直接按清单播放或预取。
  Future<PlaybackPlan> resolve(Drama drama, Episode episode) async {
    final media = await _guard(
      () => rust.fetchMedia(
        sourceId: drama.source,
        chapter: _chapterInput(drama, episode),
        requestId: _nextId('resolve'),
      ),
    );
    return PlaybackPlan(
      url: media.url,
      // CDN 签名源（剧果等）必须同时带 Cookie 与 Origin，否则播放器与
      // 下载器都会被拒。两者都为空时不写入，避免发出空头。
      headers: {
        if (media.referer.isNotEmpty) 'Referer': media.referer,
        if (media.cookies.isNotEmpty) 'Cookie': media.cookies,
        if (media.origin.isNotEmpty) 'Origin': media.origin,
        'User-Agent': _engineUserAgent,
      },
      segments: media.playlist,
      keyUri: media.keyUri,
      keyIv: media.keyIv,
      decryptionKey: media.cencKey,
      quality: media.quality,
      qualities: media.qualities,
      // 弹幕标识 = 源侧分集定位符。红果把它放在 `hongguo-cenc://<vid>`，
      // 规则源放在分集页地址；弹幕接口按 `Chapter.video_url` 回查这一集，
      // 所以这里原样带 `videoUrl`，没有时退回分集 id。
      danmakuId: episode.raw['videoUrl'] as String? ?? episode.id,
      source: drama.source,
      sourceId: drama.sourceId,
    );
  }

  static const _engineUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  /// 登记一个下载任务（不启动）。
  ///
  /// 返回引擎侧的登记序号。执行交给 [runDownload]，两者分离后
  /// 「加入下载」才能立即返回，进度交给快照与列表页轮询。
  Future<int> registerDownload({
    required String id,
    required String url,
    required String target,
    required String referer,
    required String title,
    String dramaId = '',
    String episodeId = '',
    String dramaTitle = '',
    int episodeIndex = 0,
    String coverUrl = '',
    List<String> segments = const [],
    String keyUri = '',
    String keyIv = '',
  }) async {
    final revision = await _guard(
      () => rust.enqueueDownload(
        request: rust.DownloadRequest(
          id: id,
          url: url,
          target: target,
          referer: referer,
          title: title,
          dramaId: dramaId,
          episodeId: episodeId,
          dramaTitle: dramaTitle,
          episodeIndex: episodeIndex,
          coverUrl: coverUrl,
          segments: segments,
          keyUri: keyUri,
          keyIv: keyIv,
        ),
      ),
    );
    return revision.toInt();
  }

  /// 执行一个已登记的任务，直到完成 / 暂停 / 失败。
  ///
  /// 返回完成后的字节数；失败抛 [EngineException]。调用方应在后台
  /// Future 里等待它——在 UI 调用链上 await 会让「加入下载」卡到下载结束。
  Future<int> runDownload(String id) async {
    final bytes = await _guard(() => rust.runDownload(id: id));
    return bytes.toInt();
  }

  /// 站源健康检测：目录 → 详情 → 取流 → 媒体连接。
  ///
  /// [playback] 为 false 时只测目录与详情（「仅目录检测」入口）。
  Future<SourceHealth> checkSource(
    String source, {
    bool playback = true,
  }) async {
    final result = await _guard(
      () => rust.checkSource(
        sourceId: source,
        requestId: _nextId('health'),
        playback: playback,
      ),
    );
    return SourceHealth(
      checkedAt: DateTime.fromMillisecondsSinceEpoch(
        result.checkedAtMs.toInt(),
      ),
      state: result.state,
      sample: result.sample,
      steps: [
        for (final step in result.steps)
          SourceHealthStep(
            name: step.name,
            state: step.state,
            message: step.message,
            host: step.host,
            httpStatus: step.httpStatus,
            elapsedMs: step.elapsedMs.toInt(),
          ),
      ],
    );
  }

  /// 取消某个站源正在进行的健康检测。
  Future<bool> cancelSourceCheck(String source) =>
      _guard(() => rust.cancelRequest(session: 'health-$source'));

  /// 当前下载任务快照。
  Future<List<DownloadSnapshotInfo>> downloads() async {
    final rows = await _guard(rust.downloadSnapshot);
    return [
      for (final row in rows)
        DownloadSnapshotInfo(
          id: row.id,
          title: row.title,
          revision: row.revision.toInt(),
          state: row.state,
          bytes: row.bytes.toInt(),
          total: row.total,
          progress: row.progress,
          error: row.error,
          dramaId: row.dramaId,
          episodeId: row.episodeId,
          dramaTitle: row.dramaTitle,
          episodeIndex: row.episodeIndex,
          coverUrl: row.coverUrl,
        ),
    ];
  }

  /// 下载进度流。先补发当前任务，随后持续推送变化。
  Stream<DownloadProgressInfo> watchDownloads() =>
      rust.downloadProgressStream().map(
        (event) => DownloadProgressInfo(
          id: event.id,
          dramaId: event.dramaId,
          episodeId: event.episodeId,
          title: event.title,
          state: event.state,
          bytes: event.bytes.toInt(),
          total: event.total,
          progress: event.progress,
          error: event.error,
          revision: event.revision.toInt(),
        ),
      );

  /// 暂停 / 继续 / 重试 / 删除。
  Future<bool> controlDownload(String command, String id) =>
      _guard(() => rust.controlDownload(command: command, id: id));

  /// 离线播放：把已完成任务映射为本地播放计划。
  ///
  /// 返回 `null` 表示任务已完成但文件已被删除；未下载完成时抛
  /// `Unsupported`，调用方据此回退到在线播放。
  Future<PlaybackPlan?> localPlayback({
    required String dramaId,
    required String episodeId,
    String source = '',
    String sourceId = '',
  }) async {
    final local = await _guard(
      () => rust.localPlayback(dramaId: dramaId, episodeId: episodeId),
    );
    if (local == null) return null;
    return PlaybackPlan(
      url: local.url,
      local: true,
      danmakuId: episodeId,
      source: source,
      sourceId: sourceId,
    );
  }

  /// 批量控制，返回被处理的任务数。
  Future<int> controlDownloads(String command, List<String> ids) =>
      _guard(() => rust.controlDownloads(command: command, ids: ids));

  /// 诊断快照。
  Future<EngineDiagnosticsInfo> diagnostics() async {
    final snapshot = await _guard(rust.engineDiagnostics);
    return EngineDiagnosticsInfo.fromRust(snapshot);
  }

  /// 取封面本地路径。命中缓存直接返回，否则下载后落盘。
  Future<CoverInfo> cover(Drama drama, {bool force = false}) async {
    final result = await _guard(
      () => rust.fetchCover(
        sourceId: drama.source,
        url: drama.cover,
        referer: '',
        force: force,
      ),
    );
    return CoverInfo(path: result.path, cached: result.cached);
  }

  /// 清空封面缓存，返回删除的文件数。
  Future<int> clearCoverCache() => _guard(rust.clearCoverCache);

  /// 只读导入旧版（Go）下载索引，把已完成任务转成引擎任务。
  ///
  /// 幂等：重复调用不会产生重复任务。旧索引缺失或损坏时返回
  /// `found == false`，不抛异常——旧数据不可读不该拦住启动。
  Future<LegacyMigrationInfo> importLegacyDownloads(String downloadRoot) async {
    final result = await _guard(
      () => rust.importLegacyDownloads(downloadRoot: downloadRoot),
    );
    return LegacyMigrationInfo(
      found: result.found,
      imported: result.imported,
      skipped: {
        for (final reason in result.skipped) reason.reason: reason.count,
      },
    );
  }

  /// 读取运行期资源设置（并发 / 间隔 / 代理）。
  Future<ResourceSettings> resourceSettings() async {
    final dto = await _guard(rust.resourceSettings);
    return _settingsFromDto(dto);
  }

  /// 保存资源设置。越界字段由引擎夹取，返回实际生效的值。
  Future<ResourceSettings> saveResourceSettings(
    ResourceSettings settings,
  ) async {
    final dto = await _guard(
      () => rust.saveResourceSettings(
        settings: rust.ResourceSettingsDto(
          proxyMode: settings.proxyMode,
          proxyUrl: settings.proxyUrl,
          catalogConcurrency: settings.catalogConcurrency,
          catalogIntervalMs: settings.catalogIntervalMs,
          downloadConcurrency: settings.downloadConcurrency,
          downloadBySource: settings.downloadBySource,
          warning: settings.warning,
        ),
      ),
    );
    return _settingsFromDto(dto);
  }

  static ResourceSettings _settingsFromDto(rust.ResourceSettingsDto dto) =>
      ResourceSettings(
        proxyMode: dto.proxyMode,
        proxyUrl: dto.proxyUrl,
        catalogConcurrency: dto.catalogConcurrency,
        catalogIntervalMs: dto.catalogIntervalMs,
        downloadConcurrency: dto.downloadConcurrency,
        downloadBySource: dto.downloadBySource,
        warning: dto.warning,
      );

  /// 清空某个站源的会话（令牌 / Cookie）。
  Future<int> clearSourceSession(String source) =>
      _guard(() => rust.clearSourceSession(sourceId: source));

  /// 插件安装 / 卸载后重建注册表。会话与下载任务保持不变。
  Future<int> reloadSources() => _guard(rust.reloadSources);

  /// 指定插件目录已由初始化确定，这里只暴露读取。
  Future<bool> pluginsReady() async => pluginDirectory.isNotEmpty;

  Future<String> describeSources() async {
    final list = await sources();
    return jsonEncode([
      for (final site in list)
        {
          'id': site.id,
          'name': site.name,
          'group': site.group,
          'apiLevel': site.apiLevel,
          'capabilities': site.capabilities,
        },
    ]);
  }

  int _sequence = 0;

  /// 生成请求号。同一进程内单调递增，UI 可据此丢弃过期回调。
  String _nextId([String prefix = 'req']) {
    _sequence += 1;
    final stamp = DateTime.now().microsecondsSinceEpoch;
    return '$prefix-$stamp-$_sequence';
  }

  rust.ChapterInput _chapterInput(Drama drama, Episode episode) =>
      rust.ChapterInput(
        id: episode.id,
        title: episode.title,
        sourceId: drama.sourceId,
        videoUrl: episode.raw['videoUrl'] as String? ?? '',
        pageUrl: episode.raw['pageUrl'] as String? ?? '',
        referer: episode.raw['referer'] as String? ?? '',
        vip: episode.vip,
      );

  Drama _drama(rust.DramaItem item) => Drama(
    id: item.id,
    source: item.source,
    sourceId: item.sourceId,
    title: item.title,
    description: item.description,
    cover: item.cover,
    episodes: item.episodes,
    category: item.category,
    vip: item.vip,
    heat: item.heat,
    views: item.views,
    onlineDate: item.onlineDate,
    tags: item.tags,
    releaseStatus: item.releaseStatus,
  );
}

/// 把 FRB 抛出的 `EngineFailure` 统一转成 [EngineException]。
Future<T> _guard<T>(Future<T> Function() work) async {
  try {
    return await work();
  } on rust_error.EngineFailure catch (failure) {
    throw EngineException.fromRust(failure);
  } on EngineException {
    rethrow;
  }
}

/// 封面缓存结果。
class CoverInfo {
  const CoverInfo({required this.path, required this.cached});
  final String path;

  /// 是否命中缓存（未发网络请求）。
  final bool cached;
}

/// 旧下载索引的迁移结果。
class LegacyMigrationInfo {
  const LegacyMigrationInfo({
    required this.found,
    required this.imported,
    required this.skipped,
  });

  /// 是否读到旧索引文件。
  final bool found;

  /// 成功登记的条目数。
  final int imported;

  /// 跳过原因 → 条数。
  final Map<String, int> skipped;

  @override
  String toString() =>
      'legacy(found=$found, imported=$imported, skipped=$skipped)';
}

/// 引擎声明支持的站源摘要。
class SourceSummary {
  const SourceSummary({
    required this.id,
    required this.name,
    required this.group,
    required this.apiLevel,
    required this.capabilities,
  });

  final String id;
  final String name;
  final String group;
  final int apiLevel;
  final List<String> capabilities;

  bool supports(String capability) => capabilities.contains(capability);

  @override
  String toString() => '$id($name) ${capabilities.join(",")}';
}

/// 下载任务快照（引擎侧只读视图）。
class DownloadSnapshotInfo {
  const DownloadSnapshotInfo({
    required this.id,
    required this.title,
    required this.state,
    required this.bytes,
    required this.total,
    required this.progress,
    required this.error,
    this.dramaId = '',
    this.episodeId = '',
    this.dramaTitle = '',
    this.episodeIndex = 0,
    this.coverUrl = '',
    this.revision = 0,
  });

  final String id;
  final String title;
  final String state;
  final int bytes;
  final int total;
  final double progress;
  final String error;

  /// 重启后用于重建展示上下文；旧版本索引里可能为空。
  final String dramaId;
  final String episodeId;
  final String dramaTitle;
  final int episodeIndex;
  final String coverUrl;

  /// 引擎侧版本号：每次任务被改动都会递增，用于合并清理的版本闸门。
  final int revision;

  bool get finished => state == 'completed';
  bool get failed => state == 'failed';
}

/// 下载进度事件（引擎主动推送）。
class DownloadProgressInfo {
  const DownloadProgressInfo({
    required this.id,
    required this.dramaId,
    required this.episodeId,
    required this.title,
    required this.state,
    required this.bytes,
    required this.total,
    required this.progress,
    required this.error,
    required this.revision,
  });

  final String id;
  final String dramaId;
  final String episodeId;
  final String title;
  final String state;
  final int bytes;
  final int total;
  final double progress;
  final String error;
  final int revision;

  bool get finished => state == 'completed';
  bool get failed => state == 'failed';

  DownloadSnapshotInfo get snapshot => DownloadSnapshotInfo(
    id: id,
    title: title,
    state: state,
    bytes: bytes,
    total: total,
    progress: progress,
    error: error,
  );
}

/// 诊断快照的 Dart 视图。
class EngineDiagnosticsInfo {
  const EngineDiagnosticsInfo({
    required this.version,
    required this.dataDirectory,
    required this.pluginDirectory,
    required this.sessionFile,
    required this.catalogFile,
    required this.uptime,
    required this.requestCount,
    required this.registryRevision,
    required this.activeSessions,
    required this.sessionKeys,
    required this.cachedCatalogs,
    required this.queuedJobs,
    required this.runningJobs,
    required this.completedJobs,
    required this.failedJobs,
    required this.sources,
    required this.pluginsLoaded,
    required this.pluginsFailed,
    required this.recentErrors,
  });

  final String version;
  final String dataDirectory;
  final String pluginDirectory;
  final String sessionFile;
  final String catalogFile;
  final Duration uptime;
  final int requestCount;
  final int registryRevision;
  final int activeSessions;
  final int sessionKeys;
  final int cachedCatalogs;
  final int queuedJobs;
  final int runningJobs;
  final int completedJobs;
  final int failedJobs;
  final List<SourceCapabilityInfo> sources;
  final List<String> pluginsLoaded;
  final List<PluginFailureInfo> pluginsFailed;
  final List<EngineException> recentErrors;

  factory EngineDiagnosticsInfo.fromRust(rust.EngineDiagnostics snapshot) =>
      EngineDiagnosticsInfo(
        version: snapshot.version,
        dataDirectory: snapshot.dataDirectory,
        pluginDirectory: snapshot.pluginDirectory,
        sessionFile: snapshot.sessionFile,
        catalogFile: snapshot.catalogFile,
        uptime: Duration(milliseconds: snapshot.uptimeMs.toInt()),
        requestCount: snapshot.requestCount.toInt(),
        registryRevision: snapshot.registryRevision.toInt(),
        activeSessions: snapshot.activeSessions,
        sessionKeys: snapshot.sessionKeys,
        cachedCatalogs: snapshot.cachedCatalogs,
        queuedJobs: snapshot.queuedJobs,
        runningJobs: snapshot.runningJobs,
        completedJobs: snapshot.completedJobs,
        failedJobs: snapshot.failedJobs,
        sources: [
          for (final source in snapshot.sources)
            SourceCapabilityInfo(
              id: source.id,
              name: source.name,
              group: source.group,
              apiLevel: source.apiLevel,
              capabilities: source.capabilities,
            ),
        ],
        pluginsLoaded: snapshot.pluginsLoaded,
        pluginsFailed: [
          for (final failure in snapshot.pluginsFailed)
            PluginFailureInfo(id: failure.id, detail: failure.detail),
        ],
        recentErrors: [
          for (final error in snapshot.recentErrors)
            EngineException.fromRust(error),
        ],
      );
}

/// 单个站源的能力矩阵。
class SourceCapabilityInfo {
  const SourceCapabilityInfo({
    required this.id,
    required this.name,
    required this.group,
    required this.apiLevel,
    required this.capabilities,
  });

  final String id;
  final String name;
  final String group;
  final int apiLevel;
  final List<String> capabilities;

  bool supports(String capability) => capabilities.contains(capability);
}

/// 插件加载失败原因。
class PluginFailureInfo {
  const PluginFailureInfo({required this.id, required this.detail});
  final String id;
  final String detail;
}
