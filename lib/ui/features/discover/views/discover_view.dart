import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import 'package:hoshi/ui/core/catalog_filters.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/app_build.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/features/discover/views/recommendations_screen.dart';
import 'package:hoshi/ui/features/home/widgets/saved_library.dart';
import 'package:hoshi/ui/core/vip_icon.dart';
import 'package:hoshi/ui/core/widgets.dart';
import 'package:hoshi/ui/core/empty_state.dart';
import 'package:hoshi/ui/core/skeleton.dart';
import 'package:hoshi/ui/core/surfaces.dart';
import 'package:hoshi/ui/shell/window_chrome.dart';
import 'package:hoshi/ui/theme/md3_tokens.dart';
import 'package:hoshi/ui/features/discover/controllers/catalog_controller.dart';
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
    required this.scrollController,
    required this.tabIndex,
    required this.selectionMode,
    required this.selectedDramas,
    required this.maxSelection,
    required this.appBarFocus,
    required this.selectionFocus,
    required this.onCancelSelection,
    required this.onClearSelection,
    required this.onEnterSelectionMode,
    required this.onOpenDrama,
    required this.onDramaActions,
    required this.onSelectDrama,
    required this.onConfirmSelection,
    required this.onToggleSearch,
    required this.onChangeGroup,
    required this.onChangeCategory,
    required this.onSwipeCategory,
    required this.onRefreshCatalog,
    required this.onLoadMore,
    required this.onRetryCatalog,
    required this.onManageSources,
    required this.onOpenRankings,
    required this.onChooseCatalogView,
    required this.onToggleVip,
    required this.onMoreMenu,
    this.cacheReadError,
  });

  final CatalogController controller;
  final LocalStore store;
  final ScrollController scrollController;
  final int tabIndex;
  final bool selectionMode;
  final Map<String, Drama> selectedDramas;
  final int maxSelection;
  final FocusNode appBarFocus;
  final FocusNode selectionFocus;

  final VoidCallback onCancelSelection;
  final VoidCallback onClearSelection;
  final VoidCallback onEnterSelectionMode;
  final void Function(Drama drama, {bool resume, bool download}) onOpenDrama;
  final ValueChanged<Drama> onDramaActions;
  final ValueChanged<Drama> onSelectDrama;
  final VoidCallback onConfirmSelection;
  final VoidCallback onToggleSearch;
  final ValueChanged<SourceGroup> onChangeGroup;
  final ValueChanged<String> onChangeCategory;
  final ValueChanged<int> onSwipeCategory;
  final Future<void> Function() onRefreshCatalog;
  final VoidCallback onLoadMore;
  final VoidCallback onRetryCatalog;
  final VoidCallback onManageSources;
  final VoidCallback onOpenRankings;
  final VoidCallback onChooseCatalogView;
  final VoidCallback onToggleVip;
  final ValueChanged<String> onMoreMenu;

  /// 缓存回读失败时的提示，非空时覆盖目录自身错误。
  final String? cacheReadError;

  @override
  State<DiscoverView> createState() => _DiscoverViewState();
}

class _DiscoverViewState extends State<DiscoverView> {
  CatalogController get controller => widget.controller;
  LocalStore get store => widget.store;

