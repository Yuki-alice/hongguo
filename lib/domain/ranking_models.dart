import 'package:hoshi/domain/models.dart';

class RankingBoard {
  const RankingBoard({
    required this.id,
    required this.source,
    required this.name,
    this.description = '',
  });
  final String id;
  final String source;
  final String name;
  final String description;
  String get groupId => SourceSite.byId(source).groupId;
  static String sourceForID(String id) => switch (id) {
    'hongguo-hot' ||
    'hongguo-real' ||
    'hongguo-comic' ||
    'hongguo-ai' => 'hongguo',
    'huangdou-all' ||
    'huangdou-mogai' ||
    'huangdou-search' ||
    'huangdou-favorite' ||
    'huangdou-finish' => 'huangdou',
    'huangguo-hot' ||
    'huangguo-recommend' ||
    'huangguo-potential' => 'huangguoai',
    'huangju-hot' || 'huangju-new' => 'huangju',
    'yeguo-recommend' => 'yeguo',
    'dsd-catalog' => 'dsd',
    _ => '',
  };
  factory RankingBoard.fromJson(Map<String, dynamic> json) => RankingBoard(
    id: json['id'] as String? ?? '',
    source:
        json['source'] as String? ?? sourceForID(json['id'] as String? ?? ''),
    name: json['name'] as String? ?? '',
    description: json['description'] as String? ?? '',
  );
}

class RankingItem {
  const RankingItem(this.rank, this.drama, {this.metric = ''});
  final int rank;
  final Drama drama;
  final String metric;
  factory RankingItem.fromJson(Map<String, dynamic> json) => RankingItem(
    intValue(json['rank']),
    Drama.fromJson(Map<String, dynamic>.from(json['drama'] as Map)),
    metric: json['metric'] as String? ?? '',
  );
}

class RankingPage {
  const RankingPage({
    required this.items,
    this.page = 1,
    this.hasMore = false,
    this.warning = '',
    this.updatedText = '',
    this.stale = false,
  });
  final List<RankingItem> items;
  final int page;
  final bool hasMore;
  final String warning;
  final String updatedText;
  final bool stale;
  factory RankingPage.fromJson(Map<String, dynamic> json) => RankingPage(
    items: [
      for (final row in json['items'] as List? ?? [])
        RankingItem.fromJson(Map<String, dynamic>.from(row as Map)),
    ],
    page: intValue(json['page']),
    hasMore: json['hasMore'] == true,
    warning: json['warning'] as String? ?? '',
    updatedText: json['updatedText'] as String? ?? '',
    stale: json['stale'] == true,
  );
}

/// 推荐流的一页。`offset` 与 `sessionId` 必须原样回传给下一次请求，
/// 否则站点会退化成「首屏」而不是继续翻页。
class RecommendPage {
  const RecommendPage({
    required this.items,
    this.offset = 0,
    this.sessionId = '',
    this.hasMore = false,
  });
  final List<Drama> items;
  final int offset;
  final String sessionId;
  final bool hasMore;
}

/// 一条弹幕。
class DomainDanmaku {
  const DomainDanmaku({
    required this.timeMs,
    required this.text,
    this.color = '',
  });
  final int timeMs;
  final String text;
  final String color;
}

/// 同一部剧的一季。
class SeriesSeason {
  const SeriesSeason({
    required this.season,
    required this.title,
    required this.sourceId,
  });
  final int season;
  final String title;
  final String sourceId;
}
