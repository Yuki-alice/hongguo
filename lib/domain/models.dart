import 'dart:convert';

import 'package:hoshi/app_build.dart';

class SourceSite {
  const SourceSite(
    this.id,
    this.name,
    this.description, {
    this.contentTypes = const [],
  });
  final String id;
  final String name;
  final String description;

  /// 内容类型（`short-drama` / `movie` / …）。由引擎上报，空表示未标注。
  ///
  /// 编译期常量表里不写死类型：类型是站源/扩展的属性，只有引擎知道真值
  /// （插件装的源也在这里出现），写死会让「装了动漫源但显示短剧」这种错
  /// 没法靠更新扩展修好。
  final List<String> contentTypes;

  /// 是否属于某个内容类型。未标注的源不属于任何类型。
  bool hasType(String type) => contentTypes.contains(type);
  bool get onlineSearch => id == 'hongguo' || pagedSearch;
  bool get pagedSearch =>
      id == 'huangju' || id == 'yeguo' || id == 'dsd' || duanjuPaged;
  bool get duanjuPaged => const {
    'yaguo',
    'guanguo',
    'huaguo',
    'niuguo',
    'wangguo',
    'faguo',
    'piguo',
    'wuguo',
  }.contains(id);
  bool get searchSuggestions => id == 'hongguo';
  String get groupId => switch (id) {
    'huangguo-video' || 'huangguoai' || 'cloudfront' => 'huangguo',
    _ => id,
  };
  String get groupName => groupId == 'huangguo' ? '黄果' : name;
  String get entryName => switch (id) {
    'huangguo-video' => '视频',
    'huangguoai' => 'AI',
    'cloudfront' => '旧版',
    _ => name,
  };

  static const hongguo = SourceSite('hongguo', '红果', '短剧 · 漫剧 · AI 剧');
  static const dsd = SourceSite('dsd', '帝果', '分类视频 · 在线搜索');

  /// 旧 Go 后端使用的首个源标识。源列表已改由引擎驱动，
  /// 这一个常量只用于读取历史数据时把 `huangdou:` 前缀改写为红果。
  static const legacyHuangdou = 'huangdou';

  static const duanjuValues = [
    SourceSite('yaguo', '芽果', '星芽短剧 · 登录接口'),
    SourceSite('maoguo', '猫果', '七猫短剧 · 签名接口'),
    SourceSite('fanguo', '饭果', '西饭短剧 · 搜索接口'),
    SourceSite('guanguo', '观果', '围观短剧 · 分类接口'),
    SourceSite('heguo', '河果', '河马剧场 · 网页接口'),
    SourceSite('xingguo', '星果', '星星短剧 · 连载接口'),
    SourceSite('huaguo', '花果', '花生短剧 · 网页目录'),
    SourceSite('niuguo', '牛果', '牛牛短剧 · 分类接口'),
    SourceSite('wangguo', '网果', '短剧网站 · 网页目录'),
    SourceSite('faguo', '发果', '168 短剧 · 网页目录'),
    SourceSite('wuguo', '伍果', '五五短剧 · 网页目录'),
  ];

  /// 展示用清单：只提供名称与描述，**不决定源是否存在**。
  ///
  /// 引擎上报的 id 不在表内时，用引擎给出的名称兜底；表内的 id 不在引擎
  /// 清单里时，一律隐藏（`SourceSite.values` 只返回引擎报告的条目）。
  ///
  /// `ALL_SOURCES` 仍决定**编译进哪些源**：单源版只带红果，引擎清单里
  /// 也只会有红果。版本开关不做运行时降级——引擎声明了却编译不进来，
  /// 那属于构建缺陷，应当暴露而不是静默过滤。
  static const allKnownValues = [
    hongguo,
    SourceSite('huangju', '剧果', '热门 · 最新 · 分类短剧'),
    SourceSite('yeguo', '野果', '分类短剧 · 在线搜索'),
    dsd,
    SourceSite('huangguo-video', '黄果视频', '视频剧集'),
    SourceSite('huangguoai', '黄果 AI', 'AI 短剧'),
    SourceSite('cloudfront', '黄果旧版', '旧 API 剧库'),
    ...duanjuValues,
  ];

