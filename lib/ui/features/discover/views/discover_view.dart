import 'package:flutter/material.dart';

import '../../../../app_bottom_navigation.dart';
import '../../../../app_layout.dart';
import '../../../../catalog_filters.dart';
import '../../../../catalog_sort.dart';
import '../../../../drama_actions.dart';
import '../../../../downloads_screen.dart';
import '../../../../local_store.dart';
import '../../../../models.dart';
import '../../../../recommendations_screen.dart';
import '../../../../remote_widgets.dart';
import '../../../../saved_library.dart';
import '../../../../vip_icon.dart';
import '../../../../widgets.dart';
import '../../../theme/md3_tokens.dart';
import '../controllers/catalog_controller.dart';
import '../widgets/catalog_search_header.dart';
import '../widgets/catalog_selection_bar.dart';

/// 发现页骨架：应用栏 + 导航 + 内容区。
///
/// 只做布局与装配。状态来自 [CatalogController] 与 [LocalStore]，
/// 导航、对话框、下载等副作用一律通过回调交给 `HomeScreen`。
class DiscoverView extends StatefulWidget {
  const DiscoverView({
    super.key,
    required this.controller,
    required this.store,
    required this.searchController,
    required this.scrollController,
    required this.tabIndex,
    required this.selectionMode,
    required this.selectedDramas,
    required this.maxSelection,
    required this.appBarFocus,
    required this.selectionFocus,
    required this.filtersKey,
    required this.gridKey,
    required this.navKey,
    required this.onChangeTab,
    required this.onCancelSelection,
    required this.onClearSelection,
    required this.onEnterSelectionMode,
    required this.onOpenDrama,
    required this.onDramaActions,
    required this.onSelectDrama,
    required this.onConfirmSelection,
    required this.onToggleSearch,
    required this.onSearchChanged,
    required this.onSubmitSearch,
    required this.onChangeGroup,
    required this.onChangeCategory,
    required this.onSwipeCategory,
    required this.onRefreshCatalog,
    required this.onLoadMore,
    required this.onRetryCatalog,
    required this.onManageSources,
    required this.onOpenRankings,
    required this.onChooseCatalogView,
    required this.onClearRecentSearches,
    required this.onToggleVip,
    required this.onMoreMenu,
    required this.onCancelSuggestions,
    required this.onOpenLanSync,
    required this.updatesBusy,
    this.cacheReadError,
  });

  final CatalogController controller;
  final LocalStore store;
  final TextEditingController searchController;
  final ScrollController scrollController;
  final int tabIndex;
  final bool selectionMode;
  final Map<String, Drama> selectedDramas;
  final int maxSelection;
  final FocusNode appBarFocus;
  final FocusNode selectionFocus;
  final GlobalKey<RemoteRowState> filtersKey;
  final GlobalKey<RemoteGridState> gridKey;
  final GlobalKey<RemoteListState> navKey;

  final ValueChanged<int> onChangeTab;
  final VoidCallback onCancelSelection;
  final VoidCallback onClearSelection;
  final VoidCallback onEnterSelectionMode;
  final void Function(Drama drama, {bool resume, bool download}) onOpenDrama;
  final ValueChanged<Drama> onDramaActions;
  final ValueChanged<Drama> onSelectDrama;
  final VoidCallback onConfirmSelection;
  final VoidCallback onToggleSearch;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<String> onSubmitSearch;
  final ValueChanged<SourceGroup> onChangeGroup;
  final ValueChanged<String> onChangeCategory;
  final ValueChanged<int> onSwipeCategory;
  final Future<void> Function() onRefreshCatalog;
  final VoidCallback onLoadMore;
  final VoidCallback onRetryCatalog;
  final VoidCallback onManageSources;
  final VoidCallback onOpenRankings;
  final VoidCallback onChooseCatalogView;
  final VoidCallback onClearRecentSearches;
  final VoidCallback onToggleVip;
  final ValueChanged<String> onMoreMenu;
  final VoidCallback onCancelSuggestions;
  final VoidCallback onOpenLanSync;
  final bool updatesBusy;

