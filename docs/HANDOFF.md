# 交接文档 · Flutter 技术栈现代化

> 生成时间：2026-10-20
> 分支：`main` · 版本：`0.2.62+68`
> 状态：**路由迁移已完成；P1 逻辑页面已 ViewModel 化；P2 测试改造已完成；全量测试 328 通过 / 0 失败；剩余 LAN / 首页 / 播放器 UI 状态**

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

- `home_screen.dart` 从 **1482 行降到 562 行**，成为纯装配层
  （现位于 `lib/ui/features/home/views/`）
- 发现页按 MVVM 拆为 `ui/features/discover/`（controllers / views / widgets）
- **全部 34 处 `Navigator.push` + 35 处 `MaterialPageRoute` 已清零**
  （`grep` 验证：`lib/` 内已无匹配）

### 2.5 首页响应式化（P0 已解决）

`/` 路由不再用闭包里的 `ref.read(storeProvider)`，改为 `_HomeRoute`
（`ConsumerWidget`）：

- `ref.watch(storeProvider)`：用户数据就绪 / 未就绪切换
- `ref.watch(storeRevisionProvider)`：`LocalStore` 是 `ChangeNotifier`，
  锁定、切换用户等原地变化通过 revision 计数触发重建
- `HomeScreen` 仍带 `profile-{id}-{epoch}` key，仅真正换用户时重建

> 依赖前提成立：`DuanjuApp` 的 `ProviderScope` 以 `ValueKey(store)` 重建，
> 且路由不接 `refreshListenable`，因此 `extra` 不会因首页刷新而丢失。

### 2.6 详情页状态机（`DetailController`）

`lib/ui/features/detail/controllers/detail_controller.dart` 接管：

- 取详情、合并 `catalogUpdates`、补充元数据、保存失败提示
- `generation` 与 `profileEpoch` 双重闸门，旧请求不覆盖新状态
- 剧集分页（`resumeEpisodeIndex ~/ episodePageSize`）
- `allowed` 权限判断；页面只保留对话框、导航与纯 UI 展开状态

`detail_screen.dart` 的 `setState` 从 9 处降到 4 处；新增
`test/ui/features/detail/controllers/detail_controller_test.dart`（5 条）：加载合并、失败、元数据补充、
分页通知、旧请求丢弃。

### 2.7 下载页状态机（`DownloadsController`）

`lib/ui/features/downloads/controllers/downloads_controller.dart` 接管：

- 2 秒轮询、加载 / 错误 / 刷新、`DownloadCollectionUpdater`
- 搜索、筛选、展开、多选、批量操作与失败重试选择
- 提示文案通过 `takeMessage()` 交给页面弹 SnackBar
- 删除确认对话框仍留在页面（需要 `BuildContext` 与电视焦点）

`downloads_screen.dart` 的 `setState` 从 21 处降到 1 处；新增
`test/ui/features/downloads/controllers/downloads_controller_test.dart`（6 条）：初始加载、批量筛选、
无目标任务、多选切换、搜索与归档筛选，以及控制器接页后的加载 / 展开冒烟。

### 2.8 目录与导入规范

本轮完成了页面级目录收口：

- 所有页面移入 `lib/ui/features/<feature>/views/`
- 功能控制器放在 `controllers/`，页面专用控件放在 `widgets/`
- 已建立 feature：`discover` / `detail` / `downloads` / `home` / `lan` /
  `media` / `player` / `profiles` / `rankings` / `settings` / `sources`
- `lib/` 根目录只保留领域与基础设施（`models`、`core_bridge`、
  `local_store`、`engine_*`、`media_*`、`lan_*`、播放内核等）
- `lib/` 内 `import` / `export` 统一改为 `package:duanju_app/...`，
  后续移动文件只需改目标路径，不再调整 `../../` 层级
- `lib/src/rust/` 生成代码与其相对导入保持原样，不改动
- `part` 关系保持不变（`local_store` / `media_library` / `lan_controller`）

同时删除 `scripts/finish_task.py`、`scripts/sync_source.py` 及两个测试：
它们没有 CI 或文档引用，且 `REQUIRED_FILES` 仍要求已被删除的
`AGENTS.md` / `README.md`，在当前仓库无法运行。Git 与 GitHub Actions
已经覆盖版本管理和发布物，不再保留本地镜像同步脚本。

