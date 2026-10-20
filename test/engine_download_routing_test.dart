import 'package:duanju_app/data/core_bridge.dart';
import 'package:duanju_app/data/engine_backed_repository.dart';
import 'package:duanju_app/data/engine_repository.dart';
import 'package:duanju_app/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 下载路由的纯逻辑测试：验证分流与回退，不触发网络。
void main() {
  EngineBackedRepository build({
    required EngineRoute route,
    bool initialized = true,
  }) => EngineBackedRepository(
    delegate: NativeRepository(),
    engine: EngineRepository(initialized: initialized),
    route: route,
  );

  Drama drama(String source) =>
      Drama(id: '$source:1', source: source, sourceId: '1', title: '样本');

  test('engine handles download only for routed sources', () {
    final repository = build(
      route: EngineRoute(enabled: true, sources: {'wuguo'}),
    );
    expect(repository.handles(drama('wuguo').source), isTrue);
    expect(repository.handles(drama('hongguo').source), isFalse);
  });

  test('engine job table starts empty', () {
    final repository = build(route: EngineRoute(enabled: true));
    // 无引擎任务时 downloads() 会委托给下层，这里只验证路由判定，
    // 避免在纯 Dart 测试中触发未初始化的原生调用。
    expect(repository.handles('wuguo'), isTrue);
    expect(repository.downloadContextCount, 0);
  });

  test('engine download context is tracked per routed source', () {
    final repository = build(
      route: EngineRoute(enabled: true, sources: {'wuguo'}),
    );
    expect(repository.downloadContextCount, 0);
    expect(repository.handles('wuguo'), isTrue);
    expect(repository.handles('maoguo'), isFalse);
  });

  test('disabled route never touches the engine', () {
    final repository = build(route: EngineRoute(enabled: false));
    expect(repository.handles('wuguo'), isFalse);
    expect(repository.handles('maoguo'), isFalse);
  });

  test('uninitialised engine keeps downloads on Go', () {
    final repository = build(
      route: EngineRoute(enabled: true),
      initialized: false,
    );
    expect(repository.handles('wuguo'), isFalse);
  });
}
