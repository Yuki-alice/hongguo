import 'package:duanju_app/data/core_bridge.dart';
import 'package:duanju_app/data/engine_backed_repository.dart';
import 'package:duanju_app/data/engine_repository.dart';
import 'package:duanju_app/data/engine_routing.dart';
import 'package:flutter_test/flutter_test.dart';

/// 双后端路由的纯逻辑测试：不触发网络或原生调用。
void main() {
  group('EngineRoute', () {
    test('disabled route never delegates', () {
      final policy = EngineRoute(enabled: false);
      expect(policy.allows('wuguo'), isFalse);
      expect(policy.allows('maoguo'), isFalse);
    });

    test('enabled route delegates when source set is empty', () {
      final policy = EngineRoute(enabled: true);
      expect(policy.allows('wuguo'), isTrue);
      expect(policy.allows('maoguo'), isTrue);
    });

    test('explicit source set narrows delegation', () {
      final policy = EngineRoute(enabled: true, sources: {'wuguo'});
      expect(policy.allows('wuguo'), isTrue);
      expect(policy.allows('maoguo'), isFalse);
    });

    test('empty source id is never delegated', () {
      expect(EngineRoute(enabled: true).allows(''), isFalse);
    });
  });

  group('EngineBackedRepository handles()', () {
    EngineBackedRepository build({
      required EngineRoute route,
      bool initialized = true,
    }) => EngineBackedRepository(
      delegate: NativeRepository(),
      engine: EngineRepository(initialized: initialized),
      route: route,
    );

    test('route disabled keeps every source on the Go core', () {
      expect(
        build(route: EngineRoute(enabled: false)).handles('wuguo'),
        isFalse,
      );
    });

    test('route enabled delegates when engine is ready', () {
      final repository = build(route: EngineRoute(enabled: true));
      expect(repository.handles('wuguo'), isTrue);
      expect(repository.handles('maoguo'), isTrue);
    });

    test('uninitialised engine never delegates', () {
      final repository = build(
        route: EngineRoute(enabled: true),
        initialized: false,
      );
      expect(
        repository.handles('wuguo'),
        isFalse,
        reason: '未初始化时调用 RustLib 会抛异常，必须回退到 Go',
      );
    });

    test('per-source allow list is honoured', () {
      final repository = build(
        route: EngineRoute(enabled: true, sources: {'wuguo'}),
      );
      expect(repository.handles('wuguo'), isTrue);
      expect(repository.handles('maoguo'), isFalse);
      expect(repository.handles('yeguo'), isFalse);
    });

    test('delegates capability flags to the wrapped repository', () {
      final core = NativeRepository();
      final repository = EngineBackedRepository(
        delegate: core,
        engine: EngineRepository(initialized: true),
        route: EngineRoute(enabled: true),
      );
      expect(repository.supportsDownloads, core.supportsDownloads);
      expect(
        repository.supportsSourceManagement,
        core.supportsSourceManagement,
      );
    });

    test('access forwards to the wrapped Go repository', () {
      final core = NativeRepository();
      final repository = EngineBackedRepository(
        delegate: core,
        engine: EngineRepository(initialized: true),
        route: EngineRoute(enabled: true),
      );
      expect(repository.access, isNull);
      expect(identical(repository.access, core.access), isTrue);
    });
  });

  group('EngineRouting defaults', () {
    test('is disabled without dart-define', () {
      expect(EngineRouting.enabled, isFalse);
      expect(EngineRouting.route.allows('wuguo'), isFalse);
      expect(EngineRouting.description, contains('未启用'));
    });
  });
}