### 2.9 播放器拆分 · 阶段 1：进度持久化

新增 `lib/ui/features/player/controllers/playback_progress_controller.dart`：

- 接管当前打开分集、续播位置、保存去重键与保存失败提示
- 支持剧集历史与本地媒体两条写入路径
- `onFlush` 回调负责局域网进度刷新，控制器本身不依赖 `LanController`
- 保存失败通过 `ChangeNotifier` 通知页面，页面只负责展示与重试按钮

`player_screen.dart` 减少 4 个字段（`_openedIndex`、`_resumePosition`、
`_savedProgressKey`、`_saveWarning`）和约 40 行保存逻辑；新增
`test/ui/features/player/controllers/playback_progress_controller_test.dart`（6 条）：普通保存、
去重 + flush、媒体进度、失败提示、关闭 / 用户不一致、续播位置更新。

### 2.10 播放器拆分 · 阶段 2：会话状态

新增 `lib/ui/features/player/controllers/playback_session_controller.dart`：

- 接管当前集、`generation` 票据、加载 / 错误 / 本地失败标记
- 接管请求清晰度、手动在线标记、播放计划、加载文案与首帧控件提示
- `begin` / `finish` / `fail` 统一处理状态转换并通知页面，
  `generation` 闸门仍由调用方用 `ticket == playback.generation` 判断
- `qualityLabel` / `session` 等派生值集中在一处

`player_screen.dart` 再减少 10 个字段，`setState` 从 22 处降到 18 处；
`_play` 中的三处状态写入改为 `begin` / `finish` / `fail`。新增
`test/ui/features/player/controllers/playback_session_controller_test.dart`（6 条）：票据与重置、
同集保留在线标记、安装计划、失败状态、清晰度去重通知、`invalidate`。

### 2.11 播放器拆分 · 阶段 3：播放偏好

新增 `lib/ui/features/player/controllers/playback_preferences_controller.dart`：

- 持有速度、弹幕开关、自动连播与预加载开关
- 负责写入 `LocalStore`，并在用户已切换时拒绝更新内存状态
- 清晰度仍归会话控制器，增强偏好仍归 `VideoEnhancementController`
- 页面通过 `ChangeNotifier` 重建，`_setPreferences` 不再手写 `setState`

`player_screen.dart` 再减少 4 个字段（`_speed`、`_autoAdvance`、
`_danmakuEnabled`、`_preloadEnabled`），当前状态字段约 32 个；
新增 `test/ui/features/player/controllers/playback_preferences_controller_test.dart`（3 条）：初始值、
保存与通知、用户不一致拒绝更新。

### 2.12 用户管理页

按 `.dsh/skills/flutter-apply-architecture-best-practices` 的 MVVM 约定拆分：

- `ProfilesController`：恢复 / 导出 / 切换用户 / 强制登录的忙碌与错误状态
- `ProfileEditorController`：保存、密码确认、删除用户
- 文件选择与确认对话框留在 View；列表用 `Listenable.merge` 同时监听
  `LocalStore` 与控制器
- `profiles_screen.dart` 的 `setState` 从 17 处降到 3 处（仅剩表单勾选）
- 新增 `test/ui/features/profiles/controllers/profiles_controller_test.dart`（9 条）

### 2.13 本地媒体页

- `LocalMediaController`：已下载分集、加载/错误、合并/导出视图、导出与删除
- `LocalMediaOperations` 端口隔离 `MediaLibrary`；`exportMerged` 位于扩展方法，
  无法通过继承替换，端口让控制器可以直接注入假实现
- `local_media_screen.dart` 的 `setState` 从 10 处降到 0
- 新增 `test/ui/features/media/controllers/local_media_controller_test.dart`（6 条）

### 2.14 站源管理页

- `SourcesController`：1 秒轮询、每站源状态/错误/修订号、任务与健康详情
- 保留 `profileEpoch` 与修订号双重闸门，轮询结果不会覆盖新操作
- `sources_screen.dart` 的 `setState` 从 8 处降到 0
- 新增 `test/ui/features/sources/controllers/sources_controller_test.dart`（5 条）

### 2.15 榜单页

