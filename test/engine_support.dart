import 'dart:io';

import 'package:duanju_app/src/rust/api.dart';
import 'package:duanju_app/src/rust/frb_generated.dart';

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
  await RustLib.init();
  final directory = Directory.systemTemp
      .createTempSync('guo-engine-test-')
      .path;
  await initEngineWithDirectory(dataDirectory: directory, pluginDirectory: '');
}
