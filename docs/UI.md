# 前端设计规范

> 建立：2026-10-23 · 对应「前端大改」P0–P6
> 关联：`ARCHITECTURE.md` §6（Dart 分层）、`md3_tokens.dart`（令牌定义）

## 1. 判据

桌面端（≥1000px）必须满足五条：

1. 任何页面都不出现「手机布局拉宽 + 左右大片空白」。
2. 侧栏常驻，切 tab 不丢滚动位置与筛选状态。
3. 鼠标有 hover/focus 反馈，滚动条可见，右键与键盘可达。
4. 设置类页面是两栏，不再全页替换。
5. 窗口可拖拽、可记忆尺寸、关闭可最小化到托盘。

五条都有对应的自动化测试（见 §7）。**TV 模式不在本规范范围内**，
它保留原有遥控路径，后续单独设计。

## 2. 外壳与导航

导航形态按**窗口方向**决定，与设备类型无关：

| 窗口 | 形态 |
| --- | --- |
| 竖屏（高 > 宽） | 底部导航 |
| 横屏（宽 ≥ 高） | 左侧 rail（`NavigationRail` 默认宽度 ~72px） |

结构与 Kazumi `lib/pages/menu/menu.dart` 的 `_sideMenu` 一致：

- `groupAlignment: 1`——**目的地沉到底部**，顶部大片留白；
- `labelType: selected`——**只有选中项**在图标下显示文字，整条栏始终是一个图标的宽度；
- `leading` 只放一颗搜索 FAB，没有品牌区、没有展开按钮；
- 内容区是**圆角书架**：外壳底色 `surfaceContainer`，内容 `primaryContainer`
  混合 45% 到 `surface`（品牌橙红直接铺会压过海报），左侧上下两角 16px 圆角，
  因此左上 / 左下各露出一条窄边。

**为什么用方向而不是宽度阈值**：Flutter 应用跑在可调整大小的窗口里，
「宽还是高」才是决定导航放下边还是左边的真实依据。桌面窗口通常横屏，
因此总是 rail；手机竖屏用底部导航；手机横屏也能用 rail。
电视模式走 `AppLayout.isTelevision` 独立分支，与方向体系无关。

**最小窗口 480×560**（`Md3WindowClass.minimumWindow`，与
`DesktopWindow` 的 `minimumSize` 同源）。

**踩过的坑**：第一版做成了「≥900 常驻 240px 侧栏」，同一窗口宽度下
内容区比 Kazumi 少 168px，网格从 6 列掉到 4 列。rail 固定窄宽是密度差异
的根因，不要再加展开态。

## 3. 路由

**除 4 个 tab 外，所有页面都不进外壳**：独立全屏 + 顶部返回。理由是在
1440 宽的窗口里给一个完整页面只留 1200 的内容区、还挂着侧栏，会让
「看一眼站源诊断」这种操作显得比必要更重。

### 3.1 结构

| 层 | 路径 |
| --- | --- |
| 外壳分支（只有 4 个 tab） | `/discover`、`/follows`、`/history`、`/downloads` |
| 根级全屏页 | `/settings`（+`theme`、`resources`、`downloads`、`storage`、`diagnostics`、`sources`、`sources/plugins`、`profiles`、`profiles/editor`）、`/discover/rankings`、`/downloads/local`、`/downloads/merge`、`/detail/:source/:sourceId`、`/player/:source/:sourceId`、`/picker/:source/:sourceId`、`/batch` |
| 锁屏 | `/unlock`（独立于外壳，未解锁时不能操作导航） |
| 启动 | `/` → 重定向到 `/unlock` 或 `/discover` |

### 3.2 旧路径重定向

`_redirect` 集中处理，页面里不要再引用 `AppRoutes.legacy*`：