- `RankingsController`：榜单目录、当前榜、分页合并、错误与 generation 闸门
- 控制器直接监听 `catalogUpdates`，页面用 `ListenableBuilder` 渲染
- `rankings_screen.dart` 的 `setState` 从 8 处降到 0
- 新增 `test/ui/features/rankings/controllers/rankings_controller_test.dart`（5 条）

### 2.16 设置页与存储页

- `SettingsController`：备份导出、恢复、自动导出开关与消息/忙碌状态
- `StorageController`：下载目录用量、目录迁移与错误状态
- 文件选择、恢复确认与目录选择对话框仍留在 View
- `settings_screen.dart` 的 `setState` 从 11 处降到 0
- 新增 `test/ui/features/settings/controllers/settings_controller_test.dart`（7 条）

### 2.17 网络与资源设置

- `ResourceSettingsController`：加载、表单字段、保存、忙碌/错误与管理员闸门
- 代理地址仍由 View 的 `TextEditingController` 持有，保存时传入控制器
- `resource_settings_screen.dart` 的 `setState` 从 11 处降到 1 处（仅代理可见性）
- 新增 `test/ui/features/settings/controllers/resource_settings_controller_test.dart`
  （5 条）与页面级 `settings_views_test.dart`（2 条）

### 2.18 官方分层目录

按 Flutter Architecture Guide 的 UI / Data / Domain 分层收口：

```
lib/
  main.dart              启动装配
  data/
    core_bridge / local_store / engine_* / local_profiles / local_snapshot
    catalog_browser / library_updater / background_downloads / batch_downloads
    media/               media_library(+parts)、media_pipeline
    lan/                 lan_controller(+parts)
    playback/            loader / preloader / recovery / buffer
    video_enhancement/   controller / assets / mpv / policy / output_size
  domain/                models、ranking/lan/source 状态、播放/下载/增强偏好、follow_state
  ui/
    core/                app_layout、app_theme、widgets、remote_widgets、搜索、封面解码、底部导航
    features/            discover / detail / downloads / home / lan / media / player / ...
    providers/ routing/ theme/
  src/rust/              生成代码，保持原样
  l10n/                  ARB 与生成的本地化代码
```

- `lib/` 根目录 Dart 文件从 **65 个降到 3 个**：
  `main.dart`、`app_build.dart`、`package_smoke.dart`。
- 所有 import 已同步为新的 `package:duanju_app/...` 路径。
- 页面专用组件同步归位：`episode_browser` / `drama_actions` / `catalog_filters`
  在 `ui/core`；`saved_library`、`download_picker`、`video_enhancement_settings`
  在对应 feature 的 `widgets/`；弹幕控制器与覆盖层在 `ui/features/player/danmaku/`。
- 该分层已满足官方“UI 按 feature、数据与领域按类型”的建议。

### 2.19 国际化（l10n）管线

- `pubspec.yaml`：`generate: true`、直接依赖 `intl`
- `l10n.yaml`：模板 `lib/l10n/app_zh.arb`，生成 `lib/l10n/generated/app_localizations.dart`
- `MaterialApp.router` 改用 `AppLocalizations.localizationsDelegates` 与
  `supportedLocales`，locale 为 `zh`
- 已完整迁移页面：
  - `StorageScreen`（下载目录与空间）
  - `ProfilesScreen` / `ProfileEditor` / `_PasswordDialog`（用户管理与登录）
  - `SourcesScreen` / `SourceDiagnosticsButton`（站源管理、诊断与健康详情）
  - `DownloadPicker`（下载选集）
  - `RecommendationsScreen`（红果推荐）
  - `SavedLibrary` / `MergeQueueScreen` / `BatchDownloadScreen`
  - `LocalMediaScreen` / `ResourceSettingsScreen` / `SettingsScreen`
  - `DetailScreen` / `DiscoverView` / `RankingsScreen` / `HomeScreen`
  - `PlayerControls` / `PlayerMenu` / `TelevisionControls`
- 页面测试与直接构造页面的测试均补上 delegates，保证中文断言不变
- `sourceTimestamp` 等格式化辅助函数改为接收 `AppLocalizations`，避免在
  非 Widget 层硬编码文案

> 其余页面仍有大量硬编码中文（P3 剩余项），后续按页面逐个迁移；
> 新页面和新文案必须走 ARB，不再新增硬编码。

