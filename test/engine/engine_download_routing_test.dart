import 'package:hoshi/data/core_bridge.dart';
import 'package:hoshi/data/engine_backed_repository.dart';
import 'package:hoshi/data/engine_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// 引擎接管判定的纯逻辑测试：不再有路由开关，只区分「引擎是否就绪」。
void main() {
  EngineBackedRepository build({bool initialized = true}) =>
      EngineBackedRepository(
        delegate: NativeRepository(),
        engine: EngineRepository(initialized: initialized),
      );

  test('initialised engine handles every known source', () {
    final repository = build();
    expect(repository.handles('wuguo'), isTrue);
    expect(repository.handles('hongguo'), isTrue);
    expect(repository.handles('dsd'), isTrue);
  });

  test('empty source is never handled', () {
    expect(build().handles(''), isFalse);
  });

  test('uninitialised engine hands off to the delegate', () {
    expect(build(initialized: false).handles('wuguo'), isFalse);
  });

  test('engine job table starts empty', () {
    expect(build().downloadContextCount, 0);
  });

  test('capabilities report what is actually implemented', () {
    final capabilities = build().capabilities;
    // 引擎已接管的 D4 能力。
    expect(capabilities.rankings, isTrue);
    expect(capabilities.recommendations, isTrue);
    expect(capabilities.suggestions, isTrue);
    // 弹幕已接入（引擎按分集返回，Dart 侧补分页窗口）。
    expect(capabilities.danmaku, isTrue);
    // LAN 与高级网络设置本轮明确不做，入口必须隐藏。
    expect(capabilities.lan, isFalse);
    expect(capabilities.resourceSettings, isFalse);
  });
}
