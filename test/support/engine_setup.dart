import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:hoshi/src/rust/api.dart';
import 'package:hoshi/src/rust/frb_generated.dart';

/// 引擎测试的启动前置：完成 FRB 初始化，并初始化进程级引擎单例。
///
/// Rust 动态库由 native-assets 构建钩子（hook/build.dart）在 `flutter test`
/// 启动时自动编译并注入，无需手工构建或准备产物。
///
/// 单例一旦建立就跨用例共享（这正是被测行为的一部分），数据目录固定在
/// 系统临时目录下，避免污染开发机上的真实应用数据。
///
/// 用法：各引擎测试的 `setUpAll` 里 `await initEngineForTest();`。
Future<void> initEngineForTest() async {
  await RustLib.init(externalLibrary: resolveEngineLibrary());
  final directory = Directory.systemTemp
      .createTempSync('guo-engine-test-')
      .path;
  await initEngineWithDirectory(
    dataDirectory: directory,
    pluginDirectory: '',
    bundled: const [],
  );
}

/// 显式指明钩子产物路径。
///
/// `flutter test` 把代码资产放进 `build/native_assets/<os>/`：Windows 会顺带
/// 把它加进 PATH，裸名 `DynamicLibrary.open` 能找到；Linux / macOS 不会，
/// 于是报 `cannot open shared object file`。这里统一给绝对路径，三端一致。
/// 找不到时返回 null，退回生成代码的默认解析（打包后的应用走资产映射）。
ExternalLibrary? resolveEngineLibrary() {
  final (directory, fileName) = switch (Platform.operatingSystem) {
    'windows' => ('windows', 'guo_engine.dll'),
    'macos' => ('macos', 'libguo_engine.dylib'),
    _ => ('linux', 'libguo_engine.so'),
  };
  final library = File('build/native_assets/$directory/$fileName');
  if (!library.existsSync()) return null;
  return ExternalLibrary.open(library.absolute.path);
}
