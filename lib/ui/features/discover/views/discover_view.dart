import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import 'package:hoshi/ui/core/app_bottom_navigation.dart';
import 'package:hoshi/ui/core/app_layout.dart';
import 'package:hoshi/ui/core/catalog_filters.dart';
import 'package:hoshi/domain/catalog_sort.dart';
import 'package:hoshi/ui/core/drama_actions.dart';
import 'package:hoshi/ui/features/downloads/views/downloads_screen.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/core/l10n_labels.dart';
import 'package:hoshi/ui/features/discover/views/recommendations_screen.dart';
import 'package:hoshi/ui/core/remote_widgets.dart';
import 'package:hoshi/ui/features/home/widgets/saved_library.dart';
import 'package:hoshi/ui/core/vip_icon.dart';
import 'package:hoshi/ui/core/widgets.dart';
import 'package:hoshi/ui/core/skeleton.dart';
import 'package:hoshi/ui/theme/md3_tokens.dart';
import 'package:hoshi/ui/features/discover/controllers/catalog_controller.dart';
import 'package:hoshi/ui/features/discover/widgets/catalog_search_header.dart';
import 'package:hoshi/ui/features/discover/widgets/catalog_selection_bar.dart';

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
    required this.updatesBusy,
    this.cacheReadError,
    this.shell = false,
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
  final bool updatesBusy;

  /// 缓存回读失败时的提示，非空时覆盖目录自身错误。
  final String? cacheReadError;

  /// 是否由 `AppShell` 提供导航。
  ///
  /// 为真时本页不再渲染侧栏 / 底部导航，只保留 AppBar 与内容区；
  /// 电视模式忽略此开关，继续使用自己的遥控导航列表。
  final bool shell;

  @override
  State<DiscoverView> createState() => _DiscoverViewState();
}

class _DiscoverViewState extends State<DiscoverView> {
  CatalogController get controller => widget.controller;
  LocalStore get store => widget.store;

  List<(int, IconData, IconData, String)> _destinations(
    AppLocalizations l10n,
  ) => [
    (0, Icons.explore_outlined, Icons.explore_rounded, l10n.discoverTitle),
    (1, Icons.bookmark_border_rounded, Icons.bookmark_rounded, l10n.follows),
    (2, Icons.history_outlined, Icons.history_rounded, l10n.recentlyWatched),
    if (store.canDownload)
      (3, Icons.download_outlined, Icons.download_rounded, l10n.download),
  ];

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final l10n = AppLocalizations.of(context);
      final television = AppLayout.isTelevision(context);
      final width = constraints.maxWidth;
      final desktop = Md3WindowClass.usesRail(width);
      // 外壳模式：导航由 AppShell 提供，本页只渲染内容与 AppBar。
      // 电视模式永远走自己的遥控导航，不交给外壳。
      if (widget.shell && !television) {
        // 目录页的顶栏是**滚动视图的一部分**（Kazumi 的折叠大标题），
        // 因此这条分支不往 `Scaffold.appBar` 里放东西——`AppBar` 是固定
        // 高度、不参与 stretch 的。
        final header = _usesHeaderSliver;
        // 内层背景透明：外壳的 `ContentShelf` 负责底色与左侧圆角，
        // 这里再画一层不透明背景会把圆角盖掉。
        return Scaffold(
          backgroundColor: Colors.transparent,
          appBar: header ? null : _appBar(context, width, television),
          body: _body(desktop, television),
          bottomNavigationBar: widget.selectionMode ? _selectionBar() : null,
          floatingActionButton: header && !widget.selectionMode
              ? _scrollToTop()
              : null,
        );
      }
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
                  for (final entry in _destinations(l10n))
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

