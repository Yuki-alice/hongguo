import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import 'package:hoshi/data/core_bridge.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/data/media/media_library.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/core/remote_widgets.dart';
import 'package:hoshi/ui/features/media/controllers/local_media_controller.dart';
import 'package:hoshi/ui/features/settings/views/settings_screen.dart';
import 'package:hoshi/ui/routing/app_router.dart';
import 'package:hoshi/ui/routing/route_args.dart';

class LocalMediaScreen extends StatefulWidget {
  const LocalMediaScreen({
    super.key,
    required this.repository,
    required this.store,
  });
  final AppRepository repository;
  final LocalStore store;
  @override
  State<LocalMediaScreen> createState() => _LocalMediaScreenState();
}

class _LocalMediaScreenState extends State<LocalMediaScreen> {
  late final MediaLibrary library =
      MediaLibrary.current ?? MediaLibrary(widget.repository, widget.store);
  late final LocalMediaController _controller;

  @override
  void initState() {
    super.initState();
    _controller = LocalMediaController(
      repository: widget.repository,
      library: library,
    );
    ensureTelevisionFocus(context);
    _controller.load();
  }

  @override
  void dispose() {
    _controller.dispose();
    if (library != MediaLibrary.current && !library.busy) library.dispose();
    super.dispose();
  }

  Future<void> _refresh() => _controller.load();