| 旧 | 新 |
| --- | --- |
| `/sources` | `/settings/sources` |
| `/sources/plugins` | `/settings/sources/plugins` |
| `/profiles` | `/settings/profiles` |
| `/profiles?locked=1` | `/unlock` |
| `/profiles/editor` | `/settings/profiles/editor` |
| `/local-media` | `/downloads/local` |
| `/merge-queue` | `/downloads/merge` |
| `/batch-download` | `/batch` |
| `/download-picker/:s/:id` | `/picker/:s/:id` |

重定向只在首次解析时改写，改写后 go_router 以新路径重新匹配，不会循环。

## 4. 宽度体系

`Md3WindowClass` 与 `Md3Spacing` 是唯一真相，页面不要写字面量。

| 令牌 | 值 | 用途 |
| --- | --- | --- |
| `contentMaxWidth` | 1040 | 表单、设置、诊断等长文本页 |
| `wideMaxWidth` | 1440 | 海报网格、卡片列表 |
| `pageInset(width)` | 16→32 | 页面左右留白，随窗口等级增长 |
| `contentInset(width, maxWidth:)` | — | 「标准留白」与「居中所需留白」取大者 |
| `sidebarWidth` | 240 | 侧栏 |
| `settingsPaneWidth` | 280 | 设置两栏左侧分组 |
| `detailPaneWidth` | 360 | 详情页左栏 |

**关键约定**：网格类页面用 `contentInset` 直接得到留白，不需要再套
`ConstrainedBox` —— 留白本身承担了居中职责，少一层 widget。

海报网格的列数、间距与行高只有一处算法：`Md3Grid`（`dramaGridDelegate`、
首屏骨架、遥控网格都走它）。**数值照抄 Kazumi**：

| 令牌 | 值 | 出处 / 用途 |
| --- | --- | --- |
| `Md3Grid.posterRatio` | 0.65 | Kazumi 海报是 10:16，不是 2:3 |
| `Md3Grid.spacing` | 8 | `StyleString.cardSpace`，列间距 |
| `Md3Grid.rowSpacing` | 6 | `cardSpace - 2`，行比列更紧（文字块已经把行间隔撑开） |
| `Md3Grid.textReserve` | 32 | 标题区预留，实际再过一层 `TextScaler` |
| `Md3Grid.columns(width)` | 3 / 5 / 6 | 按 600 / 840 两个断点给列数，`width` 必须是扣过留白的内容宽 |
| `remoteGridLayout(context, width)` | 可收紧到 4 | 遥控网格：同一套推算，用 min / max 把列数压下来 |

与 Kazumi 的两处**刻意偏离**：① 它按**窗口**宽度算列数，2560 宽下单张海报
接近 400px；我们按扣过 `contentInset` 的内容宽算，于是被 `wideMaxWidth`
兜住，最大约 233px。② 它的网格左右只有 8px 平铺留白，桌面会贴边；我们
保留 `contentInset`（§1 判据 1）。

改造过程中踩过的反向坑：无内容约束时单张海报接近 280px（被拉大的手机
网格），以及行距给到 18、标题固定预留三行时，整屏读起来是「一行海报
一行空白」。

## 5. 视觉系统

### 5.1 令牌

| 组 | 内容 |
| --- | --- |
| `Md3Spacing` | 8dp 间距、页面留白、内容上限 |
| `Md3Grid` | 海报网格：比例 0.65、间距 8 / 行 6、列数 3 / 5 / 6（见 §4） |
| `Md3WindowClass` | 600 / 840 / 1000 / 1200 / 1600 五档 |
| `Md3Shape` | 圆角：卡片 16、弹层 28、胶囊 999、分组外 24 / 内 4 |
| `Md3Elevation` | 0 / 1 / 3 / 6 四档，层级靠 surface 明度差而非阴影 |
| `Md3State` | 状态层：hover .08 / focus .12 / pressed .10 / disabled .38 |
| `Md3Motion` | 时长与曲线；`of(context, …)` 在关闭动画时归零 |
| `Md3Type` | 文字层级；`cardTitle(width)` 随窗口放大一档 |

### 5.2 状态层