### 2.20 P3：测试与动效令牌

- 新增 `test/domain/lan_sync_models_test.dart`（8 条）：版本包含/合并、
  冲突检测、同版本同内容合并、同版本异内容拒绝、哈希对键顺序不敏感
- 新增 `test/video_enhancement_policy_test.dart`（4 条）：动漫标签、
  色彩安全、关闭增强、不安全色彩保持原画
- 新增 `test/data/media/media_merge_test.dart`（5 条）：排序、未完成、
  跨剧、重复集数、缺口报告
- 新增 LAN 控制器（5 条）、LAN 同步页（1 条）、`VideoOutputSize`（5 条）、
  `PlayerControls`（1 条）测试
- `Md3Motion.standardAccelerate` 已用于详情页、目录筛选、播放控件与底部导航，
  不再只是定义未使用

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

### 4.0 全量测试归零（0.2.58+64 本轮）

本轮把全量 Dart 测试从 **44 失败 / 256 通过** 清到 **0 失败 / 328 通过（跳过 1）**，
`dart analyze lib test integration_test test_driver` 为 **0 error / 0 warning**（80 条历史
`info` 级 lint 保留）。

失败分三类，处理方式不同：

| 类别 | 数量 | 根因 | 处理 |
| --- | --- | --- | --- |
| 真实产品缺陷 | 9 | `_PlayerScreenState` 在 `initState` 中调用 `l10n` getter，间接触发 `AppLocalizations.of(context)` → `dependOnInheritedWidgetOfExactType`。Flutter 明令禁止在 `initState` 期间建立 inherited 依赖，断言直接抛出并让播放启动失败 | 把起播逻辑移到 `didChangeDependencies` 的一次性引导（`_bootstrapped` 闸门），播放器与弹幕相关 9 项测试全部转绿 |
| 测试环境缺少依赖 | 4 | `search_input_test` / `television_test` / `downloads_controller_test` 用裸 `MaterialApp`，没有注册 `AppLocalizations.localizationsDelegates`，`AppLocalizations.of` 的空断言崩溃 | 三处补齐 delegates 与 `supportedLocales` |
| 陈旧用例（交互已变） | 31 | 点卡片改为**直接播放**、详情页分集**默认折叠**、追剧改为**下拉菜单**、下载页改为**合集展开 + 弹层菜单**、筛选改为**弹窗**、电视端分集行不再暴露 `download-task-*` key | 按新交互重写断言，覆盖同样的用户路径 |
| 环境 | 1 | `engine_hls_download_test` 的 `tearDownAll` 在 Windows 删除临时目录，引擎仍持有分片句柄 | 清理容忍 `FileSystemException` |

引擎侧 8 个 `engine_*` 测试此前因 `frb_generated` 与 release 动态库内容哈希不一致而整组
`setUpAll` 失败，本机执行 `cargo build -p guo_engine --release` 后全部通过——这是构建前置
条件，不是代码缺陷。

### 4.1 静态检查

```
dart analyze lib test integration_test test_driver   →   0 errors, 0 warnings
```

（80 条 `info` 级 lint 为项目历史遗留，与本次迁移无关。）

### 4.2 测试

```
flutter test   →   +328 ~1   （0 失败）
```

此前一轮新增 95 条控制器 / 页面 / 纯逻辑测试，全部通过：

```
flutter test test/ui/features/detail/controllers/detail_controller_test.dart test/ui/features/downloads/controllers/downloads_controller_test.dart \
  test/ui/features/player/controllers/playback_progress_controller_test.dart test/ui/features/player/controllers/playback_session_controller_test.dart \
  test/ui/features/player/controllers/playback_preferences_controller_test.dart test/ui/features/profiles/controllers/profiles_controller_test.dart \
  test/ui/features/media/controllers/local_media_controller_test.dart test/ui/features/sources/controllers/sources_controller_test.dart \
  test/ui/features/rankings/controllers/rankings_controller_test.dart test/ui/features/settings/controllers/settings_controller_test.dart \
  test/ui/features/settings/controllers/resource_settings_controller_test.dart \
  test/domain/lan_sync_models_test.dart test/video_enhancement_policy_test.dart \
  test/data/media/media_merge_test.dart test/data/lan/lan_controller_test.dart   test/ui/features/lan/views/lan_screen_test.dart   test/data/video_enhancement/video_output_size_test.dart   test/ui/features/player/widgets/player_controls_test.dart
→   +95
```

