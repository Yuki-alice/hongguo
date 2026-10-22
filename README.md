# 星（hoshi）

独立运行的多端视频应用（短剧 / 动漫 / 电影 / 剧集，站源由插件扩展）：Flutter 前端 + Rust 本地引擎，端侧完成请求、解析、播放、下载与合并，
不依赖自建服务端。

## 一套后端：Rust 引擎

| 目录 | 语言 | 规模 | 角色 |
| --- | --- | --- | --- |
| `lib/` | Dart / Flutter | ~5 万行 | 应用与全部 UI |
| `rust/` | Rust | ~2 万行 | **唯一后端**：站源、解析、播放、下载、缓存、插件 |

发布包与 `flutter run` 跑的都是 Rust 引擎：`lib/main.dart` 装配 `EngineBackedRepository`，
引擎不可用时启动页报错并提供重试。Go 后端已在 Core-4 物理删除，仓库内不再有第二套实现，
因此也不存在「静默降级成功能不全」的路径——未接入的能力由 `capabilities` 如实报告，
UI 据此隐藏入口。

## 目录结构

```
lib/
  main.dart            启动装配
  app_build.dart       站源门控（ALL_SOURCES）与应用名
  data/                仓库、本地存储、媒体 / LAN / 播放 / 画质增强
  domain/              剧集、榜单、LAN、偏好等纯模型
  ui/
    features/<name>/   页面级 feature：views / controllers / widgets
    core/              跨 feature 的布局、主题、通用控件
    providers/ routing/ theme/
  src/rust/            flutter_rust_bridge 生成的绑定（勿手改）
  l10n/                ARB 模板与生成的本地化代码
test/                  镜像 lib/ 结构；根层放跨功能与引擎测试
rust/
  Cargo.toml           虚清单（workspace）
  bridge/              只做 FRB 边界，实现在 crates/*
  crates/              source-api（零 IO 契约）/ runtime / rule-engine /
                       plugin-host / plugin-wasm / host / media / source-*
  rules/               随包分发的声明式站源（JSON）
  rust-toolchain.toml  钉住工具链版本与交付目标（crate 目录内还有一份镜像）
docs/                  架构、审计、进度、POC、交接记录
scripts/               Windows 构建冒烟（唯一的 CLI 之外工具）
hook/build.dart        native-assets 构建钩子：flutter build/test 时自动编译引擎
```

UI 分层遵循 Flutter 官方指南：**UI 按 feature 切分，data / domain 按类型切分**。
新页面放 `lib/ui/features/<feature>/views/`，控制器放 `controllers/`，页面专用控件放 `widgets/`。

## 构建

前置：Flutter SDK、Rust 工具链（rustup，版本由 `rust/rust-toolchain.toml` 钉住）；
Android 另需 NDK 与 JDK 17。**不需要 Go**——引擎动态库由 native-assets 钩子
（`hook/build.dart`）在 `flutter build` / `flutter test` 时自动经 Cargo 构建并打包，
和纯 Flutter 项目一样直接使用 Flutter CLI：

**单版本**：应用名固定为「星」。`ALL_SOURCES` 只决定**编译进哪些站源**——
iOS 全源，Android / Windows / macOS 只带内置站源。

```sh
# Windows / macOS / Android（内置站源）
flutter build windows --release --dart-define=ALL_SOURCES=false
flutter build macos   --release --dart-define=ALL_SOURCES=false
flutter build apk --release --split-per-abi --dart-define=ALL_SOURCES=false

# iOS（全源；未签名 ipa 走 .github/workflows/convert-ios-ipa.yml）
flutter build ios --release --no-codesign --dart-define=ALL_SOURCES=true
```

日常开发直接用 `flutter run` / `flutter test`，钩子会自动处理引擎。
产物在 `build/` 对应平台目录，CI 直接从那里上传。唯一的辅助脚本是发布包验收：

```sh
python scripts/smoke_windows.py     # Windows：ffmpeg 合成媒体 + 无头启动 exe 验收
```