M3 用「叠加半透明层」表达交互状态，而不是改前景色——这样任意表面色
上都能保持对比度。代码里一律用 `Md3State.layer(base, overlay, opacity)`。

### 5.3 原语

| 文件 | 用途 |
| --- | --- |
| `ui/core/app_page.dart` | 页面骨架（宽度策略 + 留白 + 居中） |
| `ui/core/split_list.dart` | 分组列表（外圆角 24 / 内 4 / 间隔 4 / 按压→24） |
| `ui/core/widgets.dart` | `DramaCover`（纯海报）+ `DramaTile`（2:3 封面 + 两行标题 + 一行元信息） |
| `ui/core/skeleton.dart` | 骨架屏（首屏替代转圈，列数与行高与真实网格同源） |
| `ui/core/empty_state.dart` | 空态 + 手绘徽标 + 加载指示器 |
| `ui/core/app_scroll_behavior.dart` | 桌面常显滚动条 |
| `ui/core/episode_grid.dart` | 选集按钮与网格（非 TV，带 hover/Tab 焦点） |
| `ui/shell/*` | 外壳、侧栏、窗口 chrome、托盘 |

### 5.4 海报卡片

卡片照抄 Kazumi 的 `BangumiCardV`：`Card(elevation: 0, margin: 0)` +
`AspectRatio(0.65)` 海报 + 一个只有 `textReserve` 高的文字区。

- **封面上不压渐变、不烧集数**。每张海报底部一片黑时，整屏网格的视觉
  重量会盖过海报本身。
- 封面上只允许**交互件**（多选圆点、右上「更多」）与一处刻意保留的
  **VIP 角标**——VIP 决定能不能播、下载是不是试看，藏进标题行会让人
  在网格里挑完才发现。
- 标题**行数由可用高度算出来**（1–3 行，`w500` / `letterSpacing .3`），
  不是写死两行：固定预留三行时单行标题下面会挂出一条空白。
- 标题的 `TextScaler` 钳制在 1.1：列宽与行高不随字号变，放到 1.3 倍
  标题会把海报挤没。
- 圆角统一 `Md3Shape.posterRadius`（12，Kazumi 的 `imgRadius`）：封面、
  `InkWell`、hover 描边、按压 morph 同一个值，否则桌面悬停能看到错位。
- 元信息行是**可选**的：目录页不传，因此与 Kazumi 一样只有海报和标题；
  追剧 / 历史传状态与进度，此时 `dramaGridDelegate` 与
  `DramaTile.extentFor` 必须同时给 `withMeta: true`，否则行高差一行。
- 无障碍：叠字搬到文字区后，`dramaSemantic` 要显式带上元信息。

### 5.5 主题个性化

四项偏好存 `LocalStore`，改完立即生效：

| 偏好 | 键 | 说明 |
| --- | --- | --- |
| 明暗模式 | `themeMode` | light / dark / system |
| 种子色 | `themeSeed` | 8 位十六进制 ARGB，null = 品牌色 |
| 动态取色 | `useDynamicColor` | Android 12+ / macOS 14+ |
| OLED 纯黑 | `oledEnhance` | 仅深色模式，表面压到 #000 但保留容器层次 |
| 系统字体 | `useSystemFont` | 关闭后使用内置中文字体 |

种子色只给 9 个预设，不做任意取色：任意色会让「主色定位 / 标签色」
两处手工覆盖失效，也容易出现对比度不足。

## 6. 桌面专属

| 能力 | 实现 |
| --- | --- |
| 隐藏标题栏 | macOS `MainFlutterWindow.swift`（`fullSizeContentView` + 透明标题栏）；Windows `setTitleBarStyle(hidden)` |
| 红绿灯避让 | `NativeInset` 只推交互控件，背景照常画到按钮下方 |
| 拖拽 | `DragArea`：`onPanStart` 一次性交给 `windowManager.startDragging()` |
| 窗口记忆 | `windowBounds` 存 `LocalStore`；恢复时做离屏钳制（至少露出 120×80） |
| 最小尺寸 | 480×560（`DesktopWindow` 与 `Md3WindowClass.minimumWindow` 同源，见 §2） |
| 关闭行为 | `closeBehavior`：退出 / 最小化到托盘 / 每次询问（默认询问） |
| 托盘 | `DesktopTray`：显示窗口 / 退出 |
| 快捷键 | `⌘K` 搜索、`⌘,` 设置、`⌘1–4` 切分支（`control` 同义） |

