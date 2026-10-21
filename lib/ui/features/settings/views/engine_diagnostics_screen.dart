import 'dart:async';

import 'package:flutter/material.dart';

import 'package:duanju_app/data/engine_failure.dart';
import 'package:duanju_app/data/engine_repository.dart';
import 'package:duanju_app/data/repository_capabilities.dart';
import 'package:duanju_app/l10n/generated/app_localizations.dart';

/// 引擎诊断页。
///
/// 两个用途：
/// 1. 把「哪些能力当前不支持」明确列出来（Core-0 验收：未支持能力可见）；
/// 2. 展示引擎自身的版本、路径、能力矩阵、插件加载结果与最近错误（Core-1 诊断）。
///
/// 页面只读，不提供修复动作：源健康 / 批量扫描属于暂缓项（PLAN.md §5）。
class EngineDiagnosticsScreen extends StatefulWidget {
  const EngineDiagnosticsScreen({
    super.key,
    required this.engine,
    required this.capabilities,
  });

  final EngineRepository engine;
  final RepositoryCapabilities capabilities;

  @override
  State<EngineDiagnosticsScreen> createState() => _EngineDiagnosticsScreenState();
}

class _EngineDiagnosticsScreenState extends State<EngineDiagnosticsScreen> {
  EngineDiagnosticsInfo? _snapshot;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final snapshot = await widget.engine.diagnostics();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.engineDiagnosticsTitle),
        actions: [
          IconButton(
            key: const ValueKey('engine-diagnostics-refresh'),
            tooltip: l10n.retry,
            onPressed: _loading ? null : () => unawaited(_load()),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _buildBody(theme, l10n),
    );
  }

  Widget _buildBody(ThemeData theme, AppLocalizations l10n) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(describeFailure(error), textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: () => unawaited(_load()), child: Text(l10n.retry)),
            ],
          ),
        ),
      );
    }
    final snapshot = _snapshot!;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _Section(
          title: l10n.engineDiagnosticsRuntime,
          children: [
            _Row(label: l10n.engineDiagnosticsVersion, value: snapshot.version),
            _Row(label: l10n.engineDiagnosticsData, value: snapshot.dataDirectory),
            _Row(label: l10n.engineDiagnosticsPlugins, value: snapshot.pluginDirectory),
            _Row(
              label: l10n.engineDiagnosticsUptime,
              value: _duration(snapshot.uptime),
            ),
            _Row(
              label: l10n.engineDiagnosticsRequests,
              value: '${snapshot.requestCount}',
            ),
            _Row(
              label: l10n.engineDiagnosticsSessions,
              value: '${snapshot.sessionKeys} · ${snapshot.activeSessions}',
            ),
            _Row(
              label: l10n.engineDiagnosticsCache,
              value: '${snapshot.cachedCatalogs}',
            ),
            _Row(
              label: l10n.engineDiagnosticsJobs,
              value:
                  '${snapshot.queuedJobs} / ${snapshot.runningJobs} / '
                  '${snapshot.completedJobs} / ${snapshot.failedJobs}',
            ),
          ],
        ),
        const SizedBox(height: 16),
        _Section(
          title: l10n.engineDiagnosticsCapabilities,
          children: _capabilityRows(l10n),
        ),
        const SizedBox(height: 16),
        _Section(
          title: l10n.engineDiagnosticsSources,
          children: [
            for (final source in snapshot.sources)
              _Row(
                label: '${source.name}（${source.id}）',
                value: source.capabilities.join(' · '),
              ),
          ],
        ),
        if (snapshot.pluginsLoaded.isNotEmpty || snapshot.pluginsFailed.isNotEmpty) ...[
          const SizedBox(height: 16),
          _Section(
            title: l10n.engineDiagnosticsPluginReport,
            children: [
              for (final id in snapshot.pluginsLoaded)
                _Row(label: id, value: l10n.engineDiagnosticsPluginLoaded),
              for (final failure in snapshot.pluginsFailed)
                _Row(label: failure.id, value: failure.detail),
            ],
          ),
        ],
        if (snapshot.recentErrors.isNotEmpty) ...[
          const SizedBox(height: 16),
          _Section(
            title: l10n.engineDiagnosticsRecentErrors,
            children: [
              for (final failure in snapshot.recentErrors)
                _Row(label: failure.kind.name, value: failure.message),
            ],
          ),
        ],
      ],
    );
  }

  /// 能力矩阵：明确写出「不支持」而不是省略，用户才知道入口为什么不见了。
  List<Widget> _capabilityRows(AppLocalizations l10n) {
    final capabilities = widget.capabilities;
    return [
      _Row(label: l10n.engineDiagnosticsCatalog, value: _flag(true, l10n)),
      _Row(label: l10n.engineDiagnosticsPlayback, value: _flag(true, l10n)),
      _Row(label: l10n.engineDiagnosticsDownloads, value: _flag(capabilities.downloads, l10n)),
      _Row(label: l10n.engineDiagnosticsDanmaku, value: _flag(capabilities.danmaku, l10n)),
      _Row(label: l10n.engineDiagnosticsRankings, value: _flag(capabilities.rankings, l10n)),
      _Row(
        label: l10n.engineDiagnosticsRecommendations,
        value: _flag(capabilities.recommendations, l10n),
      ),
      _Row(
        label: l10n.engineDiagnosticsSuggestions,
        value: _flag(capabilities.suggestions, l10n),
      ),
      _Row(
        label: l10n.engineDiagnosticsSourceManagement,
        value: _flag(capabilities.sourceManagement, l10n),
      ),
      _Row(
        label: l10n.engineDiagnosticsResourceSettings,
        value: _flag(capabilities.resourceSettings, l10n),
      ),
      _Row(label: l10n.engineDiagnosticsLan, value: _flag(capabilities.lan, l10n)),
    ];
  }

  String _flag(bool supported, AppLocalizations l10n) => supported
      ? l10n.engineDiagnosticsSupported
      : l10n.engineDiagnosticsUnsupported;

  String _duration(Duration value) {
    if (value.inHours > 0) return '${value.inHours}h ${value.inMinutes % 60}m';
    if (value.inMinutes > 0) return '${value.inMinutes}m ${value.inSeconds % 60}s';
    return '${value.inSeconds}s';
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 132,
            child: Text(label, style: theme.textTheme.bodyMedium),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 供测试与调用方判断诊断页是否可达。
bool get engineDiagnosticsAvailable => true;

/// 失败类别名称（诊断页与错误提示共用）。
String failureKindLabel(EngineFailureKind kind) => switch (kind) {
  EngineFailureKind.unsupported => '不支持',
  EngineFailureKind.network => '网络',
  EngineFailureKind.timeout => '超时',
  EngineFailureKind.http => 'HTTP',
  EngineFailureKind.parseChanged => '解析',
  EngineFailureKind.session => '会话',
  EngineFailureKind.blocked => '受限',
  EngineFailureKind.cancelled => '已取消',
  EngineFailureKind.storage => '存储',
  EngineFailureKind.plugin => '插件',
  EngineFailureKind.internal => '内部',
};
