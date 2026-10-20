# 交接文档 · Flutter 技术栈现代化

> 生成时间：2026-10-20
> 分支：`main` · 版本：`0.2.57+63`
> 状态：**路由迁移已完成，状态管理迁移进行中（约 1/3）**

---

## 1. 任务目标

把项目的 Flutter 技术栈从「`setState` + `Navigator.push` 命令式导航」迁移到
「Riverpod + go_router 声明式」现代化栈，并把全部页面纳入新体系。

验收标准（原始目标）：

1. `dart analyze` 零错误
2. `flutter test` 无新增回归
3. Windows 与 Android 构建通过

---

## 2. 本轮已完成

### 2.1 依赖引入

`pubspec.yaml` 新增两个直接依赖（均已 `pub get` 通过）：

| 依赖 | 版本 | 说明 |
| --- | --- | --- |
| `flutter_riverpod` | `3.4.3` | 状态管理 |
| `go_router` | `17.5.0` | 声明式路由 |

**关键决策：go_router 刻意锁在 17.5.0，不上 18.x。**

18.0.0 起 go_router 把 `MaterialApp`/`CupertinoApp` 拆到独立包
（`material_ui` / `cupertino_ui`）。已实测确认该包的 `MaterialApp` 与 Flutter SDK
内的**不是同一个类**（`identical == false`），导致 go_router 的
`isMaterialApp()` 判定失败，静默降级 Hero 控制器、page builder 与错误页。
`pubspec.lock` 中已确认**不存在** `material_ui` / `cupertino_ui`。

### 2.2 路由层（`lib/ui/routing/`）

- `app_router.dart`：`AppRoutes` 路径常量 + **18 条**路由 + `routerProvider`
- `route_args.dart`：`DramaRef`（source + sourceId 的类型安全标识）、`MediaRef`

已建成的 18 条路由：

```
/                       首页（用户就绪/锁定分流）
/profiles               用户管理
/profiles/editor        用户编辑器
/detail/:source/:sourceId
/player/:source/:sourceId
/downloads
/local-media
/merge-queue
/batch-download
/settings
/settings/resources
/settings/downloads
/settings/storage
/sources
/rankings
/lan
/lan/conflicts
/download-picker/:source/:sourceId
```

**类型安全参数**：路径参数统一用 `DramaRef` 解析（`tryParse` / `fromDramaId`），
不再手拼字符串。辅助方法 `detailOf` / `playerOf` / `rankingsOf` / `sourcesOf` /
`downloadPickerOf` / `withQuery` 负责编码，避免改名漏改。

**不可序列化对象的传递**：`DramaDetail`、`MediaLibrary`、`LanController`、
`DownloadPreferences` 等无法从 URL 重建，统一走 go_router 的 `extra`，
并各自有 `@immutable` 载体类：

| 载体 | 用途 |
| --- | --- |
| `PlayerRouteExtra` | 详情、起播集数/进度、`localOnly`、覆盖仓库、测试用 `playerBuilder` |
| `BatchDownloadExtra` | 批量下载剧集列表 |
| `DownloadPickerExtra` | 选集弹层的详情与偏好 |
| `MergeQueueExtra` | 媒体库单例 + `addOnOpen` |
| `ProfileEditorExtra` | 编辑哪个用户（null = 新建） |

**深链兜底**：`extra` 不参与 URL，冷启动深链时 builder 会回落到
「按标识重新取数」（`/player` 无 `extra` 时降级到详情页），不出现空白页；
前置条件确实缺失时显示 `_InvalidRoute` 占位页。

### 2.3 状态层（`lib/ui/providers/app_providers.dart`）

| Provider | 类型 | 用途 |
| --- | --- | --- |
| `repositoryProvider` | `Provider<AppRepository>` | 仓库（必须 override） |
| `storeProvider` | `NotifierProvider<StoreHolder, LocalStore?>` | 当前用户仓库 |
| `readyStoreProvider` | `Provider<LocalStore>` | 已就绪的仓库（未就绪抛错） |
| `storeRevisionProvider` | `NotifierProvider<StoreRevision, int>` | **ChangeNotifier → Riverpod 桥** |
| `deviceProvider` | `Provider<AppDevice>` | 设备形态与版本 |
| `televisionProvider` | `Provider<bool>` | 是否电视模式 |
| `themeModeProvider` | `Provider<String>` | 主题偏好 |

### 2.4 迁移后的调用点

- `lib/home_screen.dart` 从 **1482 行降到 562 行**，成为纯装配层
- 发现页按 MVVM 拆为 `ui/features/discover/`（controllers / views / widgets）
- **全部 34 处 `Navigator.push` + 35 处 `MaterialPageRoute` 已清零**
  （`grep` 验证：`lib/` 内已无匹配）

