import 'package:flutter_test/flutter_test.dart';

import 'package:hoshi/domain/models.dart';
import 'package:hoshi/ui/features/discover/controllers/catalog_controller.dart';

/// 内容类型在 Dart 侧的落点有两处：`SourceSite`（域模型）与
/// `CatalogController` 的筛选逻辑。两者都是纯函数，不碰引擎与磁盘。
///
/// 这些用例守的是「类型来自引擎、文案来自编译期」和「源菜单顺序稳定」
/// 两条规矩——它们写错了都不会报错，只会悄悄显示错的东西。
void main() {
  tearDown(SourceSite.clearReported);

  group('SourceSite.reportFromEngine', () {
    test('类型取引擎上报，文案仍用编译期版本', () {
      SourceSite.reportFromEngine([
        (
          id: 'hongguo',
          name: '引擎里的名字',
          group: 'duanju',
          contentTypes: ['short-drama'],
        ),
      ]);

      final site = SourceSite.byId('hongguo');
      expect(site.contentTypes, ['short-drama']);
      expect(site.name, '红果', reason: '产品文案属于应用，不属于引擎');
      expect(site.hasType('short-drama'), isTrue);
      expect(site.hasType('movie'), isFalse);
    });

    test('未标注类型的源保持空表而不是猜一个', () {
      SourceSite.reportFromEngine([
        (id: 'unknown-plugin', name: '第三方源', group: 'movie', contentTypes: []),
      ]);

      final site = SourceSite.byId('unknown-plugin');
      expect(site.contentTypes, isEmpty);
      expect(site.hasType('short-drama'), isFalse);
      expect(site.name, '第三方源', reason: '引擎是唯一的名称来源');
    });

    test('已确认不可用的源不进入列表', () {
      SourceSite.reportFromEngine([
        (
          id: 'niuguo',
          name: '牛果',
          group: 'duanju',
          contentTypes: ['short-drama'],
        ),
      ]);
      expect(SourceSite.isAvailable('niuguo'), isFalse);
      expect(SourceSite.values, isEmpty);
    });
  });

  group('CatalogController.contentTypesOf', () {
    SourceSite site(String id, List<String> types) =>
        SourceSite(id, id, '', contentTypes: types);

    test('按宿主顺序排列，与上报顺序无关', () {
      final types = CatalogController.contentTypesOf([
        site('a', ['movie']),
        site('b', ['short-drama']),
        site('c', ['anime', 'movie']),
      ]);
      expect(types, ['short-drama', 'movie', 'anime']);
    });

    test('去重', () {
      final types = CatalogController.contentTypesOf([
        site('a', ['short-drama']),
        site('b', ['short-drama']),
      ]);
      expect(types, ['short-drama']);
    });

    test('未知类型排在已知类型之后而不是被丢弃', () {
      final types = CatalogController.contentTypesOf([
        site('a', ['podcast']),
        site('b', ['tv']),
      ]);
      expect(types, ['tv', 'podcast']);
    });

    test('没有任何标注时为空——源菜单不出现类型筛选行', () {
      expect(
        CatalogController.contentTypesOf([site('a', const []), site('b', const [])]),
        isEmpty,
      );
    });
  });

  group('CatalogController.sourcesOfType', () {
    final sites = [
      SourceSite('movie-a', 'A', '', contentTypes: const ['movie']),
      SourceSite('drama-a', 'B', '', contentTypes: const ['short-drama']),
      SourceSite('plain', 'C', ''),
    ];

    test('null 表示不限', () {
      expect(
        CatalogController.sourcesOfType(sites, null).map((site) => site.id),
        ['movie-a', 'drama-a', 'plain'],
      );
    });

    test('按类型过滤，未标注的源不出现', () {
      expect(
        CatalogController.sourcesOfType(sites, 'movie').map((site) => site.id),
        ['movie-a'],
      );
    });

    test('没有匹配的源时返回空表', () {
      expect(CatalogController.sourcesOfType(sites, 'anime'), isEmpty);
    });
  });
}
