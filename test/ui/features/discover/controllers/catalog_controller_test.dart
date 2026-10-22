import 'package:duanju_app/data/local_store.dart';
import 'package:duanju_app/ui/features/discover/controllers/catalog_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../support/fixtures.dart';

/// 校验发现页在拆分后的浏览状态机。
///
/// 这里直接驱动 `CatalogController`，不经过任何 Widget：
/// 分类切换、搜索、推荐位、VIP 过滤与分页闸门都应该是纯状态转换。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<LocalStore> createStore() async {
    SharedPreferences.setMockInitialValues({});
    return LocalStore(await SharedPreferences.getInstance());
  }

  group('CatalogController', () {
    test('初始分类为空，且「全部」始终是首个分类', () async {
      final store = await createStore();
      final controller = CatalogController(
        repository: FixtureRepository(),
        store: store,
      );
      expect(controller.category, '');
      final ids = controller.displayCategories.map((entry) => entry.id);
      expect(ids.first, '');
      controller.dispose();
      store.dispose();
    });

    test('推荐位用保留 id 表示，且不写回站源分类', () async {
      final store = await createStore();
      final controller = CatalogController(
        repository: FixtureRepository(),
        store: store,
      );
      controller.changeCategory(CatalogController.recommendationCategory);
      expect(controller.showRecommendations, isTrue);
      expect(
        controller.displayCategory,
        CatalogController.recommendationCategory,
      );
      // 退出推荐后应回到真实分类（此处为「全部」）。
      controller.changeCategory('');
      expect(controller.showRecommendations, isFalse);
      expect(controller.category, '');
      controller.dispose();
      store.dispose();
    });

    test('本地筛选按名称匹配，不受排序影响', () async {
      final store = await createStore();
      final controller = CatalogController(
        repository: FixtureRepository(),
        store: store,
      );
      await controller.load();
      expect(controller.items, isNotEmpty, reason: '夹具应返回条目');
      controller.searchChanged('测试');
      final titles = controller.visibleItems.map((drama) => drama.title);
      expect(titles, contains('测试短剧'));
      controller.dispose();
      store.dispose();
    });

    test('无站源时 markIdle 结束加载态', () async {
      final store = await createStore();
      final controller = CatalogController(
        repository: FixtureRepository(),
        store: store,
      );
      expect(controller.loading, isTrue, reason: '初始应为加载中');
      controller.markIdle();
      expect(controller.loading, isFalse);
      controller.dispose();
      store.dispose();
    });

    test('切换分组会清空列表并请求滚动复位', () async {
      final store = await createStore();
      final controller = CatalogController(
        repository: FixtureRepository(),
        store: store,
      );
      final groups = controller.sourceGroups;
      if (groups.length > 1) {
        controller.changeGroup(groups.last);
        expect(controller.items, isEmpty);
        expect(controller.consumeScrollReset(), isTrue);
        // 复位标志只消费一次。
        expect(controller.consumeScrollReset(), isFalse);
      }
      controller.dispose();
      store.dispose();
    });
  });
}
