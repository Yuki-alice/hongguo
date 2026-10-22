import 'package:hoshi/data/engine_failure.dart';
import 'package:hoshi/data/engine_repository.dart';
import 'package:hoshi/data/repository_capabilities.dart';
import 'package:hoshi/l10n/generated/app_localizations.dart';
import 'package:hoshi/ui/features/settings/views/engine_diagnostics_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 诊断页只依赖 `EngineRepository` 的诊断快照，这里用子类注入固定数据。
class _FakeEngine extends EngineRepository {
  _FakeEngine({this.snapshot, this.error});

  final EngineDiagnosticsInfo? snapshot;
  final Object? error;
  int calls = 0;

  @override
  Future<EngineDiagnosticsInfo> diagnostics() async {
    calls++;
    final failure = error;
    if (failure != null) throw failure;
    return snapshot!;
  }
}

EngineDiagnosticsInfo _snapshot() => EngineDiagnosticsInfo(
  version: '0.3.0',
  dataDirectory: '/data/engine',
  pluginDirectory: '/data/engine/plugins',
  sessionFile: '/data/engine/sessions.json',
  catalogFile: '/data/engine/catalogs.json',
  uptime: const Duration(minutes: 3, seconds: 20),
  requestCount: 42,
  registryRevision: 2,
  activeSessions: 1,
  sessionKeys: 3,
  cachedCatalogs: 5,
  queuedJobs: 1,
  runningJobs: 1,
  completedJobs: 7,
  failedJobs: 2,
  sources: const [
    SourceCapabilityInfo(
      id: 'hongguo',
      name: '红果',
      group: 'duanju',
      apiLevel: 1,
      capabilities: ['catalog', 'detail', 'danmaku'],
    ),
    SourceCapabilityInfo(
      id: 'dsd',
      name: '帝果',
      group: 'duanju',
      apiLevel: 1,
      capabilities: ['catalog', 'detail', 'search'],
    ),
  ],
  pluginsLoaded: const ['guo.official'],
  pluginsFailed: const [PluginFailureInfo(id: 'guo.broken', detail: '规则损坏')],
  recentErrors: [
    EngineException(kind: EngineFailureKind.network, message: '连接超时'),
  ],
);

Widget _wrap(Widget child) => MaterialApp(
  locale: const Locale('zh'),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  home: child,
);

void main() {
  testWidgets('展示运行状态、能力矩阵与站源能力', (tester) async {
    await tester.pumpWidget(
      _wrap(
        EngineDiagnosticsScreen(
          engine: _FakeEngine(snapshot: _snapshot()),
          capabilities: const RepositoryCapabilities(
            downloads: false,
            danmaku: false,
            rankings: true,
            recommendations: true,
            suggestions: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('0.3.0'), findsOneWidget);
    expect(find.text('/data/engine'), findsOneWidget);
    expect(find.text('42'), findsOneWidget);

    // 站源 / 插件 / 错误都在首屏之外，需要滚动到可见再断言。
    await tester.scrollUntilVisible(
      find.textContaining('dsd'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    // 站源能力：引擎清单里的源都要列出，并带上能力位。
    expect(find.textContaining('hongguo'), findsWidgets);
    expect(find.textContaining('dsd'), findsWidgets);

    await tester.scrollUntilVisible(
      find.text('连接超时'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    // 插件失败原因必须可见，否则用户只看到「插件没生效」。
    expect(find.text('规则损坏'), findsOneWidget);
    // 最近错误按类别 + 文案展示。
    expect(find.text('连接超时'), findsOneWidget);
  });

  testWidgets('不支持的能力显式标注而不是省略', (tester) async {
    await tester.pumpWidget(
      _wrap(
        EngineDiagnosticsScreen(
          engine: _FakeEngine(snapshot: _snapshot()),
          capabilities: const RepositoryCapabilities(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 每一项能力都要有一行；关闭的项写「当前版本不支持」。
    expect(find.text('下载与离线播放'), findsOneWidget);
    expect(find.text('局域网设备互联'), findsOneWidget);
    expect(find.text('当前版本不支持'), findsWidgets);
    // 支持的项也要能出现（目录 / 详情 / 搜索恒为支持）。
    expect(find.text('支持'), findsWidgets);
  });

  testWidgets('读取失败时给出可重试提示', (tester) async {
    await tester.pumpWidget(
      _wrap(
        EngineDiagnosticsScreen(
          engine: _FakeEngine(
            error: EngineException(
              kind: EngineFailureKind.internal,
              message: '读取失败',
            ),
          ),
          capabilities: const RepositoryCapabilities(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('读取失败，请重试'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('刷新按钮会重新读取快照', (tester) async {
    final engine = _FakeEngine(snapshot: _snapshot());
    await tester.pumpWidget(
      _wrap(
        EngineDiagnosticsScreen(
          engine: engine,
          capabilities: const RepositoryCapabilities(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(engine.calls, 1);

    await tester.tap(find.byKey(const ValueKey('engine-diagnostics-refresh')));
    await tester.pumpAndSettle();
    expect(engine.calls, 2);
  });

  test('失败类别都有中文标签', () {
    for (final kind in EngineFailureKind.values) {
      expect(failureKindLabel(kind), isNotEmpty, reason: kind.name);
    }
  });
}
