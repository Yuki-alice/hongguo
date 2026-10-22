# 真果鉴 / 红果鉴

独立运行的多端短剧应用：Flutter 前端 + Rust 本地引擎，端侧完成请求、解析、播放、下载与合并，
不依赖自建服务端。

## 一套后端：Rust 引擎

| 目录 | 语言 | 规模 | 角色 |
| --- | --- | --- | --- |
| `lib/` | Dart / Flutter | ~5 万行 | 应用与全部 UI |
| `rust/` | Rust | ~2 万行 | **唯一运行时后端**：站源、解析、播放、下载、缓存、插件 |
| `native/` | Go | ~2.1 万行 | 历史后端，已退出构建链，仅作迁移期只读参考（ADR-5c 决定最终删除） |

发布包与 `flutter run` 跑的都是 Rust 引擎：`lib/main.dart` 装配 `EngineBackedRepository`，
引擎不可用时启动页报错并提供重试，**没有**回退到 Go 的静默降级路径。
少量尚未迁完的能力（LAN、下载编排等）仍挂在 Go 委托上，干净环境缺少 `duanju_core.dll`
时按降级模式启动，调用到未迁移能力才会报错。

## 目录结构

```
lib/
  main.dart            启动装配
  app_build.dart       构建变体（ALL_SOURCES 开关）
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
native/                Go 历史后端（只读参考，不在构建链内）
scripts/               iOS 品牌切换（Xcode 构建阶段调用）与 Windows 冒烟
hook/build.dart        native-assets 构建钩子：flutter build/test 时自动编译引擎
```

UI 分层遵循 Flutter 官方指南：**UI 按 feature 切分，data / domain 按类型切分**。
新页面放 `lib/ui/features/<feature>/views/`，控制器放 `controllers/`，页面专用控件放 `widgets/`。

## 构建

前置：Flutter SDK、Rust 工具链（rustup，版本由 `rust/rust-toolchain.toml` 钉住）；
Android 另需 NDK 与 JDK 17。**不需要 Go**——引擎动态库由 native-assets 钩子
（`hook/build.dart`）在 `flutter build` / `flutter test` 时自动经 Cargo 构建并打包，
和纯 Flutter 项目一样直接使用 Flutter CLI：

```sh
# Windows / macOS（默认红果鉴；ALL_SOURCES=true 构建真果鉴）
flutter build windows --release --dart-define=ALL_SOURCES=false
flutter build macos   --release --dart-define=ALL_SOURCES=true

# Android（split-per-abi 三架构；--abi 可收窄）
flutter build apk --release --split-per-abi --dart-define=ALL_SOURCES=false

# iOS（需 macOS + Xcode；未签名 ipa 走 .github/workflows/convert-ios-ipa.yml）
flutter build ios --release --no-codesign --dart-define=ALL_SOURCES=false
```

日常开发直接用 `flutter run` / `flutter test`，钩子会自动处理引擎。

发布相关的少量项目逻辑留在脚本里（CLI 之外的事）：`scripts/configure_ios_branding.py`
在 Xcode 构建阶段切换 iOS 显示名（红果鉴 / 真果鉴），`scripts/smoke_windows.py`
直接运行 `flutter build windows` 产物做启动验收。产物在 `build/` 对应平台目录，
CI 直接从那里上传；本地出发布包用一条命令即可：

```sh
python scripts/smoke_windows.py     # Windows：ffmpeg 合成媒体 + 无头启动 exe 验收
```

国内网络环境可用 `PUB_HOSTED_URL=https://pub.flutter-io.cn dart run ...` 或
`flutter build --dart-define=... ` 前自设镜像环境变量加速依赖拉取。

## 测试

```sh
# Dart 单元 / 控件测试：默认排除在线站源用例（引擎库由钩子自动构建）
flutter test
flutter test --tags engine          # 只跑需要真实站点的用例
flutter test --coverage             # 覆盖率（CI 收集为产物）

# Rust
cargo test --workspace --manifest-path rust/Cargo.toml
```

`test/engine_*.dart` 里有一批用例会请求真实站点（`wuguo` / `maoguo` 等），
断网或站点改版时失败**不属于代码回归**，因此打了 `engine` tag，
默认运行被排除（见 `dart_test.yaml`）。CI 里它们由非阻断的 `engine-online` job 单独跑。

> 设备端集成测试（播放 / 界面 / 外观）曾存在于 `integration_test/`，因耦合已退出
> 构建链的 Go 核心且 Windows 桌面不支持截图通道而整体移除；待移植到引擎后端后
> 从 git 历史恢复（提交 `3f956f9^` 之前），按 flutter.dev 集成测试指南重建。

## CI

`.github/workflows/build.yml` 当前启用（共 7 个 job；环境准备收敛到
`.github/actions/setup` 复用组件：checkout + Flutter + rustup + cargo 缓存）：

| job | 内容 |
| --- | --- |
| `rust` | fmt / clippy / `cargo test --workspace` / 依赖方向守卫 |
| `flutter` | format / analyze（error+warning 零容忍）/ `flutter test --coverage` ×2 变体 |
| `engine-online` | 真实站点用例，`continue-on-error` |
| `windows` / `macos` | `flutter build` CLI + Windows 冒烟，双版本矩阵，产物从 `build/` 上传 |
| `android` | `flutter build apk --split-per-abi`，签名走官方 gradle 机制（secrets 缺省回退 debug） |
| `ios` | `flutter build ios --no-codesign` + ditto 打包未签名 zip |

`convert-ios-ipa.yml` 把 iOS 产物转未签名 ipa；`publish-release.yml` 收集各端产物发 Release
（Windows Release 目录在发布前打成 zip）。

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
