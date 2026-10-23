// 重集成套件：随包插件要编译并加载真实动态库，单文件约 18 秒。
// 需要时：flutter test --tags slow --run-skipped
@Tags(['slow'])
library;

// 组件插件加载需要真实动态库；不访问网络。

import 'dart:io';

import 'package:hoshi/data/bundled_plugins.dart';
import 'package:hoshi/data/engine_repository.dart';
import 'package:hoshi/src/rust/api.dart' as rust;
import 'package:flutter_test/flutter_test.dart';

import '../support/engine_setup.dart';

/// Core-3 验收：随包官方插件在首次启动时装进插件仓库，并且能被引擎加载。
///
/// 这里用仓库里的真实产物 `assets/bundled_plugins/*.zip`，与 App 启动时
/// 走的是同一份字节。
void main() {
  // rootBundle 需要 ServicesBinding：这条用例读的是真实资源包，
  // 不是自己拼的文件路径。
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dataDir;

  setUpAll(() {
    dataDir = Directory.systemTemp.createTempSync('guo-bundled-');
  });

  tearDownAll(() {
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
  });

  test('随包插件被预装并能从注册表查到', () async {
    final index = File('assets/bundled_plugins/index.json').readAsStringSync();
    final packages = <rust.BundledPlugin>[
      for (final name in [
        'guo.maoguo-1.0.0.zip',
        'guo.yaguo-1.0.0.zip',
        'guo.niuguo-1.0.0.zip',
        'guo.huangju-1.0.0.zip',
        'guo.huangguo-video-1.0.0.zip',
        'guo.huangguo-ai-1.0.0.zip',
        'guo.cloudfront-1.0.0.zip',
      ])
        rust.BundledPlugin(
          name: name,
          indexJson: index,
          archive: File('assets/bundled_plugins/$name').readAsBytesSync(),
        ),
    ];

    final repository = await EngineRepository.create(
      dataDirectory: dataDir.path,
      bundled: packages,
      engineLibrary: resolveEngineLibrary(),
    );
    for (final id in [
      'guo.maoguo',
      'guo.yaguo',
      'guo.niuguo',
      'guo.huangju',
      'guo.huangguo-video',
      'guo.huangguo-ai',
      'guo.cloudfront',
    ]) {
      expect(repository.bundledInstalled, contains(id), reason: id);
    }

    final sources = await repository.sources();
    final ids = sources.map((source) => source.id).toList();
    for (final id in [
      'guo.maoguo',
      'guo.yaguo',
      'guo.niuguo',
      'guo.huangju',
      'guo.huangguo-video',
      'guo.huangguo-ai',
      'guo.cloudfront',
    ]) {
      expect(ids, contains(id), reason: '预装的代码插件应出现在引擎清单里：$id');
    }
    final yaguo = sources.firstWhere((source) => source.id == 'guo.yaguo');
    expect(yaguo.supports('catalog'), isTrue);
    expect(yaguo.supports('categories'), isTrue);
    expect(yaguo.supports('resolve'), isTrue);
  });

  test('资源包里的随包插件能被 BundledPlugins.load 读到', () async {
    // 这条用例守的是**资源路径**，不是引擎预装：
    // `index.json` 的 `path` 是仓库布局（`plugins/<id>/<file>`），而 Flutter
    // 打包只会平铺 `assets/bundled_plugins/` 下的文件。两者不一致时
    // `BundledPlugins.load` 会静默返回空列表，App 里 7 个代码源全部消失，
    // 但日志只有一行 warn——上线前极易漏掉。
    //
    // 这里用真实的 rootBundle（测试会加载本仓库的 assets），而不是自己拼
    // File 路径，才能真正覆盖打包后的布局。
    final warnings = <String>[];
    final packages = await BundledPlugins.load(warn: warnings.add);

    expect(warnings, isEmpty, reason: '资源读取不应告警：${warnings.join('; ')}');
    expect(packages, hasLength(7), reason: '随包插件应有 7 个');
    for (final package in packages) {
      expect(package.archive, isNotEmpty, reason: package.name);
      expect(package.name, isNot(contains('plugins/')), reason: '应命中平铺布局');
    }
  });

  test('诊断页能看到预装结果', () async {
    final repository = EngineRepository.attached();
    final diagnostics = await repository.diagnostics();
    // 编译版猫果与插件版 guo.maoguo 同时存在是刻意的：
    // Core-3 迁移完成前不做删除，避免正式包丢源。
    final ids = diagnostics.sources.map((source) => source.id).toList();
    // 编译版与插件版并存：Core-3 迁移完成前不删除编译源。
    for (final pair in [
      ('maoguo', 'guo.maoguo'),
      ('yaguo', 'guo.yaguo'),
      ('niuguo', 'guo.niuguo'),
      ('huangju', 'guo.huangju'),
      ('huangguo-video', 'guo.huangguo-video'),
      ('huangguoai', 'guo.huangguo-ai'),
      ('cloudfront', 'guo.cloudfront'),
    ]) {
      expect(ids, contains(pair.$1), reason: '编译版 ${pair.$1}');
      expect(ids, contains(pair.$2), reason: '插件版 ${pair.$2}');
    }
  });
}