  Future<void> _create(bool merge) async {
    final l10n = AppLocalizations.of(context);
    if (merge) {
      await context.push(
        AppRoutes.mergeQueue,
        extra: MergeQueueExtra(library: library, addOnOpen: true),
      );
      if (mounted) await _refresh();
      return;
    }
    final jobs = _controller.jobs;
    final groups = <String, List<DownloadJob>>{};
    for (final job in jobs) {
      (groups[job.drama.id] ??= []).add(job);
    }
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(l10n.exportWhichDrama),
        children: [
          if (jobs.isNotEmpty)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, '*'),
              child: Text(l10n.allDownloaded(jobs.length)),
            ),
          for (final entry in groups.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, entry.key),
              child: Text(
                '${entry.value.first.drama.title} · ${l10n.downloadedEpisodesCount(entry.value.length)}',
              ),
            ),
          if (groups.isEmpty)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text(l10n.downloadEpisodesFirst),
            ),
        ],
      ),
    );
    if (selected == null || !mounted) return;
    await _controller.exportJobs(selected == '*' ? jobs : groups[selected]!);
  }

  Future<void> _play(LocalMediaItem item) async {
    final l10n = AppLocalizations.of(context);
    final watch = widget.store.mediaWatched(item.id);
    final episode = Episode({
      'id': item.id,
      'title': item.merged
          ? l10n.mergedVideo
          : l10n.episodeSingle(item.episodes.first),
      'currentEpisode': item.episodes.first,
    }, 1);
    final ref = DramaRef.fromDramaId(item.drama.id);
    if (ref == null) return;
    await context.push(
      AppRoutes.playerOf(ref),
      extra: PlayerRouteExtra(
        detail: DramaDetail(item.drama, [episode]),
        initialPosition: watch == null || watch.finished ? 0 : watch.position,
        repository: _LocalFileRepository(
          widget.repository,
          widget.store,
          item,
          library.fileFor(item),
          l10n,
        ),
        localOnly: true,
        allowOnlineFallback: false,
        mediaId: item.id,
      ),
    );
    if (mounted) await _refresh();
  }

  Future<void> _remove(LocalMediaItem item) async {
    final l10n = AppLocalizations.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.deleteMediaTitle),
        content: Text(
          '${l10n.deleteMediaBody}'
          '${item.merged || item.special ? '' : l10n.deleteMediaKeepHint}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.keep),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    await _controller.remove(item);
  }

  Future<void> _exportMerged(LocalMediaItem item) =>
      _controller.exportMerged(item);

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([library, _controller]),
    builder: (_, _) {
      final l10n = AppLocalizations.of(context);
      final items = library.items
          .where((item) => item.merged == _controller.merged)
          .toList();
      return Scaffold(
        appBar: AppBar(
          title: Text(l10n.localMediaTitle),
          actions: [
            IconButton(
              tooltip: l10n.localMediaRefresh,
              onPressed: library.busy ? null : _refresh,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    label: Text(l10n.mergedProducts),
                    selected: _controller.merged,
                    onSelected: (_) => _controller.showMerged(true),
                  ),
                  ChoiceChip(
                    label: Text(l10n.embyExports),
                    selected: !_controller.merged,
                    onSelected: (_) => _controller.showMerged(false),
                  ),
                  FilledButton.icon(
                    onPressed: library.busy && !_controller.merged
                        ? null
                        : () => _create(_controller.merged),
                    icon: Icon(_controller.merged ? Icons.merge : Icons.output),
                    label: Text(
                      _controller.merged
                          ? l10n.mergeDownloadedEpisodes
                          : l10n.exportDownloadedEpisodes,
                    ),
                  ),
                ],
              ),
            ),
            if (library.busy)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  children: [
                    LinearProgressIndicator(
                      value: library.progress > 0 ? library.progress : null,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(child: Text(library.status)),
                        TextButton(
                          onPressed: () => unawaited(library.cancel()),
                          child: Text(l10n.cancel),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            if (_controller.error != null || library.error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(_controller.error ?? library.error),
              ),
            if (!_controller.merged)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.embyFolderHint),
                    if (library.root != null)
                      TextButton.icon(
                        onPressed: () => Clipboard.setData(
                          ClipboardData(
                            text:
                                '${library.root}${Platform.pathSeparator}exports',
                          ),
                        ),
                        icon: const Icon(Icons.copy),
                        label: Text(l10n.copyEmbyDirectory),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: _controller.loading
                  ? const Center(child: CircularProgressIndicator())
                  : items.isEmpty
                  ? Center(
                      child: Text(
                        _controller.merged
                            ? l10n.mergeProductsEmpty
                            : l10n.noExportedMedia,
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                      itemCount: items.length,
                      itemBuilder: (context, index) {
                        final item = items[index];
                        return Card(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.drama.title,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  '${item.merged
                                      ? l10n.mergedEpisodes(item.episodes.length)
                                      : item.special
                                      ? l10n.specialRange(item.specialNumber, item.episodes.first, item.episodes.last)
                                      : l10n.episodeSingle(item.episodes.first)} · ${storageSize(item.bytes, l10n)}',
                                ),
                                if (item.merged)
                                  Text(
                                    l10n.transcodeSummary(
                                      item.videoTranscodes,
                                      item.audioTranscodes,
                                    ),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                if (item.merged)
                                  TextButton.icon(
                                    onPressed: library.busy
                                        ? null
                                        : () => _exportMerged(item),
                                    icon: const Icon(Icons.output_rounded),
                                    label: Text(l10n.exportToEmbySpecial),
                                  ),
                                Row(
                                  children: [
                                    TextButton.icon(
                                      onPressed: () => _play(item),
                                      icon: const Icon(Icons.play_arrow),
                                      label: Text(
                                        item.merged &&
                                                item.episodes.length ==
                                                    item.drama.episodes
                                            ? l10n.playAll
                                            : l10n.localPlay,
                                      ),
                                    ),
                                    const Spacer(),
                                    IconButton(
                                      tooltip: l10n.copyFilePath,
                                      onPressed: () => Clipboard.setData(
                                        ClipboardData(
                                          text: library.fileFor(item),
                                        ),
                                      ),
                                      icon: const Icon(Icons.copy),
                                    ),
                                    IconButton(
                                      tooltip: l10n.deleteProduct,
                                      onPressed: library.busy
                                          ? null
                                          : () => _remove(item),
                                      icon: const Icon(Icons.delete_outline),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      );
    },
  );
}

class _LocalFileRepository extends AppRepository {
  _LocalFileRepository(
    this.parent,
    this.store,
    this.item,
    this.file,
    this.l10n,
  );
  final AppRepository parent;
  final LocalStore store;
  final LocalMediaItem item;
  final String file;
  final AppLocalizations l10n;
  Future<PlaybackPlan> _plan() async {
    if (!store.canDownload || !store.allowsSource(item.drama.source)) {
      throw AppFailure(l10n.localMediaNoPermission);
    }
    if (!await File(file).exists() || await File(file).length() == 0) {
      throw AppFailure(l10n.localMediaMissing, code: 'local_media');
    }
    return PlaybackPlan(url: file, local: true);
  }

  @override
  Future<void> initialize() async {}
  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) => parent.catalog(
    source,
    page: page,
    query: query,
    category: category,
    force: force,
  );
  @override
  Future<CatalogPage> cached(String source, {String category = ''}) =>
      parent.cached(source, category: category);
  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) => parent.categories(source, force: force);
  @override
  Future<String> cover(Drama drama, {bool force = false}) =>
      parent.cover(drama, force: force);
  @override
  Future<DramaDetail> detail(Drama drama) => parent.detail(drama);
  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) => _plan();
  @override
  Future<PlaybackPlan?> localPlayback(Drama drama, Episode episode) => _plan();
  @override
  Future<PlaybackPlan> resolveOnline(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) => throw AppFailure(l10n.localMediaOnly);
  @override
  Future<PlaybackPlan> fallback(PlaybackPlan current) => _plan();
  @override
  Future<void> cancelPlayback() async {}
  @override
  Future<void> release(String session) async {}
}
