import 'dart:async';

import 'package:flutter/material.dart';

import 'package:hoshi/ui/core/catalog_filters.dart';
import 'package:hoshi/ui/core/app_layout.dart';
import 'package:hoshi/data/app_contract.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/features/player/views/playback_launch_screen.dart';
import 'package:hoshi/ui/core/remote_widgets.dart';
import 'package:hoshi/ui/core/widgets.dart';
import 'package:hoshi/ui/theme/md3_tokens.dart';

class RecommendationsScreen extends StatefulWidget {
  const RecommendationsScreen({
    super.key,
    required this.repository,
    required this.store,
    this.embedded = false,
    this.gridKey,
    this.onExitLeft,
  });
  final AppRepository repository;
  final LocalStore store;
  final bool embedded;
  final GlobalKey<RemoteGridState>? gridKey;
  final VoidCallback? onExitLeft;

  @override
  State<RecommendationsScreen> createState() => _RecommendationsScreenState();
}

class _RecommendationsScreenState extends State<RecommendationsScreen> {
  List<CatalogCategory> _genres(AppLocalizations l10n) => [
    CatalogCategory('short_play', l10n.realDrama),
    CatalogCategory('comic_series', l10n.comicDrama),
    CatalogCategory('ai_series', l10n.aiDrama),
  ];
  final _scroll = ScrollController();
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
    _load();
  }

  @override
  void dispose() {
    _generation++;
    widget.repository.catalogUpdates.removeListener(_metadataChanged);
    unawaited(widget.repository.cancelRecommendations());
    _scroll.dispose();
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
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final refresh = RefreshAction(
      loading: _loading || _more,
      tooltip: l10n.refreshRecommendations,
      onPressed: () => _load(force: true),
    );
    final content = Column(
      children: [
        CatalogFilters(
          categories: _genres(l10n),
          category: _genre,
          onCategory: _select,
          onRetry: () => _load(force: true),
          onExitDown: () => widget.gridKey?.currentState?.focusCurrent(),
          trailing: widget.embedded ? refresh : null,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              l10n.recommendationLoaded(_items.length),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
        if (_loading && _items.isNotEmpty)
          const LinearProgressIndicator(minHeight: 2),
        if (_error != null && _items.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
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
                      : () => _load(more: _failedMore, force: !_failedMore),
                  child: Text(l10n.retry),
                ),
              ],
            ),
          ),
        Expanded(
          child: !widget.store.allowsSource('hongguo')
              ? StatusPanel(
                  title: l10n.recommendationNoPermission,
                  message: l10n.recommendationNoPermissionHint,
                )
              : _loading && _items.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _items.isEmpty
              ? StatusPanel(
                  title: _error == null
                      ? l10n.recommendationEmpty
                      : l10n.recommendationLoadFailed,
                  message: _error ?? l10n.recommendationLater,
                  onRetry: () => _load(force: true),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    if (AppLayout.isTelevision(context)) {
                      final grid = remoteGridLayout(
                        context,
                        constraints.maxWidth,
                      );
                      return RemoteGrid(
                        key: widget.gridKey,
                        itemKeys: _items.map((item) => item.id).toList(),
                        columns: grid.columns,
                        spacing: Md3Grid.spacing,
                        itemExtent: grid.itemExtent,
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(18, 2, 18, 18),
                        onExitLeft: widget.onExitLeft,
                        footer: Padding(
                          padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
                          child: Center(
                            child: _more
                                ? const CircularProgressIndicator()
                                : _hasMore
                                ? RemoteButton(
                                    label: l10n.recommendationMore,
                                    icon: Icons.auto_awesome_rounded,
                                    onPressed: () => _load(more: true),
                                  )
                                : RemoteButton(
                                    label: l10n.refreshForNew,
                                    icon: Icons.refresh_rounded,
                                    onPressed: () => _load(force: true),
                                  ),
                          ),
                        ),
                        itemBuilder: (_, index, node, onFocus) {
                          final drama = _items[index];
                          return DramaTile(
                            key: ValueKey(drama.id),
                            drama: drama,
                            repository: widget.repository,
                            focusNode: node,
                            onFocus: onFocus,
                            onTap: () => unawaited(
                              openPlaybackDirectly(
                                context,
                                drama: drama,
                                repository: widget.repository,
                                store: widget.store,
                              ),
                            ),
                          );
                        },
                      );
                    }
                    // 与目录页同一套宽度策略：留白由 contentInset 给出，
                    // 顶部不再叠一份额外间距，两个 feed 的首行位置对齐。
                    final padding = Md3Spacing.contentInset(
                      constraints.maxWidth,
                      maxWidth: Md3Spacing.wideMaxWidth,
                    );
                    return RefreshIndicator(
                      onRefresh: () => _load(force: true),
                      child: CustomScrollView(
                        controller: _scroll,
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
                              delegate: SliverChildBuilderDelegate((
                                context,
                                index,
                              ) {
                                final drama = _items[index];
                                return DramaTile(
                                  key: ValueKey(drama.id),
                                  drama: drama,
                                  repository: widget.repository,
                                  onTap: () => unawaited(
                                    openPlaybackDirectly(
                                      context,
                                      drama: drama,
                                      repository: widget.repository,
                                      store: widget.store,
                                    ),
                                  ),
                                );
                              }, childCount: _items.length),
                            ),
                          ),
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                              child: Center(
                                child: _more
                                    ? const CircularProgressIndicator()
                                    : _hasMore
                                    ? OutlinedButton.icon(
                                        onPressed: () => _load(more: true),
                                        icon: const Icon(
                                          Icons.auto_awesome_rounded,
                                        ),
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
                      ),
                    );
                  },
                ),
        ),
      ],
    );
    if (widget.embedded) return content;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.recommendationTitle), actions: [refresh]),
      body: SafeArea(top: false, child: content),
    );
  }
}
