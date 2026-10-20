import 'package:flutter/widgets.dart';

/// 路由参数的类型安全封装。
///
/// 每个页面用一个小类描述自己的路径参数，负责「从 URL 解析」与「拼回 URL」。
/// 这样深链、分享和返回栈都只依赖可序列化的字符串，不传对象。

/// 剧集标识：站源 + 站内 id。
///
/// 详情页与播放页都只需要它来重新取数，因此可以安全地放进 URL。
@immutable
class DramaRef {
  const DramaRef({required this.source, required this.sourceId});

  final String source;
  final String sourceId;

  /// 从 `source` 与 `sourceId` 两段路径参数构造，任一段为空即视为非法。
  static DramaRef? tryParse(String? source, String? sourceId) {
    final s = source?.trim() ?? '';
    final id = sourceId?.trim() ?? '';
    if (s.isEmpty || id.isEmpty) return null;
    return DramaRef(source: s, sourceId: id);
  }

  /// 从形如 `hongguo:12345` 的复合 id 解析；站源部分缺失时返回 null。
  static DramaRef? fromDramaId(String dramaId) {
    final index = dramaId.indexOf(':');
    if (index <= 0 || index == dramaId.length - 1) return null;
    return DramaRef(
      source: dramaId.substring(0, index),
      sourceId: dramaId.substring(index + 1),
    );
  }

  /// 复合 id，与 `Drama.id` 的格式一致。
  String get dramaId => '$source:$sourceId';

  /// 路径段，两段都做百分号编码以容纳任意站内 id。
  List<String> get segments => [source, sourceId];

  @override
  bool operator ==(Object other) =>
      other is DramaRef && other.source == source && other.sourceId == sourceId;

  @override
  int get hashCode => Object.hash(source, sourceId);

  @override
  String toString() => dramaId;
}

/// 本地媒体条目标识（下载完成的分集）。
@immutable
class MediaRef {
  const MediaRef({required this.dramaId, required this.episodeId});

  final String dramaId;
  final String episodeId;

  static MediaRef? tryParse(String? dramaId, String? episodeId) {
    final d = dramaId?.trim() ?? '';
    final e = episodeId?.trim() ?? '';
    if (d.isEmpty || e.isEmpty) return null;
    return MediaRef(dramaId: d, episodeId: e);
  }

  @override
  bool operator ==(Object other) =>
      other is MediaRef &&
      other.dramaId == dramaId &&
      other.episodeId == episodeId;

  @override
  int get hashCode => Object.hash(dramaId, episodeId);
}
