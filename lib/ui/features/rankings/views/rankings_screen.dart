import 'package:flutter/material.dart';

import 'package:hoshi/ui/core/catalog_filters.dart';
import 'package:hoshi/data/app_contract.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/domain/ranking_models.dart';
import 'package:hoshi/ui/features/rankings/controllers/rankings_controller.dart';
import 'package:hoshi/ui/features/detail/views/detail_screen.dart';
import 'package:hoshi/ui/core/widgets.dart';
import 'package:hoshi/ui/core/empty_state.dart';
import 'package:hoshi/ui/core/surfaces.dart';
import 'package:hoshi/ui/theme/md3_tokens.dart';

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
          title: AppMenuButton(
            enabled: groups.length > 1,
            menuChildren: [
              for (final group in groups)
                AppMenuItem(
                  label: group.name,
                  selected: _controller.board?.groupId == group.id,
                  onPressed: () => _select(
                    _controller.boards.firstWhere(
                      (board) => board.groupId == group.id,
                    ),
                  ),
                ),
            ],
            builder: (context, toggle, open) => Tooltip(
              message: l10n.switchRankingSource,
              child: InkWell(
                onTap: toggle,
                borderRadius: BorderRadius.circular(Md3Shape.small),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Md3Spacing.xs,
                    vertical: Md3Spacing.xxs,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _controller.board == null
                            ? l10n.rankingsTitle
                            : '${SourceSite.byId(_controller.board!.source).groupName}${l10n.rankingsTitle}',
                      ),
                      if (groups.length > 1)
                        AnimatedRotation(
                          turns: open ? .5 : 0,
                          duration: Md3Motion.of(context, Md3Motion.standard),
                          child: const Icon(Icons.expand_more_rounded),
                        ),
                    ],
                  ),
                ),
              ),
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
                            const AppLoadingIndicator(),
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
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          // 榜单沿用目录的响应式海报网格（手机 3 列），
                          // 不再做单列排行或宽屏双列——Q14 已定。
                          final padding = Md3Spacing.contentInset(
                            constraints.maxWidth,
                            maxWidth: Md3Spacing.wideMaxWidth,
                          );
                          final contentWidth =
                              constraints.maxWidth - 2 * padding;
                          final withMeta = items.any(
                            (item) => item.metric.isNotEmpty,
                          );
                          return RefreshIndicator(
                            onRefresh: () => _controller.load(force: true),
                            child: CustomScrollView(
                              key: ValueKey('ranking-${_controller.board!.id}'),
                              controller: _scroll,
                              physics: const AlwaysScrollableScrollPhysics(),
                              slivers: [
                                SliverPadding(
                                  padding: EdgeInsets.fromLTRB(
                                    padding,
                                    0,
                                    padding,
                                    8,
                                  ),
                                  sliver: SliverGrid(
                                    gridDelegate: dramaGridDelegate(
                                      context,
                                      contentWidth,
                                      withMeta: withMeta,
                                    ),
                                    delegate: SliverChildBuilderDelegate(
                                      (context, index) =>
                                          _rankCard(items[index]),
                                      childCount: items.length,
                                    ),
                                  ),
                                ),
                                SliverToBoxAdapter(
                                  child: Center(
                                    child: _controller.more
                                        ? const Padding(
                                            padding: EdgeInsets.all(16),
                                            child: AppLoadingIndicator(),
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
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      );
    },
  );

  Widget _rankCard(RankingItem item) {
    void open() {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => DetailScreen(
            drama: item.drama,
            repository: widget.repository,
            store: widget.store,
          ),
        ),
      );
    }

    final colors = Theme.of(context).colorScheme;
    final top = item.rank <= 3;
    return Stack(
      children: [
        DramaTile(
          drama: item.drama,
          repository: widget.repository,
          onTap: open,
          subtitle: item.metric.isEmpty ? null : item.metric,
        ),
        Positioned(
          left: 8,
          top: 8,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: top ? colors.primary : colors.surfaceContainerHighest,
              borderRadius: Md3Shape.chip,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text(
                '${item.rank}',
                style: TextStyle(
                  fontSize: Md3Type.labelLarge,
                  fontWeight: FontWeight.w800,
                  color: top ? colors.onPrimary : colors.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
