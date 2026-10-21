import 'package:duanju_app/src/rust/frb_generated.dart';

/// 引擎测试的启动前置：完成 FRB 初始化。
///
/// Rust 动态库由 native-assets 构建钩子（hook/build.dart）在 `flutter test`
/// 启动时自动编译并注入，无需手工构建或准备产物。
///
/// 用法：各引擎测试的 `setUpAll` 里 `await initEngineForTest();`。
Future<void> initEngineForTest() async {
  await RustLib.init();
}
