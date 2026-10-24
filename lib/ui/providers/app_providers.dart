import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hoshi/data/app_contract.dart';
import 'package:hoshi/data/local_store.dart';
import 'package:hoshi/data/plugin_repository.dart';
import 'package:hoshi/ui/core/app_layout.dart';

/// 应用级依赖的 Provider 根。
///
/// 所有需要仓库、用户存储或设备信息的对象都从这里取，不再逐层构造函数注入。
/// 根依赖在 `main()` 里通过 `ProviderScope.overrides` 注入真实实现；
/// 测试同样用 override 注入假仓库，因此业务代码不感知实现来源。
final repositoryProvider = Provider<AppRepository>(
  (ref) => throw UnimplementedError('repositoryProvider 必须被 override'),
);

/// 插件仓库入口。
///
/// 单独一个 Provider 而不是挂在 `AppRepository` 上：
/// 插件管理属于「引擎能力」，与站源取数是两条独立的失败域，
/// 插件装坏了不应该让站源列表也起不来。
///
/// 构造时直接标记已初始化：`RustLib` 与引擎在 `main()` 的启动装配里
/// 已经初始化完成，`overrideWithValue` 注入的就是真实依赖。
/// **不要**在这里调 `PluginRepository.create()`——它会再跑一次 `RustLib.init`；
/// 也不返回未初始化实例：那会让插件页永远显示「没有已安装插件」，
/// 卸载 / 启停 / 回滚全部静默无效。
final pluginRepositoryProvider = Provider<PluginRepository>(
  (ref) => PluginRepository.ready(),
);

/// 当前登录用户的数据仓库。
///
/// 用 `Notifier` 而不是 `overrideWithValue`：override 的值变化不会通知下游，
/// 路由与首屏就无法响应「用户数据就绪」。Notifier 的 `state` 变化会正常
/// 触发 `ref.watch` 的依赖重建。
class StoreHolder extends Notifier<LocalStore?> {
  StoreHolder([this._initial]);

  /// 初始值必须在 `build()` 里返回：`state` 在 `build()` 完成前不可写。
  final LocalStore? _initial;

  @override
  LocalStore? build() => _initial;

  /// 设置当前用户仓库；传 null 表示回到未加载状态。
  void assign(LocalStore? value) => state = value;
}

final storeProvider = NotifierProvider<StoreHolder, LocalStore?>(
  StoreHolder.new,
);

/// 已就绪的用户仓库。
///
/// 只应在确认 `storeProvider` 非空之后读取，否则抛出可读的错误。
final readyStoreProvider = Provider<LocalStore>((ref) {
  final store = ref.watch(storeProvider);
  if (store == null) throw StateError('用户数据尚未就绪');
  return store;
});

/// 把 [LocalStore] 的 `ChangeNotifier` 通知桥接进 Riverpod。
///
/// `LocalStore` 是 `ChangeNotifier`，`notifyListeners()` 不会经过 Riverpod：
/// `ref.watch(storeProvider)` 只在 `state` 被重新赋值时触发，而改主题只是
/// 原地修改对象字段。这里订阅一次 store 并在每次通知时递增
/// 计数器，让依赖 `store.xxx` 字段的 provider 有可 watch 的刷新信号。
class StoreRevision extends Notifier<int> {
  @override
  int build() {
    final store = ref.watch(storeProvider);
    if (store == null) return 0;
    void bump() => state = state + 1;
    store.addListener(bump);
    ref.onDispose(() => store.removeListener(bump));
    return 0;
  }
}

final storeRevisionProvider = NotifierProvider<StoreRevision, int>(
  StoreRevision.new,
);

/// 设备形态与版本信息。
final deviceProvider = Provider<AppDevice>((ref) => const AppDevice());

/// 主题模式偏好；未选择用户时跟随系统。
final themeModeProvider = Provider<String>((ref) {
  ref.watch(storeRevisionProvider);
  return ref.watch(storeProvider)?.themeMode ?? 'system';
});

/// 主题个性化偏好的快照。
///
/// 合成一个对象而不是三个 provider：主题只需要重建一次，拆开会让
/// `MaterialApp` 在改一个选项时重建三次。
@immutable
class ThemePreferences {
  const ThemePreferences({
    this.seed,
    this.dynamic = false,
    this.oled = false,
    this.useSystemFont = false,
  });

  /// 种子色（ARGB 十六进制字符串），null 表示品牌默认色。
  final String? seed;
  final bool dynamic;
  final bool oled;
  final bool useSystemFont;

  Color? get seedColor {
    final value = seed;
    if (value == null || value.length != 8) return null;
    final parsed = int.tryParse(value, radix: 16);
    return parsed == null ? null : Color(parsed);
  }

  @override
  bool operator ==(Object other) =>
      other is ThemePreferences &&
      other.seed == seed &&
      other.dynamic == dynamic &&
      other.oled == oled &&
      other.useSystemFont == useSystemFont;

  @override
  int get hashCode => Object.hash(seed, dynamic, oled, useSystemFont);
}

final themePreferencesProvider = Provider<ThemePreferences>((ref) {
  ref.watch(storeRevisionProvider);
  final store = ref.watch(storeProvider);
  if (store == null) return const ThemePreferences();
  return ThemePreferences(
    seed: store.themeSeed,
    dynamic: store.useDynamicColor,
    oled: store.oledEnhance,
    useSystemFont: store.useSystemFont,
  );
});

/// 供 go_router 的 `refreshListenable` 使用的桥接。
///
/// 用户数据就绪、用户切换、锁定状态变化时，路由需要重新解析首屏；
/// go_router 实例本身不能重建（会丢掉返回栈），因此用一个会触发刷新的
/// Listenable。`storeProvider` 的 `state` 变化与 store 自身的
/// `ChangeNotifier` 通知都要转发，否则「解锁后进入首页」不会发生。
class StoreRefreshNotifier extends ChangeNotifier {
  StoreRefreshNotifier(Ref ref) {
    LocalStore? attached;
    void refresh() => notifyListeners();
    // 用闭包持有当前订阅的 store：`onDispose` 里不能再用 ref，
    // Riverpod 会断言「生命周期回调中不得访问 provider」。
    void attach(LocalStore? store) {
      if (identical(attached, store)) return;
      attached?.removeListener(refresh);
      attached = store;
      store?.addListener(refresh);
    }

    attach(ref.read(storeProvider));
    ref.listen<LocalStore?>(storeProvider, (_, next) {
      attach(next);
      refresh();
    });
    ref.onDispose(() {
      attached?.removeListener(refresh);
      attached = null;
    });
  }
}

final storeRefreshProvider = Provider<StoreRefreshNotifier>((ref) {
  final notifier = StoreRefreshNotifier(ref);
  ref.onDispose(notifier.dispose);
  return notifier;
});