macOS 主机全量结果（P3 第二批后复跑）：

```
flutter test   →   +244 ~1 -28
```

**结论：本次迁移零新增回归。** 验证方式与结果：

- 对疑似受影响的 4 个文件，用 `git stash push -- lib` 回到 HEAD 后重跑：
  `interface_test`（4）、`widget_test`（2）、`theme_test`（1）、
  `sources_test`（1），共 8 条失败，**与迁移后逐条一致**。
- `television_test` 的 2 条 `start-play` 失败在 HEAD 上同样复现。
- `downloads_test` 的 3 条失败引用 `pause-1` / `local-play-3` 等**从未存在**
  的 key（HEAD 的 `downloads_screen.dart` 中也没有），属于陈旧用例。
- 其余失败集中在 `engine_*` / `media_library`：macOS 主机没有
  `guo_engine.framework`、FFmpeg 素材也不在本机，属于**环境差异**；
  Windows 基线（`+182 ~1 -18`）不能直接与本机计数相比。

已知基线失败原因（与本次迁移无关）：
- 测试断言 `find.text('我的追剧')`，而 UI 实际渲染 `我的追剧 · 0`
  （`lib/ui/features/home/widgets/saved_library.dart:145`）
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

### P0 — 首页响应式化（已完成）

见 2.5：`/` 路由已改为 `_HomeRoute` + `ref.watch(storeProvider)` +
`storeRevisionProvider`，切换用户、锁定与就绪状态都会重建首页。

### P1 — 状态管理迁移（逻辑页面已完成，剩 UI 本地状态）

`discover`、`detail`、`downloads`、`profiles`、`local_media`、`sources`、
`rankings`、`settings` 以及播放器的三阶段拆分均已完成。当前 `setState` 分布：

| 文件 | `setState` 数 | 状态 |
| --- | --- | --- |
| `lan_screen.dart` | 19 | 部分迁移（`LanSyncController` 接管主面板的忙碌 / 取消 / 错误） |
| `player_screen.dart` | 18 | 部分迁移（进度 + 会话 + 偏好） |
| `home_screen.dart` | 12 | 待迁移（tab / 多选 / 缓存更新） |
| `resource_settings_screen.dart` | 1 | 已拆分（仅剩代理可见性） |
| `detail_screen.dart` | 4 | 已拆分（仅剩 UI 展开态） |
| `profiles_screen.dart` | 3 | 已拆分（仅剩表单勾选） |
| `downloads_screen.dart` | 1 | 已拆分（仅剩控制器变更回调） |
| `settings_screen.dart` / `local_media_screen.dart` / `sources_screen.dart` / `rankings_screen.dart` | 0 | 已拆分 |

> 剩余的 `lan_screen`、`home_screen` 与 `player_screen` 中，多数 `setState`
> 是面板选择、表单编辑、全屏/PiP 等**页面本地 UI 状态**，不需要强行下沉。
> 下一步只迁移其中的数据操作与跨组件状态，避免为“清零 setState”而制造
> 无意义的 ViewModel。
>
> 本轮只把 `LanSyncScreen` 的**动作状态**（busy / cancelling / error）收进
> `LanSyncController`，并补 7 条单元测试。`_LanDevices`、`_LanManual` 与
> `_LanPushPanel` 的状态与 `LanController` 生命周期、弹层关闭时机强耦合，
> 强行下沉会把「关闭弹层」这类导航副作用塞进控制器，因此保持原样。

**最大债务**：`_PlayerScreenState` 现有约 **32 个字段**，主要剩播放器/弹幕
控制器、恢复与健康检查，以及全屏、弹层、PiP、生命周期等页面状态。
`player_screen.dart` 现有 2020 行。

**已完成**：
- 阶段 1：观看进度持久化 → `PlaybackProgressController`（见 2.9）
- 阶段 2：会话加载/错误/计划/清晰度 → `PlaybackSessionController`（见 2.10）
- 阶段 3：速度/弹幕/自动连播/预加载 → `PlaybackPreferencesController`（见 2.11）