## 测试

```sh
# Dart 单元 / 控件测试（含离线引擎用例；引擎库由钩子自动构建）
flutter test
flutter test --tags engine          # 只跑 2 个真实站点用例（在线）
flutter test --coverage             # 覆盖率（CI 收集为产物）

# Rust
cargo test --workspace --manifest-path rust/Cargo.toml
```

测试目录按 lib 结构组织：`test/support/` 放共享夹具与 harness（`fixtures.dart`、
`router_harness.dart`、`engine_setup.dart` 等），`test/engine/` 放引擎用例，
`test/data` / `test/domain` / `test/ui` 镜像 `lib/` 对应层。根层只保留跨层用例
（`app_build_test.dart`）。

只有 `test/engine/*_live_test.dart` 两个文件会请求真实站点（`wuguo` / `maoguo` 等），
断网或站点改版时失败**不属于代码回归**，因此打了 `engine` tag 并在默认运行中排除
（见 `dart_test.yaml`）；CI 里由非阻断的 `engine-online` job 单独跑。
其余引擎用例全部是离线夹具驱动，随默认套件在 CI 必过。

**改完 Rust API 或重新 codegen 后**如果出现
`Bad state: Content hash on Dart side ... is different from Rust side`，
说明加载到了**旧的引擎动态库**——生成代码的 `ioDirectory`
（`rust/target/release/`）是手工构建的兜底路径，会遮住 native-assets
钩子产出的新库：

```sh
rm -f rust/target/release/guo_engine.dll rust/target/debug/guo_engine.dll
rm -rf "$TEMP"/frb_native_assets_*   # Windows: %TEMP%\frb_native_assets_*
flutter clean && flutter pub get
```

CI 每次都是全新工作区，不受影响。

> 设备端集成测试（播放 / 界面 / 外观）曾存在于 `integration_test/`，因耦合已退出
> 构建链的 Go 核心且 Windows 桌面不支持截图通道而整体移除；待移植到引擎后端后
> 从 git 历史恢复（提交 `3f956f9^` 之前），按 flutter.dev 集成测试指南重建。

## CI

`.github/workflows/build.yml` 共 6 个 job（单版本，无矩阵）：

| job | 内容 |
| --- | --- |
| `rust` | fmt / clippy / `cargo test --workspace` / 依赖方向守卫 |
| `flutter` | format / analyze（error+warning 零容忍）/ 离线单测 ×2 变体 / `--coverage`；在线用例同 job 内 `continue-on-error` |
| `windows` / `macos` / `android` | `flutter build` CLI（`ALL_SOURCES=false`），产物从 `build/` 上传；Android 签名走官方 gradle 机制 |
| `ios` | `flutter build ios --no-codesign --dart-define=ALL_SOURCES=true` + ditto 打包未签名 zip |

环境准备（Flutter + rustup + cargo 缓存）收敛在 `.github/actions/setup`。
`convert-ios-ipa.yml` 把 iOS 产物转未签名 ipa；`publish-release.yml` 收集各端产物发 Release。

## 环境变量

| 变量 | 用途 |
| --- | --- |
| `LIBCLANG_PATH` | Windows 上 bindgen 需要，指向 LLVM 的 `bin` |
| `ANDROID_HOME` / `JAVA_HOME` | Android 构建 |
| `PUB_CACHE` | Pub 缓存位置 |
| `PUB_HOSTED_URL` | 国内镜像加速（与 `--enforce-lockfile` 同用时需与锁文件地址一致） |

## 更多文档

- `docs/ARCHITECTURE.md` — 引擎与插件系统设计（唯一权威设计基线）
- `docs/AUDIT.md` — 对照目标架构的现状审计
- `docs/PROGRESS.md` — 每轮落地内容与验证数据
- `docs/HANDOFF.md` — Flutter 技术栈迁移的过程交接记录
- `docs/PLUGIN-BOUNDARY.md` — 应用仓库与插件仓库的边界、插件包契约与迁移清单