剩余的 `Navigator.pop`（84 处）**是有意保留**的：它们全是对话框、底部弹层、
`showDialog` 的返回值回传，属于 Navigator 的正常职责，不该改。

---

## 3. 过程中修掉的三个真实缺陷

这三个都是迁移暴露出来的**产品缺陷**，不是测试问题。

### 3.1 路由刷新会丢失 `extra`（严重）

原实现给 `GoRouter` 接了 `refreshListenable`。实测发现：go_router 收到刷新通知后
会**按 URL 重新解析**当前路由，`extra` 随之丢失。表现为批量下载、本地播放等
「带着对象跳转」的页面突然报「没有选择要下载的短剧」。

**修法**：去掉 `refreshListenable`，改为各路由 builder 内部用 Riverpod 响应式
处理用户数据变化，路由对象因此保持稳定。详见 `app_router.dart` 的注释。

> 副作用：`/` 首页原本靠 `refreshListenable` 响应「用户数据就绪」。当前生产路径下
> `AppBootstrap` 只在 store 就绪后才建立 `ProviderScope`，因此不受影响；
> **但若将来要让 `/` 响应切换用户，需把首页 builder 改为 `Consumer` + `ref.watch`。**

### 3.2 Riverpod Notifier 初始化时序

`StoreHolder()..assign(store)` 会在 `build()` 完成前写 `state`，Riverpod 直接断言失败
（"Tried to use a notifier in an uninitialized state"）。

**修法**：初始值走构造函数 `StoreHolder(store)`，在 `build()` 里返回。

### 3.3 同路由模式切换剧集不刷新

`context.replace` 切到同一路由模式（`/detail/:source/:sourceId`）时，Flutter 会复用
同一个 `State`，`initState` 不再执行，页面停留在上一部剧。表现为「相关推荐」里点
第二季，标题不更新。

**修法**：详情页加 `key: ValueKey('detail-${drama.id}')` 强制重建。

---

## 4. 验证结果（截至交接）

### 4.1 静态检查

```
dart analyze lib test   →   0 errors, 0 warnings
```

（92 条 `info` 级 lint 为项目历史遗留，与本次迁移无关。）

### 4.2 测试

```
flutter test   →   +182 ~1 -18
```

- **通过 182**，跳过 1，失败 **18**
- 这 18 条与迁移前的基线**逐条一致**，`Compare-Object` 差异集为空
- 即：**零新增回归**

> 基线获取方式：`git stash push -- lib` 后重跑全套（`build/base_now.txt`）。
> 注意基线文件里第 19 行 `catalog_controller_test.dart: loading ...` 是当时把
> `lib/ui/` 临时挪走导致的**加载失败伪影**，不是真实用例失败。
> 因此真实基线是 **18 条**。

已知的基线失败原因（与本次迁移无关）：
- 测试断言 `find.text('我的追剧')`，而 UI 实际渲染 `我的追剧 · 0`
  （`lib/saved_library.dart:145`）——占多数
- `media_library` / `engine_hls` 相关的 FFmpeg / 素材依赖问题

### 4.3 构建

本轮**尚未重新构建** Windows / Android。构建配置在上游已修好（见第 5 节），
但建议交接后重跑一次确认。

---

## 5. 环境与构建（重要）

### 5.1 环境变量

```
LIBCLANG_PATH   = C:\Program Files\LLVM\bin
ANDROID_HOME    = D:\DevCache\Android\Sdk
JAVA_HOME       = C:\Program Files\Java\jdk-17
```

- Flutter：`E:\Flutter\flutter_windows_3.47.7-stable\flutter\bin`
- Pub 缓存：`D:\DevCache\Pub`（`PUB_CACHE`）
- Gradle 缓存：`D:\DevCache\.gradle`
- Rust 工具链：1.99.1（workspace 要求 `rust-version = 1.97`）

### 5.2 命令

```powershell
# 构建前必须清掉镜像变量，否则 --enforce-lockfile 会失败
Remove-Item Env:PUB_HOSTED_URL -ErrorAction SilentlyContinue

flutter build windows --release --no-pub --dart-define=ALL_SOURCES=false
flutter build apk --release --no-pub --target-platform android-arm64
```

### 5.3 已修复的构建问题（上游遗留）

1. **Windows 找不到 DLL**：commit `790d3e6` 把 crate 改名为 `guo_engine`，但
   `rust_builder/{windows,linux}/CMakeLists.txt` 仍传 `rust_lib_guo_engine`。
   已改为 `apply_cargokit(... guo_engine "")`。