**下一步建议**：播放器的主要非 UI 状态已经下沉，剩余工作按以下顺序：

1. 恢复与健康检查（`PlaybackRecovery` / `PlaybackHealth` 已存在，可把
   计时器、错误票据与 `_acceptErrors` / `_pendingError` 收进协调器）；
2. 语义化 UI 状态（全屏、面板、移动端标签）可以留在页面层，但可考虑
   用 `ValueNotifier` 或小型控制器减少 `setState`；
3. PiP、手势、焦点与前后台生命周期保持在页面层；
4. 每阶段用 `test/ui/features/player/views/player_screen_test.dart`、`test/ui/features/player/views/television_player_test.dart`
   做定向回归，避免一次性重写。

### P2 — 测试改造（已完成）

- `test/router_harness.dart` 的 `pumpRouterApp()` 使用**生产路由表**，
  需要真实导航的测试不再手写 `MaterialApp(home: X)`。
- 功能测试已镜像 `lib/` 结构：

```
test/ui/features/
  discover/controllers/     catalog_controller_test.dart
  detail/controllers/       detail_controller_test.dart
  downloads/controllers/    downloads_controller_test.dart
  downloads/views/          downloads_test.dart
  lan/controllers/          lan_sync_controller_test.dart
  media/controllers/        local_media_controller_test.dart
  player/controllers/       playback_*_controller_test.dart
  player/views/             player_screen_test.dart、television_player_test.dart、danmaku_*
  profiles/controllers/     profiles_controller_test.dart
  profiles/views/           profiles_test.dart
  rankings/controllers/     rankings_controller_test.dart
  rankings/views/           rankings_screen_test.dart
  settings/controllers/     settings_controller_test.dart、resource_settings_controller_test.dart
  settings/views/           settings_views_test.dart
  sources/controllers/      sources_controller_test.dart
  sources/views/            sources_test.dart
```

- 新增控制器测试统一用假仓库 / 端口注入，不需要 Widget 环境；
  页面级测试只验证 ViewModel 接线与关键渲染。
- 跨功能的综合测试（`widget_test`、`interface_test`、`theme_test`、
  `library_features_widget_test`、引擎与媒体库测试）仍保留在 `test/` 根目录，
  避免为了目录整齐制造大范围无意义 diff。
- 测试改造遵循 `.dsh/skills/dart-add-unit-test` 与
  `.dsh/skills/flutter-add-widget-test`；架构遵循
  `.dsh/skills/flutter-apply-architecture-best-practices`。

### P3 — 长期改进（进行中）

已完成：

- l10n 管线（ARB + 生成代码 + `MaterialApp` delegates）；`StorageScreen`、
  `ProfilesScreen` / `ProfileEditor`、`SourcesScreen` 已完整迁移；
  新页面必须使用 ARB
- `Md3Motion.standardAccelerate` 已用于详情页与目录筛选
- 新增 LAN 同步模型（8 条）、LAN 控制器（5 条）、LAN 同步页（1 条）、
  画质增强策略（4 条）、视频输出尺寸（5 条）、媒体合并（5 条）、
  播放控件（1 条）测试，P3 点名的模块均已有可执行覆盖

剩余：

- 仍待迁移的主要 UI：`downloads_screen`、`lan_screen`、`player_screen`、
  `episode_browser` / `drama_actions` / `playback_launch_screen` / 弹幕控制器
- 数据/领域层的业务错误文案仍为中文（`local_store`、`core_bridge`、
  `lan_sync`、`media_library` 等），需要在展示边界统一本地化
- `lan_sync` 的双端同步流程仍缺端到端测试（当前覆盖模型与控制器设置）
- 无障碍（Semantics、触控区、对比度）与响应式断点的系统化验证
- 统一的 `Result` / typed failure 错误模型

---

## 6.5 Rust 引擎现状（2026-10-21 第十八轮）

引擎侧已从「一个 crate 堆全部」拆成 9 crate 工作区，并把插件体系做成可运行的代码。
细节见 `docs/PROGRESS.md` 第十三轮，这里只列对 Flutter 侧有影响的事实。

