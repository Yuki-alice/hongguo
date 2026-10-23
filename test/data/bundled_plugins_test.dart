import 'dart:convert';

import 'package:hoshi/data/bundled_plugins.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 用内存资源包模拟真实布局。
///
/// 关键点：`pubspec.yaml` 声明的是目录 `assets/bundled_plugins/`，Flutter
/// 打包时会把该目录下的文件**平铺**进资源包；而 `index.json` 里的 `path`
/// 字段是仓库布局 `plugins/<id>/<file>`。两者不一致，正是曾经让全部随包
/// 插件静默装不上的原因。
class _MemoryBundle extends CachingAssetBundle {
  _MemoryBundle(this.files);
  final Map<String, String> files;

  @override
  Future<ByteData> load(String key) async {
    final text = files[key];
    if (text == null) throw FlutterError('资源不存在：$key');
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(text)));
  }
}

String _indexJson(List<String> paths) => jsonEncode([
  for (final path in paths)
    {'id': 'guo.maoguo', 'version': '1.0.0', 'path': path},
]);

void main() {
  test('索引里的仓库路径能找到平铺的资源', () async {
    final warnings = <String>[];
    final bundle = _MemoryBundle({
      'assets/bundled_plugins/index.json': _indexJson([
        'plugins/guo.maoguo/guo.maoguo-1.0.0.zip',
      ]),
      // 打包后的实际布局：平铺，没有 plugins/<id>/ 这一层。
      'assets/bundled_plugins/guo.maoguo-1.0.0.zip': 'PK-fake-archive',
    });

    final loaded = await BundledPlugins.load(
      bundle: bundle,
      warn: warnings.add,
    );

    expect(warnings, isEmpty, reason: '平铺布局应当能直接命中，不该告警');
    expect(loaded, hasLength(1));
    expect(loaded.single.name, 'guo.maoguo-1.0.0.zip');
    expect(loaded.single.archive, isNotEmpty);
  });

  test('仓库布局（未平铺）同样能找到', () async {
    final warnings = <String>[];
    final bundle = _MemoryBundle({
      'assets/bundled_plugins/index.json': _indexJson([
        'plugins/guo.maoguo/guo.maoguo-1.0.0.zip',
      ]),
      'assets/bundled_plugins/plugins/guo.maoguo/guo.maoguo-1.0.0.zip':
          'PK-fake-archive',
    });

    final loaded = await BundledPlugins.load(
      bundle: bundle,
      warn: warnings.add,
    );

    expect(warnings, isEmpty);
    expect(loaded, hasLength(1));
    expect(loaded.single.name, 'plugins/guo.maoguo/guo.maoguo-1.0.0.zip');
  });

  test('两个布局都找不到时告警而不是抛错', () async {
    final warnings = <String>[];
    final bundle = _MemoryBundle({
      'assets/bundled_plugins/index.json': _indexJson([
        'plugins/guo.maoguo/guo.maoguo-1.0.0.zip',
      ]),
    });

    final loaded = await BundledPlugins.load(
      bundle: bundle,
      warn: warnings.add,
    );

    expect(loaded, isEmpty);
    expect(warnings, hasLength(1));
    expect(warnings.single, contains('读取失败'));
  });

  test('索引缺失时返回空列表且不抛错', () async {
    final warnings = <String>[];
    final loaded = await BundledPlugins.load(
      bundle: _MemoryBundle({}),
      warn: warnings.add,
    );
    expect(loaded, isEmpty);
    expect(warnings, hasLength(1));
  });
}
