import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import 'package:hoshi/data/app_contract.dart';
import 'package:hoshi/ui/features/downloads/widgets/download_picker.dart';
import 'package:hoshi/ui/features/player/views/player_screen.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/core/widgets.dart';
import 'package:hoshi/ui/core/adaptive_sheet.dart';
import 'package:hoshi/ui/core/surfaces.dart';
import 'package:hoshi/ui/features/detail/controllers/detail_controller.dart';
import 'package:hoshi/ui/routing/app_router.dart';
import 'package:hoshi/ui/routing/route_args.dart';
import 'package:hoshi/ui/theme/md3_tokens.dart';
import 'package:hoshi/ui/features/sources/views/sources_screen.dart';
import 'package:hoshi/ui/core/empty_state.dart';
import 'package:hoshi/ui/core/episode_browser.dart';
import 'package:hoshi/ui/core/episode_grid.dart';
import 'package:hoshi/ui/core/split_list.dart';
import 'package:hoshi/ui/features/detail/widgets/cover_backdrop.dart';
import 'package:hoshi/ui/features/detail/widgets/detail_header_card.dart';
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
    final selection = await Navigator.of(context).push<DownloadSelection>(
      MaterialPageRoute<DownloadSelection>(
        builder: (_) => DownloadPicker(
          detail: detail,
          preferences: widget.store.downloadPreferences,
        ),
      ),
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
    // 播放页在根 Navigator 上打开：参照应用的播放页铺满整个窗口，不保留
    // 左侧导航栏与内容书架。
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(
          detail: detail,
          initialIndex: index,
          initialPosition: position,
          repository: widget.repository,
          store: widget.store,
        ),
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
    // 同剧切换用 `pushReplacement`：返回栈里不应留下上一季，
    // 否则返回会回到同一部剧的另一个入口。
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => DetailScreen(
          key: ValueKey('detail-${drama.id}'),
          drama: drama,
          repository: widget.repository,
          store: widget.store,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final drama = _controller.currentDrama;
    final watched = widget.store.watched(drama.id);
    final episodes = _controller.detail?.episodes ?? <Episode>[];
    final resumeIndex = resumeEpisodeIndex(episodes, watched);
    final allowed = _controller.allowed;
    final immersive =
        MediaQuery.sizeOf(context).width >= Md3WindowClass.expanded;
    final canPlay = allowed && !_controller.loading && episodes.isNotEmpty;
    final playLabel = watched != null && episodes.isNotEmpty
        ? l10n.detailResumeEpisode(episodes[resumeIndex].number)
        : l10n.detailPlayNow;
    // 宽屏完全交给 `_immersiveDetail` 的 SliverAppBar：它自己带返回键与动作，
    // 再套一层 Scaffold AppBar 就会出现两条返回键、两组动作按钮（参照应用
    // `info_page.dart` 只有一个 SliverAppBar）。
    if (allowed && immersive) {
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.of(context).maybePop(),
          const SingleActivator(LogicalKeyboardKey.goBack): () =>
              Navigator.of(context).maybePop(),
        },
        child: Scaffold(
          body: _immersiveDetail(
            drama: drama,
            episodes: episodes,
            watchedEpisode: watched?.episode,
            immersive: true,
          ),
          floatingActionButton: FloatingActionButton.extended(
            tooltip: playLabel,
            onPressed: canPlay ? () => _play(resumeIndex, resume: true) : null,
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(playLabel),
          ),
        ),
      );
    }
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
        const SingleActivator(LogicalKeyboardKey.goBack): () =>
            Navigator.of(context).maybePop(),
      },
      child: Scaffold(
        appBar: AppBar(
          scrolledUnderElevation: 0,
          title: Text(drama.title, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              key: const ValueKey('detail-source-sheet'),
              tooltip: l10n.detailSourceTab,
              onPressed: allowed ? () => _showSourceSheet(drama) : null,
              icon: const Icon(Icons.hub_outlined),
            ),
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
              constraints: const BoxConstraints(
                maxWidth: Md3Spacing.wideMaxWidth,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (!allowed) {
                    return StatusPanel(
                      title: l10n.detailNoAccess,
                      message: l10n.detailNoAccessHint,
                    );
                  }
                  final wide = constraints.maxWidth >= Md3WindowClass.expanded;
                  final immersive =
                      MediaQuery.sizeOf(context).width >=
                      Md3WindowClass.expanded;
                  if (wide) {
                    // 参照应用 `info_page.dart` 的沉浸头：
                    //
                    //   NestedScrollView
                    //     SliverAppBar.medium（expandedHeight 412）
                    //       ├ flexibleSpace: 模糊封面 + 300 高信息卡
                    //       └ bottom: tab 条
                    //     body: 各 tab 的内容
                    //
                    // 与旧版的差别是结构性的：旧版是「360 固定左栏 + 右栏 tab」，
                    // 信息被锁在窄栏里；新版把信息铺到整幅宽度、用 412 高的
                    // 头部承担，tab 条压在头部底边，滚动时整块头部收起。
                    return _immersiveDetail(
                      drama: drama,
                      episodes: episodes,
                      watchedEpisode: watched?.episode,
                      immersive: immersive,
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
                                    mainAxisExtent: _episodeExtent(),
                                    crossAxisSpacing: 10,
                                    mainAxisSpacing: 10,
                                  ),
                              delegate: SliverChildBuilderDelegate((
                                context,
                                index,
                              ) {
                                final episode = visible[index];
                                // 带 hover 的 EpisodeButton。
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
                        child: StateActionButton(
                          key: const ValueKey('start-play'),
                          label: watched != null && episodes.isNotEmpty
                              ? l10n.detailResumeEpisode(
                                  episodes[resumeIndex].number,
                                )
                              : l10n.detailPlayNow,
                          icon: Icons.play_arrow_rounded,
                          minimumSize: const Size(0, 52),
                          onPressed:
                              !allowed ||
                                  _controller.loading ||
                                  episodes.isEmpty
                              ? null
                              : () => _play(resumeIndex, resume: true),
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

  /// 沉浸式详情页（参照应用 `info_page.dart` 的形态）。
  ///
  /// 头部下方是「剧集 / 简介」两个 Tab，剧集是主操作，默认停在剧集页；
  /// 站源信息改由 AppBar 动作打开底部弹层，不再占第三个 Tab。
  ///
  /// 头部 412 高 = 308 信息区 + 48 tab 条 + 56 工具栏。模糊封面只铺到
  /// tab 条上方（`bottom: kTextTabBarHeight`），否则模糊会透到 tab 下面。
  Widget _immersiveDetail({
    required Drama drama,
    required List<Episode> episodes,
    required int? watchedEpisode,
    required bool immersive,
  }) {
    final l10n = AppLocalizations.of(context);
    final loading = _controller.loading;
    final canPlay = !loading && episodes.isNotEmpty;

    return DefaultTabController(
      length: 2,
      child: NestedScrollView(
        headerSliverBuilder: (context, innerBoxIsScrolled) => [
          SliverOverlapAbsorber(
            handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
            sliver: SliverAppBar.medium(
              stretch: true,
              centerTitle: false,
              scrolledUnderElevation: 0,
              automaticallyImplyLeading: false,
              leading: IconButton(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back),
              ),
              title: Text(drama.title, overflow: TextOverflow.ellipsis),
              actions: [
                if (widget.repository.supportsDownloads &&
                    widget.store.canDownload)
                  IconButton(
                    tooltip: l10n.downloadPickerTitle,
                    onPressed: canPlay ? _download : null,
                    icon: const Icon(Icons.download_rounded),
                  ),
                IconButton(
                  key: const ValueKey('detail-source-sheet'),
                  tooltip: l10n.detailSourceTab,
                  onPressed: () => _showSourceSheet(drama),
                  icon: const Icon(Icons.hub_outlined),
                ),
                RefreshAction(
                  loading: loading,
                  tooltip: l10n.detailRefreshInfo,
                  onPressed: _load,
                ),
                const SizedBox(width: Md3Spacing.sm),
              ],
              expandedHeight: Md3Detail.headerHeight,
              collapsedHeight:
                  kTextTabBarHeight +
                  kToolbarHeight +
                  MediaQuery.paddingOf(context).top,
              flexibleSpace: FlexibleSpaceBar(
                collapseMode: CollapseMode.pin,
                background: Stack(
                  children: [
                    // 模糊封面只到 tab 条上沿。
                    if (immersive)
                      Positioned.fill(
                        bottom: kTextTabBarHeight,
                        child: IgnorePointer(
                          child: CoverBackdrop(
                            drama: drama,
                            repository: widget.repository,
                            height: double.infinity,
                            bottomFeather: Md3Detail.backdropFeather,
                          ),
                        ),
                      ),
                    SafeArea(
                      bottom: false,
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(
                            Md3Spacing.lg,
                            kToolbarHeight,
                            Md3Spacing.lg,
                            0,
                          ),
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                maxWidth: Md3Detail.cardMaxWidth,
                              ),
                              child: DetailHeaderCard(
                                drama: drama,
                                repository: widget.repository,
                                loading: loading,
                                coverOverlay: _coverFavoriteButton(drama),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              bottom: TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.center,
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
                ],
              ),
            ),
          ),
        ],
        body: TabBarView(
          children: [
            // 每个 tab 都放在 Builder 里：`sliverOverlapAbsorberHandleFor`
            // 必须用 NestedScrollView 之下的 context 调用，用页面 State 的
            // context 会抛 "must be called with a context that contains a
            // NestedScrollView"。
            Builder(
              builder: (paneContext) =>
                  _episodesPane(paneContext, episodes, watchedEpisode),
            ),
            Builder(builder: (paneContext) => _infoPane(paneContext, drama)),
          ],
        ),
      ),
    );
  }

  /// 「剧集」Tab。
  ///
  /// 参照应用每个 Tab 都是 `CustomScrollView`，首个 sliver 是
  /// `SliverOverlapInjector`：它把被 `SliverAppBar` 吸顶遮住的那段高度补回来，
  /// 内容才不会钻到 TabBar 底下。缺了它就会看到选集数字与 tab 文字叠在一起。
  Widget _episodesPane(
    BuildContext context,
    List<Episode> episodes,
    int? watchedEpisode,
  ) {
    final l10n = AppLocalizations.of(context);
    final handle = NestedScrollView.sliverOverlapAbsorberHandleFor(context);
    if (_controller.loading || _controller.error != null || episodes.isEmpty) {
      return CustomScrollView(
        slivers: [
          SliverOverlapInjector(handle: handle),
          SliverFillRemaining(hasScrollBody: false, child: _episodeStatus()),
        ],
      );
    }
    final start = _controller.episodePage * episodePageSize;
    final visible = episodes.skip(start).take(episodePageSize).toList();
    return CustomScrollView(
      key: const PageStorageKey('detail-episodes'),
      slivers: [
        SliverOverlapInjector(handle: handle),
        SliverToBoxAdapter(child: _seriesSelector(_controller.currentDrama)),
        SliverToBoxAdapter(
          child: EpisodeRangeBar(
            episodes: episodes,
            page: _controller.episodePage,
            title: l10n.detailGroup,
            currentNumber: watchedEpisode,
            onLocate: _locateEpisode,
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 96),
          sliver: SliverGrid(
            // 与 Kazumi 的选集网格一致：按宽度切列、单元格等高，
            // 数字再多也不换行挤压。
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 108,
              mainAxisExtent: 54,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
            ),
            delegate: SliverChildBuilderDelegate((context, index) {
              final episode = visible[index];
              return EpisodeButton(
                key: ValueKey('episode-${episode.number}'),
                number: episode.number,
                vip: episode.vip,
                current: episode.number == watchedEpisode,
                onPressed: () => _play(start + index),
              );
            }, childCount: visible.length),
          ),
        ),
      ],
    );
  }

  /// 「简介」Tab：只放长文本类信息，避免和左栏重复。
  Widget _infoPane(BuildContext context, Drama drama) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final handle = NestedScrollView.sliverOverlapAbsorberHandleFor(context);
    return CustomScrollView(
      key: const PageStorageKey('detail-overview'),
      slivers: [
        SliverOverlapInjector(handle: handle),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          sliver: SliverToBoxAdapter(
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
                      for (final tag in drama.tags) Chip(label: Text(tag)),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 站源信息改为底部弹层（参照应用 2.4.2 的 `source_sheet_view`）。
  ///
  /// 详情页只保留「剧集 / 简介」两个 Tab；站源是低频信息，放在 AppBar
  /// 动作里，用弹层承担，避免为一块只读信息单独占一个 Tab。
  Future<void> _showSourceSheet(Drama drama) {
    return showAdaptiveSheet<void>(
      context: context,
      builder: (context) => _DetailSourceSheet(
        drama: drama,
        repository: widget.repository,
        store: widget.store,
      ),
    );
  }

  /// 封面左下的收藏浮钮，位置与参照应用的 `CollectButton` 一致。
  Widget _coverFavoriteButton(Drama drama) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final followed = widget.store.following(drama.id) != null;
    return IconButton.filledTonal(
      key: const ValueKey('detail-collect'),
      tooltip: followed ? l10n.detailUnfollow : l10n.detailFollow,
      onPressed: _controller.allowed
          ? () => saveUserChange(
              context,
              () => widget.store.toggleFavorite(drama),
            )
          : null,
      style: IconButton.styleFrom(
        minimumSize: const Size(40, 40),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: colors.surface.withValues(alpha: .82),
        foregroundColor: followed ? colors.primary : colors.onSurfaceVariant,
      ),
      icon: Icon(
        followed ? Icons.bookmark_rounded : Icons.bookmark_add_outlined,
        size: 20,
      ),
    );
  }

  Widget _episodeStatus() {
    final l10n = AppLocalizations.of(context);
    if (_controller.loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: AppLoadingIndicator(),
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
                AnimatedRotation(
                  turns: expanded ? -.5 : 0,
                  duration: Md3Motion.of(context, Md3Motion.standard),
                  child: const Icon(Icons.expand_more_rounded),
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
      final extent = _episodeExtent();
      final columns = _episodeColumns(render.size.width, episodes);
      final target =
          start +
          render.size.height +
          (index % episodePageSize ~/ columns) * (extent + 10) -
          _detailScroll.position.viewportDimension * .3;
      _detailScroll.animateTo(
        target.clamp(0.0, _detailScroll.position.maxScrollExtent),
        duration: Md3Motion.of(context, Md3Motion.standardAccelerate),
        curve: Curves.easeOut,
      );
    });
  }

  /// 选集单元的行高：不小于 54，大字号随文字缩放。
  double _episodeExtent() =>
      math.max(54, MediaQuery.textScalerOf(context).scale(20) + 30);

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
              width: Md3Detail.coverWidth,
              height: Md3Detail.coverHeight,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: DramaCover(
                      drama: drama,
                      repository: widget.repository,
                      radius: Md3Shape.cardRadius,
                      heroTag: 'cover-${drama.id}',
                    ),
                  ),
                  Positioned(
                    left: 6,
                    bottom: 6,
                    child: _coverFavoriteButton(drama),
                  ),
                ],
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
        AppMenuButton(
          key: const ValueKey('follow-status'),
          menuChildren: [
            for (final status in FollowStatus.values)
              AppMenuItem(
                label: _followStatusLabel(status, l10n),
                selected: state?.status == status,
                onPressed: () async {
                  if (!_controller.allowed) return;
                  await saveUserChange(
                    context,
                    () => widget.store.setFollowStatus(drama, status),
                  );
                },
              ),
            if (state != null)
              AppMenuItem(
                label: l10n.detailUnfollow,
                destructive: true,
                onPressed: () async {
                  if (!_controller.allowed) return;
                  await saveUserChange(
                    context,
                    () => widget.store.toggleFavorite(drama),
                  );
                },
              ),
          ],
          builder: (context, toggle, open) => InkWell(
            onTap: toggle,
            borderRadius: Md3Shape.card,
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
                  AnimatedRotation(
                    turns: open ? .5 : 0,
                    duration: Md3Motion.of(context, Md3Motion.standard),
                    child: const Icon(Icons.expand_more_rounded, size: 18),
                  ),
                ],
              ),
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

/// 站源弹层：标题 + 站源描述 + 一行一项的分组列表。
///
/// 参照应用 `source_sheet_view` 的底部弹层语法：顶部标题与关闭按钮，
/// 下面用 `SplitListGroup` 承载条目；诊断入口只在支持站源管理的构建里出现。
class _DetailSourceSheet extends StatelessWidget {
  const _DetailSourceSheet({
    required this.drama,
    required this.repository,
    required this.store,
  });

  final Drama drama;
  final AppRepository repository;
  final LocalStore store;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final site = SourceSite.byId(drama.source);
    final rows = <(IconData, String, String)>[
      if (drama.category.isNotEmpty)
        (Icons.category_outlined, l10n.detailCategoryLabel, drama.category),
      if (drama.releaseStatus.isNotEmpty && drama.releaseStatus != 'unknown')
        (Icons.timelapse_rounded, l10n.detailStatusLabel, drama.releaseLabel),
      if (drama.onlineDate.isNotEmpty)
        (Icons.event_outlined, l10n.detailOnlineLabel, drama.onlineDate),
      if (drama.heat.isNotEmpty)
        (
          Icons.local_fire_department_outlined,
          l10n.detailHeatLabel,
          drama.heat,
        ),
      if (drama.views.isNotEmpty)
        (Icons.play_circle_outline_rounded, l10n.detailViewsLabel, drama.views),
    ];
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          Md3Spacing.xl,
          0,
          Md3Spacing.xl,
          Md3Spacing.xl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.detailSourceTab,
                        style: TextStyle(
                          fontSize: Md3Type.headlineSmall,
                          fontWeight: FontWeight.w700,
                          color: colors.onSurface,
                        ),
                      ),
                      const SizedBox(height: Md3Spacing.xxs),
                      Text(
                        '${site.name} · ${site.description}',
                        style: TextStyle(
                          fontSize: Md3Type.bodyMedium,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: Md3Spacing.lg),
            SplitListGroup(
              children: [
                SplitListRow(
                  leading: Icons.public_rounded,
                  title: site.name,
                  description: site.description,
                ),
                for (final row in rows)
                  SplitListRow(
                    leading: row.$1,
                    title: row.$2,
                    trailing: Text(
                      row.$3,
                      style: TextStyle(
                        fontSize: Md3Type.bodyMedium,
                        fontWeight: FontWeight.w600,
                        color: colors.onSurface,
                      ),
                    ),
                  ),
              ],
            ),
            if (repository.supportsSourceManagement) ...[
              const SizedBox(height: Md3Spacing.xl),
              Align(
                alignment: Alignment.center,
                child: SourceDiagnosticsButton(
                  repository: repository,
                  store: store,
                  drama: drama,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
