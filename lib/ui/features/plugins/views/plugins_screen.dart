import 'package:flutter/material.dart';

import 'package:hoshi/data/plugin_repository.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/core/rule_card.dart';
import 'package:hoshi/ui/core/empty_state.dart';
import 'package:hoshi/ui/core/app_page.dart';
import 'package:hoshi/ui/core/surfaces.dart';
import 'package:hoshi/ui/features/plugins/controllers/plugins_controller.dart';
import 'package:hoshi/ui/theme/md3_tokens.dart';
import 'package:hoshi/ui/shell/window_chrome.dart';

/// 插件仓库管理页。
///
/// 与站源管理页的分工：站源页看「当前能用什么」，这里管「从哪装、装哪个版本」。
class PluginsScreen extends StatefulWidget {
  const PluginsScreen({super.key, required this.repository});

  final PluginRepository repository;

  @override
  State<PluginsScreen> createState() => _PluginsScreenState();
}

class _PluginsScreenState extends State<PluginsScreen> {
  late final PluginsController _controller;
  final _repoField = TextEditingController(
    text: 'https://raw.githubusercontent.com/guoapp-rules/repo/main/repo.toml',
  );
  final _search = TextEditingController();
  String _query = '';
  bool _updatesOnly = false;

  /// 内容类型筛选；`null` 表示全部。只有仓库里出现过的类型才显示筛选片。
  String? _type;