**macOS 沙箱**：`Release.entitlements` 与 `DebugProfile.entitlements` 都
必须包含 `com.apple.security.network.client`，否则引擎的所有请求会被
系统拒绝，表现为难以归因的网络错误。

## 7. 测试

### 7.1 三层

| 层 | 位置 | 内容 |
| --- | --- | --- |
| 令牌契约 | `test/ui/theme/layout_contract_test.dart` | 断点、留白、上限、形状、状态层、动效、字体 |
| 桌面验收 | `test/ui/shell/desktop_layout_test.dart` | 五条判据的可执行版本 |
| 偏好持久化 | `test/ui/shell/desktop_window_test.dart`、`test/ui/theme/theme_preferences_test.dart` | 窗口状态与主题选项 |

### 7.2 截图（人工比对）

```sh
flutter test test/ui/shell/capture_screens_test.dart \
  --dart-define=CAPTURE_SCREENS=true --update-goldens
```

输出 `test/ui/shell/captures/`，覆盖 5 个视口（手机 390 / 平板 900 /
桌面 1280 / 宽屏 1600 / 桌面大字号 1.3×）× 三个页面（发现、设置、
外观）。用例带 `capture` 标签并默认跳过，不进入 CI 阻断路径。

截图前会把系统中文字体注册到 `Roboto` 族名下，否则测试环境只有
拉丁字形，截图里的中文全是方块，失去参考价值。

### 7.3 为什么不用像素 golden

中文字体在不同 CI runner 上的渲染差异会让 golden 持续误报。这里改用
**结构断言**：断言的是「内容宽度不超过上限」「两侧留白不小于页面留白」
「悬停后边框不再是透明」，这些跨平台稳定，且直接编码验收标准。

### 7.4 必须保留的 key

外壳与页面测试依赖以下 key，重构时不能改名：

`bottom-nav-N`、`tv-nav-N`、`side-nav-<id>`、`catalog-refresh`（且仍是
`RefreshAction`）、`toggle-search`、`source-switch`、`open-rankings`、
`select-catalog-dramas`、`download-selected-dramas`、`episode-N`、
`follow-status`、`series-<id>`、`saved-<id>`、`history-search`、
`continue-watching`、`follow-filter-updates`、`drama-actions-<id>`、
`download-task-<id>`、`download-quality`、`enqueue-downloads`、
`download-episode-N`、`submit-batch-downloads`、`player-speed`、
`player-quality`、`player-picture-in-picture`、`player-progress`、
`player-gesture-surface`、`play-episode-N`、`player-danmaku-*`、
`update/check/source/health-toggle-<id>`、`engine-diagnostics-refresh`、
`theme-setting`、`search-suggestion-N`、`rank-<n>-<id>`。

## 8. 已完成（第二轮）

| 项 | 做法 |
| --- | --- |
| 下载页主从 | ≥1000 左合集 360 + 右剧集明细；复用 `_expanded` 当选中态，切窗口尺寸不丢上下文 |
| 站源双列 | ≥1000 且源数 >1 时两列；用 `Wrap` 而非 `GridView`，因为卡片高度随诊断展开而变 |
| 选集网格 | 新增 `episode_grid.dart`：`EpisodeButton` + `EpisodeGrid`，手机/桌面用 hover 与 Tab 焦点环，TV 仍走 `RemoteGrid` |
| 封面 Hero | `DramaCover.heroTag` + `heroFlightShuttleBuilder`（`InheritedTheme.captureAll` 防转场闪白） |
| 排序选择器 | ≥840 居中对话框（宽 480），以下仍是底部弹层；内容组件受控，两个形态共用 |

