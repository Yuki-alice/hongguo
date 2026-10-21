@Tags(['engine'])
library;

// 组件插件加载需要真实动态库；不访问网络。

import 'dart:io';

import 'package:duanju_app/data/engine_repository.dart';
import 'package:duanju_app/src/rust/api.dart' as rust;
import 'package:flutter_test/flutter_test.dart';

/// Core-3 验收：随包官方插件在首次启动时装进插件仓库，并且能被引擎加载。
///
/// 这里用仓库里的真实产物 `assets/bundled_plugins/*.zip`，与 App 启动时
/// 走的是同一份字节。
void main() {
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
    );
    for (final id in ['guo.maoguo', 'guo.yaguo', 'guo.niuguo']) {
      expect(repository.bundledInstalled, contains(id), reason: id);
    }

    final sources = await repository.sources();
    final ids = sources.map((source) => source.id).toList();
    for (final id in ['guo.maoguo', 'guo.yaguo', 'guo.niuguo']) {
      expect(ids, contains(id), reason: '预装的代码插件应出现在引擎清单里：$id');
    }
    final yaguo = sources.firstWhere((source) => source.id == 'guo.yaguo');
    expect(yaguo.supports('catalog'), isTrue);
    expect(yaguo.supports('categories'), isTrue);
    expect(yaguo.supports('resolve'), isTrue);
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
    ]) {
      expect(ids, contains(pair.$1), reason: '编译版 ${pair.$1}');
      expect(ids, contains(pair.$2), reason: '插件版 ${pair.$2}');
    }
  });
}
