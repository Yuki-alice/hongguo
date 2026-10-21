import 'package:flutter/services.dart';

import 'package:duanju_app/src/rust/api.dart' as rust;

/// 读取随包分发的官方插件，交给引擎在初始化时预装。
///
/// 资源布局（`pubspec.yaml` 的 `assets/bundled_plugins/`）：
///
/// ```text
/// assets/bundled_plugins/index.json            # 官方索引（可含多条）
/// assets/bundled_plugins/guo.<id>-<ver>.zip    # 包体
/// ```
///
/// 读取失败返回空列表：随包资源缺失属于构建缺陷，应记日志而不是拦住启动，
/// 诊断页可以看到「没有预装任何插件」。
class BundledPlugins {
  static const _root = 'assets/bundled_plugins';

  /// 加载全部随包插件。
  static Future<List<rust.BundledPlugin>> load({
    AssetBundle? bundle,
    void Function(String message)? warn,
  }) async {
    final assets = bundle ?? rootBundle;
    final String indexText;
    try {
      indexText = await assets.loadString('$_root/index.json');
    } on Object catch (error) {
      warn?.call('随包插件索引读取失败，跳过预装：$error');
      return const [];
    }

    final paths = _packagePaths(indexText);
    if (paths.isEmpty) return const [];

    final loaded = <rust.BundledPlugin>[];
    for (final path in paths) {
      try {
        final data = await assets.load('$_root/$path');
        loaded.add(
          rust.BundledPlugin(
            name: path,
            // 每包单独一份索引：引擎按 id 选条目，不必让索引与包严格配对。
            indexJson: indexText,
            archive: data.buffer.asUint8List(),
          ),
        );
      } on Object catch (error) {
        warn?.call('随包插件 $path 读取失败：$error');
      }
    }
    return loaded;
  }

  /// 从索引里取出所有 `path` 字段。解析失败按「没有插件」处理。
  ///
  /// 不引入 `dart:convert` 之外的正则解析：索引是构建产物，格式由
  /// `pack_rules` / `pack_component` 固定，这里只要能容忍未来新增字段。
  static List<String> _packagePaths(String indexText) {
    final matcher = RegExp(r'"path"\s*:\s*"([^"]+)"');
    final paths = <String>[];
    for (final match in matcher.allMatches(indexText)) {
      final path = match.group(1);
      if (path == null || path.isEmpty) continue;
      // 只接受包内相对路径：`path` 来自构建产物，但不应允许跳出资源目录。
      if (path.contains('..') || path.startsWith('/')) continue;
      if (!paths.contains(path)) paths.add(path);
    }
    return paths;
  }
}
