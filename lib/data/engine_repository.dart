import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:duanju_app/domain/models.dart';
import 'package:duanju_app/domain/ranking_models.dart';
import 'package:duanju_app/src/rust/api.dart' as rust;
import 'package:duanju_app/src/rust/api/plugins.dart' as rust_plugins;
import 'package:duanju_app/src/rust/frb_generated.dart';

/// 把 Rust 引擎的返回结构映射为应用既有的 Dart 模型。
///
/// 刻意不修改 `Drama` / `CatalogPage` / `Episode` 的字段，
/// 保证 UI 层不感知后端来源（见 `test/engine_model_parity_test.dart`）。
class EngineRepository {
  EngineRepository({this.initialized = false});

  /// 是否已完成 `RustLib.init()`。测试里由调用方预先初始化。
  bool initialized;

  static Future<EngineRepository> create() async {
    await RustLib.init();
    return EngineRepository(initialized: true);
  }

  /// 引擎是否声明支持该站源。
  Future<bool> supports(String source) async {
    if (source.isEmpty) return false;
    final catalog = await rust.sourceCatalog();
    return catalog.any((site) => site.id == source);
  }

  /// 指定插件根目录（安装、状态、日志都在这里）。
  ///
  /// 必须在任何插件调用之前设置一次；重复设置返回 `false`，不抛异常。
  Future<bool> setPluginDirectory(String directory) async {
    if (!initialized) return false;
    return rust_plugins.setPluginDirectory(directory: directory);
  }

  /// 把引擎的站源清单同步到 [SourceSite]。
  ///
  /// 只登记内置清单之外的新 id（插件安装的源）；内置条目的名称与描述
  /// 属于产品文案，保留编译期版本。引擎不可用时静默跳过，
  /// 站源列表仍以编译期常量工作。
  Future<int> syncSourceCatalog() async {
    if (!initialized) return 0;
    try {
      final catalog = await rust.sourceCatalog();
      SourceSite.reportFromEngine(
        catalog.map(
          (site) => (id: site.id, name: site.name, group: site.group),
        ),
      );
      return catalog.length;
    } catch (error) {
      debugPrint('读取引擎站源清单失败，保留编译期站源：$error');
      return 0;
    }
  }