**Hero 的边界**：go_router 给每个 Navigator 单独装了 `HeroControllerScope`，
所以 Hero 只在**同一 Navigator 内**生效。目前用于榜单 → 详情与详情切季；
卡片（分支 Navigator）→ 详情（根 Navigator）的跨层转场不会触发。

## 9. 第三轮（本轮）

| 项 | 做法 |
| --- | --- |
| 导航形态 | 改为按窗口方向（竖屏底部 / 横屏 rail），与 Kazumi 一致 |
| rail 规格 | 固定窄宽、目的地沉底、仅选中项显示标签、顶部只有搜索 FAB |
| 内容书架 | `surfaceContainer` 外壳 + 混合后的 `primaryContainer` 内容面，左侧 16px 圆角 |
| 首页形态 | 目录页改成 Kazumi 那套：顶栏是滚动视图的第一个 sliver（`SliverAppBar(pinned, stretch, expandedHeight: 120)`），标题=站源切换器，字号 28→20、字重 w700→w500 随滚动插值；分页进度条 4px 淡入；右下角回顶 FAB |
| 网格密度 | `Md3Grid` 的数值整体照抄 Kazumi：海报 0.65、列间距 8 / 行间距 6、文字区 32、列数按 600 / 840 给 3 / 5 / 6。两处刻意偏离见 §4 |
| 封面瘦身 | `DramaCover` 去掉压暗渐变与烧进画面的集数；`DramaTile` 改成 `Card(elevation 0)` + 实测行数标题（1–3 行、`w500`、`letterSpacing .3`、缩放钳到 1.1），元信息行改为可选 |
| 全屏页 | 设置及其全部面板、榜单、本地媒体、合并队列全部移出外壳 |
| 详情 Tab | 剧集 / 简介 / 来源；非滚动 `TabBar` 均分右栏 |

## 10. 已知遗留

| 项 | 现状 | 后续 |
| --- | --- | --- |
| 跨层 Hero | 分支 → 根 不生效 | 需要覆盖 `HeroControllerScope`，代价高且易碎 |
| 详情页折叠标题 | 沉浸头已接入模糊封面 | 滚动时标题字号插值（`lerpDouble`） |
| 右键菜单 | 仅剧集卡片有 | 合集、下载任务、集数按钮 |
| 键盘导航 | 桌面快捷键已接入 | 完整的 Tab 顺序审查与焦点陷阱 |
| 海报淡入 | 解码完成后硬切 | 这个 Flutter 版本已移除 `Image.fadeDuration`，要 120ms 淡入得自己写 `frameBuilder` + 控制器（`Md3Motion.image` 目前没人用） |
| rail 两套实现 | `AppRail`（外壳）与 `DiscoverView._rail`（非外壳分支，路由里已不可达）参数不一致 | 删死分支，并让 `navigationRailTheme` 与实际值一致 |
| 页面骨架未接入 | `AppPage` 只用在 2 个页面，`AppPageScope` 从未被插入树；十余处仍手写 `Center + ConstrainedBox` | 要么接入并删手抄，要么删掉 `AppPageScope` |
| 首页折叠头覆盖面 | 只有目录页走 `SliverAppBar`；推荐位自带 Scaffold + AppBar，仍是旧 Column 形态 | 把推荐位也并进同一个滚动视图，或让它复用 `_headerSliver` |
| 首页动作数量 | 折叠头已照抄 Kazumi，但动作仍是 5 个图标（排序 / 榜单 / 多选 / 搜索 / 刷新），Kazumi 只有 1–3 个 | 收进溢出菜单需要同步改 4 个直接 tap 这些 key 的用例 |
| 未使用的令牌 | `listGap`、`cardTitle`、`constrainsContent`、`containerPair` 等只在契约测试里出现 | 用到调用点或删令牌删断言，避免假绿灯 |
