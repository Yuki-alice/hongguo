# POC-2：flutter_rust_bridge 四端可行性

日期：2026-10-18
结论：**通过（Windows 未在本机验证）**

## 验证内容

| 平台 | 验证方式 | 结果 |
| --- | --- | --- |
| iOS | 构建 + 模拟器集成测试真实调用 Rust | ✅ `All tests passed!` |
| macOS | 构建 | ✅ `Built build/macos/.../frb_gen.app` |
| Android | 构建（4 ABI 交叉编译） | ✅ APK 产出，~750s |
| Windows | 本机无法链接（缺 MSVC `lib.exe`） | ⚠️ 未验证，需 Windows/CI |

iOS 集成测试断言：

```dart
expect(find.textContaining('Result: `Hello, Tom!`'), findsOneWidget);
```

该断言只有在 Rust 的 `greet()` 被真实调用并返回时才通过。

## 版本

- `flutter_rust_bridge` 2.13.0（本地已有缓存）
- `flutter_rust_bridge_codegen` 2.13.0
- Flutter 3.47.7 / Rust 1.97.1

## 发现的问题

1. **SPM 警告**：`rust_lib_*` 插件不支持 Swift Package Manager，当前只是 warning，但 Flutter 提示「This will become an error in a future version of Flutter」。
   现有主项目 `pubspec.yaml` 已显式设置 `enable-swift-package-manager: false`，与此一致。
2. **iOS 模拟器需 arm64 + 显式 triple**：见 POC-1 文档的 `BINDGEN_EXTRA_CLANG_ARGS` 说明。
3. **Android 首次构建慢**：需交叉编译 4 个 ABI，首次约 12 分钟，增量后显著加快。

## 对方案的意义

FRB 的桥接能力在 iOS / macOS / Android 上已验证可用，覆盖主项目当前支持的三端，
并补上主项目缺失的 macOS。Windows 需在 Windows 机器或 CI 上补验。

现有 `lib/core_bridge.dart` 存在两个 FRB 可直接消除的问题：
- 每次调用 `DynamicLibrary.open` + `lookupFunction`；
- 每次调用 `Isolate.run` 新建 isolate。

FRB 的生成绑定等价于「绑定一次 + 二进制 codec + 原生 StreamSink」，无需手写。
