# 真果鉴 / 红果鉴

独立运行的多端短剧应用：Flutter 前端 + 本地站源引擎，端侧完成请求、解析、播放、下载与合并，
不依赖自建服务端。

## 三套后端，当前默认走 Go

仓库里同时存在三套代码，**这是理解本项目的第一个关键事实**：

| 目录 | 语言 | 规模 | 角色 |
| --- | --- | --- | --- |
| `lib/` | Dart / Flutter | ~4.7 万行 | 应用与全部 UI |
| `native/` | Go | ~2.1 万行 + 5 千行测试 | **默认运行路径**：站源请求、解析、下载、局域网、缓存 |
| `rust/` | Rust | ~1.8 万行 | 目标后端，通过 `ENGINE_ROUTE` 开关**按站源灰度接管** |

`lib/main.dart` 的选择逻辑是：

```dart
if (!EngineRouting.enabled) return core;   // ENGINE_ROUTE 未设置 → 直接用 Go
```

`ENGINE_ROUTE` 默认为空，所以**发布包跑的是 Go 核心**。Rust 引擎是并行开发的第二实现，
按站源逐个接管，未接管的自动回落 Go（`EngineBackedRepository` 是装饰器，不是继承）。

打开方式：

```sh
flutter run --dart-define=ENGINE_ROUTE=all              # 全部站源走 Rust
flutter run --dart-define=ENGINE_ROUTE=wuguo,maoguo     # 只指定站源
```

`docs/ARCHITECTURE.md` 的 ADR-5c 已决定最终删除 Go 后端、不做长期双栈，
迁移进度见 `docs/PROGRESS.md`（P2 站源迁移进行中）。

## 目录结构

```
lib/
  main.dart            启动装配
  app_build.dart       构建变体（ALL_SOURCES 开关）
  data/                仓库、本地存储、引擎路由、媒体 / LAN / 播放 / 画质增强
  domain/              剧集、榜单、LAN、偏好等纯模型
  ui/
    features/<name>/   页面级 feature：views / controllers / widgets
    core/              跨 feature 的布局、主题、通用控件
    providers/ routing/ theme/
  src/rust/            flutter_rust_bridge 生成的绑定（勿手改）
  l10n/                ARB 模板与生成的本地化代码
test/                 镜像 lib/ 结构；根层放跨功能与引擎测试
rust/
  Cargo.toml           虚清单（workspace）
  bridge/              只做 FRB 边界，实现在 crates/*
  crates/              source-api（零 IO 契约）/ runtime / rule-engine /
                       plugin-host / plugin-wasm / host / media / source-*
  rules/               随包分发的声明式站源（JSON）
docs/                  架构、审计、进度、POC、交接记录
native/                Go 后端（迁移期只读规格来源，不再接受新修复）
scripts/               构建、打包、镜像、引擎准备
```

UI 分层遵循 Flutter 官方指南：**UI 按 feature 切分，data / domain 按类型切分**。
新页面放 `lib/ui/features/<feature>/views/`，控制器放 `controllers/`，页面专用控件放 `widgets/`。

## 构建

前置：Flutter SDK、Go、Rust 工具链；Android 另需 NDK 与 JDK 17。

```sh
# Windows（默认红果鉴；--all-sources 构建真果鉴）
python scripts/build_windows.py
python scripts/build_windows.py --all-sources

# Android
python scripts/build_android.py
python scripts/build_android.py --all-sources --abi arm64-v8a

# iOS（需 macOS + Xcode；未签名 ipa 走 .github/workflows/convert-ios-ipa.yml）
python scripts/build_ios.py
```

构建脚本会先跑 `build_native.py`（Go 核心），再 `flutter build`，最后 `package_release.py`。
产物在 `dist/`，不进版本管理。

Rust 动态库由 native-assets 构建钩子（`hook/build.dart`）在 `flutter build` /
`flutter test` 时自动经 Cargo 构建并打包，无需手工准备产物；工具链与目标平台由
`rust/rust-toolchain.toml` 钉住，首次运行 rustup 会自动安装缺失部分。

## 测试

```sh
# Dart：默认排除在线站源用例（引擎动态库由 native-assets 钩子自动构建）
flutter test
flutter test --tags engine          # 只跑需要真实站点的用例

# Rust
cargo test --workspace --manifest-path rust/Cargo.toml

# Go
cd native && go test -race ./...
```

在 **Windows** 上跑 Go 测试会看到 `TestLegacyAnonymousCatalogAndSessionReuse` 失败
（`anonymous session must be private`）：该用例断言会话文件权限是 `0600`，
而 Windows 不模拟 Unix 权限位。CI 跑在 ubuntu 上，那里该断言成立。

`test/engine_*.dart` 里有 9 个文件会请求真实站点（`wuguo` / `maoguo` 等），
断网或站点改版时失败**不属于代码回归**，因此打了 `engine` tag，
默认运行被排除（见 `dart_test.yaml`）。CI 里它们由非阻断的 `engine-online` job 单独跑。

## CI

`.github/workflows/build.yml` 当前启用：

| job | 内容 |
| --- | --- |
| `rust` | fmt / clippy / `cargo test --workspace` / 依赖方向守卫 |
| `flutter` | `dart format --set-exit-if-changed` / `dart analyze` / `flutter test` |
| `go` | `go test -race`（普通与 `buildAllSources=true` 两轮） |
| `scripts` | `scripts/test_*.py` |
| `engine-online` | 真实站点用例，`continue-on-error` |
| `windows` | Windows 构建 + 冒烟 |

`android` 与 `ios` 两个构建 job 目前是 `if: false`，需要时手动打开。

## 环境变量

| 变量 | 用途 |
| --- | --- |
| `LIBCLANG_PATH` | Windows 上 bindgen 需要，指向 LLVM 的 `bin` |
| `ANDROID_HOME` / `JAVA_HOME` | Android 构建 |
| `PUB_CACHE` | Pub 缓存位置 |

构建前需清掉 `PUB_HOSTED_URL`，否则 `--enforce-lockfile` 会失败。

## 更多文档

- `docs/ARCHITECTURE.md` — 引擎与插件系统设计（唯一权威设计基线）
- `docs/AUDIT.md` — 对照目标架构的现状审计
- `docs/PROGRESS.md` — 每轮落地内容与验证数据
- `docs/HANDOFF.md` — Flutter 技术栈迁移的过程交接记录
