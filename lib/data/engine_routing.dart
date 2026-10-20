import 'package:duanju_app/data/engine_repository.dart';

/// Rust 引擎的路由配置。
///
/// 通过 `--dart-define` 控制，默认关闭：
///
/// ```sh
/// # 全部站源走 Rust 引擎（引擎未声明支持的会自然抛错，便于暴露缺口）
/// flutter run --dart-define=ENGINE_ROUTE=all
///
/// # 仅指定站源走 Rust
/// flutter run --dart-define=ENGINE_ROUTE=wuguo,maoguo
/// ```
///
/// 未开启时应用行为与纯 Go 版本完全一致，可随时回退。
abstract final class EngineRouting {
  static const _route = String.fromEnvironment('ENGINE_ROUTE');

  /// 开关值：空表示关闭，`all` 表示全部，其余按逗号分隔的站源 id。
  static String get raw => _route.trim();

  static bool get enabled => raw.isNotEmpty;

  static EngineRoute get route {
    final value = raw;
    if (value.isEmpty) return EngineRoute(enabled: false);
    if (value == 'all') return EngineRoute(enabled: true);
    final sources = {
      for (final part in value.split(','))
        if (part.trim().isNotEmpty) part.trim(),
    };
    return EngineRoute(enabled: true, sources: sources);
  }

  /// 供诊断面板展示。
  static String get description {
    if (!enabled) return 'Rust 引擎未启用';
    final policy = route;
    if (policy.sources.isEmpty) return 'Rust 引擎：全部站源';
    return 'Rust 引擎：${policy.sources.join(", ")}';
  }
}
