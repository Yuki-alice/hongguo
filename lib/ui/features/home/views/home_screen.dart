import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:go_router/go_router.dart';

import 'package:hoshi/ui/core/app_layout.dart';
import 'package:hoshi/data/app_contract.dart';
import 'package:hoshi/ui/core/catalog_sort_sheet.dart';
import 'package:hoshi/ui/core/drama_actions.dart';
import 'package:hoshi/data/library_updater.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/data/batch_downloads.dart';
import 'package:hoshi/ui/features/player/views/playback_launch_screen.dart';
import 'package:hoshi/ui/core/remote_widgets.dart';
import 'package:hoshi/ui/features/discover/controllers/catalog_controller.dart';
import 'package:hoshi/ui/features/discover/views/discover_view.dart';
import 'package:hoshi/ui/routing/app_router.dart';
import 'package:hoshi/ui/routing/route_args.dart';
import 'package:hoshi/ui/core/widgets.dart';

/// 应用主页面。
///
/// 只负责装配：把 `CatalogController` 的浏览状态接到 `DiscoverView`，
/// 并集中承接需要 `BuildContext` 的副作用（导航、对话框、提示）。
/// 具体的浏览逻辑见 `CatalogController`，布局见 `DiscoverView`。
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.repository, required this.store});

  final AppRepository repository;
  final LocalStore store;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final CatalogController _catalog;
  late final LibraryUpdater _updater;
  final _search = TextEditingController();
  final _scroll = ScrollController();
  final _selectedDramas = <String, Drama>{};
  bool _selectionMode = false;
  int _tab = 0;
  Timer? _cacheRefreshTimer;
  final _changedSources = <String>{};
  bool _refreshingUpdatedCache = false;
  String? _cacheReadError;
  bool _catalogLoadScheduled = false;

  final _filtersKey = GlobalKey<RemoteRowState>();
  final _gridKey = GlobalKey<RemoteGridState>();
  final _navKey = GlobalKey<RemoteListState>();
  final _appBarFocus = FocusNode(debugLabel: 'tv-appbar');
  final _selectionFocus = FocusNode(debugLabel: 'tv-selection');

  @override
  void initState() {
    super.initState();
    _catalog = CatalogController(
      repository: widget.repository,
      store: widget.store,
    )..addListener(_onCatalogChanged);
    _scroll.addListener(_onCatalogScroll);
    _updater = LibraryUpdater(
      widget.repository,
      widget.store,
      onCatalogChanged: _catalogUpdated,
    )..addListener(_updateChanged);
    _updater.startWatching();
    widget.repository.catalogUpdates.addListener(_metadataChanged);
    if (widget.store.sources.isNotEmpty) {
      unawaited(_catalog.load(useCache: true));
      unawaited(_catalog.loadCategories());
    } else {
      _catalog.markIdle();
    }
  }

  @override
  void dispose() {
    _updater.removeListener(_updateChanged);
    _updater.dispose();
    _cacheRefreshTimer?.cancel();
    widget.repository.catalogUpdates.removeListener(_metadataChanged);
    unawaited(widget.repository.cancelSuggestions());
    _catalog.removeListener(_onCatalogChanged);
    _catalog.dispose();
    _search.dispose();
    _scroll.removeListener(_onCatalogScroll);
    _scroll.dispose();
    _appBarFocus.dispose();
    _selectionFocus.dispose();
    super.dispose();
  }

  void _onCatalogChanged() {
    if (!mounted) return;
    if (_catalog.consumeScrollReset() && _scroll.hasClients) {
      _scroll.jumpTo(0);
    }
    setState(() {});
  }

  void _onCatalogScroll() {
    if (!mounted ||
        _catalog.showRecommendations ||
        !_catalog.hasMore ||
        _catalog.loading ||
        _catalog.loadingMore ||
        !_scroll.hasClients) {
      return;
    }
    final position = _scroll.position;
    final threshold = (position.viewportDimension * 1.5).clamp(320.0, 900.0);
    if (position.extentAfter > threshold || _catalogLoadScheduled) return;
    _catalogLoadScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _catalogLoadScheduled = false;
      if (!mounted ||
          _catalog.showRecommendations ||
          !_catalog.hasMore ||
          _catalog.loading ||
          _catalog.loadingMore ||
          !_scroll.hasClients) {
        return;
      }
      unawaited(_catalog.load(more: true));
    });
  }

  void _metadataChanged() {
    final drama = widget.repository.catalogUpdates.latest;
    if (!mounted || drama == null || !widget.store.allowsSource(drama.source)) {
      return;
    }
    _catalog.mergeDrama(drama);
    unawaited(saveUserChange(context, () => widget.store.refreshDrama(drama)));
  }

  void _updateChanged() {
    if (mounted) setState(() {});
  }

  void _catalogUpdated(String source) {
    _changedSources.add(source);
    _cacheRefreshTimer?.cancel();
    _cacheRefreshTimer = Timer(
      const Duration(milliseconds: 100),
      _reloadUpdatedCache,
    );
  }

  /// 站源更新结束后把磁盘上的新条目并入当前列表。
  ///
  /// 依次：读缓存 → 就地合并条目与已选项 → 写回追剧资料 → 刷新分类与目录缓存。
  /// 每步都核对用户代次，切换用户后丢弃过期结果。
  Future<void> _reloadUpdatedCache() async {
    final l10n = AppLocalizations.of(context);
    if (!mounted || _changedSources.isEmpty || _refreshingUpdatedCache) return;
    _refreshingUpdatedCache = true;
    final epoch = widget.store.profileEpoch;
    final sources = Set.of(_changedSources);
    try {
      final updates = <String, Drama>{};
      for (final source in sources) {
        if (!mounted || epoch != widget.store.profileEpoch) return;
        try {
          final cached = await widget.repository.cached(source);
          for (final drama in cached.items) {
            if (widget.store.allowsSource(drama.source)) {
              updates[drama.id] = drama;
            }
          }
        } catch (error) {
          if (mounted && epoch == widget.store.profileEpoch) {
            setState(() => _cacheReadError = l10n.cacheReadError('$error'));
          }
        }
      }
      if (!mounted || epoch != widget.store.profileEpoch) return;
      _catalog.mergeItems(updates.values);
      setState(() {
        for (final id in _selectedDramas.keys.toList()) {
          final update = updates[id];
          if (update != null) {
            _selectedDramas[id] = _selectedDramas[id]!.merge(update);
          }
        }
      });
      await saveUserChange(
        context,
        () => widget.store.refreshDramas(updates.values),
      );
      if (!mounted || epoch != widget.store.profileEpoch) return;
      if (_catalog.group.sources.any((source) => sources.contains(source.id))) {
        await _catalog.loadCategories(cacheOnly: true);
        if (mounted &&
            !_catalog.loading &&
            !_catalog.loadingMore &&
            (!_catalog.onlineSearch || _search.text.trim().isEmpty)) {
          await _catalog.load(cacheOnly: true);
        }
      }
    } finally {
      _changedSources.clear();
      _refreshingUpdatedCache = false;
    }
  }

  /// 更新剧库：支持站源管理时走原生更新任务，由缓存回读带出新条目；
  /// 否则退化为重新取分类与目录。
  Future<void> _refreshCatalog() async {
    if (widget.repository.supportsSourceManagement) {
      if (_catalog.group.sources.any((source) => _updater.busy(source.id))) {
        return;
      }
      _pauseCatalog();
      await _updater.update(_catalog.group.sources);
      return;
    }
    await _catalog.loadCategories(force: true);
    if (mounted) await _catalog.load(force: true);
  }

  Future<void> _chooseCatalogView() async {
    final selected = await chooseCatalogView(context, widget.store.catalogView);
    if (selected == null || !mounted) return;
    await saveUserChange(context, () => widget.store.setCatalogView(selected));
    if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
  }

  void _changeGroup(SourceGroup group) {
    _catalog.changeGroup(group);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _changeCategory(String category) {
    _search.clear();
    _catalog.changeCategory(category);
  }

  void _toggleSearch() {
    if (AppLayout.isTelevision(context)) {
      unawaited(_televisionSearch());
      return;
    }
    if (_catalog.showRecommendations) _catalog.changeCategory('');
    _catalog.toggleSearch();
    if (!_catalog.searchVisible) _search.clear();
  }

  void _searchChanged(String query) {
    setState(() {
      _selectionMode = false;
      _selectedDramas.clear();
    });
    _catalog.searchChanged(query);
  }

  void _submitSearch(String query) {
    setState(() {
      _selectionMode = false;
      _selectedDramas.clear();
    });
    _search.text = query.trim();
    if (_search.text.isNotEmpty) {
      unawaited(
        saveUserChange(
          context,
          () => widget.store.rememberSearch(_search.text),
        ),
      );
    }
    _catalog.submitSearch(query);
  }

  Future<void> _televisionSearch() async {
    final l10n = AppLocalizations.of(context);
    final group = _catalog.group;
    final query = await showDialog<String>(
      context: context,
      builder: (_) => TelevisionSearchDialog(
        initialValue: _search.text,
        title: group.id == 'all'
            ? l10n.searchOpenSources
            : _catalog.onlineSearch
            ? l10n.searchGroup(group.name)
            : l10n.filterLoadedDramas,
        recentSearches: widget.store.recentSearches,
        onCancel: () => unawaited(widget.repository.cancelSuggestions()),
        suggestions: _catalog.searchSuggestions
            ? widget.repository.suggestions
            : null,
      ),
    );
    if (query != null && mounted) _submitSearch(query);
  }

  void _changeTab(int tab) => setState(() {
    _tab = tab;
    _selectionMode = false;
    _selectedDramas.clear();
  });

  void _cancelSelection() => setState(() {
    _selectionMode = false;
    _selectedDramas.clear();
  });

  void _enterSelectionMode() => setState(() {
    _selectionMode = true;
    _selectedDramas.clear();
  });

  void _clearSelection() => setState(_selectedDramas.clear);

  void _selectDrama(Drama drama) {
    final l10n = AppLocalizations.of(context);
    if (!widget.store.canDownload ||
        !widget.repository.supportsDownloads ||
        !widget.store.allowsSource(drama.source)) {
      return;
    }
    if (!_selectedDramas.containsKey(drama.id) &&
        _selectedDramas.length >= BatchDownloads.maxDramas) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.homeMaxSelection)));
      return;
    }
    setState(() {
      _selectionMode = true;
      if (_selectedDramas.remove(drama.id) == null) {
        _selectedDramas[drama.id] = drama;
      }
    });
  }

  void _confirmSelection() {
    if (!widget.store.canDownload || _selectedDramas.isEmpty) return;
    _pauseCatalog();
    // 批量下载需要完整的剧集列表，无法从 URL 重建，用 extra 传递；
    // 深链进入时 extra 为空，路由会显示「没有选择要下载的短剧」。
    context.go(
      AppRoutes.batchDownload,
      extra: BatchDownloadExtra(_selectedDramas.values.toList()),
    );
  }

  void _openDrama(Drama drama, {bool resume = false, bool download = false}) {
    _pauseCatalog();
    final ref = DramaRef.fromDramaId(drama.id);
    if (ref == null) return;
    if (download) {
      context.go(
        AppRoutes.withQuery(AppRoutes.detailOf(ref), {'download': true}),
        extra: drama,
      );
      return;
    }
    unawaited(
      openPlaybackDirectly(
        context,
        drama: drama,
        repository: widget.repository,
        store: widget.store,
      ),
    );
  }

  void _dramaActions(Drama drama) => showDramaActions(
    context,
    drama: drama,
    store: widget.store,
    onContinue: () => _openDrama(drama, resume: true),
    onDownload: widget.repository.supportsDownloads && widget.store.canDownload
        ? () => _openDrama(drama, download: true)
        : null,
    onSelect: widget.repository.supportsDownloads && widget.store.canDownload
        ? () => _selectDrama(drama)
        : null,
  );

  void _pauseCatalog() {
    _catalog.pause();
    unawaited(widget.repository.cancelSuggestions());
  }

  void _openRankings() {
    _pauseCatalog();
    context.go(AppRoutes.rankingsOf(_catalog.group.id));
  }

  Future<void> _manageSources() async {
    _pauseCatalog();
    // 用 `push` 而不是 `go`：返回时要重新读取分类与目录缓存，
    // 用 await 等路由出栈后再刷新，保持原有语义。
    await context.push(AppRoutes.sourcesOf(_catalog.source.id));
    if (!mounted) return;
    await _catalog.loadCategories();
    if (mounted && (!_catalog.onlineSearch || _catalog.searchQuery.isEmpty)) {
      await _catalog.load(useCache: true);
    }
  }

  Future<void> _moreMenu(String value) async {
    final l10n = AppLocalizations.of(context);
    switch (value) {
      case 'update':
        await _refreshCatalog();
      case 'sources':
        await _manageSources();
      case 'settings':
        if (!mounted) return;
        await context.push(AppRoutes.settings);
      case 'users':
        if (!mounted) return;
        await context.push(AppRoutes.profiles);
      case 'display':
        await _chooseDisplayMode();
      case 'about':
        if (!mounted) return;
        showAboutDialog(
          context: context,
          applicationName: appName,
          applicationVersion: AppLayout.versionOf(context),
          applicationIcon: Icon(
            Icons.play_circle_filled_rounded,
            size: 48,
            color: Theme.of(context).colorScheme.primary,
          ),
          children: [Text(l10n.appIntro)],
        );
    }
  }

  Future<void> _chooseDisplayMode() async {
    final l10n = AppLocalizations.of(context);
    final selection = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(l10n.displayMode),
        children: [
          RadioGroup<String>(
            groupValue: widget.store.displayMode,
            onChanged: (value) => Navigator.pop(context, value),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final mode in {
                  'auto': l10n.autoDetectDevice,
                  'television': l10n.displayTelevision,
                  'standard': l10n.displayPhoneComputer,
                }.entries)
                  RadioListTile<String>(
                    value: mode.key,
                    autofocus: mode.key == widget.store.displayMode,
                    title: Text(mode.value),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (selection != null && mounted) {
      await saveUserChange(
        context,
        () => widget.store.setDisplayMode(selection),
      );
    }
  }

  void _toggleVip() => unawaited(
    saveUserChange(
      context,
      () => widget.store.setHideVip(!widget.store.hideVip),
    ),
  );

  void _clearRecentSearches() =>
      unawaited(saveUserChange(context, widget.store.clearRecentSearches));

  bool get _updatesBusy =>
      _catalog.group.sources.any((source) => _updater.busy(source.id));

  @override
  Widget build(BuildContext context) {
    final catalog = _catalog;
    final television = AppLayout.isTelevision(context);
    final view = DiscoverView(
      controller: catalog,
      store: widget.store,
      searchController: _search,
      scrollController: _scroll,
      tabIndex: _tab,
      selectionMode: _selectionMode,
      selectedDramas: _selectedDramas,
      maxSelection: BatchDownloads.maxDramas,
      appBarFocus: _appBarFocus,
      selectionFocus: _selectionFocus,
      filtersKey: _filtersKey,
      gridKey: _gridKey,
      navKey: _navKey,
      onChangeTab: _changeTab,
      onCancelSelection: _cancelSelection,
      onClearSelection: _clearSelection,
      onEnterSelectionMode: _enterSelectionMode,
      onOpenDrama: _openDrama,
      onDramaActions: _dramaActions,
      onSelectDrama: _selectDrama,
      onConfirmSelection: _confirmSelection,
      onToggleSearch: _toggleSearch,
      onSearchChanged: _searchChanged,
      onSubmitSearch: _submitSearch,
      onChangeGroup: _changeGroup,
      onChangeCategory: _changeCategory,
      onSwipeCategory: catalog.swipeCategory,
      onRefreshCatalog: _refreshCatalog,
      onLoadMore: () => unawaited(catalog.load(more: true)),
      onRetryCatalog: () => unawaited(catalog.load(force: true)),
      onManageSources: () => unawaited(_manageSources()),
      onOpenRankings: _openRankings,
      onChooseCatalogView: () => unawaited(_chooseCatalogView()),
      onClearRecentSearches: _clearRecentSearches,
      onToggleVip: _toggleVip,
      onMoreMenu: (value) => unawaited(_moreMenu(value)),
      onCancelSuggestions: () =>
          unawaited(widget.repository.cancelSuggestions()),
      updatesBusy: _updatesBusy,
      cacheReadError: _cacheReadError,
    );
    if (!television && !_selectionMode) return view;
    return PopScope(
      canPop:
          !_selectionMode && (!television || _tab == 0 && _search.text.isEmpty),
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _televisionBack();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.of(context).maybePop(),
        },
        child: Focus(autofocus: true, child: view),
      ),
    );
  }

  void _televisionBack() {
    if (_selectionMode) {
      _cancelSelection();
    } else if (_tab != 0) {
      setState(() => _tab = 0);
    } else if (_search.text.isNotEmpty) {
      _search.clear();
      _searchChanged('');
    }
  }
}
