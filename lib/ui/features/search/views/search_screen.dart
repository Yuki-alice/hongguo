import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:hoshi/data/app_contract.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/core/adaptive_sheet.dart';
import 'package:hoshi/ui/core/empty_state.dart';
import 'package:hoshi/ui/core/widgets.dart';
import 'package:hoshi/ui/features/discover/controllers/catalog_controller.dart';
import 'package:hoshi/ui/features/detail/views/detail_screen.dart';
import 'package:hoshi/ui/theme/md3_tokens.dart';

/// 独立搜索页。
///
/// 结构照参照应用的 `search_page.dart`：
///
/// - **未搜索**时是「按条件查找 + 最近搜索」，搜索框在顶部；
/// - **已搜索**时搜索框固定（`pinSearch`），下面换成结果网格；
/// - 结果卡是 0.7 封面 + 两行标题 + 一行元信息，列数按
///   `max(2, 宽度 / 180)` 推。
///
/// 与参照应用的差异只有数据侧：它搜 Bangumi 条目（有评分与排名），我们搜
/// 站源目录（有集数与上线日期）。因此元信息行放「N 集 · 年份」，不伪造评分。
class SearchScreen extends StatefulWidget {
  const SearchScreen({
    super.key,
    required this.repository,
    required this.store,
    this.initialQuery = '',
  });

  final AppRepository repository;
  final LocalStore store;
  final String initialQuery;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  late final CatalogController _catalog;
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  String? _submitted;

  bool get _hasSearched => _submitted != null;

