import 'package:flutter/material.dart';

import 'package:hoshi/ui/core/app_layout.dart';
import 'package:hoshi/domain/catalog_sort.dart';
import 'package:hoshi/data/app_contract.dart';
import 'package:hoshi/ui/core/drama_actions.dart';
import 'package:hoshi/domain/follow_state.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/core/remote_widgets.dart';
import 'package:hoshi/ui/core/widgets.dart';

class SavedLibrary extends StatefulWidget {
  const SavedLibrary({
    super.key,
    required this.repository,
    required this.store,
    required this.history,
    required this.onOpen,
    required this.onContinue,
    this.onDownload,
    this.remoteAutofocus = false,
    this.onExitLeft,
    this.onExitUp,
  });

  final AppRepository repository;
  final LocalStore store;
  final bool history;
  final ValueChanged<Drama> onOpen;
  final ValueChanged<Drama> onContinue;
  final ValueChanged<Drama>? onDownload;
  final bool remoteAutofocus;
  final VoidCallback? onExitLeft;
  final VoidCallback? onExitUp;

  @override
  State<SavedLibrary> createState() => _SavedLibraryState();
}

class _SavedLibraryState extends State<SavedLibrary> {
  final _search = TextEditingController();
  String _filter = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _clearHistory() async {
    final epoch = widget.store.profileEpoch;
    final l10n = AppLocalizations.of(context);
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.clearHistoryTitle),
        content: Text(l10n.clearHistoryBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.clear),
          ),
        ],
      ),
    );
    if (accepted == true && mounted && epoch == widget.store.profileEpoch) {
      await saveUserChange(context, widget.store.clearHistory);
    }
  }

  void _actions(Drama drama) => showDramaActions(
    context,
    drama: drama,
    store: widget.store,
    history: widget.history,
    onContinue: () => widget.onContinue(drama),
    onDownload: widget.onDownload == null
        ? null
        : () => widget.onDownload!(drama),
  );

  Widget _tile(
    Drama drama, {
    required AppLocalizations l10n,
    FocusNode? focusNode,
    VoidCallback? onFocus,
  }) {
    final watched = widget.store.watched(drama.id);
    final state = widget.store.following(drama.id);
    final badge = state == null ? null : _followBadge(state, l10n);
    return DramaTile(
      key: ValueKey('saved-${drama.id}'),
      drama: drama,
      repository: widget.repository,
      focusNode: focusNode,
      onFocus: onFocus,
      onTap: () => widget.onOpen(drama),
      onMore: () => _actions(drama),
      actions: DramaActionButton(
        drama: drama,
        onPressed: () => _actions(drama),
      ),
      badge: badge,
      subtitle: watched == null
          ? SourceSite.byId(drama.source).name
          : l10n.episodeProgress(
              watched.episode,
              formatPosition(watched.position),
            ),
    );
  }

  String _statusLabel(FollowStatus status, AppLocalizations l10n) =>
      switch (status) {
        FollowStatus.planned => l10n.followPlanned,
        FollowStatus.watching => l10n.followWatching,
        FollowStatus.watched => l10n.followWatched,
      };

  String _followBadge(FollowState state, AppLocalizations l10n) {
    final label = state.manuallyWatched
        ? l10n.followManual
        : _statusLabel(state.status, l10n);
    final updates = [
      if (state.newEpisodes > 0) l10n.followUpdateEpisodes(state.newEpisodes),
      if (state.newSeasons > 0) l10n.followUpdateSeasons(state.newSeasons),
    ];
    return updates.isEmpty ? label : '$label · ${updates.join(' · ')}';
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) {
      final l10n = AppLocalizations.of(context);
      final history = widget.store.history;
      final all = widget.history
          ? history.map((entry) => entry.drama).toList()
          : widget.store.favorites;
      final items = all.where((drama) {
        if (!matchesDramaQuery(drama, _search.text)) return false;
        final state = widget.store.following(drama.id);
        return widget.history ||
            _filter.isEmpty ||
            (_filter == 'updates'
                ? state?.hasUpdates == true
                : state?.status.name == _filter);
      }).toList();
      final ids = items.map((drama) => drama.id).toSet();
      final resume = history
          .where(
            (entry) =>
                ids.contains(entry.drama.id) &&
                (!entry.finished ||
                    entry.drama.episodes <= 0 ||
                    entry.episode < entry.drama.episodes),
          )
          .firstOrNull;
      final header = [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  l10n.savedHeader(
                    widget.history ? l10n.recentlyWatched : l10n.myFollows,
                    all.length,
                  ),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              if (widget.history && all.isNotEmpty)
                IconButton(
                  tooltip: l10n.clearHistoryTooltip,
                  onPressed: _clearHistory,
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            key: ValueKey(
              widget.history ? 'history-search' : 'favorites-search',
            ),
            controller: _search,
            onChanged: (_) => setState(() {}),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: widget.history
                  ? l10n.searchHistoryHint
                  : l10n.searchFollowsHint,
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: l10n.clearSearch,
                      onPressed: () => setState(_search.clear),
                      icon: const Icon(Icons.close_rounded),
                    ),
            ),
          ),
        ),
        if (!widget.history)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                for (final filter in [
                  ('', l10n.filterAll),
                  for (final status in FollowStatus.values)
                    (status.name, _statusLabel(status, l10n)),
                  ('updates', l10n.filterUpdates),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      key: ValueKey('follow-filter-${filter.$1}'),
                      label: Text(filter.$2),
                      selected: _filter == filter.$1,
                      onSelected: (_) => setState(() => _filter = filter.$1),
                    ),
                  ),
              ],
            ),
          ),
        if (resume != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                key: const ValueKey('continue-watching'),
                leading: const Icon(Icons.play_circle_outline),
                title: Text(
                  l10n.continueWatchingTitle(resume.drama.title),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  l10n.episodeProgress(
                    resume.episode,
                    formatPosition(resume.position),
                  ),
                ),
                onTap: () => widget.onContinue(resume.drama),
              ),
            ),
          ),
      ];
      final empty = StatusPanel(
        title: all.isEmpty
            ? widget.history
                  ? l10n.noHistory
                  : l10n.noFollows
            : l10n.noMatches,
        message: all.isEmpty ? l10n.emptyHistoryHint : l10n.emptyFilterHint,
        icon: widget.history
            ? Icons.history_rounded
            : Icons.bookmark_border_rounded,
      );
      return LayoutBuilder(
        builder: (context, constraints) {
          if (AppLayout.isTelevision(context)) {
            final columns = ((constraints.maxWidth - 36) / 150).floor().clamp(
              1,
              8,
            );
            final tileWidth =
                (constraints.maxWidth - 36 - (columns - 1) * 14) / columns;
            return Column(
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: constraints.maxHeight * .5,
                  ),
                  child: SingleChildScrollView(child: Column(children: header)),
                ),
                Expanded(
                  child: items.isEmpty
                      ? empty
                      : RemoteGrid(
                          key: ValueKey(
                            'saved-tv-${widget.history}-$_filter-${_search.text}',
                          ),
                          itemKeys: items.map((item) => item.id).toList(),
                          columns: columns,
                          itemExtent:
                              DramaTile.extentFor(context, tileWidth - 14) + 14,
                          autofocus: widget.remoteAutofocus,
                          onExitLeft: widget.onExitLeft,
                          onExitUp: widget.onExitUp,
                          itemBuilder: (_, index, node, onFocus) => _tile(
                            items[index],
                            l10n: l10n,
                            focusNode: node,
                            onFocus: onFocus,
                          ),
                        ),
                ),
              ],
            );
          }
          final padding = constraints.maxWidth < 600 ? 16.0 : 24.0;
          return CustomScrollView(
            key: PageStorageKey(
              'saved-${widget.history}-$_filter-${_search.text}',
            ),
            slivers: [
              SliverToBoxAdapter(child: Column(children: header)),
              if (items.isEmpty)
                SliverFillRemaining(hasScrollBody: false, child: empty)
              else
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(padding, 0, padding, 20),
                  sliver: SliverGrid(
                    gridDelegate: dramaGridDelegate(
                      context,
                      constraints.maxWidth - 2 * padding,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (_, index) => _tile(items[index], l10n: l10n),
                      childCount: items.length,
                    ),
                  ),
                ),
            ],
          );
        },
      );
    },
  );
}
