import 'dart:io';

import 'package:duanju_app/src/rust/frb_generated.dart';

/// 引擎测试的启动前置：加载 Rust 动态库并完成 FRB 初始化。
///
/// 生成代码把 `ioDirectory` 写死成 `engine/target/release/`，且 `flutter test`
/// 以仓库根为工作目录。`scripts/prepare_engine.py` 会把构建产物同时放到
/// `engine/target/` 与 `engine/bridge/target/`，因此正常情况下直接 init 即可，
/// 重新生成绑定时也不需要手工改生成文件。
///
/// 库缺失时这里先给出可执行的构建命令——否则 FRB 抛出的
/// 「Failed to load dynamic library」会把真正的原因（没构建）藏起来。
///
/// 用法：各引擎测试的 `setUpAll` 里 `await initEngineForTest();`。
Future<void> initEngineForTest() async {
  if (!_built()) {
    throw StateError(
      '未找到引擎动态库。请先在仓库根执行：\n'
      '  python scripts/prepare_engine.py\n'
      '（或 cargo build -p guo_engine --release --manifest-path engine/Cargo.toml）',
    );
  }
  await RustLib.init();
}

bool _built() {
  for (final profile in ['release', 'debug']) {
    final path = 'engine/target/$profile/${_libraryName()}';
    if (File(path).existsSync()) return true;
  }
  return false;
}

String _libraryName() {
  if (Platform.isWindows) return 'guo_engine.dll';
  if (Platform.isMacOS) return 'libguo_engine.dylib';
  return 'libguo_engine.so';
}
