import 'dart:async';

import 'package:flutter/material.dart';

import 'package:hoshi/ui/core/catalog_filters.dart';
import 'package:hoshi/data/app_contract.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/features/detail/views/detail_screen.dart';
import 'package:hoshi/ui/core/widgets.dart';
import 'package:hoshi/ui/core/empty_state.dart';
import 'package:hoshi/ui/theme/md3_tokens.dart';

/// 推荐流：作为目录 `CustomScrollView` 的一组 sliver 存在。
///
/// 改造前它自带 `Scaffold + AppBar + ScrollController`，选中「推荐」分类
/// 时整页会换成另一条滚动视图——标题栏、分类栏与网格分属两层，滚动位置
/// 与回顶都不连续。现在它只产出 slivers，滚动、下拉刷新与分页都由宿主
/// 那条 `CustomScrollView` 统一承担。
class RecommendationsSlivers extends StatefulWidget {
  const RecommendationsSlivers({
    super.key,
    required this.repository,
    required this.store,
    required this.scrollController,
    this.showFilters = true,
  });

  final AppRepository repository;
  final LocalStore store;

  /// 宿主滚动视图的控制器：分页监听与「换分类回顶」都挂在它上面。
  final ScrollController scrollController;

  /// 是否渲染「真人 / 漫剧 / AI 剧」分类栏。宿主自带分类栏时由宿主决定。
  final bool showFilters;

  @override
  State<RecommendationsSlivers> createState() => RecommendationsSliversState();
}

class RecommendationsSliversState extends State<RecommendationsSlivers> {
  List<CatalogCategory> _genres(AppLocalizations l10n) => [
    CatalogCategory('short_play', l10n.realDrama),
    CatalogCategory('comic_series', l10n.comicDrama),
    CatalogCategory('ai_series', l10n.aiDrama),
  ];
  String _genre = 'short_play';
  List<Drama> _items = [];
  bool _loading = false;
  bool _more = false;
  bool _hasMore = true;
  bool _failedMore = false;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    widget.repository.catalogUpdates.addListener(_metadataChanged);
    widget.scrollController.addListener(_onScroll);
    _load();
  }

  @override
  void didUpdateWidget(covariant RecommendationsSlivers oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollController != widget.scrollController) {
      oldWidget.scrollController.removeListener(_onScroll);
      widget.scrollController.addListener(_onScroll);
    }
    if (oldWidget.repository != widget.repository) {
      oldWidget.repository.catalogUpdates.removeListener(_metadataChanged);
      widget.repository.catalogUpdates.addListener(_metadataChanged);
    }
  }

  @override
  void dispose() {
    widget.scrollController.removeListener(_onScroll);
    widget.repository.catalogUpdates.removeListener(_metadataChanged);
    _generation++;
    unawaited(widget.repository.cancelRecommendations());
    super.dispose();
  }

  void _metadataChanged() {
    final drama = widget.repository.catalogUpdates.latest;
    if (!mounted || drama == null) return;
    setState(() {
      _items = [
        for (final item in _items)
          item.id == drama.id ? item.merge(drama) : item,
      ];
    });
  }

  /// 宿主滚到底部附近时自动取下一页，替代原来的内层 `_scroll` 监听。
  void _onScroll() {
    if (!mounted ||
        _loading ||
        _more ||
        !_hasMore ||
        !widget.scrollController.hasClients) {
      return;
    }
    if (widget.scrollController.position.extentAfter < 600) {
      unawaited(_load(more: true));
    }
  }

  /// 下拉刷新入口，供宿主 `RefreshIndicator` 调用。
  Future<void> refresh() => _load(force: true);

  Future<void> _load({bool more = false, bool force = false}) async {
    if (more && (_loading || _more || !_hasMore)) return;
    final generation = ++_generation;
    final genre = _genre;
    setState(() {
      _loading = !more;
      _more = more;
      _error = null;
      _failedMore = more;
    });
    try {
      await widget.repository.cancelRecommendations();
      if (!mounted || generation != _generation) return;
      final page = await widget.repository.recommendations(
        genre,
        more: more,
        force: force,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = page.items;
        _hasMore = page.hasMore;
        _error = page.warning.isEmpty ? null : page.warning;
        _loading = _more = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = _more = false;
        _error = error.toString();
      });
    }
  }

  void _select(String genre) {
    if (_genre == genre) return;
    setState(() {
      _genre = genre;
      _items = [];
      _hasMore = true;
    });
    // 推荐流与目录共用一条滚动视图；换分类后回到顶部才看得到新首屏。
    if (widget.scrollController.hasClients) widget.scrollController.jumpTo(0);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final l10n = AppLocalizations.of(context);
        final width = constraints.crossAxisExtent;
        final padding = Md3Spacing.contentInset(
          width,
          maxWidth: Md3Spacing.wideMaxWidth,
        );
        return SliverMainAxisGroup(
          slivers: [
            if (widget.showFilters)
              SliverToBoxAdapter(
                child: CatalogFilters(
                  categories: _genres(l10n),
                  category: _genre,
                  onCategory: _select,
                  onRetry: () => _load(force: true),
                  trailing: RefreshAction(
                    loading: _loading || _more,
                    tooltip: l10n.refreshRecommendations,
                    onPressed: () => _load(force: true),
                  ),
                ),
              ),
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(padding, 0, padding, 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    l10n.recommendationLoaded(_items.length),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
            ),
            if (_loading && _items.isNotEmpty)
              const SliverToBoxAdapter(
                child: LinearProgressIndicator(minHeight: 2),
              ),
            if (_error != null && _items.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: padding),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: _loading || _more
                            ? null
                            : () =>
                                  _load(more: _failedMore, force: !_failedMore),
                        child: Text(l10n.retry),
                      ),
                    ],
                  ),
                ),
              ),
            if (!widget.store.allowsSource('hongguo'))
              SliverFillRemaining(
                hasScrollBody: false,
                child: StatusPanel(
                  title: l10n.recommendationNoPermission,
                  message: l10n.recommendationNoPermissionHint,
                ),
              )
            else if (_loading && _items.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.all(Md3Spacing.xxl),
                    child: AppLoadingIndicator(),
                  ),
                ),
              )
            else if (_items.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: StatusPanel(
                  title: _error == null
                      ? l10n.recommendationEmpty
                      : l10n.recommendationLoadFailed,
                  message: _error ?? l10n.recommendationLater,
                  onRetry: () => _load(force: true),
                ),
              )
            else ...[
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  padding,
                  0,
                  padding,
                  Md3Spacing.lg,
                ),
                sliver: SliverGrid(
                  gridDelegate: dramaGridDelegate(context, width - 2 * padding),
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final drama = _items[index];
                    return DramaTile(
                      key: ValueKey(drama.id),
                      drama: drama,
                      repository: widget.repository,
                      onTap: () {
                        unawaited(
                          Navigator.of(context).push(
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
                  }, childCount: _items.length),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    padding,
                    0,
                    padding,
                    Md3Spacing.xl,
                  ),
                  child: Center(
                    child: _more
                        ? const AppLoadingIndicator(size: 24)
                        : _hasMore
                        ? OutlinedButton.icon(
                            onPressed: () => _load(more: true),
                            icon: const Icon(Icons.auto_awesome_rounded),
                            label: Text(l10n.recommendationMore),
                          )
                        : TextButton(
                            onPressed: () => _load(force: true),
                            child: Text(l10n.recommendationEnded),
                          ),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
