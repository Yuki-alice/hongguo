import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:hoshi/data/batch_downloads.dart';
import 'package:hoshi/data/app_contract.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/routing/app_router.dart';
import 'package:hoshi/ui/core/surfaces.dart';
import 'package:hoshi/ui/core/widgets.dart';
import 'package:hoshi/ui/theme/md3_tokens.dart';
import 'package:hoshi/ui/shell/window_chrome.dart';

class BatchDownloadScreen extends StatefulWidget {
  const BatchDownloadScreen({
    super.key,
    required this.repository,
    required this.store,
    required this.dramas,
  });
  final AppRepository repository;
  final LocalStore store;
  final List<Drama> dramas;

  @override
  State<BatchDownloadScreen> createState() => _BatchDownloadScreenState();
}

class _BatchDownloadScreenState extends State<BatchDownloadScreen> {
  late final BatchDownloads _batch;

  @override
  void initState() {
    super.initState();
    _batch = BatchDownloads(widget.repository, widget.store, widget.dramas);
    unawaited(_batch.prepare());
  }

  @override
  void dispose() {
    _batch.dispose();
    super.dispose();
  }

  String _subtitle(BatchDownloadItem item, AppLocalizations l10n) {
    if (item.loading) return l10n.readingEpisodes;
    if (item.error != null) return item.error!;
    if (item.detail == null) return l10n.waitingEpisodes;
    final count = item.episodes(_batch.includeVip).length;
    final vip = item.detail!.episodes.where((episode) => episode.vip).length;
    if (count == 0) return l10n.noNonVip;
    final pieces = <String>[
      l10n.selectedEpisodes(count),
      if (!_batch.includeVip && vip > 0) l10n.excludedVip(vip),
      if (item.added > 0) l10n.addedEpisodes(item.added),
      if (item.existing > 0) l10n.existingEpisodes(item.existing),
      if (_batch.settingsLocked && item.pending(_batch.includeVip).isEmpty)
        l10n.queued,
      if (item.detail!.warning.isNotEmpty) item.detail!.warning,
    ];
    return pieces.join(' · ');
  }

  void _openDownloads() => context.push(AppRoutes.downloads);

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([_batch, widget.store]),
    builder: (context, _) {
      final l10n = AppLocalizations.of(context);
      return Scaffold(
        appBar: DesktopAppBar(title: Text(l10n.batchDownloadTitle)),
        body: SafeArea(
          top: false,
          child: !_batch.hasAccess
              ? StatusPanel(
                  title: l10n.downloadPermissionChanged,
                  message: l10n.reselectDramas,
                )
              : Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: Md3Spacing.contentMaxWidth,
                    ),
                    child: Column(
                      children: [
                        if (_batch.busy)
                          const LinearProgressIndicator(minHeight: 2),
                        Expanded(
                          child: ListView(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                            children: [
                              Text(
                                l10n.batchCount(_batch.items.length),
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: 8),
                              Text(l10n.batchIntro),
                              const SizedBox(height: 12),
                              DropdownButtonFormField<int>(
                                key: const ValueKey('batch-download-quality'),
                                initialValue: _batch.quality,
                                isExpanded: true,
                                decoration: InputDecoration(
                                  labelText: l10n.downloadQuality,
                                ),
                                onChanged: _batch.busy || _batch.settingsLocked
                                    ? null
                                    : (value) => _batch.setQuality(value ?? 0),
                                items: [
                                  DropdownMenuItem(
                                    value: 0,
                                    child: Text(l10n.autoHighPriority),
                                  ),
                                  for (final quality in [1080, 720, 480])
                                    DropdownMenuItem(
                                      value: quality,
                                      child: Text('${quality}P'),
                                    ),
                                ],
                              ),
                              CheckboxListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(l10n.includeVip),
                                subtitle: Text(l10n.vipPreviewHint),
                                value: _batch.includeVip,
                                onChanged: _batch.busy || _batch.settingsLocked
                                    ? null
                                    : (value) =>
                                          _batch.setIncludeVip(value ?? false),
                              ),
                              if (_batch.warning.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: Text(
                                    _batch.warning,
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.error,
                                    ),
                                  ),
                                ),
                              if (_batch.current != null)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: Text(
                                    '${_batch.submitting ? l10n.addingDramas : l10n.readingDramas}'
                                    '：${_batch.current!.drama.title}',
                                  ),
                                ),
                              for (final item in _batch.items)
                                TonalCard(
                                  child: CheckboxListTile(
                                    key: ValueKey(
                                      'batch-drama-${item.drama.id}',
                                    ),
                                    value: item.selected,
                                    onChanged:
                                        _batch.busy || _batch.settingsLocked
                                        ? null
                                        : (value) => _batch.select(
                                            item,
                                            value ?? false,
                                          ),
                                    title: Text(
                                      item.detail?.drama.title ??
                                          item.drama.title,
                                    ),
                                    subtitle: Text(
                                      _subtitle(item, l10n),
                                      style: item.error == null
                                          ? null
                                          : TextStyle(
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.error,
                                            ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                [
                                  l10n.addedEpisodes(_batch.added),
                                  l10n.existingEpisodes(_batch.existing),
                                  if (_batch.failures > 0)
                                    l10n.batchRetry(_batch.failures),
                                  if (_batch.stopped) l10n.batchStopped,
                                ].join(' · '),
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                alignment: WrapAlignment.end,
                                children: [
                                  if (_batch.busy)
                                    OutlinedButton(
                                      onPressed: _batch.stopping
                                          ? null
                                          : _batch.stop,
                                      child: Text(
                                        _batch.stopping
                                            ? l10n.stopping
                                            : _batch.submitting
                                            ? l10n.stopAdding
                                            : l10n.stopReading,
                                      ),
                                    )
                                  else ...[
                                    if (_batch.unread > 0)
                                      OutlinedButton(
                                        onPressed: _batch.prepare,
                                        child: Text(l10n.readRemaining),
                                      ),
                                    if (_batch.added + _batch.existing > 0 &&
                                        widget.store.canDownload)
                                      TextButton(
                                        onPressed: _openDownloads,
                                        child: Text(l10n.viewDownloads),
                                      ),
                                    FilledButton.icon(
                                      key: const ValueKey(
                                        'submit-batch-downloads',
                                      ),
                                      onPressed:
                                          !widget.store.canDownload ||
                                              _batch.pendingEpisodes == 0
                                          ? null
                                          : _batch.submit,
                                      icon: const Icon(Icons.download_rounded),
                                      label: Text(
                                        l10n.batchSubmit(
                                          _batch.settingsLocked
                                              ? l10n.continueAdding
                                              : l10n.addDownloads,
                                          _batch.pendingEpisodes,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
        ),
      );
    },
  );
}
