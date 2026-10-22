import 'package:hoshi/data/engine_backed_repository.dart';
import 'package:hoshi/data/engine_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// 引擎接管判定的纯逻辑测试。
///
/// Go 后端已在 Core-4 物理移除，因此这里不再有「交回下层」的语义：
/// 引擎未就绪时该站源直接不可用（`handles` 为 false），调用会得到
/// `UnsupportedFailure`，而不是静默降级到另一套实现。
void main() {
  EngineBackedRepository build({bool initialized = true}) =>
      EngineBackedRepository(
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

  test('uninitialised engine handles nothing', () {
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
    // 下载与离线播放由引擎索引承担；Go 删除后不再依赖下层能力探测。
    expect(capabilities.downloads, isTrue);
    expect(capabilities.localPlayback, isTrue);
    // LAN 已随 Core-4 删除，入口必须隐藏。
    expect(capabilities.lan, isFalse);
    // 资源设置已迁入引擎（并发 / 间隔 / 代理），入口应可见。
    expect(capabilities.resourceSettings, isTrue);
    // 站源诊断尚未迁入引擎，诊断页据实标注。
    expect(capabilities.sourceManagement, isFalse);
  });
}
