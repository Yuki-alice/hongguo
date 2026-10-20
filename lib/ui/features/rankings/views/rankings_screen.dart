import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:duanju_app/ui/core/app_layout.dart';
import 'package:duanju_app/ui/core/catalog_filters.dart';
import 'package:duanju_app/data/core_bridge.dart';
import 'package:duanju_app/data/local_store.dart';
import 'package:duanju_app/domain/models.dart';
import 'package:duanju_app/l10n/generated/app_localizations.dart';
import 'package:duanju_app/domain/ranking_models.dart';
import 'package:duanju_app/ui/core/remote_widgets.dart';
import 'package:duanju_app/ui/features/rankings/controllers/rankings_controller.dart';
import 'package:duanju_app/ui/routing/app_router.dart';
import 'package:duanju_app/ui/routing/route_args.dart';
import 'package:duanju_app/ui/core/widgets.dart';

class RankingsScreen extends StatefulWidget {
  const RankingsScreen({
    super.key,
    required this.repository,
    required this.store,
    required this.initialGroup,
  });
  final AppRepository repository;
  final LocalStore store;
  final String initialGroup;

  @override
  State<RankingsScreen> createState() => _RankingsScreenState();
}

class _RankingsScreenState extends State<RankingsScreen> {
  final _scroll = ScrollController();
  final _boardsKey = GlobalKey<RemoteRowState>();
  final _listKey = GlobalKey<RemoteListState>();
  late final RankingsController _controller;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _controller = RankingsController(
      repository: widget.repository,
      store: widget.store,
      initialGroup: widget.initialGroup,
    );
    _controller.initialize();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_controller.hasMore ||
        _controller.loading ||
        _controller.more ||
        !_scroll.hasClients) {
      return;
    }
    final position = _scroll.position;
    final threshold = (position.viewportDimension * 1.2).clamp(260.0, 720.0);
    if (position.extentAfter <= threshold) {
      _controller.load(more: true);
    }
  }

  void _select(RankingBoard board) {
    _controller.select(board);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      final l10n = AppLocalizations.of(context);
      final television = AppLayout.isTelevision(context);
      final groups = SourceGroup.fromSources(
        _controller.boards
            .map((board) => SourceSite.byId(board.source))
            .toSet(),
      );
      final boards = _controller.boards
          .where((board) => board.groupId == _controller.board?.groupId)
          .toList();
      final items = _controller.items
          .map(
            (item) => RankingItem(
              item.rank,
              widget.repository.catalogUpdates.current(item.drama),
              metric: item.metric,
            ),
          )
          .where(
            (item) =>
                widget.store.allowsSource(item.drama.source) &&
                !(item.drama.source == 'huangdou' &&
                    widget.store.hideVip &&
                    item.drama.vip),
          )
          .toList();
      return Scaffold(
        appBar: AppBar(
          title: PopupMenuButton<SourceGroup>(
            tooltip: l10n.switchRankingSource,
            enabled: groups.length > 1,
            onSelected: (group) => _select(
              _controller.boards.firstWhere(
                (board) => board.groupId == group.id,
              ),
            ),
            itemBuilder: (_) => [
              for (final group in groups)
                PopupMenuItem(value: group, child: Text(group.name)),
            ],
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _controller.board == null
                      ? l10n.rankingsTitle
                      : '${SourceSite.byId(_controller.board!.source).groupName}${l10n.rankingsTitle}',
                ),
                if (groups.length > 1) const Icon(Icons.expand_more_rounded),
              ],
            ),
          ),
          actions: [
            RefreshAction(
              loading: _controller.loading || _controller.more,
              tooltip: l10n.refreshRankings,
              onPressed: _controller.board == null
                  ? _controller.initialize
                  : () => _controller.load(force: true),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              if (boards.isNotEmpty)
                CatalogFilters(
                  key: ValueKey('ranking-boards-${_controller.board!.groupId}'),
                  categories: [
                    for (final board in boards)
                      CatalogCategory(board.id, board.name),
                  ],
                  category: _controller.board!.id,
                  remoteKey: _boardsKey,
                  remoteAutofocus: television,
                  onExitDown: television
                      ? () => _listKey.currentState?.focusCurrent()
                      : null,
                  onCategory: (id) =>
                      _select(boards.firstWhere((board) => board.id == id)),
                  onRetry: () => _controller.load(force: true),
                ),
              if (_controller.board != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      [
                        _controller.board!.description,
                        if (_controller.updated.isNotEmpty) _controller.updated,
                      ].join(' '),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
              if (_controller.loading && items.isNotEmpty)
                const LinearProgressIndicator(minHeight: 2),
              if (_controller.error != null && items.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _controller.error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: _controller.loading || _controller.more
                            ? null
                            : () => _controller.load(
                                more: _controller.failedMore,
                                force: true,
                              ),
                        child: Text(l10n.retry),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: _controller.loading && items.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CircularProgressIndicator(),
                            if (_controller.board?.source == 'hongguo') ...[
                              const SizedBox(height: 16),
                              Text(l10n.rankingsLoadingHint),
                            ],
                          ],
                        ),
                      )
                    : items.isEmpty
                    ? StatusPanel(
                        title: _controller.error == null
                            ? l10n.noRankings
                            : l10n.rankingsLoadFailed,
                        message: _controller.error ?? l10n.noRankingsHint,
                        onRetry: _controller.board == null
                            ? _controller.initialize
                            : () => _controller.load(force: true),
                      )
                    : television
                    ? RemoteList(
                        key: _listKey,
                        itemKeys: [
                          for (final item in items)
                            '${item.rank}-${item.drama.id}',
                        ],
                        itemExtent: 140,
                        spacing: 10,
                        controller: _scroll,
                        onExitUp: () => _boardsKey.currentState?.focusCurrent(),
                        itemBuilder: (_, index, node, onFocus) => _rankTile(
                          items[index],
                          focusNode: node,
                          onFocus: onFocus,
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: () => _controller.load(force: true),
                        child: ListView.builder(
                          key: ValueKey('ranking-${_controller.board!.id}'),
                          controller: _scroll,
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                          itemCount: items.length + 1,
                          itemBuilder: (context, index) {
                            if (index == items.length) {
                              return Center(
                                child: _controller.more
                                    ? const Padding(
                                        padding: EdgeInsets.all(16),
                                        child: CircularProgressIndicator(),
                                      )
                                    : _controller.hasMore
                                    ? OutlinedButton(
                                        onPressed: () =>
                                            _controller.load(more: true),
                                        child: Text(l10n.loadMore),
                                      )
                                    : Padding(
                                        padding: const EdgeInsets.all(16),
                                        child: Text(l10n.allRankingsShown),
                                      ),
                              );
                            }
                            return _rankTile(items[index]);
                          },
                        ),
                      ),
              ),
            ],
          ),
        ),
      );
    },
  );

  Widget _rankTile(
    RankingItem item, {
    FocusNode? focusNode,
    VoidCallback? onFocus,
  }) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    void open() {
      final ref = DramaRef.fromDramaId(item.drama.id);
      if (ref == null) return;
      context.push(AppRoutes.detailOf(ref), extra: item.drama);
    }

    final body = Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          SizedBox(
            width: 36,
            child: Text(
              '${item.rank}',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w800,
                color: item.rank <= 3
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          SizedBox(
            width: 72,
            height: 108,
            child: DramaCover(
              drama: item.drama,
              repository: widget.repository,
              radius: 8,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.drama.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
                if (item.drama.category.isNotEmpty)
                  Text(
                    item.drama.category,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                if (item.metric.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      item.metric,
                      style: TextStyle(color: theme.colorScheme.primary),
                    ),
                  ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded),
        ],
      ),
    );
    if (focusNode == null && onFocus == null) {
      return Builder(
        builder: (itemContext) => Card(
          child: InkWell(
            key: ValueKey('rank-${item.rank}-${item.drama.id}'),
            borderRadius: BorderRadius.circular(12),
            onFocusChange: (focused) {
              if (focused) {
                Scrollable.ensureVisible(itemContext, alignment: .4);
              }
            },
            onTap: open,
            child: body,
          ),
        ),
      );
    }
    return RemoteTarget(
      key: ValueKey('rank-${item.rank}-${item.drama.id}'),
      focusNode: focusNode,
      onFocus: onFocus,
      outlined: true,
      borderWidth: 2,
      radius: 12,
      padding: EdgeInsets.zero,
      onPressed: open,
      label: l10n.rankLabel(
        item.rank,
        item.drama.title,
        item.metric.isEmpty ? '' : '，${item.metric}',
      ),
      child: Card(margin: EdgeInsets.zero, child: body),
    );
  }
}
