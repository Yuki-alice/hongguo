import 'dart:async';

import 'package:flutter/material.dart';

import 'package:hoshi/data/app_contract.dart';
import 'package:hoshi/data/catalog_browser.dart';
import 'package:hoshi/domain/catalog_sort.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/ui/core/app_l10n.dart';

/// 发现页的浏览状态与取数逻辑。
///
/// 职责边界：
/// - 持有可变浏览状态（站源、分类、条目、加载与错误标志）；
/// - 驱动 `CatalogBrowser` 取数与取消；
/// - 对外暴露只读快照与查询方法，供 View 渲染。
///
/// 不构造任何 Widget、不弹对话框、不导航，因此不依赖 `BuildContext`，
/// 可直接用假仓库做单元测试。
class CatalogController extends ChangeNotifier {
  CatalogController({
    required AppRepository repository,
    required LocalStore store,
  }) : _repository = repository,
       _store = store {
    _source = SourceSite.byId(store.source);
    _allSources = store.catalogView.allSources;
    _browser = CatalogBrowser(repository);
  }

  /// “推荐”分类的保留 id，与真实站源分类区分。
  static const recommendationCategory = 'app:recommendations';

  final AppRepository _repository;
  final LocalStore _store;
  late final CatalogBrowser _browser;

  late SourceSite _source;
  bool _allSources = false;
  List<Drama> _items = const [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;
  int _generation = 0;
  String _submittedQuery = '';
  final _categorySelections = <String, String>{};
  bool _searchVisible = false;
  bool _categoriesLoading = false;
  String? _categoriesError;
  int _categoryGeneration = 0;
  bool _showRecommendations = false;
  String _searchQuery = '';
  bool _disposed = false;
  Timer? _debounce;
  bool _scrollReset = false;

  AppRepository get repository => _repository;
  LocalStore get store => _store;
  SourceSite get source => _source;
  bool get allSources => _allSources;
  List<Drama> get items => _items;
  bool get loading => _loading;
  bool get loadingMore => _loadingMore;
  bool get hasMore => _hasMore;
  String? get error => _error;
  bool get searchVisible => _searchVisible;
  bool get categoriesLoading => _categoriesLoading;
  String? get categoriesError => _categoriesError;
  bool get showRecommendations => _showRecommendations;
  String get searchQuery => _searchQuery;
  bool get isDisposed => _disposed;

  /// View 消费后复位的一次性“回到顶部”请求。
  bool consumeScrollReset() {
    if (!_scrollReset) return false;
    _scrollReset = false;
    return true;
  }

  List<SourceGroup> get sourceGroups {
    final groups = SourceGroup.fromSources(_store.sources);
    return [
      if (groups.length > 1)
        SourceGroup('all', AppL10n.current.allSources, _store.sources),
      ...groups,
    ];
  }

  SourceGroup get group =>
      sourceGroups
          .where((group) => group.id == (_allSources ? 'all' : _source.groupId))
          .firstOrNull ??
      SourceGroup(_source.groupId, _source.groupName, [_source]);

  bool get onlineSearch => group.sources.any((source) => source.onlineSearch);
  bool get searchSuggestions =>
      group.sources.any((source) => source.searchSuggestions);

  String get searchHint {
    final online = group.sources
        .where((source) => source.onlineSearch)
        .toList();
    if (online.isEmpty) return AppL10n.current.filterUpdatedLibrary;
    final names = online.map((source) => source.name).join('、');
    return online.length == group.sources.length
        ? AppL10n.current.searchSources(names)
        : AppL10n.current.searchSourcesLocal(names);
  }

  String get category => _categorySelections[group.id] ?? '';
  List<CatalogCategory> get categories => _browser.categories(group);
  String get displayCategory =>
      _showRecommendations ? recommendationCategory : category;

  List<CatalogCategory> get displayCategories => [
    CatalogCategory.all,
    if (group.id == 'hongguo')
      CatalogCategory(recommendationCategory, AppL10n.current.recommendations),
    ...categories.where((entry) => entry.id.isNotEmpty),
  ];

  /// 是否有任何条目带 VIP 标记。
  ///
  /// 以前这里写死 `source.id == 'huangdou'`，黄豆下线后该分支永远为假，
  /// VIP 过滤控件就再也不会出现。改成看数据本身：只要当前源返回的条目里
  /// 有 VIP 标记，这个开关就有意义。
  bool get supportsVipFilter => _items.any((drama) => drama.vip);
  bool get hideVip => supportsVipFilter && _store.hideVip;

  /// 当前应渲染的条目：按权限、分类、VIP 与本地筛选收窄后排序。
  List<Drama> get visibleItems {
    final query = _searchQuery.trim().toLowerCase();
    return sortCatalog(
      _items.where((drama) {
        if (!_store.allowsSource(drama.source)) return false;
        if (category.startsWith('local:') &&
            categoryName(drama.category) != category.substring(6)) {
          return false;
        }
        if (hideVip && drama.vip) return false;
        return onlineSearch || query.isEmpty || matchesDramaQuery(drama, query);
      }),
      _store.catalogView,
    );
  }

  /// 是否允许继续加载下一页，供“加载更多”按钮判断可用性。
  bool get canLoadMore =>
      _hasMore &&
      !_loadingMore &&
      (!onlineSearch ||
          _searchQuery.isEmpty ||
          group.sources.any((source) => source.pagedSearch));

  Future<void> loadCategories({
    bool force = false,
    bool cacheOnly = false,
  }) async {
    final generation = ++_categoryGeneration;
    final current = group;
    _categoriesLoading = true;
    _categoriesError = null;
    notifyListeners();
    String? error;
    try {
      error = await _browser.loadCategories(
        current,
        force: force,
        cacheOnly: cacheOnly,
      );
    } catch (failure) {
      error = failure.toString();
    }
    if (_disposed || generation != _categoryGeneration) return;
    _categoriesLoading = false;
    _categoriesError = error;
    notifyListeners();
  }

  /// 没有可用站源时直接结束加载态，避免界面停在转圈。
  void markIdle() {
    _loading = false;
    _loadingMore = false;
    notifyListeners();
  }

  /// 取目录。`more` 追加下一页，`useCache` 允许先返回磁盘缓存。
  Future<void> load({
    bool more = false,
    bool useCache = false,
    bool force = false,
    bool cacheOnly = false,
  }) async {
    if (_showRecommendations) return;
    if (more && (_loading || _loadingMore || !_hasMore)) return;
    final generation = ++_generation;
    final current = group;
    final query = onlineSearch ? _searchQuery.trim() : '';
    _error = null;
    if (query.isNotEmpty) _categorySelections[current.id] = '';
    if (more) {
      _loadingMore = true;
    } else {
      _loading = true;
      _loadingMore = false;
      if (query != _submittedQuery) _items = const [];
    }
    notifyListeners();

    void accept(CatalogPage result, {bool cached = false}) {
      if (_disposed || generation != _generation) return;
      _items = result.items;
      _hasMore = result.hasMore;
      _submittedQuery = query;
      _loading = cached && !result.fresh;
      _loadingMore = false;
      _error = result.warning.isEmpty ? null : result.warning;
      notifyListeners();
    }

    try {
      final result = await _browser.load(
        current,
        category: category,
        query: query,
        more: more,
        useCache: useCache,
        force: force,
        cacheOnly: cacheOnly,
        onCached: (result) => accept(result, cached: true),
      );
      accept(result);
    } catch (failure) {
      if (_disposed || generation != _generation) return;
      _loading = false;
      _loadingMore = false;
      _error = failure.toString();
      notifyListeners();
    }
  }

  /// 站源更新后把磁盘上的新条目并入当前列表，按 id 去重后保留现有顺序。
  void mergeItems(Iterable<Drama> incoming) {
    final index = {for (final item in _items) item.id: item};
    for (final drama in incoming) {
      index[drama.id] = index.containsKey(drama.id)
          ? index[drama.id]!.merge(drama)
          : drama;
    }
    _items = index.values.toList();
    notifyListeners();
  }

  /// 目录资料更新时就地合并，避免整页重取。
  void mergeDrama(Drama drama) {
    _browser.updateDrama(drama);
    _items = [
      for (final item in _items) item.id == drama.id ? item.merge(drama) : item,
    ];
    notifyListeners();
  }

  void changeGroup(SourceGroup value) {
    if (value.id == group.id) return;
    final target = value.sources.firstOrNull;
    if (target == null) return;
    _changeSource(target, allSources: value.id == 'all');
  }

  void _changeSource(SourceSite value, {bool allSources = false}) {
    if (_source.id == value.id && _allSources == allSources) return;
    _debounce?.cancel();
    _cancelTranscripts();
    _showRecommendations = false;
    _source = value;
    _allSources = allSources;
    _items = const [];
    _hasMore = true;
    _submittedQuery = '';
    _error = null;
    _searchQuery = '';
    _scrollReset = true;
    notifyListeners();
    unawaited(load(useCache: true));
    unawaited(loadCategories());
  }

  void changeCategory(String value) {
    if (value == recommendationCategory) {
      if (_showRecommendations) return;
      _cancelTranscripts();
      _showRecommendations = true;
      _searchQuery = '';
      _searchVisible = false;
      _submittedQuery = '';
      notifyListeners();
      return;
    }
    if (category == value && !_showRecommendations) return;
    _debounce?.cancel();
    _showRecommendations = false;
    _categorySelections[group.id] = value;
    if (onlineSearch) {
      _searchQuery = '';
      _submittedQuery = '';
    }
    _items = const [];
    _hasMore = true;
    _error = null;
    _scrollReset = true;
    notifyListeners();
    unawaited(load(useCache: true));
  }

  void swipeCategory(int direction) {
    final categories = displayCategories;
    final index = categories.indexWhere((entry) => entry.id == displayCategory);
    final next = index + direction;
    if (next >= 0 && next < categories.length) {
      changeCategory(categories[next].id);
    }
  }

  void toggleSearch() {
    if (_showRecommendations) changeCategory('');
    final hadQuery = _searchQuery.isNotEmpty;
    _searchVisible = !_searchVisible;
    if (!_searchVisible) _searchQuery = '';
    notifyListeners();
    if (!_searchVisible && hadQuery) unawaited(load());
  }

  void submitSearch(String query) {
    if (_showRecommendations) {
      _showRecommendations = false;
      _categorySelections[group.id] = '';
    }
    _searchQuery = query.trim();
    _debounce?.cancel();
    if (onlineSearch) {
      unawaited(load());
    } else {
      notifyListeners();
    }
  }

  /// 输入变化：在线搜索时取消在途请求并 300 毫秒防抖后重载。
  void searchChanged(String query) {
    _debounce?.cancel();
    _searchQuery = query;
    if (onlineSearch && (_loading || _loadingMore)) {
      _generation++;
      unawaited(_browser.cancel());
      _loading = false;
      _loadingMore = false;
    }
    notifyListeners();
    if (onlineSearch && query.trim().isEmpty) {
      _debounce = Timer(const Duration(milliseconds: 300), () {
        if (!_disposed) unawaited(load());
      });
    }
  }

  /// 离开页面或打开其它路由时停止在途取数。
  void pause() {
    _debounce?.cancel();
    _generation++;
    unawaited(_browser.cancel());
    _loading = false;
    _loadingMore = false;
    notifyListeners();
  }

  /// 取消防抖并清空搜索词（切换站源或分类时使用）。
  void _cancelTranscripts() {
    _debounce?.cancel();
    _searchQuery = '';
  }

  Future<void> cancel() => _browser.cancel();

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _generation++;
    _categoryGeneration++;
    unawaited(_browser.cancel());
    super.dispose();
  }
}
