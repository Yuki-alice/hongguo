import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import 'package:hoshi/data/app_contract.dart';
import 'package:hoshi/domain/download_collections.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/features/settings/views/settings_screen.dart';
import 'package:hoshi/ui/features/downloads/controllers/downloads_controller.dart';
import 'package:hoshi/ui/routing/app_router.dart';
import 'package:hoshi/ui/routing/route_args.dart';
import 'package:hoshi/ui/core/empty_state.dart';
import 'package:hoshi/ui/core/adaptive_sheet.dart';
import 'package:hoshi/ui/core/surfaces.dart';
import 'package:hoshi/ui/core/widgets.dart';
import 'package:hoshi/ui/theme/md3_tokens.dart';

class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({
    super.key,
    required this.repository,
    required this.store,
    this.embedded = false,
    this.playerBuilder,
  });
  final AppRepository repository;
  final LocalStore store;
  final bool embedded;
  @visibleForTesting
  final Widget Function(DramaDetail, int, double)? playerBuilder;
  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  /// 每行「更多」菜单的外置控制器：右键与菜单按钮共用同一个弹出位置。
  final _menuControllers = <String, MenuController>{};

  MenuController _menuControllerFor(String id) =>
      _menuControllers.putIfAbsent(id, MenuController.new);

  AppLocalizations get l10n => AppLocalizations.of(context);
  final _search = TextEditingController();
  late DownloadsController _controller;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _attachController();
  }

  @override
  void didUpdateWidget(covariant DownloadsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository ||
        oldWidget.store != widget.store) {
      _detachController();
      _attachController();
    }
  }

  void _attachController() {
    _controller = DownloadsController(
      repository: widget.repository,
      store: widget.store,
    )..addListener(_changed);
  }

  void _detachController() {
    _controller.removeListener(_changed);
    _controller.dispose();
  }

  void _changed() {
    if (!mounted) return;
    final message = _controller.takeMessage();
    if (message != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
    setState(() {});
  }

  @override
  void dispose() {
    _detachController();
    _search.dispose();
    super.dispose();
  }

  Future<void> _refresh() => _controller.refresh();

  Future<void> _batch(String command, Iterable<DownloadJob> source) async {
    if (_controller.busy || !_controller.allowed) return;
    if (command == 'remove') {
      final jobs = _controller.targets(command, source);
      if (jobs.isEmpty) {
        await _controller.batch(command, source);
        return;
      }
      final completed = jobs.where((job) => job.completed).length;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            completed > 0
                ? l10n.deleteSelectedVideos
                : l10n.cancelSelectedDownloads,
          ),
          content: Text(
            l10n.confirmRemoveBody(
              jobs.length,
              completed > 0 ? l10n.completedIncluded(completed) : '',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.keep),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.confirmDelete),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted || !_controller.allowed) return;
    }
    await _controller.batch(command, source);
  }

  Future<void> _update(Drama drama) => _controller.updateCollection(drama);

  Future<void> _play(DownloadJob job) async {
    if (_opening || !_controller.allowed) return;
    _opening = true;
    final completed =
        _controller.jobs
            .where((entry) => entry.completed && entry.drama.id == job.drama.id)
            .toList()
          ..sort((a, b) => a.episode.number.compareTo(b.episode.number));
    final index = completed.indexWhere((entry) => entry.id == job.id);
    if (index < 0) {
      _opening = false;
      return;
    }
    final detail = DramaDetail(
      job.drama,
      completed.map((entry) => entry.episode).toList(),
    );
    final watch = widget.store.watched(job.drama.id);
    final position = watch?.episode == job.episode.number && !watch!.finished
        ? watch.position
        : 0.0;
    final ref = DramaRef.fromDramaId(job.drama.id);
    if (ref == null) {
      _opening = false;
      return;
    }
    try {
      // 本地已下载内容只依赖本地文件，播放时不再请求详情。
      await context.push(
        AppRoutes.playerOf(ref),
        extra: PlayerRouteExtra(
          detail: detail,
          initialIndex: index,
          initialPosition: position,
          localOnly: true,
          playerBuilder: widget.playerBuilder,
        ),
      );
    } finally {
      _opening = false;
      if (mounted) await _refresh();
    }
  }

  void _select(Iterable<DownloadJob> jobs) => _controller.select(jobs);

  Future<void> _filters() async {
    var state = _controller.filter, release = _controller.release;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, change) => AlertDialog(
          title: Text(l10n.filterDownloads),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.taskStatus),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final entry in {
                        'all': l10n.filterAllTasks,
                        'pending': l10n.filterPending,
                        'active': l10n.filterActive,
                        'paused': l10n.filterPaused,
                        'failed': l10n.filterFailed,
                        'completed': l10n.downloadedState,
                        'archived': l10n.archivedVideos,
                      }.entries)
                        ChoiceChip(
                          label: Text(entry.value),
                          selected: state == entry.key,
                          onSelected: (_) => change(() => state = entry.key),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Text(l10n.episodeStatusFilter),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final entry in {
                        '': l10n.filterAll,
                        'ongoing': l10n.releaseOngoing,
                        'finished': l10n.releaseFinished,
                      }.entries)
                        ChoiceChip(
                          label: Text(entry.value),
                          selected: release == entry.key,
                          onSelected: (_) => change(() => release = entry.key),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.apply),
            ),
          ],
        ),
      ),
    );
    if (result == true && mounted) {
      _controller.applyFilters(filter: state, release: release);
    }
  }

  List<Widget> _titleActions(List<DownloadCollection> collections) => [
    if (_controller.selecting) ...[
      IconButton(
        tooltip: l10n.selectAllCurrent,
        onPressed: _controller.busy
            ? null
            : () => _select(collections.expand((c) => c.jobs)),
        icon: const Icon(Icons.select_all_rounded),
      ),
      IconButton(
        tooltip: l10n.exitSelection,
        onPressed: _controller.busy ? null : _controller.exitSelecting,
        icon: const Icon(Icons.close_rounded),
      ),
    ] else ...[
      IconButton(
        tooltip: l10n.filterDownloads,
        onPressed: _filters,
        icon: Badge(
          isLabelVisible:
              _controller.filter != 'all' || _controller.release.isNotEmpty,
          child: const Icon(Icons.filter_list_rounded),
        ),
      ),
      IconButton(
        tooltip: l10n.multiSelectDownloads,
        onPressed: _controller.startSelecting,
        icon: const Icon(Icons.checklist_rounded),
      ),
      IconButton(
        key: const ValueKey('download-local-media'),
        tooltip: l10n.localMediaMerge,
        onPressed: () => context.push(AppRoutes.localMedia),
        icon: const Icon(Icons.video_library_outlined),
      ),
    ],
    AppMenuButton(
      key: const ValueKey('download-queue-actions'),
      enabled: !_controller.busy,
      menuChildren: [
        AppMenuItem(
          label: l10n.pauseAll,
          onPressed: () => _batch('pause', _controller.jobs),
        ),
        AppMenuItem(
          label: l10n.resumeAll,
          onPressed: () => _batch('resume', _controller.jobs),
        ),
        AppMenuItem(
          label: l10n.archiveCompleted,
          onPressed: () => _batch('archive', _controller.jobs),
        ),
        AppMenuItem(label: l10n.refreshRecords, onPressed: _refresh),
      ],
      builder: (context, toggle, open) => IconButton(
        tooltip: l10n.queueActions,
        onPressed: toggle,
        icon: const Icon(Icons.more_vert_rounded),
      ),
    ),
  ];

  /// 宽窗口主从布局。
  ///
  /// 左列固定 360：合集列表（标题 + 进度摘要）。右列是选中合集的剧集
  /// 明细，没有选中时提示从左侧选一部。
  ///
  /// 复用 `_expanded` 作为「当前选中」：这样手机上「展开」与桌面上
  /// 「选中」是同一个状态，切窗口尺寸时不会丢失上下文。
  Widget _masterDetail(double width, List<DownloadCollection> collections) {
    final l10n = AppLocalizations.of(context);
    final selectedId = _controller.expanded.length == 1
        ? _controller.expanded.first
        : null;
    final selected = collections
        .where((collection) => collection.drama.id == selectedId)
        .firstOrNull;
    final masterWidth = (Md3Spacing.detailPaneWidth + Md3Spacing.xl).clamp(
      300.0,
      420.0,
    );
    // 主从区域整体受页面留白与最大宽度约束：在 1600 宽下不把两栏拉散。
    final inset = Md3Spacing.contentInset(
      width,
      maxWidth: Md3Spacing.wideMaxWidth,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: inset),
        SizedBox(
          width: masterWidth,
          child: ListView.builder(
            padding: EdgeInsets.fromLTRB(
              0,
              Md3Spacing.xs,
              Md3Spacing.sm,
              Md3Spacing.xl,
            ),
            itemCount: collections.length,
            itemBuilder: (context, index) {
              final collection = collections[index];
              return Padding(
                padding: const EdgeInsets.only(bottom: Md3Spacing.sm),
                child: _collection(
                  collection,
                  selected: collection.drama.id == selectedId,
                  compact: true,
                ),
              );
            },
          ),
        ),
        VerticalDivider(
          width: 1,
          thickness: 1,
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
        Expanded(
          child: selected == null
              ? EmptyState(
                  title: l10n.downloadsPickCollection,
                  message: l10n.downloadsPickCollectionHint,
                  icon: Icons.download_done_rounded,
                  compact: true,
                )
              : _collectionDetail(selected, width, inset),
        ),
        SizedBox(width: inset),
      ],
    );
  }

  /// 右列：选中合集的标题栏 + 剧集列表。
  Widget _collectionDetail(
    DownloadCollection collection,
    double width,
    double inset,
  ) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            inset,
            Md3Spacing.md,
            inset,
            Md3Spacing.sm,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      collection.drama.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: Md3Type.titleMedium,
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: Md3Spacing.xxs),
                    Text(
                      l10n.collectionDownloadedRatio(
                        collection.completed,
                        collection.jobs.length,
                        storageSize(collection.bytes, l10n),
                      ),
                      style: TextStyle(
                        fontSize: Md3Type.bodySmall,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: l10n.collectionActions(collection.drama.title),
                onPressed: _controller.busy
                    ? null
                    : () => _collectionActions(collection),
                icon: const Icon(Icons.more_horiz_rounded),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            padding: EdgeInsets.fromLTRB(
              inset,
              Md3Spacing.sm,
              inset,
              Md3Spacing.xl,
            ),
            itemCount: collection.jobs.length,
            itemBuilder: (context, index) => _episode(collection.jobs[index]),
          ),
        ),
      ],
    );
  }

  Widget _collection(
    DownloadCollection collection, {
    bool selected = false,
    bool compact = false,
  }) {
    final count = collection.jobs
        .where((job) => _controller.selected.contains(job.id))
        .length;
    final expanded = _controller.expanded.contains(collection.drama.id);
    final highlighted = compact && selected;
    final colors = Theme.of(context).colorScheme;
    final menuController = _menuControllerFor(
      'collection-${collection.drama.id}',
    );
    return TonalCard(
      color: highlighted ? colors.secondaryContainer : null,
      child: GestureDetector(
        onSecondaryTap: _controller.busy ? null : () => menuController.open(),
        child: ListTile(
          selected: highlighted,
          contentPadding: compact
              ? const EdgeInsets.fromLTRB(
                  Md3Spacing.md,
                  Md3Spacing.xs,
                  Md3Spacing.xs,
                  Md3Spacing.xs,
                )
              : null,
          leading: _controller.selecting
              ? Checkbox(
                  tristate: true,
                  value: count == 0
                      ? false
                      : count == collection.jobs.length
                      ? true
                      : null,
                  onChanged: _controller.busy
                      ? null
                      : (_) => _select(collection.jobs),
                )
              : Icon(
                  expanded ? Icons.folder_open_rounded : Icons.folder_rounded,
                  color: highlighted ? colors.onSecondaryContainer : null,
                ),
          title: Text(
            collection.drama.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            '${l10n.collectionDownloadedRatio(collection.completed, collection.jobs.length, storageSize(collection.bytes, l10n))}'
            '${collection.active > 0 ? l10n.collectionActive(collection.active) : ''}'
            '${collection.failed > 0 ? l10n.collectionFailed(collection.failed) : ''}',
          ),
          onTap: () => _controller.toggleExpanded(collection.drama.id),
          trailing: AppMenuButton(
            key: ValueKey('collection-menu-${collection.drama.id}'),
            controller: menuController,
            enabled: !_controller.busy,
            menuChildren: [
              AppMenuItem(
                label: l10n.updateCollectionFull,
                onPressed: _controller.updater.busy
                    ? null
                    : () => _update(collection.drama),
              ),
              AppMenuItem(
                label: l10n.selectCollection,
                onPressed: () => _select(collection.jobs),
              ),
              AppMenuItem(
                label: l10n.pauseCollection,
                onPressed: () => _batch('pause', collection.jobs),
              ),
              AppMenuItem(
                label: l10n.resumeCollection,
                onPressed: () => _batch('resume', collection.jobs),
              ),
              AppMenuItem(
                label: l10n.archiveCompleted,
                onPressed: () => _batch('archive', collection.jobs),
              ),
              if (_controller.filter == 'archived')
                AppMenuItem(
                  label: l10n.restoreList,
                  onPressed: () => _batch('restore', collection.jobs),
                ),
              AppMenuItem(
                label: l10n.removeCollection,
                destructive: true,
                onPressed: () => _batch('remove', collection.jobs),
              ),
            ],
            builder: (context, toggle, open) => IconButton(
              tooltip: l10n.collectionActions(collection.drama.title),
              onPressed: toggle,
              icon: const Icon(Icons.more_vert_rounded),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _collectionActions(DownloadCollection collection) async {
    final value = await showAdaptiveSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final action in <(String, String, IconData, bool)>[
              (
                'update',
                l10n.updateDrama,
                Icons.cloud_download_rounded,
                !_controller.updater.busy,
              ),
              ('select', l10n.selectCollection, Icons.checklist_rounded, true),
              ('pause', l10n.pauseCollection, Icons.pause_rounded, true),
              ('resume', l10n.resumeCollection, Icons.play_arrow_rounded, true),
              ('archive', l10n.cleanupCompleted, Icons.archive_rounded, true),
              if (_controller.filter == 'archived')
                ('restore', l10n.restoreList, Icons.unarchive_rounded, true),
              (
                'remove',
                l10n.removeCollection,
                Icons.delete_outline_rounded,
                true,
              ),
            ])
              ListTile(
                key: ValueKey('collection-action-${action.$1}'),
                leading: Icon(action.$3),
                title: Text(action.$2),
                enabled: action.$4,
                onTap: action.$4
                    ? () => Navigator.pop(sheetContext, action.$1)
                    : null,
              ),
          ],
        ),
      ),
    );
    if (value == null || !mounted) return;
    if (value == 'update') {
      await _update(collection.drama);
    } else if (value == 'select') {
      _select(collection.jobs);
    } else {
      await _batch(value, collection.jobs);
    }
  }

  Widget _episode(DownloadJob job) => Padding(
    padding: const EdgeInsets.only(left: 12),
    child: TonalCard(
      key: ValueKey('download-task-${job.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            onSecondaryTap: _controller.busy
                ? null
                : () => _menuControllerFor('job-${job.id}').open(),
            child: ListTile(
              leading: _controller.selecting
                  ? Checkbox(
                      value: _controller.selected.contains(job.id),
                      onChanged: _controller.busy
                          ? null
                          : (_) => _select([job]),
                    )
                  : Icon(
                      job.completed
                          ? Icons.offline_pin_outlined
                          : job.state == 'failed'
                          ? Icons.error_outline
                          : Icons.downloading_rounded,
                    ),
              title: Text(
                job.episode.vip
                    ? l10n.episodeTitleVip(job.episode.number)
                    : l10n.episodeTitle(job.episode.number),
              ),
              subtitle: Text(
                '${job.archived ? l10n.archivedVideos : job.stateLabel} · ${storageSize(job.bytes, l10n)}'
                '${job.actualQuality > 0 ? ' · ${job.actualQuality}P' : ''}${job.error.isNotEmpty ? '\n${job.error}' : ''}',
              ),
              onTap: _controller.busy
                  ? null
                  : _controller.selecting
                  ? () => _select([job])
                  : job.completed
                  ? () => _play(job)
                  : null,
              trailing: _controller.selecting
                  ? null
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 进度环照参照应用：任务在下载或已有进度时给一圈，
                        // 比底部整条进度条更贴近「一张卡一个任务」的读法。
                        if (!job.completed && (job.active || job.progress > 0))
                          Padding(
                            padding: const EdgeInsets.only(
                              right: Md3Spacing.xs,
                            ),
                            child: SizedBox.square(
                              dimension: 22,
                              child: CircularProgressIndicator(
                                value: job.progress > 0
                                    ? job.progress
                                    : job.active
                                    ? null
                                    : 0,
                                strokeWidth: 2.5,
                              ),
                            ),
                          ),
                        AppMenuButton(
                          key: ValueKey('job-menu-${job.id}'),
                          controller: _menuControllerFor('job-${job.id}'),
                          enabled: !_controller.busy,
                          menuChildren: [
                            if (job.completed)
                              AppMenuItem(
                                label: l10n.localPlayback,
                                onPressed: () => _play(job),
                              ),
                            if (job.active)
                              AppMenuItem(
                                label: l10n.pause,
                                onPressed: () => _batch('pause', [job]),
                              ),
                            if (job.resumable)
                              AppMenuItem(
                                label: l10n.resumeRetry,
                                onPressed: () => _batch('resume', [job]),
                              ),
                            if (job.completed)
                              AppMenuItem(
                                label: job.archived
                                    ? l10n.restoreTask
                                    : l10n.cleanupTaskKeep,
                                onPressed: () => _batch(
                                  job.archived ? 'restore' : 'archive',
                                  [job],
                                ),
                              ),
                            AppMenuItem(
                              label: job.completed
                                  ? l10n.deleteVideo
                                  : l10n.cancelDownload,
                              destructive: true,
                              onPressed: () => _batch('remove', [job]),
                            ),
                          ],
                          builder: (context, toggle, open) => IconButton(
                            tooltip: l10n.episodeActions,
                            onPressed: toggle,
                            icon: const Icon(Icons.more_vert_rounded),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _batchBar() => Material(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Wrap(
          spacing: 6,
          runSpacing: 4,
          alignment: WrapAlignment.center,
          children: [
            if (_controller.busy)
              TextButton(
                onPressed: _controller.stopBatch,
                child: Text(l10n.stopBatch),
              )
            else ...[
              for (final entry in {
                'pause': l10n.pause,
                'resume': l10n.resumeRetry,
                'archive': l10n.keep,
                'remove': l10n.delete,
              }.entries)
                TextButton(
                  onPressed: _controller.selected.isEmpty
                      ? null
                      : () => _batch(entry.key, _controller.selectedJobs),
                  child: Text(entry.value),
                ),
              if (_controller.retryCommand != null)
                FilledButton(
                  onPressed: () => _batch(
                    _controller.retryCommand!,
                    _controller.selectedJobs,
                  ),
                  child: Text(l10n.retryFailed),
                ),
            ],
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (!_controller.allowed) {
      return StatusPanel(
        title: l10n.noAccessDownloads,
        message: l10n.returnRetry,
      );
    }
    final collections = _controller.collections;
    final rows = <Object>[
      for (final collection in collections) ...[
        collection,
        if (_controller.expanded.contains(collection.drama.id))
          ...collection.jobs,
      ],
    ];
    final title = _controller.selecting
        ? l10n.selectedItems(_controller.selected.length)
        : l10n.downloadsTitle;
    final actions = _titleActions(collections);
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.embedded)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                ...actions,
              ],
            ),
          ),
        LayoutBuilder(
          builder: (context, constraints) {
            // 搜索框属于整页头部：与主体共用「居中的内容宽度」，
            // 而不是只加留白——1600 宽下只加 32 留白仍会横跨全屏。
            final inset = Md3Spacing.contentInset(
              constraints.maxWidth,
              maxWidth: Md3Spacing.wideMaxWidth,
            );
            return Padding(
              padding: EdgeInsets.fromLTRB(
                inset,
                Md3Spacing.sm,
                inset,
                Md3Spacing.sm,
              ),
              child: TextField(
                controller: _search,
                onChanged: _controller.setQuery,
                decoration: InputDecoration(
                  hintText: l10n.downloadsSearchHint,
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: l10n.clearSearch,
                          onPressed: () {
                            _search.clear();
                            _controller.setQuery('');
                          },
                          icon: const Icon(Icons.close_rounded),
                        ),
                ),
              ),
            );
          },
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            final inset = Md3Spacing.contentInset(
              constraints.maxWidth,
              maxWidth: Md3Spacing.wideMaxWidth,
            );
            return Padding(
              padding: EdgeInsets.fromLTRB(
                inset,
                Md3Spacing.xs,
                inset,
                Md3Spacing.xs,
              ),
              child: Text(
                '${l10n.downloadsSummary(collections.length, collections.fold<int>(0, (sum, c) => sum + c.jobs.length))}'
                '${_controller.filter == 'archived' ? l10n.downloadsArchivedFilterHint : ''}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            );
          },
        ),
        if (_controller.updater.busy || _controller.busy)
          const LinearProgressIndicator(minHeight: 2),
        if (_controller.updater.busy || _controller.busy)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _controller.busy
                        ? _controller.operation
                        : _controller.updater.status,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_controller.updater.busy)
                  TextButton(
                    onPressed: _controller.updater.cancel,
                    child: Text(l10n.stop),
                  ),
              ],
            ),
          ),
        if (_controller.error != null && _controller.jobs.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(_controller.error!),
          ),
        Expanded(
          child: _controller.loading
              ? const Center(child: AppLoadingIndicator())
              : _controller.error != null && _controller.jobs.isEmpty
              ? StatusPanel(
                  title: l10n.noReadDownloads,
                  message: _controller.error!,
                  onRetry: _refresh,
                )
              : rows.isEmpty
              ? StatusPanel(
                  title: _controller.jobs.isEmpty
                      ? l10n.noDownloadTasks
                      : l10n.noSuitableTasks,
                  message: l10n.noTasksHint,
                  icon: Icons.download_outlined,
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    // 宽窗口走主从：左列合集，右列当前合集的剧集明细。
                    // 手机上仍是「合集 + 行内展开」，因为竖屏放不下两列。
                    if (Md3WindowClass.usesTwoPane(constraints.maxWidth)) {
                      return _masterDetail(constraints.maxWidth, collections);
                    }
                    final inset = Md3Spacing.contentInset(
                      constraints.maxWidth,
                      maxWidth: Md3Spacing.contentMaxWidth,
                    );
                    return ListView.builder(
                      padding: EdgeInsets.fromLTRB(
                        inset,
                        Md3Spacing.xs,
                        inset,
                        Md3Spacing.xl,
                      ),
                      itemCount: rows.length,
                      itemBuilder: (_, index) => switch (rows[index]) {
                        DownloadCollection collection => _collection(
                          collection,
                        ),
                        DownloadJob job => _episode(job),
                        _ => const SizedBox.shrink(),
                      },
                    );
                  },
                ),
        ),
        if (_controller.selecting) _batchBar(),
      ],
    );
    if (widget.embedded) return body;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
        const SingleActivator(LogicalKeyboardKey.goBack): () =>
            Navigator.of(context).maybePop(),
      },
      child: Scaffold(
        appBar: AppBar(title: Text(title), actions: actions),
        body: SafeArea(top: false, child: body),
      ),
    );
  }
}
