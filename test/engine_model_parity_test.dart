import 'package:duanju_app/models.dart';
import 'package:duanju_app/src/rust/api.dart';
import 'package:duanju_app/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// 结构对拍：Rust 引擎产出的数据必须能被现有 Dart 模型无损解析。
///
/// 这是「替换 Go 核心」的关键约束——UI 层不应感知后端换成了 Rust。
void main() {
  setUpAll(() async {
    await RustLib.init();
  });

  test('engine DramaItem maps onto the existing Dart Drama model', () async {
    final page = await fetchCatalog(sourceId: 'wuguo', page: 1, category: '1');
    expect(page.items, isNotEmpty);

    for (final item in page.items.take(5)) {
      final drama = Drama(
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

      // 往返一次 JSON，确认字段名与 Dart 模型完全一致。
      final roundTripped = Drama.fromJson(drama.toJson());
      expect(roundTripped.id, item.id);
      expect(roundTripped.source, item.source);
      expect(roundTripped.sourceId, item.sourceId);
      expect(roundTripped.title, item.title);
      expect(roundTripped.cover, item.cover);
      expect(roundTripped.episodes, item.episodes);
      expect(roundTripped.category, item.category);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('engine identity format matches Go convention', () async {
    final page = await fetchCatalog(sourceId: 'wuguo', page: 1, category: '1');
    for (final item in page.items.take(10)) {
      // Go 与 Dart 都按 `<source>:<sourceId>` 约定生成 ID。
      expect(item.id, '${item.source}:${item.sourceId}');
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('chapter maps onto existing Dart Episode model', () async {
    final page = await fetchCatalog(sourceId: 'maoguo', page: 1, category: '0');
    final target = page.items.first;
    final detail = await fetchDetail(
      sourceId: 'maoguo',
      dramaSourceId: target.sourceId,
    );

    for (final chapter in detail.chapters.take(5)) {
      expect(chapter.id, isNotEmpty);
      expect(chapter.title, isNotEmpty);
      // Go 侧分集链接要么是直链，要么是待解析的页面地址。
      expect(
        chapter.videoUrl.isNotEmpty || chapter.pageUrl.isNotEmpty,
        isTrue,
        reason: 'chapter ${chapter.id} has neither videoUrl nor pageUrl',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