  /// 推荐流的下拉刷新入口。推荐流与目录共用宿主滚动视图，刷新动作要从
  /// 宿主转发给它。
  final _recommendationsKey = GlobalKey<RecommendationsSliversState>();

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final desktop = Md3WindowClass.usesRail(width);
      // 目录页的顶栏是**滚动视图的一部分**（Kazumi 的折叠大标题），
      // 因此不往 `Scaffold.appBar` 里放东西——`AppBar` 是固定
      // 高度、不参与 stretch 的。追剧页同样不放：页面自带「我的追剧」
      // 标题与搜索框，「星」这层标题栏纯属重复；只有万一处于多选态
      // 时才保留 AppBar 承载它的操作。
      final header = _usesHeaderSliver;
      final showAppBar = !header && widget.selectionMode;
      // 内层背景透明：外壳的 `ContentShelf` 负责底色与左侧圆角，
      // 这里再画一层不透明背景会把圆角盖掉。
      return Scaffold(
        backgroundColor: Colors.transparent,
        appBar: showAppBar ? _appBar(context) : null,
        body: _body(desktop),
        bottomNavigationBar: widget.selectionMode ? _selectionBar() : null,
        floatingActionButton: header && !widget.selectionMode
            ? _scrollToTop()
            : null,
      );
    },
  );

  Widget _body(bool desktop) {
    final l10n = AppLocalizations.of(context);
    if (widget.tabIndex == 0) {
      if (store.sources.isEmpty) {
        return StatusPanel(
          title: l10n.noAvailableSources,
          message: l10n.noSourcesHint,
        );
      }
      return _catalog(selectionInBody: desktop);
    }
    // tabIndex 1 是追剧。历史与下载在 S1 之后是「我的」的下级全屏页，
    // 不再经过这里。页面不再有 AppBar，移动端用 SafeArea 补状态栏
    // 顶部内边距（桌面窗口无系统内边距，此处是空操作）。
    return SafeArea(
      top: true,
      bottom: false,
      child: SavedLibrary(
        key: ValueKey('saved-tab-${widget.tabIndex}'),
        repository: controller.repository,
        store: store,
        history: false,
        onOpen: (drama) => widget.onOpenDrama(drama),
        onContinue: (drama) => widget.onOpenDrama(drama, resume: true),
        onDownload: controller.repository.supportsDownloads && store.canDownload
            ? (drama) => widget.onOpenDrama(drama, download: true)
            : null,
      ),
    );
  }

  /// 目录页是否走「折叠大标题」形态（Kazumi 首页）。
  ///
  /// 推荐流也走这条分支：它现在只产出 slivers，与目录共用同一个
  /// `CustomScrollView`，因此不再需要单独的 Scaffold + AppBar。
  bool get _usesHeaderSliver => widget.tabIndex == 0;

  /// 折叠头的高度与标题字号区间，照抄 Kazumi `buildSliverAppBar`。
  static const double headerHeight = Md3HomeHeader.height;
  static const double titleExpanded = Md3HomeHeader.titleExpanded;
  static const double titleCollapsed = Md3HomeHeader.titleCollapsed;

  /// 标题行的点击高度（图标 + 文字一行）。
  static const double _titleHeight = 44;

  /// Kazumi 首页形态：顶栏、分类栏、网格在**同一个** `CustomScrollView` 里，
  /// 于是标题能随滚动从 28/w700 收缩成 20/w500，分类栏跟着内容一起滚走。
  Widget _catalogScroll() {
    return RefreshIndicator(
      onRefresh: controller.showRecommendations
          ? () =>
                _recommendationsKey.currentState?.refresh() ??
                Future<void>.value()
          : widget.onRefreshCatalog,
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
              if (controller.showRecommendations)
                RecommendationsSlivers(
                  key: _recommendationsKey,
                  repository: controller.repository,
                  store: store,
                  scrollController: widget.scrollController,
                )
              else ...[
                if (controller.loading && controller.items.isNotEmpty)
                  SliverToBoxAdapter(child: _loadBar()),
                ..._catalogSlivers(
                  controller.visibleItems,
                  constraints.maxWidth - 2 * padding,
                  padding,
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  /// 折叠大标题。标题本身是站源切换器，左右留白与网格取同一个
  /// `contentInset`，首列与标题对齐。
  ///
  /// 安全区约束：macOS 隐藏标题栏后 `MediaQuery.padding.top` 恒为 0
  /// （`window_manager` 会加 `.fullSizeContentView`），所以 `SafeArea`
  /// 不可用，[WindowSafeArea.top] 必须显式参与定位。标题的位置只能靠
  /// **计算**偏移，不能在 `flexibleSpace` 外层加 `Padding`——SliverAppBar
  /// 按 `toolbarHeight` 裁切，内容被推下去会切掉标题上半截。
  Widget _headerSliver(BuildContext context, double width) {
    final l10n = AppLocalizations.of(context);
    final safeTop = WindowSafeArea.top;
    final toolbar = kToolbarHeight + safeTop;
    final expanded = headerHeight + safeTop;
    return SliverAppBar(
      pinned: true,
      stretch: true,
      expandedHeight: expanded,
      toolbarHeight: toolbar,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleSpacing: 0,
      centerTitle: false,
      backgroundColor: Theme.of(context).colorScheme.surface,
      actions: widget.selectionMode
          ? _selectionActions(l10n)
          : _catalogActions(l10n),
      title: widget.selectionMode
          ? Text(l10n.selectDrama, maxLines: 1, overflow: TextOverflow.ellipsis)
          : null,
      flexibleSpace: LayoutBuilder(
        builder: (context, constraints) {
          // t：0 = 完全展开，1 = 收到工具栏高度。
          final t =
              (1 -
                      ((constraints.maxHeight - toolbar) / (expanded - toolbar))
                          .clamp(0.0, 1.0))
                  .toDouble();
          // 标题顶边在「展开态居中」与「工具栏内居中」之间插值，并钳制在
          // 安全区下沿与可视区间内，滚动全程都不会被裁切。
          final titleTop = lerpDouble(
            safeTop + (expanded - _titleHeight) / 2,
            safeTop + (kToolbarHeight - _titleHeight) / 2,
            t,
          )!;
          return Stack(
            children: [
              Positioned(
                left: 16,
                right: 60,
                top: titleTop.clamp(
                  safeTop,
                  constraints.maxHeight - _titleHeight,
                ),
                child: SizedBox(
                  height: _titleHeight,
                  child: widget.selectionMode
                      ? const SizedBox.shrink()
                      : _categoryMenu(
                          context,
                          fontSize: lerpDouble(
                            titleExpanded,
                            titleCollapsed,
                            t,
                          )!,
                          bold: t < .5,
                        ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 分页进度条：4px、淡入淡出，而不是转圈（Kazumi `popular_page.dart`）。
  Widget _loadBar() => AnimatedOpacity(
    opacity: controller.loading || controller.loadingMore ? 1 : 0,
    duration: Md3Motion.of(context, Md3Motion.standard),
    child: const LinearProgressIndicator(minHeight: 4),
  );

  Widget _filtersRow() {
    final l10n = AppLocalizations.of(context);
    return CatalogFilters(
      key: ValueKey('filters-${controller.group.id}'),
      categories: controller.displayCategories,
      category: controller.displayCategory,
      error: controller.categoriesError,
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
        duration: Md3Motion.of(context, Md3Motion.standardDecelerate),
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
                ? const AppLoadingIndicator(size: 24)
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
    // 非外壳路径也把推荐流放进同一条滚动视图：分类栏在顶部滚走，
    // 不再出现「外层分类栏 + 内层网格」两层滚动的形态。
    if (controller.showRecommendations) {
      return RefreshIndicator(
        onRefresh: () =>
            _recommendationsKey.currentState?.refresh() ?? Future<void>.value(),
        child: CustomScrollView(
          controller: widget.scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: _filtersRow()),
            RecommendationsSlivers(
              key: _recommendationsKey,
              repository: controller.repository,
              store: store,
              scrollController: widget.scrollController,
            ),
          ],
        ),
      );
    }
    final items = controller.visibleItems;
    return Column(
      children: [
        _filtersRow(),
        if (controller.loading && controller.items.isNotEmpty) _loadBar(),
        Expanded(
          child: GestureDetector(
            onHorizontalDragEnd: (details) {
              final velocity = details.primaryVelocity ?? 0;
              if (velocity.abs() < 240) return;
              widget.onSwipeCategory(velocity < 0 ? 1 : -1);
            },
            child: _catalogBody(items),
          ),
        ),
        if (widget.selectionMode && selectionInBody)
          _selectionBar(safeBottom: false),
      ],
    );
  }

  Widget _catalogBody(List<Drama> items) {
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

  Widget _tile(Drama drama) {
    final canSelect =
        store.canDownload && controller.repository.supportsDownloads;
    // 目录页的卡片与 Kazumi 同形：只有海报和标题。追剧状态属于「追剧」页，
    // 塞进目录网格会让每张卡多一行灰字、密度掉一档。
    return DramaTile(
      key: ValueKey(drama.id),
      drama: drama,
      repository: controller.repository,
      onTap: () => widget.selectionMode
          ? widget.onSelectDrama(drama)
          : widget.onOpenDrama(drama),
      onLongPress: canSelect ? () => widget.onSelectDrama(drama) : null,
      onMore: () => widget.onDramaActions(drama),
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

  /// 多选态的动作。`appBarFocus` 是多选工具栏的焦点入口，不能改名。
  List<Widget> _selectionActions(AppLocalizations l10n) => [
    TextButton(
      key: const ValueKey('clear-catalog-selection'),
      onPressed: widget.selectedDramas.isEmpty ? null : widget.onClearSelection,
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
  /// 参照应用 `buildActions()` 只留 1–3 个图标。这里固定为「搜索、排序、
  /// 更多」三个：VIP 过滤、更新剧库、榜单、多选、站源、设置、用户、关于
  /// 全部收进溢出菜单。推荐流不参与排序，此时只显示「搜索 + 更多」。
  List<Widget> _catalogActions(AppLocalizations l10n) {
    return [
      IconButton(
        key: const ValueKey('toggle-search'),
        tooltip: l10n.search,
        icon: const Icon(Icons.search_rounded),
        onPressed: widget.onToggleSearch,
      ),
      if (!controller.showRecommendations)
        IconButton(
          key: const ValueKey('catalog-sort'),
          tooltip: l10n.sortAndFilterTitle,
          onPressed: widget.onChooseCatalogView,
          icon: const Icon(Icons.tune_rounded),
        ),
      ..._moreActions(l10n),
    ];
  }

  /// 「更多」菜单：所有页面常驻，条目本身不承载布局职责。
  ///
  /// 头部只留 3 个图标后，排序 / 榜单 / 多选 / 设置 / 用户 / 显示模式都
  /// 收在这里。菜单项带 key，测试仍可按 `open-rankings` /
  /// `select-catalog-dramas` 定位（它们从 IconButton 变成了菜单项）。
  List<Widget> _moreActions(AppLocalizations l10n) => [
    AppMenuButton(
      key: const ValueKey('catalog-more'),
      menuChildren: [
        if (!controller.showRecommendations &&
            store.canDownload &&
            controller.repository.supportsDownloads)
          AppMenuItem(
            label: l10n.multiDownload,
            onPressed: () => widget.onMoreMenu('select'),
          ),
        AppMenuItem(
          label: l10n.rankingsTitle,
          onPressed: () => widget.onMoreMenu('rankings'),
        ),
        if (controller.supportsVipFilter)
          AppMenuItem(
            key: const ValueKey('catalog-vip'),
            label: l10n.vipShow,
            selected: !store.hideVip,
            onPressed: () => widget.onMoreMenu('vip'),
          ),
        const AppMenuDivider(),
        AppMenuItem(
          label: l10n.refreshLibrary,
          onPressed: () => widget.onMoreMenu('update'),
        ),
        AppMenuItem(
          label: l10n.sourceManagement,
          onPressed: () => widget.onMoreMenu('sources'),
        ),
        AppMenuItem(
          label: l10n.settingsTitle,
          onPressed: () => widget.onMoreMenu('settings'),
        ),
        AppMenuItem(
          label: l10n.userManagement,
          onPressed: () => widget.onMoreMenu('users'),
        ),
        AppMenuItem(
          label: l10n.about,
          onPressed: () => widget.onMoreMenu('about'),
        ),
      ],
      builder: (context, toggle, open) => IconButton(
        tooltip: l10n.more,
        onPressed: toggle,
        icon: const Icon(Icons.more_vert_rounded),
      ),
    ),
  ];

  AppBar _appBar(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AppBar(
      titleSpacing: Md3Spacing.md,
      title: widget.selectionMode
          ? Text(l10n.selectDrama, maxLines: 1, overflow: TextOverflow.ellipsis)
          : widget.tabIndex != 0
          ? const Text(appName)
          : _sourceSwitcher(context, fontSize: Md3Type.titleMedium),
      actions: widget.selectionMode
          ? _selectionActions(l10n)
          : _catalogActions(l10n),
    );
  }

  /// 站源切换器，同时充当目录页的**大标题**（Kazumi 那里是分类下拉）。
  ///
  /// [fontSize] 与 [bold] 由折叠进度给出：展开时 28/w700，收到工具栏高度
  /// 时 20/w500。
  /// 标题即分类菜单（Kazumi `popular_page.dart` 的 `buildSliverAppBar`）。
  ///
  /// 参照应用没有独立的分类栏：大标题本身就是下拉，点开是「热门番组 +
  /// 一排分类」。这样首屏顶部只有一行文字，网格整体上移一屏高——分类栏
  /// 那 52px 在桌面上是一整行海报的高度。
  ///
  /// 站源切换并进同一个菜单的末尾：两者都是「决定下面网格内容」的选择，
  /// 分开放会让标题行同时挂着两个下拉箭头。
  Widget _categoryMenu(
    BuildContext context, {
    required double fontSize,
    bool bold = true,
  }) {
    final categories = controller.displayCategories;
    final current = controller.displayCategory;
    final groups = controller.sourceGroups;
    final group = controller.group;
    // 标题文本：分类名；分类为空时用站源名兜底，避免标题整片空白。
    final currentCategory = categories.firstWhere(
      (entry) => entry.id == current,
      orElse: () => categories.first,
    );
    final label = currentCategory.id.isEmpty
        ? group.name
        : currentCategory.name;

    return AppMenuButton(
      key: const ValueKey('source-switch'),
      // 参照应用的菜单上限 240×350：分类多时靠滚动而不是撑满屏。
      maxSize: const Size(240, 350),
      menuChildren: [
        for (final category in categories)
          AppMenuItem(
            label: category.name,
            selected: category.id == current,
            onPressed: () => widget.onChangeCategory(category.id),
          ),
        if (groups.length > 1) const AppMenuDivider(),
        if (groups.length > 1)
          for (final entry in groups)
            AppMenuItem(
              label: entry.name,
              selected: entry.id == group.id,
              onPressed: () {
                final target = groups.firstWhere(
                  (candidate) => candidate.id == entry.id,
                  orElse: () => group,
                );
                widget.onChangeGroup(target);
              },
            ),
      ],
      // 结构照 `popular_page.dart` 的 builder：InkWell(radius 8) 包一行
      // 「文字 + 4px 间隙 + 跟随字号的下拉箭头」。
      builder: (context, toggle, open) => InkWell(
        onTap: toggle,
        borderRadius: BorderRadius.circular(Md3Shape.small),
        child: SizedBox(
          height: 48,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontSize: fontSize,
                    fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              AnimatedRotation(
                turns: open ? .5 : 0,
                duration: Md3Motion.of(context, Md3Motion.standard),
                child: Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: fontSize,
                  color: Theme.of(context).iconTheme.color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sourceSwitcher(
    BuildContext context, {
    required double fontSize,
    bool bold = true,
  }) {
    final groups = controller.sourceGroups;
    final current = controller.group;
    return AppMenuButton(
      key: const ValueKey('source-switch'),
      enabled: groups.length > 1,
      menuChildren: [
        for (final group in groups)
          AppMenuItem(
            label: group.name,
            selected: group.id == current.id,
            onPressed: () => widget.onChangeGroup(group),
          ),
      ],
      builder: (context, toggle, open) => InkWell(
        onTap: toggle,
        borderRadius: BorderRadius.circular(Md3Shape.small),
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
                AnimatedRotation(
                  turns: open ? .5 : 0,
                  duration: Md3Motion.of(context, Md3Motion.standard),
                  child: Icon(Icons.expand_more_rounded, size: fontSize),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