  @override
  void initState() {
    super.initState();
    _controller = PluginsController(repository: widget.repository);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller.refresh();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _repoField.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final query = _query.trim().toLowerCase();
        final updates = _controller.installed
            .where(_controller.hasUpdate)
            .length;
        // 类型筛选片按「实际出现过的类型」生成：空仓库不放一排死按钮。
        final types = <String>[
          for (final type in _contentTypeOrder)
            if (_controller.available.any((entry) => entry.hasType(type)) ||
                _controller.installed.any((entry) => entry.hasType(type)))
              type,
        ];
        final available = _controller.available
            .where((entry) => _type == null || entry.hasType(_type!))
            .toList();
        final installed = _controller.installed.where((entry) {
          final matches =
              query.isEmpty ||
              entry.name.toLowerCase().contains(query) ||
              entry.id.toLowerCase().contains(query);
          return matches && (!_updatesOnly || _controller.hasUpdate(entry));
        }).toList();
        // 版式照参照应用 `plugin_view_page.dart`：顶部介绍块 → 搜索框 →
        // 「全部 / 可更新」筛选片 → 规则卡片列表。不是左侧导航 + 右栏的形态。
        return Scaffold(
          appBar: DesktopAppBar(
            title: Text(l10n.pluginsManageTitle),
            actions: [
              IconButton(
                tooltip: l10n.pluginsRefresh,
                onPressed: _controller.loading ? null : _controller.refresh,
                icon: const Icon(Icons.refresh),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: AppPage(
            vertical: 12,
            child: ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                _intro(l10n),
                const SizedBox(height: 20),
                TextField(
                  controller: _search,
                  onChanged: (value) => setState(() => _query = value),
                  decoration: InputDecoration(
                    hintText: l10n.pluginsSearchHint,
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: l10n.clearSearch,
                            onPressed: () {
                              _search.clear();
                              setState(() => _query = '');
                            },
                            icon: const Icon(Icons.close_rounded),
                          ),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilterChip(
                      label: Text(
                        l10n.pluginsAllCount(_controller.installed.length),
                      ),
                      selected: !_updatesOnly,
                      onSelected: (_) => setState(() => _updatesOnly = false),
                    ),
                    FilterChip(
                      label: Text(l10n.pluginsUpdatesCount(updates)),
                      selected: _updatesOnly,
                      onSelected: (value) =>
                          setState(() => _updatesOnly = value),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (installed.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: EmptyState(
                      compact: true,
                      title: query.isEmpty && !_updatesOnly
                          ? l10n.pluginsEmpty
                          : l10n.pluginsNoMatch,
                    ),
                  )
                else
                  for (final entry in installed) _installedCard(entry, l10n),
                const SizedBox(height: 24),
                _repoSection(l10n),
                if (_controller.available.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Text(
                        l10n.pluginsAvailable,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${available.length}/${_controller.available.length}',
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (types.isNotEmpty)
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        FilterChip(
                          label: Text(l10n.pluginsTypeAll),
                          selected: _type == null,
                          onSelected: (_) => setState(() => _type = null),
                        ),
                        for (final type in types)
                          FilterChip(
                            label: Text(_typeLabel(l10n, type)),
                            selected: _type == type,
                            onSelected: (selected) =>
                                setState(() => _type = selected ? type : null),
                          ),
                      ],
                    ),
                  const SizedBox(height: 8),
                  if (available.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: EmptyState(compact: true, title: l10n.pluginsNoMatch),
                    )
                  else
                    for (final entry in available) _availableCard(entry, l10n),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  /// 顶部介绍块，照参照应用 `RulePageIntro`：primaryContainer 底、32 圆角、
  /// 24 内边距、headlineMedium 标题、右上角 32 图标。
  Widget _intro(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(Md3Shape.extraLargeIncreased),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  l10n.pluginsMyRules,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: colors.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Icon(
                Icons.extension_rounded,
                size: 32,
                color: colors.onPrimaryContainer,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            l10n.pluginsRulesDescription,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onPrimaryContainer,
            ),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
                onPressed: _controller.loading
                    ? null
                    : () => _controller.loadRepository(_repoField.text.trim()),
                icon: const Icon(Icons.add_rounded),
                label: Text(l10n.pluginsAddRule),
              ),
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(minimumSize: const Size(120, 48)),
                onPressed: () => _scrollToRepo(),
                icon: const Icon(Icons.travel_explore_rounded),
                label: Text(l10n.pluginsRuleStore),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _scrollToRepo() {
    // 仓库地址就在卡片列表下方，直接滚过去，不做额外的弹层。
    Scrollable.ensureVisible(
      _repoKey.currentContext ?? context,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  final _repoKey = GlobalKey();

  Widget _repoSection(AppLocalizations l10n) {
    final repoKey = 'repo:${_repoField.text.trim()}';
    final busy = _controller.busy(repoKey);
    final error = _controller.errorOf(repoKey);
    return TonalCard(
      key: _repoKey,
      padding: const EdgeInsets.all(Md3Spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.pluginsRepoSection),
          const SizedBox(height: Md3Spacing.sm),
          TextField(
            controller: _repoField,
            decoration: InputDecoration(
              labelText: l10n.pluginsRepoUrl,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: Md3Spacing.sm),
          Row(
            children: [
              FilledButton.icon(
                onPressed: busy
                    ? null
                    : () => _controller.loadRepository(_repoField.text.trim()),
                icon: const Icon(Icons.cloud_download_outlined),
                label: Text(l10n.pluginsLoadRepo),
              ),
              const SizedBox(width: Md3Spacing.md),
              if (busy)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: AppLoadingIndicator(size: 20),
                ),
            ],
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: Md3Spacing.sm),
              child: Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }

  Widget _installedCard(PluginEntry entry, AppLocalizations l10n) {
    final busy = _controller.busy(entry.id);
    final error = _controller.errorOf(entry.id);
    final colors = Theme.of(context).colorScheme;
    final tagStyle = (colors.surfaceContainerHighest, colors.onSurfaceVariant);
    return RuleCard(
      title: entry.name,
      installed: true,
      subtitle: entry.isCode
          ? l10n.pluginsKindCode
          : l10n.pluginsKindDeclarative,
      tags: [
        RuleTag(
          label: entry.version,
          background: tagStyle.$1,
          foreground: tagStyle.$2,
        ),
        RuleTag(
          label: entry.signed ? l10n.pluginsSigned : l10n.pluginsUnsigned,
          background: tagStyle.$1,
          foreground: tagStyle.$2,
        ),
        for (final type in entry.contentTypes)
          RuleTag(
            label: _typeLabel(l10n, type),
            background: tagStyle.$1,
            foreground: tagStyle.$2,
          ),
        RuleTag(
          label: entry.enabled ? l10n.pluginStateOn : l10n.pluginStateOff,
          background: entry.enabled
              ? colors.secondaryContainer
              : colors.surfaceContainerHighest,
          foreground: entry.enabled
              ? colors.onSecondaryContainer
              : colors.onSurfaceVariant,
        ),
      ],
      caption: error,
      trailing: busy
          ? const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox.square(
                dimension: 20,
                child: AppLoadingIndicator(size: 20),
              ),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: entry.enabled,
                  onChanged: (value) => _controller.setEnabled(entry.id, value),
                ),
                AppMenuButton(
                  menuChildren: [
                    AppMenuItem(
                      label: l10n.pluginsUninstall,
                      destructive: true,
                      onPressed: () => _confirmUninstall(entry, l10n),
                    ),
                  ],
                  builder: (context, toggle, open) => IconButton(
                    tooltip: l10n.more,
                    onPressed: toggle,
                    icon: const Icon(Icons.more_vert_rounded),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _availableCard(PluginEntry entry, AppLocalizations l10n) {
    final busy = _controller.busy(entry.id);
    final update = _controller.hasUpdate(entry);
    final installed = _controller.installed.any((item) => item.id == entry.id);
    final colors = Theme.of(context).colorScheme;
    return RuleCard(
      title: entry.name,
      subtitle: entry.isCode
          ? l10n.pluginsKindCode
          : l10n.pluginsKindDeclarative,
      tags: [
        RuleTag(
          label: entry.version,
          background: colors.surfaceContainerHighest,
          foreground: colors.onSurfaceVariant,
        ),
        RuleTag(
          label: entry.signed ? l10n.pluginsSigned : l10n.pluginsUnsigned,
          background: colors.surfaceContainerHighest,
          foreground: colors.onSurfaceVariant,
        ),
        for (final type in entry.contentTypes)
          RuleTag(
            label: _typeLabel(l10n, type),
            background: colors.surfaceContainerHighest,
            foreground: colors.onSurfaceVariant,
          ),
        if (update)
          RuleTag(
            label: l10n.pluginsUpdate,
            background: colors.secondaryContainer,
            foreground: colors.onSecondaryContainer,
          ),
      ],
      trailing: busy
          ? const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox.square(
                dimension: 20,
                child: AppLoadingIndicator(size: 20),
              ),
            )
          : TextButton(
              onPressed: installed && !update ? null : () => _install(entry),
              child: Text(
                update
                    ? l10n.pluginsUpdate
                    : installed
                    ? l10n.pluginsInstalledAction
                    : l10n.pluginsInstall,
              ),
            ),
    );
  }

  /// 类型展示顺序：与宿主 `ContentType::ALL` 一致。
  static const _contentTypeOrder = <String>[
    'short-drama',
    'movie',
    'tv',
    'anime',
    'variety',
    'documentary',
  ];

  /// 内容类型 → 本地化标签。未知类型原样显示，便于第三方扩展新增类型时排查。
  String _typeLabel(AppLocalizations l10n, String type) => switch (type) {
    'short-drama' => l10n.contentTypeShortDrama,
    'movie' => l10n.contentTypeMovie,
    'tv' => l10n.contentTypeTv,
    'anime' => l10n.contentTypeAnime,
    'variety' => l10n.contentTypeVariety,
    'documentary' => l10n.contentTypeDocumentary,
    _ => type,
  };

  Future<void> _install(PluginEntry entry) async {
    final ok = await _controller.install(
      entry,
      repoUrl: _repoField.text.trim(),
    );
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? l10n.pluginsInstalledDone(entry.name)
              : l10n.pluginsInstallFailed,
        ),
      ),
    );
  }

  Future<void> _confirmUninstall(
    PluginEntry entry,
    AppLocalizations l10n,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.pluginsUninstall),
        content: Text(l10n.pluginsUninstallConfirm(entry.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.pluginsUninstall),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _controller.uninstall(entry.id);
    }
  }
}
