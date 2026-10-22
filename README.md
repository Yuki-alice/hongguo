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
integration_test/      设备端集成测试（播放 / 界面 / 外观，见「测试」）
rust/
  Cargo.toml           虚清单（workspace）
  bridge/              只做 FRB 边界，实现在 crates/*
  crates/              source-api（零 IO 契约）/ runtime / rule-engine /
                       plugin-host / plugin-wasm / host / media / source-*
  rules/               随包分发的声明式站源（JSON）
  rust-toolchain.toml  钉住工具链版本与交付目标（crate 目录内还有一份镜像）
docs/                  架构、审计、进度、POC、交接记录
native/                Go 历史后端（只读参考，不在构建链内）
scripts/               发布打包、签名、镜像加速、测试媒体等 CLI 之外的事
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

发布打包（产物命名、原生库校验、SHA256SUMS）与 Android 签名在脚本里，
CI 与正式发版走脚本，本地验证可直接用上面的 CLI：

```sh
python scripts/build_android.py --all-sources --abi arm64-v8a   # ABI 映射 + 签名 + 打包
python scripts/build_ios.py                                     # 未签名 app → zip + 校验和
python scripts/package_release.py --platform windows            # 单打包（构建已完成时）
```

产物在 `dist/`，不进版本管理。国内网络环境可用 `--cn-mirrors`（Android 脚本）或自设
`PUB_HOSTED_URL` 加速依赖拉取。

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

### 设备端集成测试（integration_test/）

播放 / 界面 / 外观三类用例，依赖本地合成媒体服务器，按以下顺序运行：

```sh
python scripts/create_test_media.py                                   # ffmpeg 生成 MP4/HLS/CENC 夹具
python scripts/serve_test_media.py &                                  # 127.0.0.1:38473 合成媒体源
flutter test integration_test -d windows \
  --dart-define=DISABLE_REMOTE_IMAGES=true \
  --dart-define=FIXTURE_BASE_URL=http://127.0.0.1:38473
```

已知限制：① 外观用例的截图依赖 `integration_test` 插件的 `takeScreenshot`，
Windows 桌面端未实现该通道，需在 Android / iOS 设备上运行；② 夹具仓库
（`DeviceFixtureRepository`）的播放 / 下载链路仍调用 Go 核心，移植到引擎后端
后才能全量运行——目前作为手动设备验证工具，未纳入 CI。

## CI

`.github/workflows/build.yml` 当前启用（共 7 个 job；环境准备收敛到
`.github/actions/setup` 复用组件：checkout + Flutter + rustup + cargo 缓存）：

| job | 内容 |
| --- | --- |
| `rust` | fmt / clippy / `cargo test --workspace` / 依赖方向守卫 |
| `flutter` | format / analyze（error+warning 零容忍）/ `flutter test --coverage` ×2 变体 |
| `engine-online` | 真实站点用例，`continue-on-error` |
| `windows` / `macos` | `flutter build` CLI + `package_release.py` + Windows 冒烟，双版本矩阵 |
| `android` | ABI 拆分 + 签名 + 打包，双版本矩阵 |
| `ios` | 未签名 app 打包，双版本矩阵 |

`convert-ios-ipa.yml` 把 iOS 产物转未签名 ipa；`publish-release.yml` 收集产物发 Release。

## 环境变量

| 变量 | 用途 |
| --- | --- |
| `LIBCLANG_PATH` | Windows 上 bindgen 需要，指向 LLVM 的 `bin` |
| `ANDROID_HOME` / `JAVA_HOME` | Android 构建 |
| `PUB_CACHE` | Pub 缓存位置 |
| `PUB_HOSTED_URL` | 国内镜像加速（需与 `--enforce-lockfile` 的锁文件地址一致，脚本会自动改写） |

## 更多文档

- `docs/ARCHITECTURE.md` — 引擎与插件系统设计（唯一权威设计基线）
- `docs/AUDIT.md` — 对照目标架构的现状审计
- `docs/PROGRESS.md` — 每轮落地内容与验证数据
- `docs/HANDOFF.md` — Flutter 技术栈迁移的过程交接记录
