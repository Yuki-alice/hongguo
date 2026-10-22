import 'dart:async';

import 'package:flutter/material.dart';

import 'package:hoshi/data/core_bridge.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/data/media/media_library.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/core/remote_widgets.dart';
import 'package:hoshi/ui/core/widgets.dart';

class MergeQueueScreen extends StatefulWidget {
  const MergeQueueScreen({
    super.key,
    required this.library,
    required this.repository,
    required this.store,
    this.addOnOpen = false,
  });
  final MediaLibrary library;
  final AppRepository repository;
  final LocalStore store;
  final bool addOnOpen;
  @override
  State<MergeQueueScreen> createState() => _MergeQueueScreenState();
}

class _MergeQueueScreenState extends State<MergeQueueScreen> {
  bool _loading = true, _adding = false;
  String? _error;
  late final int _epoch = widget.store.profileEpoch;
  bool get _allowed =>
      widget.store.canDownload && widget.store.profileEpoch == _epoch;
  @override
  void initState() {
    super.initState();
    ensureTelevisionFocus(context);
    _load();
  }

  Future<void> _load() async {
    try {
      await widget.library.merges.load();
      if (mounted && _allowed && widget.addOnOpen) await _add();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _add() async {
    if (_adding || !_allowed) return;
    final l10n = AppLocalizations.of(context);
    setState(() => _adding = true);
    try {
      final jobs = await widget.repository.downloads();
      if (!mounted || !_allowed) return;
      final groups = <String, List<DownloadJob>>{};
      for (final job in jobs.where((job) => job.completed)) {
        (groups[job.drama.id] ??= []).add(job);
      }
      final rows = groups.entries.toList();
      final errors = <String, String>{};
      for (final row in rows) {
        try {
          continuousMergeJobs(row.value);
        } catch (error) {
          errors[row.key] = error.toString();
        }
      }
      final selected = <String>{};
      var cleanup = false;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, change) => AlertDialog(
            title: Text(l10n.selectMergeDramas),
            content: SizedBox(
              width: 520,
              height: MediaQuery.sizeOf(context).height * .6,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(l10n.mergeQueueIntro),
                  const SizedBox(height: 8),
                  Expanded(
                    child: rows.isEmpty
                        ? Center(child: Text(l10n.needTwoContinuous))
                        : ListView.builder(
                            itemCount: rows.length,
                            itemBuilder: (_, index) {
                              final row = rows[index];
                              return CheckboxListTile(
                                contentPadding: EdgeInsets.zero,
                                value: selected.contains(row.key),
                                title: Text(row.value.first.drama.title),
                                subtitle: Text(
                                  errors[row.key] ??
                                      l10n.downloadedEpisodesRange(
                                        row.value.length,
                                        row.value
                                            .map((job) => job.episode.number)
                                            .reduce((a, b) => a < b ? a : b),
                                        row.value
                                            .map((job) => job.episode.number)
                                            .reduce((a, b) => a > b ? a : b),
                                      ),
                                ),
                                onChanged: errors.containsKey(row.key)
                                    ? null
                                    : (value) => change(() {
                                        if (value == true &&
                                            selected.length < 50) {
                                          selected.add(row.key);
                                        } else {
                                          selected.remove(row.key);
                                        }
                                      }),
                              );
                            },
                          ),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: cleanup,
                    title: Text(l10n.cleanupOriginals),
                    subtitle: Text(l10n.cleanupHint),
                    onChanged: (value) => change(() => cleanup = value == true),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.cancel),
              ),
              FilledButton(
                onPressed: selected.isEmpty
                    ? null
                    : () => Navigator.pop(context, true),
                child: Text(l10n.joinDramas(selected.length)),
              ),
            ],
          ),
        ),
      );
      if (accepted != true || !mounted || !_allowed) return;
      final count = await widget.library.merges.enqueue([
        for (final id in selected) groups[id]!,
      ], cleanup: cleanup);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.addedDramas(count))));
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _control(MergeQueueJob job, String action) async {
    if (!_allowed) return;
    try {
      await widget.library.merges.control(job.id, action);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.library,
    builder: (context, _) {
      final l10n = AppLocalizations.of(context);
      final jobs = widget.library.merges.items;
      return Scaffold(
        appBar: AppBar(
          title: Text(l10n.mergeQueueTitle),
          actions: [
            IconButton(
              tooltip: l10n.addMultipleDramas,
              onPressed: _adding || !_allowed ? null : _add,
              icon: const Icon(Icons.add_rounded),
            ),
          ],
        ),
        body: !_allowed
            ? StatusPanel(
                title: l10n.currentUserSwitched,
                message: l10n.reopenMergeQueue,
              )
            : _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_adding) const LinearProgressIndicator(),
                  if (_error != null || widget.library.merges.error.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(_error ?? widget.library.merges.error),
                    ),
                  Expanded(
                    child: jobs.isEmpty
                        ? StatusPanel(
                            title: l10n.noMergeTasks,
                            message: l10n.mergeQueueEmptyHint,
                            secondaryAction: FilledButton.icon(
                              onPressed: _adding ? null : _add,
                              icon: const Icon(Icons.add_rounded),
                              label: Text(l10n.addDramas),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.all(12),
                            itemCount: jobs.length,
                            itemBuilder: (_, index) {
                              final job = jobs[index];
                              final processing =
                                  job.state == 'running' ||
                                  job.state == 'cleanup';
                              return Card(
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Text(
                                        job.drama.title,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleMedium,
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        l10n.mergeEpisodeRange(
                                          job.episodes.first,
                                          job.episodes.last,
                                          job.label,
                                          job.cleanup
                                              ? ' · ${l10n.mergeCleaned}'
                                              : '',
                                        ),
                                      ),
                                      if (processing) ...[
                                        const SizedBox(height: 10),
                                        LinearProgressIndicator(
                                          value: widget.library.progress > 0
                                              ? widget.library.progress
                                              : null,
                                        ),
                                        const SizedBox(height: 6),
                                        Text(widget.library.status),
                                      ],
                                      if (job.error.isNotEmpty)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            top: 8,
                                          ),
                                          child: Text(job.error),
                                        ),
                                      Wrap(
                                        spacing: 8,
                                        children: [
                                          if (job.active)
                                            TextButton.icon(
                                              onPressed: () =>
                                                  _control(job, 'pause'),
                                              icon: const Icon(
                                                Icons.pause_rounded,
                                              ),
                                              label: Text(l10n.pause),
                                            ),
                                          if (job.state == 'paused' ||
                                              job.state == 'failed')
                                            TextButton.icon(
                                              onPressed: () =>
                                                  _control(job, 'resume'),
                                              icon: const Icon(
                                                Icons.play_arrow_rounded,
                                              ),
                                              label: Text(
                                                job.state == 'failed'
                                                    ? l10n.retry
                                                    : l10n.resume,
                                              ),
                                            ),
                                          if (job.state != 'completed' &&
                                              job.state != 'cancelled')
                                            TextButton(
                                              onPressed: () =>
                                                  _control(job, 'cancel'),
                                              child: Text(l10n.cancelTask),
                                            ),
                                          if (job.state == 'completed' ||
                                              job.state == 'cancelled')
                                            TextButton(
                                              onPressed: () =>
                                                  _control(job, 'forget'),
                                              child: Text(l10n.cleanRecords),
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
