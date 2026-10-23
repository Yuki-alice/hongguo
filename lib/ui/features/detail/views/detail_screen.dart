import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import 'package:hoshi/ui/core/app_layout.dart';
import 'package:hoshi/data/app_contract.dart';
import 'package:hoshi/ui/features/downloads/widgets/download_picker.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/core/widgets.dart';
import 'package:hoshi/ui/features/detail/controllers/detail_controller.dart';
import 'package:hoshi/ui/routing/app_router.dart';
import 'package:hoshi/ui/routing/route_args.dart';
import 'package:hoshi/ui/theme/md3_tokens.dart';
import 'package:hoshi/ui/features/sources/views/sources_screen.dart';
import 'package:hoshi/ui/core/empty_state.dart';
import 'package:hoshi/ui/core/episode_browser.dart';
import 'package:hoshi/ui/core/episode_grid.dart';
import 'package:hoshi/ui/features/detail/widgets/cover_backdrop.dart';
import 'package:hoshi/domain/follow_state.dart';
import 'package:hoshi/domain/hongguo_series.dart';

class DetailScreen extends StatefulWidget {
  const DetailScreen({
    super.key,
    required this.drama,
    required this.repository,
    required this.store,
    this.resumeOnOpen = false,
    this.downloadOnOpen = false,
  });
  final Drama drama;
  final AppRepository repository;
  final LocalStore store;
  final bool resumeOnOpen;
  final bool downloadOnOpen;
  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  late DetailController _controller;
  bool _expandedDescription = false;
  bool _episodesExpanded = false;
  final _episodeAnchor = GlobalKey();
  final _detailScroll = ScrollController();
  final _playFocus = FocusNode(debugLabel: 'tv-detail-play');
  bool _initialActionHandled = false;
  Widget? get _sourceDiagnostics => widget.repository.supportsSourceManagement
      ? SourceDiagnosticsButton(
          repository: widget.repository,
          store: widget.store,
          drama: widget.drama,
        )
      : null;

  @override
  void initState() {
    super.initState();
    _attachController();
  }