  /// 当前版本可用的展示清单。
  static const knownValues = allSourcesEnabled ? allKnownValues : [hongguo];

  /// 引擎报告的站源（含插件安装的源）。这是源列表的唯一来源。
  ///
  /// 启动时由 `EngineRepository.syncSourceCatalog` 填充，插件安装 / 卸载后重填。
  /// 尚未同步时（测试、启动早期）回退到 [knownValues]，保证 UI 不空。
  static final Map<String, SourceSite> _reported = {};

  static bool _synced = false;

  /// 2026-10-24 实网复测确认「点进去必坏」的源（`check_source` 取流未过）。
  ///
  /// 站点常复活，因此**只隐藏 UI 入口，不删源码**；复测恢复后从本表移除。
  /// 清单与复测记录见 `docs/PLAN.md`。
  static const _offlineIds = {
    // 目录可读、取流必失败：用户点进详情就等于看到「播放失败」。
    'niuguo', // 解析服务器挂，取流 20s 超时
    'huangju', // 分集目录 404
    'huaguo', // 分集目录解析失败
    'fanguo', // 取流解析失败
    'guanguo', // 分集目录解析失败
    'xingguo', // 分集目录解析失败
    // 目录都进不去。
    'cloudfront', // 4001
    'huangguoai', // 入口超时
    'huangguo-video', // 403
    'wuguo', // 空响应
    'dsd', // 入口超时
  };

  /// 当前可用站源。引擎同步过就以引擎为准；否则用内置表兜底。
  static List<SourceSite> get values {
    if (!_synced) return knownValues;
    return [for (final id in _reported.keys) _reported[id]!];
  }

  /// 用引擎的站源清单替换当前列表。重复调用是幂等的。
  ///
  /// 引擎只给 id / name / group，展示文案仍优先取编译期版本：
  /// 「帝果 · 分类视频」这类描述是产品文案，不该由引擎的 group 字段决定。
  /// 已确认不可用的源（[_offlineIds]）在写入前剔除，UI 不会再给出必坏入口。
  static void reportFromEngine(
    Iterable<
      ({String id, String name, String group, List<String> contentTypes})
    >
    entries,
  ) {
    _reported
      ..clear()
      ..addEntries(
        entries.where((entry) => !_offlineIds.contains(entry.id)).map((entry) {
          final known = knownValues.where((site) => site.id == entry.id);
          // 文案取编译期版本，**类型取引擎**：类型属于扩展，不属于产品文案。
          return MapEntry(
            entry.id,
            SourceSite(
              entry.id,
              known.isNotEmpty ? known.first.name : entry.name,
              known.isNotEmpty ? known.first.description : entry.group,
              contentTypes: entry.contentTypes,
            ),
          );
        }),
      );
    _synced = true;
  }

  /// 清空引擎上报（测试与「重置站源」用）。
  static void clearReported() {
    _reported.clear();
    _synced = false;
  }

  /// 引擎是否已上报过清单。
  static bool get synced => _synced;

  /// 是否可用。
  ///
  /// 引擎同步过就以引擎清单为准——它已经包含版本裁剪的结果（单源构建里
  /// 引擎只注册红果）。未同步时按编译期清单兜底，供启动早期与测试使用。
  static bool isAvailable(String id) => _synced
      ? _reported.containsKey(id)
      : knownValues.any((site) => site.id == id);

  /// 是否是「认识」的 id。旧数据里可能引用已下线的源（`huangdou` / `piguo`），
  /// 这些仍算已知，才能读回档案与历史而不报格式错误。
  static bool isKnown(String id) =>
      allKnownValues.any((site) => site.id == id) ||
      id == legacyHuangdou ||
      _reported.containsKey(id);
  static SourceSite byId(String id) =>
      _reported[id] ??
      allKnownValues.firstWhere((site) => site.id == id, orElse: () => hongguo);
}

class SourceGroup {
  const SourceGroup(this.id, this.name, this.sources);
  final String id;
  final String name;
  final List<SourceSite> sources;