  Future<List<SourceSummary>> sources() async {
    final catalog = await rust.sourceCatalog();
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
    final boards = await rust.fetchRankingBoards(sourceId: source);
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
    final result = await rust.fetchRanking(
      sourceId: source,
      boardId: boardId,
      page: page,
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
    final result = await rust.fetchRecommend(
      sourceId: source,
      offset: offset,
      sessionId: sessionId,
      genre: genre,
    );
    return RecommendPage(
      items: [for (final item in result.items) _drama(item)],
      offset: result.offset,
      sessionId: result.sessionId,
      hasMore: result.hasMore,
    );
  }

  /// 搜索联想词。
  Future<List<String>> suggestions(String source, String keyword) async {
    if (keyword.trim().isEmpty) return const [];
    try {
      return await rust.fetchSuggestions(sourceId: source, keyword: keyword);
    } catch (error) {
      // 联想是「锦上添花」，失败不能拦住用户输入。
      debugPrint('联想词获取失败：$error');
      return const [];
    }
  }

  /// 一集的弹幕（从 `startMs` 起 60 秒）。
  Future<List<DomainDanmaku>> danmaku(
    Drama drama,
    Episode episode, {
    int startMs = 0,
  }) async {
    final items = await rust.fetchDanmaku(
      sourceId: drama.source,
      chapter: rust.ChapterInput(
        id: episode.id,
        title: episode.title,
        sourceId: drama.sourceId,
        videoUrl: episode.raw['videoUrl'] as String? ?? '',
        pageUrl: episode.raw['pageUrl'] as String? ?? '',
        referer: episode.raw['referer'] as String? ?? '',
      ),
      startMs: startMs,
    );
    return [
      for (final item in items)
        DomainDanmaku(
          timeMs: item.timeMs.toInt(),
          text: item.text,
          color: item.color,
        ),
    ];
  }

  /// 同一部剧的其它季。
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
      );
      return [
        for (final row in rows)
          SeriesSeason(
            season: row.season,
            title: row.title,
            sourceId: row.sourceId,
          ),
      ];
    } catch (error) {
      debugPrint('系列剧查询失败：$error');
      return const [];
    }
  }

  /// 读取站源分类，首项为引擎给出的「全部」。
  Future<List<CatalogCategory>> categories(String source) async {
    final rows = await rust.fetchCategories(sourceId: source);
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
        ? await rust.fetchCatalog(
            sourceId: source,
            page: page,
            category: category,
          )
        : await rust.fetchSearch(
            sourceId: source,
            query: query.trim(),
            page: page,
          );

    return CatalogPage(
      [for (final item in result.items) _drama(item)],
      hasMore: result.hasMore,
      warning: result.warning,
      page: result.page,
      fresh: false,
    );
  }

  /// 指定缓存目录。必须在首次访问缓存前调用。
  Future<bool> setCacheDirectory(String directory) =>
      rust.setCacheDirectory(directory: directory);

  /// 读取缓存中的目录，不联网。
  Future<CatalogPage> cachedCatalog(
    String source, {
    String category = '',
  }) async {
    final page = await rust.cachedCatalog(sourceId: source, category: category);
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
      rust.catalogIsFresh(sourceId: source, category: category);

  /// 清空指定键的缓存。
  Future<void> clearCatalog(String source, {String category = ''}) =>
      rust.clearCatalog(sourceId: source, category: category);

  /// 读取详情，返回应用既有的 `DramaDetail`。
  Future<DramaDetail> detail(Drama drama) async {
    final result = await rust.fetchDetail(
      sourceId: drama.source,
      dramaSourceId: drama.sourceId,
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
          'currentEpisode': i + 1,
        }, i + 1),
    ]);
  }

  /// 取流：把分集解析为可播放地址。
  ///
  /// HLS 会带回分片清单，播放器可直接按清单播放或预取。
  Future<PlaybackPlan> resolve(Drama drama, Episode episode) async {
    final media = await rust.fetchMedia(
      sourceId: drama.source,
      chapter: rust.ChapterInput(
        id: episode.id,
        title: episode.title,
        sourceId: drama.sourceId,
        videoUrl: episode.raw['videoUrl'] as String? ?? '',
        pageUrl: episode.raw['pageUrl'] as String? ?? '',
        referer: episode.raw['referer'] as String? ?? '',
      ),
    );
    return PlaybackPlan(
      url: media.url,
      headers: {
        if (media.referer.isNotEmpty) 'Referer': media.referer,
        'User-Agent': _engineUserAgent,
      },
      segments: media.playlist,
      keyUri: media.keyUri,
      keyIv: media.keyIv,
    );
  }

  static const _engineUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  /// 登记并执行一个下载任务。
  ///
  /// 返回下载完成后的字节数；失败时抛出异常由调用方回退。
  Future<int> download({
    required String id,
    required String url,
    required String target,
    required String referer,
    required String title,
    List<String> segments = const [],
    String keyUri = '',
    String keyIv = '',
  }) async {
    await rust.enqueueDownload(
      request: rust.DownloadRequest(
        id: id,
        url: url,
        target: target,
        referer: referer,
        title: title,
        segments: segments,
        keyUri: keyUri,
        keyIv: keyIv,
      ),
    );
    final bytes = await rust.runDownload(id: id);
    return bytes.toInt();
  }

  /// 当前下载任务快照。
  Future<List<DownloadSnapshotInfo>> downloads() async {
    final rows = await rust.downloadSnapshot();
    return [
      for (final row in rows)
        DownloadSnapshotInfo(
          id: row.id,
          title: row.title,
          state: row.state,
          bytes: row.bytes.toInt(),
          total: row.total,
          progress: row.progress,
          error: row.error,
        ),
    ];
  }

  /// 暂停 / 继续 / 重试 / 删除。
  Future<bool> controlDownload(String command, String id) =>
      rust.controlDownload(command: command, id: id);

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

  /// 导出引擎站源清单为 JSON，便于诊断面板展示。
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

/// 决定某个站源/动作是否交给 Rust 引擎处理。
///
/// 默认关闭，只有显式开启且引擎声明支持时才路由，
/// 确保 Go 路径不受影响，可随时回退。
class EngineRoute {
  const EngineRoute({required this.enabled, this.sources = const {}});

  /// 全局开关。
  final bool enabled;

  /// 允许交给引擎的站源集合；为空表示跟随引擎能力。
  final Set<String> sources;

  static final disabled = EngineRoute(enabled: false);

  bool allows(String source) {
    if (!enabled || source.isEmpty) return false;
    if (sources.isEmpty) return true;
    return sources.contains(source);
  }
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
  });

  final String id;
  final String title;
  final String state;
  final int bytes;
  final int total;
  final double progress;
  final String error;

  bool get finished => state == 'completed';
  bool get failed => state == 'failed';
}
