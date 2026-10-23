import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import 'package:hoshi/data/app_contract.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/domain/models.dart';
import 'package:hoshi/ui/core/empty_state.dart';
import 'package:hoshi/ui/core/remote_widgets.dart';
import 'package:hoshi/domain/source_status.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/features/sources/controllers/sources_controller.dart';
import 'package:hoshi/ui/routing/app_router.dart';
import 'package:hoshi/ui/theme/md3_tokens.dart';

String sourceTimestamp(DateTime? value, AppLocalizations l10n) {
  if (value == null) return l10n.sourceNoRecord;
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.month}/${local.day} ${two(local.hour)}:${two(local.minute)}';
}

class SourcesScreen extends StatefulWidget {
  const SourcesScreen({
    super.key,
    required this.repository,
    required this.store,
    this.initialSource,
    this.drama,
  });

  final AppRepository repository;
  final LocalStore store;
  final String? initialSource;
  final Drama? drama;

  @override
  State<SourcesScreen> createState() => _SourcesScreenState();
}

class _SourcesScreenState extends State<SourcesScreen> {
  late final SourcesController _controller;

  @override
  void initState() {
    super.initState();
    _controller = SourcesController(
      repository: widget.repository,
      store: widget.store,
      initialSource: widget.initialSource,
      drama: widget.drama,
    );
    ensureTelevisionFocus(context);
    _controller.start();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _refresh() => _controller.refresh();

  Future<void> _run(SourceSite source, String operation) =>
      _controller.run(source, operation);

  Future<void> _copy(SourceSite source, SourceStatus status) async {
    final l10n = AppLocalizations.of(context);
    final text = StringBuffer('${source.name}\n');
    text.writeln(
      l10n.sourceCacheSummary(
        status.count,
        sourceTimestamp(status.updatedAt, l10n),
      ),
    );
    final health = status.health;
    if (health != null) {
      text.writeln(
        l10n.sourceHealthSummary(
          health.label,
          sourceTimestamp(health.checkedAt, l10n),
        ),
      );
      if (health.sample.isNotEmpty) {
        text.writeln(l10n.sourceSample(health.sample));
      }
      for (final step in health.steps) {
        text.writeln(l10n.sourceStep(step.name, step.message));
        text.writeln(
          l10n.sourceStepHost(step.host, step.httpStatus, step.elapsedMs),
        );
        if (step.cfRay.isNotEmpty) text.writeln(l10n.sourceCfRay(step.cfRay));
      }
    }
    if (status.error.isNotEmpty) text.writeln(status.error);
    if (status.storageError.isNotEmpty) text.writeln(status.storageError);
    await Clipboard.setData(ClipboardData(text: text.toString()));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.diagnosticsCopied)));
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([widget.store, _controller]),
    builder: (context, _) {
      final l10n = AppLocalizations.of(context);
      final sources = widget.store.sources.toList()
        ..sort((a, b) {
          final aFirst = a.id == widget.initialSource ? 0 : 1;
          final bFirst = b.id == widget.initialSource ? 0 : 1;
          return aFirst.compareTo(bFirst);
        });
      final viewPaddingBottom = MediaQuery.viewPaddingOf(context).bottom;
      final paddingBottom = MediaQuery.paddingOf(context).bottom;
      final bottomInset = viewPaddingBottom > paddingBottom
          ? viewPaddingBottom
          : paddingBottom;
      return Scaffold(
        appBar: AppBar(
          title: Text(l10n.sourcesTitle),
          actions: [
            IconButton(
              tooltip: l10n.pluginsTitle,
              onPressed: () => context.push(AppRoutes.plugins),
              icon: const Icon(Icons.extension_outlined),
            ),
          ],
        ),
        body: LayoutBuilder(
          builder: (context, constraints) {
            // 宽窗口双列：站源卡片是高信息量的独立单元，单列在 1000 以上
            // 会留下大片横向空白。用 Wrap 而不是 GridView：每张卡的高度
            // 随诊断信息展开而变，固定行高会截断内容。
            // 双列只在「宽窗口且真有两个以上源」时启用：只有一张卡片
            // 时按半宽摆放会让页面比单列更空。
            final columns =
                Md3WindowClass.usesTwoPane(constraints.maxWidth) &&
                    sources.length > 1
                ? 2
                : 1;
            final inset = Md3Spacing.pageInset(constraints.maxWidth);
            final available = constraints.maxWidth - inset * 2;
            final cardWidth =
                (available - (columns - 1) * Md3Spacing.md) / columns;
            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  inset,
                  Md3Spacing.lg,
                  inset,
                  Md3Spacing.lg + bottomInset,
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: Md3Spacing.lg),
                    child: Text(l10n.sourcesIntro),
                  ),
                  if (sources.isEmpty)
                    EmptyState(
                      title: l10n.sourcesEmpty,
                      icon: Icons.dns_outlined,
                    ),
                  for (final group in SourceGroup.fromSources(sources))
                    if (group.id == 'huangguo')
                      Padding(
                        padding: const EdgeInsets.only(bottom: Md3Spacing.md),
                        child: Card(
                          clipBehavior: Clip.antiAlias,
                          child: ExpansionTile(
                            key: const PageStorageKey(
                              'source-group-huangguo',
                            ),
                            initiallyExpanded: group.sources.any(
                              (source) => source.id == widget.initialSource,
                            ),
                            leading: const Icon(Icons.hub_outlined),
                            title: Text(l10n.sourceHuangguoGroup),
                            subtitle: Text(
                              l10n.sourceGroupSummary(
                                group.sources.length,
                                group.sources.fold<int>(
                                  0,
                                  (count, source) =>
                                      count +
                                      (_controller.statusOf(source.id)?.count ??
                                          0),
                                ),
                              ),
                            ),
                            childrenPadding: const EdgeInsets.all(
                              Md3Spacing.sm,
                            ),
                            children: [
                              _sourceWrap(group.sources, cardWidth, columns),
                            ],
                          ),
                        ),
                      )
                    else
                      _sourceWrap(group.sources, cardWidth, columns),
                ],
              ),
            );
          },
        ),
      );
    },
  );

  /// 把一组站源排成 1 或 2 列。
  Widget _sourceWrap(List<SourceSite> sources, double width, int columns) {
    if (columns == 1) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final source in sources)
            Padding(
              padding: const EdgeInsets.only(bottom: Md3Spacing.md),
              child: _sourceCard(source),
            ),
        ],
      );
    }
    return Wrap(
      spacing: Md3Spacing.md,
      runSpacing: Md3Spacing.md,
      children: [
        for (final source in sources)
          SizedBox(width: width, child: _sourceCard(source)),
      ],
    );
  }

  Widget _sourceCard(SourceSite source) {
    final l10n = AppLocalizations.of(context);
    final status = _controller.statusOf(source.id);
    final pending = _controller.pending(source.id);
    final busy = pending || status?.running == true;
    final seconds = status?.retrySeconds ?? 0;
    final enabled =
        !busy && seconds == 0 && widget.repository.supportsSourceManagement;
    final cachedError = _controller.errorOf(source.id);
    final error = cachedError.isEmpty ? status?.error ?? '' : cachedError;
    final health = status?.health;
    final healthExpanded = _controller.healthExpanded(source.id);
    final colors = Theme.of(context).colorScheme;
    return Card(
      key: ValueKey('source-${source.id}'),
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.dns_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    source.name,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                Text(l10n.sourceCount(status?.count ?? 0)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              l10n.sourceLastUpdated(sourceTimestamp(status?.updatedAt, l10n)),
            ),
            if (status != null && status.count > 0)
              Text(
                '${l10n.sourceLoadedPage(status.page)} · ${status.hasMore ? l10n.sourceCanLoadMore : l10n.sourcePageComplete}',
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  key: ValueKey('update-${source.id}'),
                  onPressed: enabled ? () => _run(source, 'update') : null,
                  icon: const Icon(Icons.sync_rounded),
                  label: Text(l10n.sourceUpdate),
                ),
                OutlinedButton.icon(
                  key: ValueKey('check-${source.id}'),
                  onPressed: enabled ? () => _run(source, 'check') : null,
                  icon: const Icon(Icons.network_check),
                  label: Text(l10n.sourceCheck),
                ),
                if (status?.running == true)
                  TextButton(
                    onPressed: pending ? null : () => _run(source, 'cancel'),
                    child: Text(l10n.sourceStop),
                  ),
                PopupMenuButton<String>(
                  tooltip: l10n.sourceMoreActions(source.name),
                  enabled: enabled,
                  onSelected: (operation) => _run(source, operation),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'more',
                      enabled: status?.hasMore ?? true,
                      child: Text(l10n.sourceLoadMore),
                    ),
                    PopupMenuItem(
                      value: 'metadata',
                      child: Text(l10n.sourceFillMetadata),
                    ),
                    if (source.id == 'huangdou')
                      PopupMenuItem(
                        value: 'vipMetadata',
                        enabled: (status?.unknownVip ?? 0) > 0,
                        child: Text(
                          l10n.sourceFillVip(status?.unknownVip ?? 0),
                        ),
                      ),
                    PopupMenuItem(
                      value: 'checkCatalog',
                      child: Text(l10n.sourceCheckCatalog),
                    ),
                  ],
                ),
              ],
            ),
            if (busy) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: status != null && status.total > 0
                    ? (status.completed / status.total).clamp(0, 1)
                    : null,
              ),
              const SizedBox(height: 8),
              Text(
                '${status?.stage.isNotEmpty == true ? status!.stage : l10n.sourcePreparing}'
                '${(status?.total ?? 0) > 0 ? ' · ${status!.completed}/${status.total}' : ''}',
              ),
            ] else if (status != null && status.stage.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                '${status.stage}'
                '${status.added > 0 ? ' · ${l10n.sourceAdded(status.added)}' : ''}',
              ),
            ],
            if (seconds > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  l10n.sourceRetryIn(seconds),
                  style: TextStyle(color: colors.error),
                ),
              ),
            if (error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SelectableText(
                  error,
                  style: TextStyle(color: colors.error),
                ),
              ),
            if (status != null && status.storageError.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      status.storageError,
                      style: TextStyle(color: colors.error),
                    ),
                    TextButton.icon(
                      key: ValueKey('save-${source.id}'),
                      onPressed:
                          !busy && widget.repository.supportsSourceManagement
                          ? () => _run(source, 'retrySave')
                          : null,
                      icon: const Icon(Icons.save_outlined),
                      label: Text(l10n.sourceRetrySave),
                    ),
                  ],
                ),
              ),
            if (health != null) ...[
              const Divider(height: 28),
              Row(
                children: [
                  Expanded(
                    child: Semantics(
                      expanded: healthExpanded,
                      child: Tooltip(
                        message: healthExpanded
                            ? l10n.sourceCollapseHealth
                            : l10n.sourceExpandHealth,
                        child: TextButton(
                          key: ValueKey('health-toggle-${source.id}'),
                          onPressed: () => _controller.toggleHealth(source.id),
                          style: TextButton.styleFrom(
                            foregroundColor: colors.onSurface,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 8,
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(health.label),
                                    Text(
                                      sourceTimestamp(health.checkedAt, l10n),
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Icon(
                                healthExpanded
                                    ? Icons.expand_less_rounded
                                    : Icons.expand_more_rounded,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.sourceCopyDiagnostics,
                    onPressed: () => _copy(source, status!),
                    icon: const Icon(Icons.copy_rounded),
                  ),
                ],
              ),
              if (healthExpanded) ...[
                if (health.sample.isNotEmpty)
                  Text(l10n.sourceSample(health.sample)),
                for (final step in health.steps)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          step.state == 'ok'
                              ? Icons.check_circle_outline
                              : Icons.error_outline,
                          size: 20,
                          color: step.state == 'ok'
                              ? colors.primary
                              : colors.error,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(l10n.sourceStep(step.name, step.message)),
                              if (step.host.isNotEmpty || step.httpStatus > 0)
                                Text(
                                  step.httpStatus > 0
                                      ? l10n.sourceStepHost(
                                          step.host,
                                          step.httpStatus,
                                          step.elapsedMs,
                                        )
                                      : l10n.sourceStepHostNoStatus(
                                          step.host,
                                          step.elapsedMs,
                                        ),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ] else ...[
              const SizedBox(height: 12),
              Text(l10n.sourceNotTested),
            ],
          ],
        ),
      ),
    );
  }
}

class SourceDiagnosticsButton extends StatelessWidget {
  const SourceDiagnosticsButton({
    super.key,
    required this.repository,
    required this.store,
    required this.drama,
  });
  final AppRepository repository;
  final LocalStore store;
  final Drama drama;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return TextButton.icon(
      onPressed: () =>
          context.push(AppRoutes.sourcesOf(drama.source), extra: drama),
      icon: const Icon(Icons.network_check),
      label: Text(l10n.sourceDiagnostics),
    );
  }
}