| 事项 | 现状 |
| --- | --- |
| 工作区 | `rust/Cargo.toml` 虚清单；`bridge/` 只做 FRB 边界，实现在 `rust/crates/*` |
| 主源 | `guo-source-hongguo` 已注册进 `builtin_registry()`，能力位覆盖目录 / 详情 / 搜索 / 取流 / 分类；发果规则带在线验证用例（`--ignored`） |
| 插件安装 | `bridge/src/api/plugins.rs` 暴露 `setPluginDirectory` / `parseRepository` / `installPlugin` / `installedPlugins` / `uninstallPlugin` / `setPluginEnabled` / `rollbackPlugin` / `rememberRepository`，Dart 绑定已生成到 `lib/src/rust/api/plugins.dart` |
| 代码插件 | WIT 契约 `rust/crates/plugin-wasm/wit/source-plugin.wit`；模板 `rust/examples/plugin-template/`（`./build.sh`） |
| 站源 | 引擎注册 13 个：红果主源；代码源猫果、牛果、剧果；9 条声明式规则（伍果 / 花果 / 饭果 / 观果 / 星果 / 河果 / 网果 / 帝果 / 发果） |
| 测试 | `cargo test --workspace` 367 项；Dart 引擎测试 9 项需先 `python scripts/prepare_engine.py` |

**Dart 测试的前置条件**：跑引擎测试前先准备动态库：

```
python scripts/prepare_engine.py          # release（推荐）
python scripts/prepare_engine.py --debug  # 调试
```

脚本会构建并把产物同时放到 `rust/target/<profile>/` 与
`rust/bridge/target/<profile>/`。生成代码的 `ioDirectory` 写的是前者，
codegen 按 `rust_root` 推出的是后者——两侧都有库，所以重新生成绑定后
**不需要再手工修改生成文件**。`test/engine_support.dart` 的
`initEngineForTest()` 在库缺失时会直接给出上面这条命令，而不是让
`RustLib.init()` 抛出 `Failed to load dynamic library`。

**重新生成绑定**（`flutter_rust_bridge_codegen generate`）后：
若新增了 FRB 不可序列化的 Rust 类型，给对应函数加
`#[flutter_rust_bridge::frb(ignore)]`（`debug_env`、`plugin_error_hint`
就是这么处理的）。`ioDirectory` 无需手工修改。

---

## 7. 关键文件索引