  Widget _rail(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return NavigationRail(
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
        for (final entry in _destinations(l10n))
          NavigationRailDestination(
            icon: Icon(entry.$2),
            selectedIcon: Icon(entry.$3),
            label: Text(entry.$4),
          ),
      ],
    );
  }

  Widget _televisionNavigation() {
    final l10n = AppLocalizations.of(context);
    return SizedBox(
      width: 132,
      child: RemoteList(
        key: widget.navKey,
        itemKeys: [for (final entry in _destinations(l10n)) '${entry.$1}'],
        itemExtent: 60,
        spacing: 14,
        padding: EdgeInsets.zero,
        autofocus: true,
        onExitRight: widget.tabIndex == 0
            ? () => widget.gridKey.currentState?.focusCurrent()
            : null,
        itemBuilder: (_, index, node, onFocus) {
          final entry = _destinations(l10n)[index];
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
  }

  Widget _body(bool desktop, bool television) {
    final l10n = AppLocalizations.of(context);
    if (widget.tabIndex == 0) {
      if (store.sources.isEmpty) {
        return StatusPanel(
          title: l10n.noAvailableSources,
          message: l10n.noSourcesHint,
        );
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

  /// 目录页是否走「折叠大标题」形态（Kazumi 首页）。
  ///
  /// 推荐位自带一整套 Scaffold + AppBar + 分类栏，塞进同一个滚动视图会
  /// 出现两条标题栏，因此它保持原来的 Column 形态。
  bool get _usesHeaderSliver =>
      widget.shell &&
      !AppLayout.isTelevision(context) &&
      widget.tabIndex == 0 &&
      !controller.showRecommendations;

  /// 折叠头的高度与标题字号区间，照抄 Kazumi `buildSliverAppBar`。
  static const double headerHeight = 120;
  static const double titleExpanded = 28;
  static const double titleCollapsed = 20;

  /// Kazumi 首页形态：顶栏、分类栏、网格在**同一个** `CustomScrollView` 里，
  /// 于是标题能随滚动从 28/w700 收缩成 20/w500，分类栏跟着内容一起滚走。
  Widget _catalogScroll() {
    return RefreshIndicator(
      onRefresh: widget.onRefreshCatalog,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final padding = Md3Spacing.contentInset(
            constraints.maxWidth,
            maxWidth: Md3Spacing.wideMaxWidth,
          );
          return CustomScrollView(
            controller: widget.scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              _headerSliver(context, constraints.maxWidth),
              if (controller.searchVisible)
                SliverToBoxAdapter(child: _searchHeader()),
              SliverToBoxAdapter(child: _filtersRow()),
              if (controller.loading && controller.items.isNotEmpty)
                SliverToBoxAdapter(child: _loadBar()),
              ..._catalogSlivers(
                controller.visibleItems,
                constraints.maxWidth - 2 * padding,
                padding,
              ),
            ],
          );
        },
      ),
    );
  }

  /// 折叠大标题。标题位置就是站源切换器（Kazumi 那里是分类下拉），
  /// 左右留白与下面的网格取同一个 `contentInset`，首列与标题对齐。
  Widget _headerSliver(BuildContext context, double width) {
    final l10n = AppLocalizations.of(context);
    return SliverAppBar(
      pinned: true,
      stretch: true,
      expandedHeight: headerHeight,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleSpacing: 0,
      centerTitle: false,
      backgroundColor: Colors.transparent,
      actions: widget.selectionMode
          ? _selectionActions(l10n)
          : [..._catalogActions(l10n, width), ..._moreActions(l10n)],
      title: widget.selectionMode
          ? Text(
              l10n.selectDrama,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            )
          : null,
      flexibleSpace: SafeArea(
        bottom: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final maxExtent =
                headerHeight - MediaQuery.paddingOf(context).top;
            // t = 0 完全展开，t = 1 收到工具栏高度。
            final t =
                1 -
                ((constraints.maxHeight - kToolbarHeight) /
                        (maxExtent - kToolbarHeight))
                    .clamp(0.0, 1.0);
            return Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.only(
                  left: Md3Spacing.contentInset(
                    constraints.maxWidth,
                    maxWidth: Md3Spacing.wideMaxWidth,
                  ),
                  right: 60,
                  top: Md3Spacing.sm,
                  bottom: Md3Spacing.sm,
                ),
                child: SizedBox(
                  height: 44,
                  child: widget.selectionMode
                      ? const SizedBox.shrink()
                      : _sourceSwitcher(
                          context,
                          fontSize: lerpDouble(titleExpanded, titleCollapsed, t)!,
                          bold: t < .5,
                        ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 分页进度条：4px、淡入淡出，而不是转圈（Kazumi `popular_page.dart`）。
  Widget _loadBar() => AnimatedOpacity(
    opacity: controller.loading || controller.loadingMore ? 1 : 0,
    duration: Md3Motion.standard,
    child: const LinearProgressIndicator(minHeight: 4),
  );

  Widget _searchHeader() => CatalogSearchHeader(
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
  );

  Widget _filtersRow() {
    final l10n = AppLocalizations.of(context);
    final television = AppLayout.isTelevision(context);
    return CatalogFilters(
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
              tooltip: store.hideVip ? l10n.vipHide : l10n.vipShow,
              onPressed: widget.onToggleVip,
              icon: VipIcon(hidden: store.hideVip),
            ),
        ],
      ),
    );
  }

  /// 回顶按钮。长列表在桌面端只有滚轮和滚动条，缺一个「回到开头」。
  Widget _scrollToTop() => FloatingActionButton(
    key: const ValueKey('catalog-scroll-top'),
    heroTag: null,
    elevation: 0,
    onPressed: () {
      if (!widget.scrollController.hasClients) return;
      widget.scrollController.animateTo(
        0,
        duration: Md3Motion.standardDecelerate,
        curve: Curves.easeOut,
      );
    },
    child: const Icon(Icons.arrow_upward_rounded),
  );

  /// 目录内容区的 slivers：骨架 / 错误 / 空态 / 网格 + 分页尾部。
  ///
  /// [contentWidth] 与 [padding] 由调用方按同一个 `contentInset` 算出来，
  /// 骨架屏与真实网格因此列数、行高完全一致。
  List<Widget> _catalogSlivers(
    List<Drama> items,
    double contentWidth,
    double padding,
  ) {
    final l10n = AppLocalizations.of(context);
    if (controller.loading && controller.items.isEmpty) {
      final columns = Md3Grid.columns(contentWidth);
      return [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(padding, 0, padding, Md3Spacing.lg),
          sliver: SliverToBoxAdapter(
            child: SkeletonGrid(
              columns: columns,
              tileExtent: DramaTile.extentFor(
                context,
                Md3Grid.tileWidth(contentWidth, columns),
              ),
            ),
          ),
        ),
      ];
    }
    if (controller.items.isEmpty && controller.error != null) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: StatusPanel(
            title: l10n.loadFailed,
            message: controller.error!,
            onRetry: widget.onRetryCatalog,
            secondaryAction: controller.repository.supportsSourceManagement
                ? TextButton(
                    onPressed: widget.onManageSources,
                    child: Text(l10n.sourceDiagnostics),
                  )
                : null,
            icon: Icons.wifi_off_rounded,
          ),
        ),
      ];
    }
    if (items.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: StatusPanel(
            title: l10n.noMatchingDramas,
            message: controller.hideVip
                ? l10n.searchEmptyHint
                : store.sources.length > 1
                ? l10n.sourceEmptyHint
                : l10n.errorEmptyHint,
            onRetry: controller.canLoadMore ? widget.onLoadMore : null,
            action: l10n.loadMore,
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: EdgeInsets.fromLTRB(padding, 0, padding, Md3Spacing.lg),
        sliver: SliverGrid(
          gridDelegate: dramaGridDelegate(context, contentWidth),
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
                    label: Text(l10n.loadMore),
                  )
                : Text(
                    l10n.allCaughtUp,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: Md3Type.bodySmall,
                    ),
                  ),
          ),
        ),
      ),
    ];
  }

  Widget _catalog({required bool selectionInBody}) {
    if (_usesHeaderSliver) return _catalogScroll();
    final items = controller.visibleItems;
    final television = AppLayout.isTelevision(context);
    return Column(
      children: [
        if (controller.searchVisible && !television) _searchHeader(),
        _filtersRow(),
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
          if (controller.loading && controller.items.isNotEmpty) _loadBar(),
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
    final l10n = AppLocalizations.of(context);
    if (television) {
      return LayoutBuilder(
        builder: (context, constraints) => _televisionGrid(
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
                      label: l10n.loadMore,
                      icon: Icons.expand_more,
                      onPressed: widget.onLoadMore,
                    )
                  : Text(l10n.allCaughtUp),
            ),
          ),
        ),
      );
    }
    // 内容宽度上限：网格不随窗口无限铺开。留白同时承担居中职责，
    // 因此不需要额外的 ConstrainedBox 层级。
    return LayoutBuilder(
      builder: (context, constraints) {
        final padding = Md3Spacing.contentInset(
          constraints.maxWidth,
          maxWidth: Md3Spacing.wideMaxWidth,
        );
        return RefreshIndicator(
          onRefresh: widget.onRefreshCatalog,
          child: CustomScrollView(
            controller: widget.scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: _catalogSlivers(
              items,
              constraints.maxWidth - 2 * padding,
              padding,
            ),
          ),
        );
      },
    );
  }

  Widget _tile(Drama drama, {FocusNode? focusNode, VoidCallback? onFocus}) {
    final canSelect =
        store.canDownload && controller.repository.supportsDownloads;
    // 目录页的卡片与 Kazumi 同形：只有海报和标题。追剧状态属于「追剧」页，
    // 塞进目录网格会让每张卡多一行灰字、密度掉一档。
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
    final grid = remoteGridLayout(context, width);
    return RemoteGrid(
      key: widget.gridKey,
      itemKeys: items.map((item) => item.id).toList(),
      columns: grid.columns,
      spacing: Md3Grid.spacing,
      itemExtent: grid.itemExtent,
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

  /// 多选态的动作。`appBarFocus` 是遥控与 Tab 顺序的入口，不能改名。
  List<Widget> _selectionActions(AppLocalizations l10n) => [
    TextButton(
      key: const ValueKey('clear-catalog-selection'),
      onPressed: widget.selectedDramas.isEmpty
          ? null
          : widget.onClearSelection,
      child: Text(l10n.clear),
    ),
    TextButton(
      key: const ValueKey('cancel-catalog-selection'),
      focusNode: widget.appBarFocus,
      onPressed: widget.onCancelSelection,
      child: Text(l10n.cancel),
    ),
  ];

  /// 目录页（tab 0）的动作区。
  ///
  /// Kazumi 首页只有 1–3 个图标，这里保留 5 个：排序、榜单、多选、搜索、
  /// 刷新都是真实入口，收进溢出菜单会让 4 个测试与鼠标用户一起找不到路。
  List<Widget> _catalogActions(AppLocalizations l10n, double width) {
    final colors = Theme.of(context).colorScheme;
    return [
      if (!controller.showRecommendations)
        IconButton(
          tooltip: l10n.sortAndFilter(
            catalogSortLabel(store.catalogView.sort, l10n),
          ),
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
        tooltip: l10n.rankingsTitle,
        onPressed: store.sources.isEmpty ? null : widget.onOpenRankings,
        icon: const Icon(Icons.leaderboard_outlined),
      ),
      if (!controller.showRecommendations &&
          store.canDownload &&
          controller.repository.supportsDownloads)
        IconButton(
          key: const ValueKey('select-catalog-dramas'),
          tooltip: l10n.multiDownload,
          onPressed: widget.onEnterSelectionMode,
          icon: const Icon(Icons.checklist_rounded),
        ),
      IconButton(
        key: const ValueKey('toggle-search'),
        tooltip: controller.searchVisible ? l10n.closeSearch : l10n.search,
        icon: Icon(
          controller.searchVisible
              ? Icons.search_off_rounded
              : Icons.search_rounded,
        ),
        onPressed: widget.onToggleSearch,
      ),
      if (!controller.showRecommendations && width >= 400)
        RefreshAction(
          key: const ValueKey('catalog-refresh'),
          loading:
              controller.loading ||
              controller.loadingMore ||
              controller.categoriesLoading ||
              widget.updatesBusy,
          tooltip: l10n.refreshLibrary,
          onPressed: store.sources.isEmpty ? null : widget.onRefreshCatalog,
        ),
    ];
  }

  /// 「更多」菜单：所有页面常驻，条目本身不承载布局职责。
  List<Widget> _moreActions(AppLocalizations l10n) => [
    PopupMenuButton<String>(
      tooltip: l10n.more,
      onSelected: widget.onMoreMenu,
      itemBuilder: (_) => [
        PopupMenuItem(value: 'update', child: Text(l10n.refreshLibrary)),
        PopupMenuItem(value: 'sources', child: Text(l10n.sourceManagement)),
        PopupMenuItem(value: 'settings', child: Text(l10n.settingsTitle)),
        PopupMenuItem(value: 'users', child: Text(l10n.userManagement)),
        PopupMenuItem(value: 'display', child: Text(l10n.displayMode)),
        PopupMenuItem(value: 'about', child: Text(l10n.about)),
      ],
    ),
  ];

  AppBar _appBar(BuildContext context, double width, bool television) {
    final l10n = AppLocalizations.of(context);
    return AppBar(
      toolbarHeight: television ? 64 : null,
      titleSpacing: Md3Spacing.md,
      title: widget.selectionMode
          ? Text(l10n.selectDrama, maxLines: 1, overflow: TextOverflow.ellipsis)
          : widget.tabIndex != 0
          ? const Text(appName)
          : _sourceSwitcher(context, fontSize: Md3Type.titleMedium),
      actions: widget.selectionMode
          ? _selectionActions(l10n)
          : [
              if (widget.tabIndex == 0) ..._catalogActions(l10n, width),
              ..._moreActions(l10n),
            ],
    );
  }

  /// 站源切换器，同时充当目录页的**大标题**（Kazumi 那里是分类下拉）。
  ///
  /// [fontSize] 与 [bold] 由折叠进度给出：展开时 28/w700，收到工具栏高度
  /// 时 20/w500。
  Widget _sourceSwitcher(
    BuildContext context, {
    required double fontSize,
    bool bold = true,
  }) {
    final l10n = AppLocalizations.of(context);
    final groups = controller.sourceGroups;
    final current = controller.group;
    return PopupMenuButton<SourceGroup>(
      key: const ValueKey('source-switch'),
      tooltip: l10n.switchSource,
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
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontSize: fontSize,
                  fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
            if (groups.length > 1)
              Icon(Icons.expand_more_rounded, size: fontSize),
          ],
        ),
      ),
    );
  }
}