2. **Android 交叉编译**：`BINDGEN_EXTRA_CLANG_ARGS_aarch64_linux_android` 需
   **正斜杠**，且要配 `RUSTFLAGS="-C link-arg=--target=aarch64-linux-android26"`。
3. **NDK 缺失**：`sdkmanager 'ndk;28.2.13676358'`，并补装 `cmdline-tools`。
4. **Kotlin 增量缓存损坏**：`D:\DevCache\.gradle\gradle.properties` 加
   `kotlin.incremental=false`。
5. 网络：GitHub / Gradle 需本地代理 `http://127.0.0.1:7897`；
   Rust 用 `RUSTUP_DIST_SERVER=https://rsproxy.cn`。

---

## 6. 未完成工作（按优先级）

### P0 — 让首页响应式化

`/` 首页 builder 目前用 `ref.read(storeProvider)`。去掉 `refreshListenable` 后，
若要让首页响应「切换用户 / 锁定状态变化」，需改为 `Consumer` + `ref.watch`。
当前生产路径未受影响，但这是**已知的设计缺口**。

### P1 — 状态管理迁移（约 1/3 完成）

`discover` 页已完整迁到 Riverpod（可作为样板）。其余页面仍以 `setState` 为主，
按 `setState` 调用数排序：

| 文件 | `setState` 数 |
| --- | --- |
| `lan_screen.dart` | 24 |
| `player_screen.dart` | 22 |
| `downloads_screen.dart` | 21 |
| `profiles_screen.dart` | 17 |
| `home_screen.dart` | 12 |
| `resource_settings_screen.dart` / `settings_screen.dart` | 各 11 |
| `local_media_screen.dart` | 10 |
| `detail_screen.dart` | 9 |
| `rankings_screen.dart` / `sources_screen.dart` | 各 8 |

**最大债务**：`_PlayerScreenState` 有 **73 个字段**，覆盖 7 个正交关注点
（播放控制 / 弹幕 / 下载 / 弹层 / 手势 / 记忆 / 生命周期），
应拆成多个 `Notifier`。`player_screen.dart` 现有 2042 行。

**建议顺序**：`detail_screen`（结构简单）→ `downloads_screen` →
`player_screen`（最难，放最后）。

### P2 — 测试改造

- 新增 `test/router_harness.dart`：`pumpRouterApp()` 用**生产路由表**启动界面，
  供需要真实导航的测试使用（替代原来的 `MaterialApp(home: X)` 写法）。
  已改造 `downloads_test.dart` 与 `library_features_widget_test.dart`。
- 其余测试仍可直接构造页面（不触发导航时无需 harness）。
- 182 个测试 / 87 处 `FixtureRepository` 引用，后续迁移页面时需同步调整注入方式。

### P3 — 长期改进

- **838 处硬编码中文**，无 l10n 国际化
- `Md3Motion` 已定义但几乎未被使用
- `lan_screen` / `lan_controller` / `lan_sync` / `video_enhancement` /
  `media_merge` / `player_controls` 的测试覆盖为 **0 引用**

---

## 7. 关键文件索引

| 文件 | 职责 |
| --- | --- |
| `lib/main.dart` | 启动装配、`ProviderScope` 注入、`DuanjuApp` 外壳 |
| `lib/ui/routing/app_router.dart` | 路由表（18 条）、`extra` 载体、`AppRoutes` |
| `lib/ui/routing/route_args.dart` | `DramaRef` 类型安全标识 |
| `lib/ui/providers/app_providers.dart` | 全部 Provider + ChangeNotifier 桥 |
| `lib/ui/features/discover/` | Riverpod 迁移样板（controller / view / widgets） |
| `lib/ui/theme/md3_tokens.dart` | MD3 设计令牌（`Md3Spacing` 等） |
| `test/router_harness.dart` | 路由测试脚手架 |
| `engine/` | Rust 引擎（cargo workspace，`guo_engine` crate） |

---

## 8. 注意事项

1. **`DuanjuApp` 保留旧签名**（`repository` / `store` / `bootstrapError` 等），
   是为了让 13 处既有测试调用点继续编译。`wrapScope` 控制是否自建
   `ProviderScope`（`AppBootstrap` 已建时传 `false`）。
2. `DuanjuApp` 的 `ProviderScope` 带 `key: ValueKey<LocalStore?>(store)`：
   override 只替换 notifier 工厂，不会重跑已存在 provider 的 `build()`，
   换 key 才能让「null → 有 store」这一转变被正确解析。
3. 路由常量统一走 `AppRoutes`，不要手写路径字符串。
4. 新增需要对象参数的页面时，照 `PlayerRouteExtra` 的样式加一个
   `@immutable` 载体，并同时提供深链兜底。