  /// 缓存回读失败时的提示，非空时覆盖目录自身错误。
  final String? cacheReadError;

  @override
  State<DiscoverView> createState() => _DiscoverViewState();
}

class _DiscoverViewState extends State<DiscoverView> {
  CatalogController get controller => widget.controller;
  LocalStore get store => widget.store;

  List<(int, IconData, IconData, String)> get _destinations => [
    (0, Icons.explore_outlined, Icons.explore_rounded, '发现'),
    (1, Icons.bookmark_border_rounded, Icons.bookmark_rounded, '追剧'),
    (2, Icons.history_outlined, Icons.history_rounded, '最近观看'),
    if (store.canDownload)
      (3, Icons.download_outlined, Icons.download_rounded, '下载'),
  ];

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final television = AppLayout.isTelevision(context);
      final width = constraints.maxWidth;
      final desktop = Md3WindowClass.usesRail(width);
      return Scaffold(
        appBar: _appBar(context, width, television),
        body: Row(
          children: [
            if (television) ...[
              _televisionNavigation(),
              const VerticalDivider(width: 1),
            ] else if (desktop) ...[
              _rail(context),
              const VerticalDivider(width: 1, thickness: 1),
            ],
            Expanded(child: _body(desktop, television)),
          ],
        ),
        bottomNavigationBar: desktop || television
            ? null
            : widget.selectionMode
            ? _selectionBar()
            : AppBottomNavigation(
                selectedIndex: widget.tabIndex,
                onDestinationSelected: widget.onChangeTab,
                destinations: [
                  for (final entry in _destinations)
                    NavigationDestination(
                      icon: Icon(entry.$2),
                      selectedIcon: Icon(entry.$3),
                      label: entry.$4,
                    ),
                ],
              ),
      );
    },
  );

  Widget _rail(BuildContext context) => NavigationRail(
    selectedIndex: widget.tabIndex,
    onDestinationSelected: widget.onChangeTab,
    groupAlignment: -.8,
    leading: Padding(
      padding: const EdgeInsets.only(top: Md3Spacing.sm),
      child: Icon(
        Icons.play_circle_fill_rounded,
        color: Theme.of(context).colorScheme.primary,
        size: 32,
      ),
    ),
    destinations: [
      for (final entry in _destinations)
        NavigationRailDestination(
          icon: Icon(entry.$2),
          selectedIcon: Icon(entry.$3),
          label: Text(entry.$4),
        ),
    ],
  );

  Widget _televisionNavigation() => SizedBox(
    width: 132,
    child: RemoteList(
      key: widget.navKey,
      itemKeys: [for (final entry in _destinations) '${entry.$1}'],
      itemExtent: 60,
      spacing: 14,
      padding: EdgeInsets.zero,
      autofocus: true,
      onExitRight: widget.tabIndex == 0
          ? () => widget.gridKey.currentState?.focusCurrent()
          : null,
      itemBuilder: (_, index, node, onFocus) {
        final entry = _destinations[index];
        return RemoteButton(
          key: ValueKey('tv-nav-${entry.$1}'),
          label: entry.$4,
          icon: entry.$2,
          selected: widget.tabIndex == entry.$1,
          focusNode: node,
          onFocus: onFocus,
          onPressed: () => widget.onChangeTab(entry.$1),
        );
      },
    ),
  );

  Widget _body(bool desktop, bool television) {
    if (widget.tabIndex == 0) {
      if (store.sources.isEmpty) {
        return const StatusPanel(title: '暂无可用站源', message: '请联系管理员为当前用户开放站源。');
      }
      return _catalog(selectionInBody: desktop || television);
    }
    if (widget.tabIndex == 3) {
      return DownloadsScreen(
        repository: controller.repository,
        store: store,
        embedded: true,
      );
    }
    return SavedLibrary(
      key: ValueKey('saved-tab-${widget.tabIndex}'),
      repository: controller.repository,
      store: store,
      history: widget.tabIndex == 2,
      remoteAutofocus: television,
      onExitLeft: television
          ? () => widget.navKey.currentState?.focusCurrent()
          : null,
      onOpen: (drama) => widget.onOpenDrama(drama),
      onContinue: (drama) => widget.onOpenDrama(drama, resume: true),
      onDownload: controller.repository.supportsDownloads && store.canDownload
          ? (drama) => widget.onOpenDrama(drama, download: true)
          : null,
    );
  }

  Widget _catalog({required bool selectionInBody}) {
    final items = controller.visibleItems;
    final television = AppLayout.isTelevision(context);
    return Column(
      children: [
        if (controller.searchVisible && !television)
          CatalogSearchHeader(
            groupId: controller.group.id,
            controller: widget.searchController,
            hint: controller.searchHint,
            recentSearches: store.recentSearches,
            suggestions: controller.searchSuggestions
                ? controller.repository.suggestions
                : null,
            onChanged: widget.onSearchChanged,
            onSearch: widget.onSubmitSearch,
            onClearRecent: widget.onClearRecentSearches,
            onCancelSuggestions: widget.onCancelSuggestions,
          ),
        CatalogFilters(
          key: ValueKey('filters-${controller.group.id}'),
          categories: controller.displayCategories,
          category: controller.displayCategory,
          error: controller.categoriesError,
          remoteKey: widget.filtersKey,
          onExitUp: television && widget.selectionMode
              ? () => widget.appBarFocus.requestFocus()
              : null,
          onExitDown: television
              ? () => widget.gridKey.currentState?.focusCurrent()
              : null,
          onCategory: widget.onChangeCategory,
          onRetry: widget.onRetryCatalog,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (controller.supportsVipFilter)
                IconButton(
                  tooltip: store.hideVip ? 'VIP：隐藏' : 'VIP：显示',
                  onPressed: widget.onToggleVip,
                  icon: VipIcon(hidden: store.hideVip),
                ),
            ],
          ),
        ),
        if (controller.showRecommendations)
          Expanded(
            child: GestureDetector(
              onHorizontalDragEnd: television
                  ? null
                  : (details) => widget.onSwipeCategory(
                      (details.primaryVelocity ?? 0) < 0 ? 1 : -1,
                    ),
              child: RecommendationsScreen(
                repository: controller.repository,
                store: store,
                embedded: true,
                gridKey: widget.gridKey,
                onExitLeft: television
                    ? () => widget.navKey.currentState?.focusCurrent()
                    : null,
              ),
            ),
          )
        else ...[
          if (controller.loading && controller.items.isNotEmpty)
            const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: GestureDetector(
              onHorizontalDragEnd: television
                  ? null
                  : (details) {
                      final velocity = details.primaryVelocity ?? 0;
                      if (velocity.abs() < 240) return;
                      widget.onSwipeCategory(velocity < 0 ? 1 : -1);
                    },
              child: _catalogBody(items, television),
            ),
          ),
          if (widget.selectionMode && selectionInBody)
            _selectionBar(safeBottom: false),
        ],
      ],
    );
  }

  Widget _catalogBody(List<Drama> items, bool television) {
    if (controller.loading && controller.items.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: Md3Spacing.lg),
            Text('正在加载剧集'),
          ],
        ),
      );
    }
    if (controller.items.isEmpty && controller.error != null) {
      return StatusPanel(
        title: '暂时无法加载',
        message: controller.error!,
        onRetry: widget.onRetryCatalog,
        secondaryAction: controller.repository.supportsSourceManagement
            ? TextButton(
                onPressed: widget.onManageSources,
                child: const Text('站源诊断'),
              )
            : null,
        icon: Icons.wifi_off_rounded,
      );
    }
    if (items.isEmpty) {
      return StatusPanel(
        title: '没有找到匹配的短剧',
        message: controller.hideVip
            ? '可以换个搜索词，或显示 VIP 内容。'
            : store.sources.length > 1
            ? '可以换个搜索词或切换站源。'
            : '可以换个搜索词，或刷新后重试。',
        onRetry: controller.canLoadMore ? widget.onLoadMore : null,
        action: '加载更多',
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        if (television) {
          return _televisionGrid(
            items,
            constraints.maxWidth,
            controller: widget.scrollController,
            footer: Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, Md3Spacing.xl),
              child: Center(
                child: controller.loadingMore
                    ? const CircularProgressIndicator()
                    : controller.hasMore
                    ? RemoteButton(
                        label: '加载更多',
                        icon: Icons.expand_more,
                        onPressed: widget.onLoadMore,
                      )
                    : const Text('已经看到这里的全部剧集'),
              ),
            ),
          );
        }
        final padding = constraints.maxWidth < 600
            ? Md3Spacing.lg
            : Md3Spacing.xl;
        return RefreshIndicator(
          onRefresh: widget.onRefreshCatalog,
          child: CustomScrollView(
            controller: widget.scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  padding,
                  0,
                  padding,
                  Md3Spacing.lg,
                ),
                sliver: SliverGrid(
                  gridDelegate: dramaGridDelegate(
                    context,
                    constraints.maxWidth - 2 * padding,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (_, index) => _tile(items[index]),
                    childCount: items.length,
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: Md3Spacing.xl),
                  child: Center(
                    child: controller.loadingMore
                        ? const CircularProgressIndicator()
                        : controller.hasMore
                        ? OutlinedButton.icon(
                            onPressed: widget.onLoadMore,
                            icon: const Icon(Icons.expand_more_rounded),
                            label: const Text('加载更多'),
                          )
                        : Text(
                            '已经看到这里的全部剧集',
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _tile(Drama drama, {FocusNode? focusNode, VoidCallback? onFocus}) {
    final following = store.following(drama.id);
    final canSelect =
        store.canDownload && controller.repository.supportsDownloads;
    return DramaTile(
      key: ValueKey(drama.id),
      drama: drama,
      repository: controller.repository,
      focusNode: focusNode,
      onFocus: onFocus,
      onTap: () => widget.selectionMode
          ? widget.onSelectDrama(drama)
          : widget.onOpenDrama(drama),
      onLongPress: canSelect ? () => widget.onSelectDrama(drama) : null,
      onMore: () => widget.onDramaActions(drama),
      actions: DramaActionButton(
        drama: drama,
        onPressed: () => widget.onDramaActions(drama),
      ),
      selected: widget.selectionMode
          ? widget.selectedDramas.containsKey(drama.id)
          : null,
      badge: following == null
          ? null
          : '${following.status.label}${following.hasUpdates ? ' · ${following.updateLabel}' : ''}',
    );
  }

  Widget _selectionBar({bool safeBottom = true}) => CatalogSelectionBar(
    count: widget.selectedDramas.length,
    maxCount: widget.maxSelection,
    confirmFocusNode: widget.selectionFocus,
    onConfirm: widget.onConfirmSelection,
    safeBottom: safeBottom,
  );

  Widget _televisionGrid(
    List<Drama> items,
    double width, {
    ScrollController? controller,
    Widget? footer,
  }) {
    final columns = ((width - 36) / 150).floor().clamp(1, 8);
    final tileWidth = (width - 36 - (columns - 1) * 14) / columns;
    return RemoteGrid(
      key: widget.gridKey,
      itemKeys: items.map((item) => item.id).toList(),
      columns: columns,
      itemExtent: DramaTile.extentFor(context, tileWidth - 14) + 14,
      controller: controller,
      footer: footer,
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 18),
      onExitUp: () => widget.filtersKey.currentState?.focusCurrent(),
      onExitLeft: () => widget.navKey.currentState?.focusCurrent(),
      onExitDown: widget.selectionMode
          ? () => widget.selectionFocus.requestFocus()
          : null,
      itemBuilder: (_, index, node, onFocus) =>
          _tile(items[index], focusNode: node, onFocus: onFocus),
    );
  }

  AppBar _appBar(BuildContext context, double width, bool television) {
    final colors = Theme.of(context).colorScheme;
    return AppBar(
      toolbarHeight: television ? 64 : null,
      titleSpacing: Md3Spacing.md,
      title: widget.selectionMode
          ? const Text('选择短剧', maxLines: 1, overflow: TextOverflow.ellipsis)
          : widget.tabIndex != 0
          ? const Text(appName)
          : _sourceSwitcher(context),
      actions: [
        if (widget.selectionMode) ...[
          TextButton(
            key: const ValueKey('clear-catalog-selection'),
            onPressed: widget.selectedDramas.isEmpty
                ? null
                : widget.onClearSelection,
            child: const Text('清空'),
          ),
          TextButton(
            key: const ValueKey('cancel-catalog-selection'),
            focusNode: widget.appBarFocus,
            onPressed: widget.onCancelSelection,
            child: const Text('取消'),
          ),
        ] else ...[
          if (widget.tabIndex == 1)
            IconButton(
              key: const ValueKey('follow-lan-sync'),
              tooltip: '追剧同步',
              onPressed: widget.onOpenLanSync,
              icon: const Icon(Icons.sync_rounded),
            ),
          if (widget.tabIndex == 0) ...[
            if (!controller.showRecommendations)
              IconButton(
                tooltip: '排序与筛选 · ${store.catalogView.sort.label}',
                onPressed: widget.onChooseCatalogView,
                color:
                    store.catalogView.sort != CatalogSort.source ||
                        store.catalogView.release.isNotEmpty
                    ? colors.primary
                    : null,
                icon: const Icon(Icons.sort_rounded),
              ),
            IconButton(
              key: const ValueKey('open-rankings'),
              tooltip: '榜单',
              onPressed: store.sources.isEmpty ? null : widget.onOpenRankings,
              icon: const Icon(Icons.leaderboard_outlined),
            ),
            if (!controller.showRecommendations &&
                store.canDownload &&
                controller.repository.supportsDownloads)
              IconButton(
                key: const ValueKey('select-catalog-dramas'),
                tooltip: '多选下载',
                onPressed: widget.onEnterSelectionMode,
                icon: const Icon(Icons.checklist_rounded),
              ),
            IconButton(
              key: const ValueKey('toggle-search'),
              tooltip: controller.searchVisible ? '收起搜索' : '搜索',
              icon: Icon(
                controller.searchVisible
                    ? Icons.search_off_rounded
                    : Icons.search_rounded,
              ),
              onPressed: widget.onToggleSearch,
            ),
          ],
          if (widget.tabIndex == 0 &&
              !controller.showRecommendations &&
              width >= 400)
            RefreshAction(
              key: const ValueKey('catalog-refresh'),
              loading:
                  controller.loading ||
                  controller.loadingMore ||
                  controller.categoriesLoading ||
                  widget.updatesBusy,
              tooltip: '更新剧库',
              onPressed: store.sources.isEmpty ? null : widget.onRefreshCatalog,
            ),
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: widget.onMoreMenu,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'update', child: Text('更新剧库')),
              PopupMenuItem(value: 'sources', child: Text('站源管理')),
              PopupMenuItem(value: 'settings', child: Text('设置与备份')),
              PopupMenuItem(value: 'users', child: Text('用户管理')),
              PopupMenuItem(value: 'display', child: Text('界面模式')),
              PopupMenuItem(value: 'about', child: Text('关于')),
            ],
          ),
        ],
      ],
    );
  }

  Widget _sourceSwitcher(BuildContext context) {
    final groups = controller.sourceGroups;
    final current = controller.group;
    return PopupMenuButton<SourceGroup>(
      key: const ValueKey('source-switch'),
      tooltip: '切换站源',
      enabled: groups.length > 1,
      onSelected: widget.onChangeGroup,
      itemBuilder: (_) => [
        for (final group in groups)
          PopupMenuItem(
            value: group,
            child: Row(
              children: [
                Expanded(child: Text(group.name)),
                if (group.id == current.id)
                  const Icon(Icons.check_rounded, size: 20),
              ],
            ),
          ),
      ],
      child: SizedBox(
        height: 48,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                current.name,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            if (groups.length > 1) const Icon(Icons.expand_more_rounded),
          ],
        ),
      ),
    );
  }
}