  @override
  void didUpdateWidget(covariant DetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store ||
        oldWidget.repository != widget.repository ||
        oldWidget.drama.id != widget.drama.id) {
      _detachController();
      _attachController();
    }
  }

  @override
  void dispose() {
    _detachController();
    _detailScroll.dispose();
    _playFocus.dispose();
    super.dispose();
  }

  void _attachController() {
    _initialActionHandled = false;
    _controller = DetailController(
      drama: widget.drama,
      repository: widget.repository,
      store: widget.store,
    )..addListener(_onChanged);
    unawaited(_load());
  }

  void _detachController() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
  }

  void _onChanged() {
    final l10n = AppLocalizations.of(context);
    if (!mounted) return;
    if (_controller.takeSaveError() != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.detailSaveFailed)));
    }
    setState(() {});
  }

  Future<void> _load() async {
    final loaded = await _controller.load();
    if (!mounted || !loaded || !_controller.allowed) return;
    final detail = _controller.detail;
    if (detail == null || detail.episodes.isEmpty || _initialActionHandled) {
      return;
    }
    _initialActionHandled = true;
    if (widget.resumeOnOpen) {
      unawaited(
        _play(
          resumeEpisodeIndex(
            detail.episodes,
            widget.store.watched(detail.drama.id),
          ),
          resume: true,
        ),
      );
    } else if (widget.downloadOnOpen && widget.store.canDownload) {
      unawaited(_download());
    }
  }

  Future<void> _download() async {
    final l10n = AppLocalizations.of(context);
    final detail = _controller.detail;
    if (detail == null || !widget.store.canDownload || !_controller.allowed) {
      return;
    }
    // 选集弹层需要完整详情与用户偏好，用 extra 传递；返回结果仍是
    // `DownloadSelection`，因此用 `push` 而不是 `go`。
    final ref = DramaRef.fromDramaId(detail.drama.id);
    if (ref == null) return;
    final selection = await context.push<DownloadSelection>(
      AppRoutes.downloadPickerOf(ref),
      extra: DownloadPickerExtra(detail, widget.store.downloadPreferences),
    );
    if (selection == null ||
        !mounted ||
        !widget.store.canDownload ||
        !_controller.allowed) {
      return;
    }
    try {
      final added = await widget.repository.enqueueDownloads(
        detail,
        selection.episodes,
        quality: selection.quality,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            added == 0 ? l10n.detailAlreadyQueued : l10n.detailAdded(added),
          ),
          action: SnackBarAction(
            label: l10n.detailView,
            onPressed: () => context.push(AppRoutes.downloads),
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> _play(int index, {bool resume = false}) async {
    final l10n = AppLocalizations.of(context);
    final detail = _controller.detail;
    if (detail == null ||
        index < 0 ||
        index >= detail.episodes.length ||
        !_controller.allowed ||
        !widget.store.allowsSource(detail.drama.source)) {
      return;
    }
    if (detail.episodes[index].vip &&
        detail.drama.source != SourceSite.dsd.id) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.detailVipDialogTitle),
          content: Text(l10n.detailVipWarning),
          actions: [
            TextButton(
              autofocus: AppLayout.isTelevision(context),
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.detailTryPlay),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) {
        return;
      }
    }
    final saved = widget.store.watched(detail.drama.id);
    final position =
        resume &&
            saved?.episode == detail.episodes[index].number &&
            !saved!.finished
        ? saved.position
        : 0.0;
    if (!mounted || !_controller.allowed) {
      return;
    }
    final ref = DramaRef.fromDramaId(detail.drama.id);
    if (ref == null) return;
    await context.push(
      AppRoutes.playerOf(ref),
      extra: PlayerRouteExtra(
        detail: detail,
        initialIndex: index,
        initialPosition: position,
      ),
    );
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _openSeriesDrama(Drama drama) async {
    if (!_controller.allowed || drama.id == _controller.currentDrama.id) {
      return;
    }
    final anchor = _controller.currentDrama;
    if (widget.store.following(anchor.id)?.seriesSeasons[drama.id]?.read ==
        false) {
      await saveUserChange(
        context,
        () => widget.store.markSeriesSeasonRead(anchor.id, drama.id),
      );
      if (!mounted) return;
    }
    // 同剧切换用 `replace` 而不是 `push`：返回栈里不应留下上一季，
    // 否则返回会回到同一部剧的另一个入口。
    final ref = DramaRef.fromDramaId(drama.id);
    if (ref == null) return;
    context.replace(AppRoutes.detailOf(ref), extra: drama);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final drama = _controller.currentDrama;
    final watched = widget.store.watched(drama.id);
    final episodes = _controller.detail?.episodes ?? <Episode>[];
    final resumeIndex = resumeEpisodeIndex(episodes, watched);
    final television = AppLayout.isTelevision(context);
    final allowed = _controller.allowed;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
        const SingleActivator(LogicalKeyboardKey.goBack): () =>
            Navigator.of(context).maybePop(),
      },
      child: Scaffold(
        // 桌面端用透明 AppBar 叠在模糊封面上，标题由页面正文承担；
        // 移动端保持不透明，避免小屏上文字压在海报上看不清。
        extendBodyBehindAppBar: !television && MediaQuery.sizeOf(context).width >= Md3WindowClass.expanded,
        appBar: AppBar(
          toolbarHeight: television ? 64 : null,
          backgroundColor: MediaQuery.sizeOf(context).width >= Md3WindowClass.expanded
              ? Colors.transparent
              : null,
          scrolledUnderElevation: 0,
          title: Text(drama.title, overflow: TextOverflow.ellipsis),
          actions: [
            RefreshAction(
              loading: _controller.loading,
              tooltip: l10n.detailRefreshInfo,
              onPressed: allowed ? _load : null,
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          bottom: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: Md3Spacing.wideMaxWidth),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (!allowed) {
                    return StatusPanel(
                      title: l10n.detailNoAccess,
                      message: l10n.detailNoAccessHint,
                    );
                  }
                  final wide =
                      television ||
                      constraints.maxWidth >= Md3WindowClass.expanded;
                  final immersive =
                      !television &&
                      MediaQuery.sizeOf(context).width >=
                          Md3WindowClass.expanded;
                  if (wide) {
                    final panes = Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          // 桌面端左栏固定宽度：剧集信息量与封面尺寸都稳定，
                          // 不会随窗口变宽而把右栏挤窄。
                          width: Md3Spacing.detailPaneWidth,
                          child: SingleChildScrollView(
                            padding: EdgeInsets.fromLTRB(
                              Md3Spacing.xl,
                              MediaQuery.sizeOf(context).width >=
                                      Md3WindowClass.expanded
                                  ? MediaQuery.paddingOf(context).top +
                                        kToolbarHeight
                                  : Md3Spacing.xl,
                              Md3Spacing.xl,
                              Md3Spacing.xl,
                            ),
                            child: _overview(drama),
                          ),
                        ),
                        const VerticalDivider(width: 1),
                        Expanded(
                          child: _wideTabs(
                            drama: drama,
                            episodes: episodes,
                            watchedEpisode: watched?.episode,
                          ),
                        ),
                      ],
                    );
                    if (!immersive) return panes;
                    // 沉浸头：模糊封面铺在顶部，内容整体叠在其上。
                    return Stack(
                      children: [
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: CoverBackdrop(
                            drama: drama,
                            repository: widget.repository,
                          ),
                        ),
                        panes,
                      ],
                    );
                  }
                  final start = _controller.episodePage * episodePageSize;
                  final visible = episodes
                      .skip(start)
                      .take(episodePageSize)
                      .toList();
                  final showEpisodes = _episodesExpanded;
                  return CustomScrollView(
                    controller: _detailScroll,
                    slivers: [
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                          child: _overview(drama),
                        ),
                      ),
                      if (_controller.loading ||
                          _controller.error != null ||
                          episodes.isEmpty)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: _episodeStatus(),
                        )
                      else ...[
                        SliverToBoxAdapter(child: _seriesSelector(drama)),
                        SliverToBoxAdapter(
                          child: _episodeSummary(
                            episodes,
                            currentNumber: watched?.episode,
                            expanded: showEpisodes,
                          ),
                        ),
                        if (showEpisodes) ...[
                          SliverToBoxAdapter(
                            child: EpisodeRangeBar(
                              key: _episodeAnchor,
                              episodes: episodes,
                              page: _controller.episodePage,
                              title: l10n.detailGroup,
                              currentNumber: watched?.episode,
                              onLocate: _locateEpisode,
                            ),
                          ),
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                            sliver: SliverGrid(
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: _episodeColumns(
                                      constraints.maxWidth,
                                      episodes,
                                    ),
                                    mainAxisExtent: math.max(
                                      54,
                                      MediaQuery.textScalerOf(
                                            context,
                                          ).scale(20) +
                                          30,
                                    ),
                                    crossAxisSpacing: 10,
                                    mainAxisSpacing: 10,
                                  ),
                              delegate: SliverChildBuilderDelegate((
                                context,
                                index,
                              ) {
                                final episode = visible[index];
                                // 手机 / 桌面用带 hover 的 EpisodeButton；
                                // 电视分支在上面已经提前返回，不会走到这里。
                                return EpisodeButton(
                                  key: ValueKey('episode-${episode.number}'),
                                  number: episode.number,
                                  vip: episode.vip,
                                  current: episode.number == watched?.episode,
                                  onPressed: () => _play(start + index),
                                );
                              }, childCount: visible.length),
                            ),
                          ),
                        ],
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
        ),
        bottomNavigationBar: Material(
          color: Theme.of(context).colorScheme.surface,
          child: SafeArea(
            top: false,
            child: Center(
              heightFactor: 1,
              child: ConstrainedBox(
                // 与上方内容区同宽：改造前这里是硬编码 1000，而内容区
                // 是 1200，宽窗口下两者边缘对不齐。
                constraints: const BoxConstraints(
                  maxWidth: Md3Spacing.wideMaxWidth,
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Md3Spacing.xl,
                    Md3Spacing.sm,
                    Md3Spacing.xl,
                    Md3Spacing.md,
                  ),
                  child: Row(
                    children: [
                      if (widget.repository.supportsDownloads &&
                          widget.store.canDownload) ...[
                        IconButton.filledTonal(
                          tooltip: l10n.downloadPickerTitle,
                          onPressed:
                              allowed &&
                                  !_controller.loading &&
                                  episodes.isNotEmpty
                              ? _download
                              : null,
                          style: IconButton.styleFrom(
                            minimumSize: const Size(52, 52),
                          ),
                          icon: const Icon(Icons.download_rounded),
                        ),
                        const SizedBox(width: 12),
                      ],
                      Expanded(
                        child: FilledButton.icon(
                          key: const ValueKey('start-play'),
                          autofocus: television,
                          focusNode: television ? _playFocus : null,
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(0, 52),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                          ),
                          onPressed:
                              !allowed ||
                                  _controller.loading ||
                                  episodes.isEmpty
                              ? null
                              : () => _play(resumeIndex, resume: true),
                          icon: const Icon(Icons.play_arrow_rounded, size: 26),
                          label: Text(
                            watched != null && episodes.isNotEmpty
                                ? l10n.detailResumeEpisode(
                                    episodes[resumeIndex].number,
                                  )
                                : l10n.detailPlayNow,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 宽屏右栏：剧集 / 简介 / 来源 三个 Tab。
  ///
  /// 左栏放「这部剧是什么」（封面、标题、收藏、简介摘要），右栏放
  /// 「能做什么」——剧集是主操作，所以默认停在剧集页。
  Widget _wideTabs({
    required Drama drama,
    required List<Episode> episodes,
    required int? watchedEpisode,
  }) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final tabs = DefaultTabController(
      length: 3,
      child: Column(
        children: [
          // Tab 栏占满右栏宽度、三个标签均分。
          //
          // 非滚动模式会按可用宽度等分，正好填满宽栏；可滚动模式按内容
          // 宽度收缩，在 700px 右栏里只剩不到 200px 的一条。
          Container(
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: colors.outlineVariant),
              ),
            ),
            child: TabBar(
              isScrollable: false,
              dividerHeight: 0,
              labelStyle: TextStyle(
                fontSize: Md3Type.labelLarge,
                fontWeight: FontWeight.w700,
              ),
              unselectedLabelStyle: TextStyle(
                fontSize: Md3Type.labelLarge,
                fontWeight: FontWeight.w500,
              ),
              tabs: [
                Tab(
                  key: const ValueKey('detail-tab-episodes'),
                  text: l10n.detailEpisodesTab,
                ),
                Tab(
                  key: const ValueKey('detail-tab-overview'),
                  text: l10n.detailOverviewTab,
                ),
                Tab(
                  key: const ValueKey('detail-tab-source'),
                  text: l10n.detailSourceTab,
                ),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                _episodesPane(episodes, watchedEpisode),
                _infoPane(drama),
                _sourcePane(drama),
              ],
            ),
          ),
        ],
      ),
    );
    return tabs;
  }

  Widget _episodesPane(List<Episode> episodes, int? watchedEpisode) {
    if (_controller.loading ||
        _controller.error != null ||
        episodes.isEmpty) {
      return _episodeStatus();
    }
    return Column(
      children: [
        _seriesSelector(_controller.currentDrama),
        Expanded(
          child: EpisodeBrowser(
            episodes: episodes,
            currentNumber: watchedEpisode,
            onExitDown: () => _playFocus.requestFocus(),
            onSelected: (index) => _play(index),
          ),
        ),
      ],
    );
  }

  /// 「简介」Tab：只放长文本类信息，避免和左栏重复。
  Widget _infoPane(Drama drama) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(Md3Spacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (drama.description.isEmpty)
            EmptyState(
              title: l10n.detailNoSynopsis,
              icon: Icons.article_outlined,
              compact: true,
            )
          else
            SelectableText(
              drama.description,
              style: TextStyle(
                fontSize: Md3Type.bodyLarge,
                height: 1.7,
                color: colors.onSurface,
              ),
            ),
          if (drama.tags.isNotEmpty) ...[
            const SizedBox(height: Md3Spacing.xl),
            Text(
              l10n.detailTagsTitle,
              style: TextStyle(
                fontSize: Md3Type.labelLarge,
                fontWeight: FontWeight.w700,
                color: colors.primary,
              ),
            ),
            const SizedBox(height: Md3Spacing.sm),
            Wrap(
              spacing: Md3Spacing.sm,
              runSpacing: Md3Spacing.sm,
              children: [
                for (final tag in drama.tags)
                  Chip(label: Text(tag)),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// 「来源」Tab：站源与统计信息。
  Widget _sourcePane(Drama drama) {
    final l10n = AppLocalizations.of(context);
    final site = SourceSite.byId(drama.source);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(Md3Spacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DetailInfoRow(label: l10n.detailSourceTab, value: site.name),
          if (site.description.isNotEmpty)
            _DetailInfoRow(label: '', value: site.description),
          if (drama.category.isNotEmpty)
            _DetailInfoRow(
              label: l10n.detailCategoryLabel,
              value: drama.category,
            ),
          if (drama.releaseStatus.isNotEmpty &&
              drama.releaseStatus != 'unknown')
            _DetailInfoRow(
              label: l10n.detailStatusLabel,
              value: drama.releaseLabel,
            ),
          if (drama.onlineDate.isNotEmpty)
            _DetailInfoRow(
              label: l10n.detailOnlineLabel,
              value: drama.onlineDate,
            ),
          if (drama.heat.isNotEmpty)
            _DetailInfoRow(label: l10n.detailHeatLabel, value: drama.heat),
          if (drama.views.isNotEmpty)
            _DetailInfoRow(label: l10n.detailViewsLabel, value: drama.views),
          const SizedBox(height: Md3Spacing.xl),
          if (widget.repository.supportsSourceManagement)
            OutlinedButton.icon(
              onPressed: () => context.push(
                AppRoutes.sourcesOf(drama.source),
                extra: drama,
              ),
              icon: const Icon(Icons.troubleshoot_rounded),
              label: Text(l10n.sourceDiagnostics),
            ),
        ],
      ),
    );
  }

  Widget _episodeStatus() {
    final l10n = AppLocalizations.of(context);
    if (_controller.loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: CircularProgressIndicator(),
        ),
      );
    }
    return StatusPanel(
      title: _controller.error != null
          ? l10n.detailUnavailable
          : l10n.detailNoPlayable,
      message: _controller.error ?? l10n.detailUnavailableHint,
      onRetry: _load,
      secondaryAction: _sourceDiagnostics,
    );
  }

  Widget _episodeSummary(
    List<Episode> episodes, {
    required int? currentNumber,
    required bool expanded,
  }) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final current = currentNumber == null
        ? ''
        : l10n.detailCurrentNumber(currentNumber);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Material(
        color: colors.surfaceContainer,
        borderRadius: Md3Shape.chip,
        child: InkWell(
          borderRadius: Md3Shape.chip,
          onTap: () => setState(() => _episodesExpanded = !expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(Icons.grid_view_rounded, color: colors.onSurfaceVariant),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.detailEpisodeSelector(episodes.length, current),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(expanded ? l10n.detailCollapse : l10n.detailExpand),
                const SizedBox(width: 2),
                Icon(
                  expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _locateEpisode(int index) {
    final episodes = _controller.detail!.episodes;
    _controller.setEpisodePage(index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final anchor = _episodeAnchor.currentContext;
      if (!mounted || anchor == null || !_detailScroll.hasClients) return;
      final render = anchor.findRenderObject();
      if (render is! RenderBox || !render.hasSize) return;
      final viewport = RenderAbstractViewport.maybeOf(render);
      if (viewport == null) return;
      final start = viewport.getOffsetToReveal(render, 0).offset;
      final extent = math.max(
        54,
        MediaQuery.textScalerOf(context).scale(20) + 30,
      );
      final columns = _episodeColumns(render.size.width, episodes);
      final target =
          start +
          render.size.height +
          (index % episodePageSize ~/ columns) * (extent + 10) -
          _detailScroll.position.viewportDimension * .3;
      _detailScroll.animateTo(
        target.clamp(0.0, _detailScroll.position.maxScrollExtent),
        duration: Md3Motion.standardAccelerate,
        curve: Curves.easeOut,
      );
    });
  }

  int _episodeColumns(double width, List<Episode> episodes) {
    final digits = episodes.fold<int>(
      1,
      (value, episode) => math.max(value, episode.number.toString().length),
    );
    final minimum = math.max(
      82,
      MediaQuery.textScalerOf(context).scale(20) * digits * .65 + 40,
    );
    return ((width - 40) / minimum).floor().clamp(1, 12);
  }

  Widget _overview(Drama drama) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final meta = [
      SourceSite.byId(drama.source).name,
      if (drama.episodes > 0) l10n.detailTotalEpisodes(drama.episodes),
      if (drama.releaseStatus.isNotEmpty && drama.releaseStatus != 'unknown')
        drama.releaseLabel,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 108,
              height: 162,
              child: DramaCover(
                drama: drama,
                repository: widget.repository,
                radius: Md3Shape.cardRadius,
                heroTag: 'cover-${drama.id}',
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DetailHeadline(
                    title: drama.title,
                    width: MediaQuery.sizeOf(context).width,
                  ),
                  const SizedBox(height: Md3Spacing.sm),
                  Text(
                    meta.join(' · '),
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                  if (drama.category.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        drama.category,
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    ),
                  if (drama.source == 'huangdou')
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        drama.vipStatus == null
                            ? l10n.detailVipPending
                            : drama.vip
                            ? l10n.detailVipContent
                            : l10n.detailFreeContent,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _followingControls(drama),
        if (drama.onlineDate.isNotEmpty ||
            drama.heat.isNotEmpty ||
            drama.views.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              [
                if (drama.onlineDate.isNotEmpty)
                  l10n.detailOnlineDate(drama.onlineDate),
                if (drama.heat.isNotEmpty) l10n.detailHeat(drama.heat),
                if (drama.views.isNotEmpty) l10n.detailPlayViews(drama.views),
              ].join(' · '),
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
            ),
          ),
        if (drama.tags.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final tag in drama.tags.take(12))
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerHighest,
                      borderRadius: Md3Shape.chip,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 5,
                      ),
                      child: Text(
                        tag,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        if (drama.description.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            drama.description,
            maxLines: _expandedDescription ? null : 3,
            overflow: _expandedDescription
                ? TextOverflow.visible
                : TextOverflow.ellipsis,
            style: TextStyle(color: colors.onSurfaceVariant, height: 1.6),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () =>
                  setState(() => _expandedDescription = !_expandedDescription),
              child: Text(
                _expandedDescription
                    ? l10n.detailCollapseSynopsis
                    : l10n.detailExpandSynopsis,
              ),
            ),
          ),
        ],
        if (_controller.detail?.warning.isNotEmpty == true)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _controller.detail!.warning,
              style: TextStyle(color: colors.error),
            ),
          ),
      ],
    );
  }

  Widget _seriesSelector(Drama drama) {
    final l10n = AppLocalizations.of(context);
    final entries = hongguoSeriesEntries(
      drama,
      widget.store.seriesDramasFor(drama),
    );
    if (entries.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    final notices = widget.store.following(drama.id)?.seriesSeasons ?? const {};
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.detailRelated,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final entry in entries)
                ChoiceChip(
                  key: ValueKey('series-${entry.drama.id}'),
                  label: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 260),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            '${entry.label} · ${entry.drama.title}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (notices[entry.drama.id]?.read == false) ...[
                          const SizedBox(width: 6),
                          Icon(
                            Icons.fiber_new_rounded,
                            size: 18,
                            color: colors.primary,
                          ),
                        ],
                      ],
                    ),
                  ),
                  selected: entry.drama.id == drama.id,
                  onSelected: entry.drama.id == drama.id
                      ? null
                      : (_) => _openSeriesDrama(entry.drama),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _followStatusLabel(FollowStatus status, AppLocalizations l10n) =>
      switch (status) {
        FollowStatus.planned => l10n.followPlanned,
        FollowStatus.watching => l10n.followWatching,
        FollowStatus.watched => l10n.followWatched,
      };

  Widget _followingControls(Drama drama) {
    final l10n = AppLocalizations.of(context);
    final state = widget.store.following(drama.id);
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        PopupMenuButton<String>(
          key: const ValueKey('follow-status'),
          tooltip: l10n.detailFollowStatus,
          onSelected: (value) async {
            if (!_controller.allowed) return;
            if (value == 'remove') {
              await saveUserChange(
                context,
                () => widget.store.toggleFavorite(drama),
              );
            } else {
              final status = FollowStatus.values.firstWhere(
                (status) => status.name == value,
              );
              await saveUserChange(
                context,
                () => widget.store.setFollowStatus(drama, status),
              );
            }
          },
          itemBuilder: (_) => [
            for (final status in FollowStatus.values)
              CheckedPopupMenuItem(
                value: status.name,
                checked: state?.status == status,
                child: Text(_followStatusLabel(status, l10n)),
              ),
            if (state != null)
              PopupMenuItem(value: 'remove', child: Text(l10n.detailUnfollow)),
          ],
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: state == null
                  ? Theme.of(context).colorScheme.surfaceContainerHighest
                  : Theme.of(context).colorScheme.secondaryContainer,
              borderRadius: Md3Shape.card,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  state?.status == FollowStatus.watched
                      ? Icons.check_circle_outline
                      : state == null
                      ? Icons.bookmark_add_outlined
                      : Icons.bookmark_rounded,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  state == null
                      ? l10n.detailFollow
                      : _followStatusLabel(state.status, l10n),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.expand_more_rounded, size: 18),
              ],
            ),
          ),
        ),
        if (state != null && state.hasUpdates)
          ActionChip(
            label: Text(l10n.detailMarkRead(state.updateLabel)),
            onPressed: () => saveUserChange(
              context,
              () => widget.store.markUpdatesRead(drama.id),
            ),
          ),
      ],
    );
  }
}

/// 详情页「来源」Tab 的一行信息。
class _DetailInfoRow extends StatelessWidget {
  const _DetailInfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Md3Spacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label.isNotEmpty)
            SizedBox(
              width: 88,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: Md3Type.bodyMedium,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                fontSize: Md3Type.bodyMedium,
                color: colors.onSurface,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