  @override
  void initState() {
    super.initState();
    _catalog = CatalogController(
      repository: widget.repository,
      store: widget.store,
    )..addListener(_onChanged);
    _scroll.addListener(_loadMoreOnScroll);
    if (widget.initialQuery.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _submit(widget.initialQuery);
      });
    }
  }

  @override
  void dispose() {
    _catalog.removeListener(_onChanged);
    _catalog.dispose();
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  void _loadMoreOnScroll() {
    if (!_scroll.hasClients || _scroll.position.extentAfter > 360) return;
    if (_catalog.loading || _catalog.loadingMore || !_catalog.hasMore) return;
    unawaited(_catalog.load(more: true));
  }

  Future<void> _submit(String raw) async {
    final query = raw.trim();
    if (query.isEmpty) return;
    _focus.unfocus();
    setState(() => _submitted = query);
    if (_scroll.hasClients) _scroll.jumpTo(0);
    unawaited(widget.store.rememberSearch(query));
    _catalog.submitSearch(query);
  }

  void _clear() {
    _focus.unfocus();
    _input.clear();
    setState(() => _submitted = null);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.searchTitle),
        leading: const BackButton(),
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 未搜索时内容更窄：只有搜索框与最近搜索，铺太宽会显得空。
            final horizontal = constraints.maxWidth >= 700 ? 32.0 : 20.0;
            final width = math.min(
              _hasSearched ? 1120.0 : 760.0,
              constraints.maxWidth - horizontal * 2,
            );
            final inset = (constraints.maxWidth - width) / 2;
            // 搜索后把搜索框钉在顶部：结果很长时仍然随时能改词。
            final pinSearch =
                _hasSearched &&
                constraints.maxHeight >= 420 &&
                MediaQuery.textScalerOf(context).scale(16) <= 24;

            Widget scrollView(List<Widget> slivers) => CustomScrollView(
              controller: _scroll,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(inset, 0, inset, Md3Spacing.xl),
                  sliver: SliverMainAxisGroup(slivers: slivers),
                ),
              ],
            );

            return Column(
              children: [
                if (pinSearch)
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: inset),
                    child: _header(),
                  ),
                Expanded(
                  child: _hasSearched
                      ? scrollView([
                          if (!pinSearch) SliverToBoxAdapter(child: _header()),
                          ..._resultSlivers(width),
                        ])
                      : scrollView([
                          SliverToBoxAdapter(child: _header()),
                          SliverToBoxAdapter(child: _discovery()),
                        ]),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _header() => Padding(
    padding: EdgeInsets.only(
      top: _hasSearched ? Md3Spacing.sm : Md3Spacing.xl,
      bottom: Md3Spacing.lg,
    ),
    child: _searchField(),
  );

  Widget _searchField() {
    final colors = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _input,
      builder: (context, value, _) => SearchBar(
        controller: _input,
        focusNode: _focus,
        hintText: l10n.searchHintGeneric,
        textInputAction: TextInputAction.search,
        constraints: const BoxConstraints(minHeight: 64),
        elevation: const WidgetStatePropertyAll(0),
        backgroundColor: WidgetStatePropertyAll(colors.surfaceContainerHigh),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: Md3Spacing.sm),
        ),
        leading: IconButton(
          tooltip: l10n.search,
          onPressed: () => _submit(_input.text),
          icon: const Icon(Icons.search_rounded),
        ),
        trailing: [
          if (value.text.isNotEmpty || _hasSearched)
            IconButton(
              tooltip: l10n.clearSearch,
              onPressed: _clear,
              icon: const Icon(Icons.close_rounded),
            ),
        ],
        onSubmitted: _submit,
      ),
    );
  }

  /// 未搜索时的落地内容。
  ///
  /// 结构照 `search_page.dart` 的 `_discovery()`：
  ///   1. 「按条件查找」入口（ListTile，圆角 20，tune 图标）
  ///   2. 间隔 28
  ///   3. 「最近搜索」标题行（左标题 + 右「清空」）
  ///   4. 最近搜索列表（圆角 16，history 图标 + north_west 尾标）
  ///
  /// 参照应用的「按条件查找」打开的是一个筛选面板（题材 / 放送时间 /
  /// 评分）。我们的站源只提供分类这一个维度，因此这个入口直接按分类
  /// 筛选——按钮在、能点、有结果，而不是删掉入口。
  Widget _discovery() {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final histories = widget.store.recentSearches;
    final categories = [
      for (final entry in _catalog.displayCategories)
        if (entry.id.isNotEmpty) entry.name,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (categories.isNotEmpty)
          Material(
            type: MaterialType.transparency,
            child: ListTile(
              key: const ValueKey('search-by-condition'),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(Md3Shape.largeIncreased),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: Md3Spacing.lg,
                vertical: Md3Spacing.xs,
              ),
              leading: const Icon(Icons.tune_rounded),
              title: Text(l10n.searchByCondition),
              subtitle: Text(l10n.searchByConditionHint),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _showCategoryFilter(categories),
            ),
          ),
        const SizedBox(height: 28),
        if (histories.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Md3Spacing.xl),
            child: EmptyState(
              icon: Icons.search_rounded,
              title: l10n.searchEmptyTitle,
              message: l10n.searchEmptyHint,
              compact: true,
            ),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.only(
              left: Md3Spacing.lg,
              right: Md3Spacing.xs,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.recentSearches,
                    style: TextStyle(
                      fontSize: Md3Type.titleSmall,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    await widget.store.clearRecentSearches();
                    if (mounted) setState(() {});
                  },
                  child: Text(l10n.clearAll),
                ),
              ],
            ),
          ),
          for (final history in histories.take(10))
            Material(
              type: MaterialType.transparency,
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: Md3Spacing.lg,
                  vertical: Md3Spacing.xs,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(Md3Shape.large),
                ),
                leading: Icon(
                  Icons.history_rounded,
                  color: theme.colorScheme.onSurfaceVariant,
                  size: 22,
                ),
                title: Text(
                  history,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Icon(
                  Icons.north_west_rounded,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                onTap: () {
                  _input.text = history;
                  _submit(history);
                },
              ),
            ),
        ],
      ],
    );
  }

  /// 按分类筛选：参照应用用筛选面板，我们用底部分段列表。
  Future<void> _showCategoryFilter(List<String> categories) async {
    final picked = await showAdaptiveSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final category in categories)
              ListTile(
                title: Text(category),
                onTap: () => Navigator.of(context).pop(category),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    _input.text = picked;
    await _submit(picked);
  }

  List<Widget> _resultSlivers(double width) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final items = _catalog.visibleItems;
    final busy = _catalog.loading;
    final failed = _catalog.error != null;

    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(bottom: Md3Spacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.searchResults,
                style: TextStyle(
                  fontSize: Md3Type.titleMedium,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              Text(
                busy ? l10n.searching : l10n.searchResultCount(items.length),
                style: TextStyle(
                  fontSize: Md3Type.bodySmall,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
      if (busy && items.isEmpty)
        const SliverToBoxAdapter(child: _SearchLoadingState())
      else if (failed && items.isEmpty)
        SliverToBoxAdapter(
          child: EmptyState(
            icon: Icons.wifi_off_rounded,
            title: l10n.loadFailed,
            tone: EmptyStateTone.error,
            actions: [
              FilledButton.icon(
                onPressed: () => _catalog.load(force: true),
                icon: const Icon(Icons.refresh_rounded),
                label: Text(l10n.retry),
              ),
            ],
          ),
        )
      else if (items.isEmpty)
        SliverToBoxAdapter(
          child: EmptyState(
            icon: Icons.search_off_rounded,
            title: l10n.searchNoResults,
          ),
        )
      else
        _resultGrid(items, width),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Md3Spacing.xl),
          child: Center(
            child: busy && items.isNotEmpty
                ? const AppLoadingIndicator(size: 32)
                : _catalog.hasMore
                ? TextButton.icon(
                    onPressed: () => _catalog.load(more: true),
                    icon: const Icon(Icons.expand_more_rounded),
                    label: Text(l10n.loadMore),
                  )
                : Text(
                    l10n.allResultsShown,
                    style: TextStyle(
                      fontSize: Md3Type.bodySmall,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
          ),
        ),
      ),
    ];
  }

  Widget _resultGrid(List<Drama> items, double width) {
    // 列数照参照应用：按 180px 一张推，至少 2 列。间距、海报比例与卡片
    // 复用 [DramaTile]，与目录 / 追剧网格同一套视觉（圆角 12、比例 0.65、
    // hover 描边），不再维护第二张搜索卡。
    final columns = math.max(2, (width / 180).floor());
    final tileWidth = Md3Grid.tileWidth(width, columns);
    return SliverGrid.builder(
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        crossAxisSpacing: Md3Grid.spacing,
        mainAxisSpacing: Md3Grid.rowSpacing,
        mainAxisExtent: DramaTile.extentFor(context, tileWidth, withMeta: true),
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final drama = items[index];
        final year = drama.onlineDate.length >= 4
            ? drama.onlineDate.substring(0, 4)
            : '';
        final meta = [
          if (drama.episodes > 0) '${drama.episodes} 集',
          if (year.isNotEmpty) year,
        ].join(' · ');
        return DramaTile(
          drama: drama,
          repository: widget.repository,
          subtitle: meta.isEmpty ? null : meta,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => DetailScreen(
                drama: drama,
                repository: widget.repository,
                store: widget.store,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SearchLoadingState extends StatelessWidget {
  const _SearchLoadingState();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(
      vertical: Md3Spacing.xxxl,
      horizontal: Md3Spacing.lg,
    ),
    child: Column(
      children: [
        const AppLoadingIndicator(size: 40),
        const SizedBox(height: Md3Spacing.xl),
        Semantics(
          liveRegion: true,
          child: Text(
            AppLocalizations.of(context).searchingCatalog,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: Md3Type.titleMedium,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
      ],
    ),
  );
}