  static List<SourceGroup> fromSources(Iterable<SourceSite> sources) {
    final groups = <String, List<SourceSite>>{};
    for (final source in sources) {
      (groups[source.groupId] ??= []).add(source);
    }
    return [
      for (final group in groups.entries)
        SourceGroup(group.key, group.value.first.groupName, group.value),
    ];
  }
}

class CatalogCategory {
  const CatalogCategory(this.id, this.name, {this.local = false});
  static const all = CatalogCategory('', '全部');
  final String id;
  final String name;
  final bool local;
  factory CatalogCategory.fromJson(Map<String, dynamic> json) =>
      CatalogCategory(
        json['id'] as String? ?? '',
        json['name'] as String? ?? '全部',
      );
}

int intValue(Object? value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;

class Drama {
  const Drama({
    required this.id,
    required this.source,
    required this.title,
    this.sourceId = '',
    this.description = '',
    this.cover = '',
    this.episodes = 0,
    this.category = '',
    bool? vip,
    this.heat = '',
    this.views = '',
    this.onlineDate = '',
    this.tags = const [],
    this.releaseStatus = '',
  }) : vipStatus = vip;
  final String id;
  final String source;
  final String sourceId;
  final String title;
  final String description;
  final String cover;
  final int episodes;
  final String category;
  final bool? vipStatus;
  bool get vip => vipStatus == true;
  final String heat;
  final String views;
  final String onlineDate;
  final List<String> tags;
  final String releaseStatus;
  String get releaseLabel => switch (releaseStatus) {
    'finished' || 'completed' => '已完结',
    'ongoing' => '连载中',
    _ => '状态未知',
  };

  factory Drama.fromJson(Map<String, dynamic> json) => Drama(
    id: json['id'] as String? ?? '',
    source: json['source'] as String? ?? 'hongguo',
    sourceId: json['sourceId'] as String? ?? '',
    title: json['title'] as String? ?? '短剧',
    description: json['description'] as String? ?? '',
    cover: json['cover'] as String? ?? '',
    episodes: intValue(json['episodes']),
    category: json['category'] as String? ?? '',
    vip: json['vip'] == true
        ? true
        : json['vip'] == false &&
              (json['source'] != 'huangdou' ||
                  intValue(json['metadataSchema']) >= 1)
        ? false
        : null,
    heat: json['heat']?.toString() ?? '',
    views: json['views']?.toString() ?? '',
    onlineDate: json['onlineDate'] as String? ?? '',
    tags: (json['tags'] as List? ?? const []).whereType<String>().toList(),
    releaseStatus: json['releaseStatus'] as String? ?? '',
  );
  Map<String, dynamic> toJson() => {
    'metadataSchema': 1,
    'id': id,
    'source': source,
    'sourceId': sourceId,
    'title': title,
    'description': description,
    'cover': cover,
    'episodes': episodes,
    'category': category,
    'vip': vipStatus,
    'heat': heat,
    'views': views,
    'onlineDate': onlineDate,
    'tags': tags,
    'releaseStatus': releaseStatus,
  };

  Drama merge(Drama fresh) {
    if (id != fresh.id) return fresh;
    const genericCategories = {
      '短剧',
      '真人剧',
      '漫剧',
      'AI剧',
      'AI 剧',
      'AI短剧',
      'AI 短剧',
      'AI漫剧',
      'AI 漫剧',
    };
    return Drama(
      id: id,
      source: fresh.source.isEmpty ? source : fresh.source,
      sourceId: fresh.sourceId.isEmpty ? sourceId : fresh.sourceId,
      title: fresh.title.isEmpty || fresh.title == '短剧' ? title : fresh.title,
      description: fresh.description.isEmpty ? description : fresh.description,
      cover: fresh.cover.isEmpty ? cover : fresh.cover,
      episodes: fresh.episodes > 0 ? fresh.episodes : episodes,
      category:
          fresh.category.isEmpty ||
              genericCategories.contains(fresh.category) &&
                  category.isNotEmpty &&
                  !genericCategories.contains(category)
          ? category
          : fresh.category,
      vip: fresh.vipStatus ?? vipStatus,
      heat: fresh.heat.isEmpty ? heat : fresh.heat,
      views: fresh.views.isEmpty ? views : fresh.views,
      onlineDate: fresh.onlineDate.isEmpty ? onlineDate : fresh.onlineDate,
      tags: fresh.tags.isEmpty ? tags : fresh.tags,
      releaseStatus:
          fresh.releaseStatus.isEmpty || fresh.releaseStatus == 'unknown'
          ? releaseStatus
          : fresh.releaseStatus,
    );
  }
}

class Episode {
  Episode(this.raw, int fallback)
    : id = raw['id'] as String? ?? '',
      title = raw['title'] as String? ?? '第$fallback集',
      number = intValue(raw['currentEpisode']) > 0
          ? intValue(raw['currentEpisode'])
          : fallback,
      vip = raw['vip'] == true;
  final Map<String, dynamic> raw;
  final String id;
  final String title;
  final int number;
  final bool vip;
}

class DramaDetail {
  DramaDetail(this.drama, this.episodes, {this.warning = ''});
  final Drama drama;
  final List<Episode> episodes;
  final String warning;
  factory DramaDetail.fromJson(Map<String, dynamic> json) {
    final rows = json['chapters'] as List? ?? const [];
    return DramaDetail(
      Drama.fromJson(Map<String, dynamic>.from(json['drama'] as Map)),
      [
        for (var i = 0; i < rows.length; i++)
          Episode(Map<String, dynamic>.from(rows[i] as Map), i + 1),
      ],
      warning: json['warning'] as String? ?? '',
    );
  }
}

class CatalogPage {
  CatalogPage(
    this.items, {
    this.hasMore = false,
    this.warning = '',
    this.page = 1,
    this.fresh = false,
  });
  final List<Drama> items;
  final bool hasMore;
  final String warning;
  final int page;
  final bool fresh;
  factory CatalogPage.fromJson(Map<String, dynamic> json) => CatalogPage(
    [
      for (final row in json['items'] as List? ?? const [])
        Drama.fromJson(Map<String, dynamic>.from(row as Map)),
    ],
    hasMore: json['hasMore'] == true,
    warning: json['warning'] as String? ?? '',
    page: intValue(json['page']) > 0 ? intValue(json['page']) : 1,
    fresh: json['fresh'] == true,
  );
}

class PlaybackPlan {
  const PlaybackPlan({
    required this.url,
    this.headers = const {},
    this.decryptionKey = '',
    this.quality = 0,
    this.qualities = const [],
    this.session = '',
    this.danmakuId = '',
    this.prefetchedBytes = 0,
    this.expiresAt = 0,
    this.routeIndex = 0,
    this.routeCount = 1,
    this.local = false,
    this.segments = const [],
    this.keyUri = '',
    this.keyIv = '',
    this.source = '',
    this.sourceId = '',
  });
  final String url;

  /// 来源站源与分集标识。
  ///
  /// 弹幕、下载与离线播放都要按「哪一源的哪一集」定位，而 URL 本身
  /// 可能随时效或签名变化，不能反推。引擎产出的计划会带上这两项。
  final String source;
  final String sourceId;

  /// HLS 分片清单；非空表示可按分片下载。
  final List<String> segments;

  /// HLS AES-128 密钥地址。
  final String keyUri;

  /// HLS AES-128 的 IV。
  final String keyIv;
  final Map<String, String> headers;
  final String decryptionKey;
  final int quality;
  final List<int> qualities;
  final String session;
  final String danmakuId;
  final int prefetchedBytes;
  final int expiresAt;
  final int routeIndex;
  final int routeCount;
  final bool local;
  bool get hasAlternative => session.isNotEmpty && routeIndex + 1 < routeCount;
  factory PlaybackPlan.fromJson(Map<String, dynamic> json) => PlaybackPlan(
    url: json['url'] as String? ?? '',
    local: json['local'] == true,
    headers: (json['headers'] as Map? ?? {}).map(
      (key, value) => MapEntry(key.toString(), value.toString()),
    ),
    decryptionKey: json['decryptionKey'] as String? ?? '',
    quality: intValue(json['quality']),
    qualities: (json['qualities'] as List? ?? []).map(intValue).toSet().toList()
      ..sort((a, b) => b.compareTo(a)),
    session: json['session'] as String? ?? '',
    danmakuId: json['danmakuId'] as String? ?? '',
    prefetchedBytes: intValue(json['prefetchedBytes']),
    expiresAt: intValue(json['expiresAt']),
    routeIndex: intValue(json['routeIndex']),
    routeCount: intValue(json['routeCount']) > 0
        ? intValue(json['routeCount'])
        : 1,
    source: json['source'] as String? ?? '',
    sourceId: json['sourceId'] as String? ?? '',
  );
}

class WatchEntry {
  WatchEntry({
    required this.drama,
    required this.episode,
    required this.position,
    required this.duration,
    required this.updatedAt,
  });
  final Drama drama;
  final int episode;
  final double position;
  final double duration;
  final DateTime updatedAt;
  bool get finished => duration > 1 && position >= duration - 1;
  Map<String, dynamic> toJson() => {
    'drama': drama.toJson(),
    'episode': episode,
    'position': position,
    'duration': duration,
    'updatedAt': updatedAt.toIso8601String(),
  };
  factory WatchEntry.fromJson(Map<String, dynamic> json) => WatchEntry(
    drama: Drama.fromJson(Map<String, dynamic>.from(json['drama'] as Map)),
    episode: intValue(json['episode']),
    position: (json['position'] as num?)?.toDouble() ?? 0,
    duration: (json['duration'] as num?)?.toDouble() ?? 0,
    updatedAt:
        DateTime.tryParse(json['updatedAt'].toString()) ?? DateTime(2000),
  );
}

class DownloadJob {
  const DownloadJob({
    required this.id,
    required this.drama,
    required this.episode,
    required this.state,
    this.bytes = 0,
    this.total = 0,
    this.progress = 0,
    this.quality = 0,
    this.actualQuality = 0,
    this.error = '',
    this.created = 0,
    this.revision = 0,
    this.archived = false,
  });
  final int created;
  final int revision;
  final bool archived;
  final String id;
  final Drama drama;
  final Episode episode;
  final String state;
  final int bytes;
  final int total;
  final double progress;
  final int quality;
  final int actualQuality;
  final String error;
  bool get completed => state == 'completed';

  /// 「下载中」包括排队与执行：引擎把执行中状态叫 `running`
  /// （旧 Go 版叫 `downloading`，两个都认，避免历史数据丢状态）。
  bool get active =>
      state == 'queued' || state == 'downloading' || state == 'running';
  bool get resumable => state == 'paused' || state == 'failed';
  String get stateLabel => switch (state) {
    'queued' => '等待下载',
    'downloading' || 'running' => '正在下载',
    'paused' => '已暂停',
    'failed' => '下载失败',
    'completed' => '已下载',
    'removing' => '正在取消',
    _ => '等待更新',
  };
  factory DownloadJob.fromJson(Map<String, dynamic> value) => DownloadJob(
    id: value['id'] as String? ?? '',
    drama: Drama.fromJson(Map<String, dynamic>.from(value['drama'] as Map)),
    episode: Episode(
      Map<String, dynamic>.from(value['chapter'] as Map),
      intValue(value['index']),
    ),
    state: value['state'] as String? ?? 'failed',
    bytes: intValue(value['bytes']),
    total: intValue(value['total']),
    progress: ((value['progress'] as num?)?.toDouble() ?? 0).clamp(0, 1),
    quality: intValue(value['quality']),
    actualQuality: intValue(value['actualQuality']),
    error: value['error'] as String? ?? '',
    created: intValue(value['created']),
    revision: intValue(value['revision']),
    archived: value['archived'] == true,
  );
}

List<Map<String, dynamic>> readJsonList(String? value) {
  try {
    return (jsonDecode(value ?? '[]') as List)
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  } catch (_) {
    return [];
  }
}