| 文件 | 职责 |
| --- | --- |
| `lib/main.dart` | 启动装配、`ProviderScope` 注入、`DuanjuApp` 外壳 |
| `lib/ui/routing/app_router.dart` | 路由表（18 条）、`extra` 载体、`AppRoutes` |
| `lib/ui/routing/route_args.dart` | `DramaRef` 类型安全标识 |
| `lib/ui/providers/app_providers.dart` | 全部 Provider + ChangeNotifier 桥 |
| `lib/ui/features/` | 页面级 feature 目录（views / controllers / widgets） |
| `lib/ui/features/discover/` | 发现页 MVVM 样板（controller / view / widgets） |
| `lib/ui/features/detail/controllers/detail_controller.dart` | 详情取数、元数据合并、分页与权限 |
| `lib/ui/features/detail/views/detail_screen.dart` | 详情页 UI 与导航 |
| `lib/ui/features/downloads/controllers/downloads_controller.dart` | 下载轮询、筛选、多选与批量操作 |
| `lib/ui/features/downloads/views/downloads_screen.dart` | 下载合集页 UI 与确认弹层 |
| `lib/ui/features/player/views/player_screen.dart` | 播放器页面（待继续分阶段拆分） |
| `lib/ui/features/player/controllers/playback_progress_controller.dart` | 观看进度保存、去重与失败提示 |
| `lib/ui/features/player/controllers/playback_session_controller.dart` | 会话加载、错误、播放计划与清晰度状态 |
| `lib/ui/features/player/controllers/playback_preferences_controller.dart` | 速度、弹幕、连播与预加载偏好 |
| `lib/ui/features/profiles/controllers/` | 用户管理与编辑器 ViewModel |
| `lib/ui/features/media/controllers/local_media_controller.dart` | 本地媒体加载、导出与删除 |
| `lib/ui/features/sources/controllers/sources_controller.dart` | 站源轮询、任务与健康状态 |
| `lib/ui/features/rankings/controllers/rankings_controller.dart` | 榜单目录、分页与切换 |
| `lib/ui/features/settings/controllers/` | 设置备份/恢复、存储迁移与资源设置 |
| `lib/ui/features/player/widgets/` | 播放控制、菜单、遥控与交互层 |
| `lib/data/` | 仓库、本地存储、引擎路由、媒体 / LAN / 播放 / 增强服务 |
| `lib/data/media/media_library.dart` | 媒体合并、导出与目录任务 |
| `lib/data/lan/lan_controller.dart` | 设备互联与同步 |
| `lib/ui/features/lan/controllers/lan_sync_controller.dart` | 同步页动作状态（忙碌 / 取消 / 错误） |
| `lib/data/playback/` | 播放取流、预加载与恢复 |
| `lib/data/video_enhancement/` | 画质增强策略与 MPV 集成 |
| `lib/domain/` | 剧集、榜单、LAN、偏好等纯领域模型 |
| `lib/ui/core/` | 跨 feature 的布局、主题、通用 Widget |
| `lib/l10n/app_zh.arb` | 中文文案模板 |
| `lib/l10n/generated/` | `flutter gen-l10n` 生成的本地化类 |
| `lib/ui/theme/md3_tokens.dart` | MD3 设计令牌（`Md3Spacing` 等） |
| `rust/bridge/src/api/` | FRB 入口：站源取数、下载、缓存、插件管理 |
| `rust/crates/source-api/` | 站源契约：模型、错误、trait（零 IO） |
| `rust/crates/plugin-host/` | 插件包格式、仓库协议、安装器 |
| `rust/crates/plugin-wasm/` | WASM 组件宿主与能力注入 |
| `rust/crates/source-hongguo/` | 红果主源（签名、`_ROUTER_DATA` 解析） |
| `docs/ARCHITECTURE.md` | 引擎架构与阶段划分（唯一权威设计文档） |
| `docs/PROGRESS.md` | 每轮落地内容与验证数据 |
| `lib/src/rust/` | FRB 生成的 Dart 绑定（勿手改，含 `ioDirectory`） |
| `test/router_harness.dart` | 路由测试脚手架 |
| `test/ui/features/detail/controllers/detail_controller_test.dart` | 详情控制器单元测试 |
| `test/ui/features/downloads/controllers/downloads_controller_test.dart` | 下载控制器单元测试 |
| `test/ui/features/player/controllers/playback_progress_controller_test.dart` | 播放进度控制器单元测试 |
| `test/ui/features/player/controllers/playback_session_controller_test.dart` | 播放会话控制器单元测试 |
| `test/ui/features/player/controllers/playback_preferences_controller_test.dart` | 播放偏好控制器单元测试 |
| `test/ui/features/profiles/controllers/profiles_controller_test.dart` | 用户管理 / 编辑器控制器测试 |
| `test/ui/features/media/controllers/local_media_controller_test.dart` | 本地媒体控制器测试 |
| `test/ui/features/sources/controllers/sources_controller_test.dart` | 站源控制器测试 |
| `test/ui/features/rankings/controllers/rankings_controller_test.dart` | 榜单控制器测试 |
| `test/ui/features/settings/controllers/settings_controller_test.dart` | 设置 / 存储控制器测试 |
| `test/ui/features/settings/controllers/resource_settings_controller_test.dart` | 资源设置控制器测试 |
| `test/ui/features/settings/views/settings_views_test.dart` | 资源设置 / 存储页 Widget 测试 |
| `test/ui/features/rankings/views/rankings_screen_test.dart` | 榜单页 Widget 测试 |
| `test/domain/lan_sync_models_test.dart` | LAN 同步版本与冲突测试 |
| `test/video_enhancement_policy_test.dart` | 画质增强策略测试 |
| `test/data/media/media_merge_test.dart` | 合并分集连续性校验测试 |
| `rust/` | Rust 引擎（cargo workspace，`guo_engine` crate） |

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
5. 新增页面放到 `lib/ui/features/<feature>/views/`，控制器放
   `controllers/`，页面专用控件放 `widgets/`；`lib/` 根目录不再新增页面文件。
6. `lib/` 内统一使用 `package:duanju_app/...` 导入；`lib/src/rust/` 与
   `part` 文件除外。
