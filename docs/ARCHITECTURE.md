# 星（hoshi）架构

> 更新：2026-10-23 · 依据当前代码核实（Core-0～4 全部完成，Go 与 LAN 已物理删除；
> 前端完成外壳与桌面布局重构，见 `docs/UI.md`）
> 本文是唯一权威设计文档。历史设计过程见 `docs/PROGRESS.md`，性能数据见 `docs/PERFORMANCE.md`。

## 0. 一句话

**一套后端**：Flutter 前端 + Rust 引擎，端侧完成请求、解析、播放、下载。
站源分三类——编译进二进制的主源与代码源、随包分发的声明式规则、可安装的官方 Wasm 插件。

## 1. 现状（2026-10-23 核实）

### 1.1 规模

| 项 | 数值 | 来源 |
| --- | --- | --- |
| Rust 源文件 | 131 个 | `find rust -name '*.rs'`（不含 target） |
| Rust crate | 14 个 + 桥接层 | `rust/crates/` + `rust/bridge/` |
| 随包扩展 | 6 个 Wasm + 1 个脚本（猫果 1.1.0），合计约 404 KB | `assets/bundled_plugins/` |
| 随包声明式规则 | 9 条 | `rust/rules/` |
| FRB API 函数 | 52 个（40 站源 + 12 插件） | `rust/bridge/src/api/` |
| FRB Stream | 1 个（下载进度） | `download_progress_stream` |

### 1.2 已删除的东西（不要再假设它们存在）

| 已删除 | 时间 | 替代 |
| --- | --- | --- |
| Go 后端 `native/`（128 文件 / 约 2.6 万行） | Core-4（2026-10-22） | Rust 引擎 |
| `lib/data/core_bridge.dart` 的 Go FFI | Core-4 | `lib/data/app_contract.dart`（纯契约） |
| LAN（`lib/data/lan/`、`lib/ui/features/lan/`、2 条路由） | Core-4 | 无，明确不提供 |
| `ENGINE_ROUTE` / `EngineRouting` | Core-0 | 引擎是唯一后端 |
| cargokit（`rust_builder/`） | 2026-10-21 | native-assets（`hook/build.dart`） |
| `scripts/` 的 11 个构建脚本 | 构建链收敛 | 3 个（性能 / 体积 / Windows 冒烟） |

### 1.3 双版本已取消

应用名固定「星」，`ALL_SOURCES` 只决定**编译进哪些站源**（iOS 全源，其余平台内置）。
`appSlug` 恒为 `hoshi`，不再有「红果鉴 / 真果鉴」两套发布物。

## 2. 目标与非目标

### 目标

1. **单栈**：仓库里只有一套后端实现。
2. **状态正确**：会话 / 缓存 / 下载跨重启保留；错误分级；请求可取消。
3. **站源可扩展**：官方插件可安装、可启停、可回滚，且不丢会话与任务。
4. **可发布**：四端可构建、有性能与包体护栏。

### 非目标

- 剩余站源（黄豆 / 野果 / 皮果）。
- LAN 设备互联。
- 封面修复、源健康扫描、代理 / DNS / CDN 高级设置、下载合集。
- 插件市场与第三方生态（只保证官方源）。
- 红果主源 Wasm 化。

## 3. 关键决策（ADR）

| # | 决策 | 理由 |
| --- | --- | --- |
| ADR-5c | Go 后端整体移除，不并行发版 | 双栈 = 两套实现、两套夹具、两倍回归面，行为漂移无人负责 |
| ADR-7 | 主源与插件实现**同一个 trait** | 防止主源走第二套路径，导致插件侧缺能力时无人发现 |
| ADR-8 | Dart 与引擎之间不用字符串错误 | 用 `EngineFailure`（`kind` / `retryable` / `http_status`），UI 才能分级处理 |
| ADR-9 | 请求可取消（`request_id` + 会话代次），进度用 Stream | 避免切页后旧结果覆盖新状态 |
| ADR-10 | 虚工作区 + 桥接 crate 在 `rust/bridge/`，包名 `guo_engine` | native-assets 按 crate 名找产物；workspace 共享 target |
| ADR-11 | 代码插件目标 Pulley 字节码，关闭 wasmtime `async` | iOS 禁止 JIT；Pulley 是便携解释器；关 async 避免 fiber 协程栈 |
| ADR-12 | 宿主提供 `html_select` / `json_path` 提取原语，**crypto 由插件自带** | 重解析留在原生侧抵消解释开销；crypto 用插件携带的依赖，**不是手写算法**（见 §7.4） |

## 4. 架构总览

```text
Flutter UI
  └─ EngineBackedRepository（lib/data/）
       ├─ EngineException（类型化失败）
       ├─ request_id / 取消
       └─ 下载进度 Stream
            │  FRB（rust/bridge/src/api/）
            ▼
      Engine 单例（rust/crates/engine/）
       ├─ EngineConfig（数据目录 / 插件目录 / 并发 / 超时）
       ├─ SourceRegistry ← 编译源 + 9 条随包规则 + 已装插件
       ├─ DiskSourceStore（sessions.json，按 source_id 命名空间）
       ├─ CatalogCache（catalogs.json，TTL 15 分钟）
       ├─ CoverCache（covers/<sha256 前两位>/<哈希>）
       ├─ Scheduler（downloads/index.json，断点续传 + 并发可调）
       ├─ Settings（settings.json，目录限流 / 下载并发）
       ├─ EventBus（下载进度）
       ├─ CancellationRegistry
       └─ Diagnostics（能力矩阵 / 最近错误 / 计数）
```

## 5. Rust 工作区（14 crate）

| crate | 职责 | 依赖谁 |
| --- | --- | --- |
| `source-api` | 契约：模型、能力位、错误、`SourcePlugin` trait、MD5 / SHA-256 原语 | **仅** serde / async-trait |
| `rule-engine` | 声明式规则 DSL：模板（含 `{var:…}` 前置变量）、CSS / JSON / **正则** 提取（`kind`：`html` / `json` / `next` / `regex`）、`preflight` 多步编排提取 | source-api / regex / scraper |
| `host` | 传输（reqwest + 流式截断）、QuickJS 沙箱、**脚本型站源宿主**（`JsPluginHost`） | source-api / rquickjs |
| `media` | HLS 播放列表解析、分片解密 | 无（纯计算） |
| `runtime` | 目录缓存、下载调度、规则源（含 `preflight` 驱动与 TTL 缓存）与**脚本源**包装 | host / media / rule-engine / source-api |
| `plugin-host` | 插件包格式、仓库协议、安装器、打包器 | source-api |
| `plugin-wasm` | Wasm 组件宿主、能力注入、提取原语实现 | rule-engine / source-api / wasmtime |
| `engine` | **进程级单例**：装配、会话、缓存、调度、诊断、预装、迁移、封面、设置 | 上面全部 |
| `bench` | 解析热路径基准 | rule-engine / runtime |
| `source-hongguo` | 红果主源（签名、`_ROUTER_DATA`） | source-api |
| `source-niuguo` | 牛果（AES-ECB 响应解密） | source-api |
| `source-yaguo` | 芽果（设备登录令牌） | source-api |
| `source-huangju` | 剧果（访客令牌 + CDN Cookie） | source-api |
| `source-huangguo` | 黄果三源（旧版 / AI / 视频） | source-api |
| `bridge` | 只做 FRB 边界 | 全部 |

**依赖铁律**（CI 守卫生效）：`source-api` 不得引入 tokio / reqwest / wasmtime / rquickjs
（`rust/crates/source-api/tests/dependency_direction.rs`）；宿主不依赖具体站源 crate
（`engine` 通过 `BuiltinSources` 函数指针注入）。

## 6. Dart 分层

```text
lib/
  main.dart            启动装配：读随包插件 → 初始化引擎 → 注入 Provider
  app_build.dart       ALL_SOURCES 门控 + 应用名 / slug
  data/
    app_contract.dart  AppRepository 抽象 + AppFailure（纯契约，无 FFI）
    engine_repository.dart    FRB 调用 + 模型映射 + EngineException 转换
    engine_backed_repository.dart  唯一实现：能力门控 + UnsupportedFailure
    engine_failure.dart       EngineException / EngineFailureKind
    repository_capabilities.dart  能力矩阵
    bundled_plugins.dart      读 assets/bundled_plugins/ → 传给引擎
    local_store.dart / local_profiles.dart / local_snapshot.dart
    media/ playback/ video_enhancement/ background_downloads.dart ...
  domain/              纯模型（Drama / RankingBoard / 偏好 / 备份格式）
  ui/
    shell/             外壳：AppShell / 侧栏 / 窗口 chrome / 托盘 / 窗口状态
    features/<name>/   views / controllers / widgets
    core/ providers/ routing/ theme/
  src/rust/            FRB 生成绑定（勿手改，`ioDirectory` 一处手改）
  l10n/                ARB 模板与生成代码
```

**导航结构**：`StatefulShellRoute.indexedStack` 下挂 5 个分支
（发现 / 追剧 / 历史 / 下载 / 设置），每个分支有独立 Navigator，
切分支保留滚动与筛选；详情、播放、选集等沉浸页挂在根 Navigator 上。
导航形态按窗口宽度三选一：<840 底部导航、840–1000 图标轨、
≥1000 常驻侧栏。电视模式走独立分支，不受宽度体系影响。

**桌面专属**：自绘标题栏（macOS 隐藏系统标题栏 + 红绿灯避让，
Windows 自绘按钮）、可拖拽标题区、窗口尺寸与位置记忆（含离屏钳制）、
关闭行为三态（退出 / 最小化到托盘 / 每次询问）、系统托盘。

设计规范与测试约定见 `docs/UI.md`。

**能力矩阵是唯一真相**：`EngineBackedRepository.capabilities` 的当前值：

| 能力 | 值 | 说明 |
| --- | --- | --- |
| `downloads` / `localPlayback` | ✅ | 引擎下载索引 + 离线播放；登记即由 worker 执行 |
| `danmaku` | ✅ | 评论签名（Argus / Ladon）已通，窗口游标由服务端给出（30s 分段） |
| `rankings` | ✅ | 网页榜单四频道，名次区间校验分页 |
| `recommendations` | ⚠️ | App 推荐接口已死，降级为网页分类页 |
| `suggestions` | ⚠️ | 搜索页改客户端渲染，降级为联想接口（≤10 条） |
| `resourceSettings` | ✅ | 第三十五轮迁入引擎 |
| `sourceManagement` | ✅ | 单源健康检测（目录 → 详情 → 取流 → 媒体连接） |
| `lan` | ❌ | 已删除 |

UI 按能力隐藏入口；诊断页 `/settings/diagnostics` 把每一项显式标为「支持 / 当前版本不支持」。
红果 `video_model` 匿名通道已死，全量画质需要登录态或渠道接口，属产品决策而非工程待办。

## 7. 插件系统

### 7.1 三类站源

| 类型 | 来源 | 数量 | 加载方式 |
| --- | --- | --- | --- |
| 主源 | `source-hongguo` 编译 | 1 | `BuiltinSources` 注入 |
| 编译代码源 | `source-*` crate | 6 | 同上 |
| 声明式规则 | `rust/rules/*.json` | 9 | `include_str!` 随包 |
| 随包 Wasm 插件 | `assets/bundled_plugins/*.zip` | 6 | 首次启动预装 → 注册表 |
| 随包脚本扩展 | 同上（`kind: "script"`） | 1（猫果 1.1.0） | 同上，QuickJS 宿主加载（ADR-13） |

**当前是双轨**：猫果 / 牛果 / 芽果 / 剧果 / 黄果三源**同时**有编译版与插件版。
这是刻意的——`docs/PLUGIN-BOUNDARY.md` 的迁移完成前，删掉编译版会让正式包丢源。

### 7.2 包格式（`spec = 1`）

- 清单 `plugin.toml`：`kind = "declarative" | "component" | "script"`，`api.level <= 1`；
- 包：zip，SHA-256 校验，`PackageLimits`（单文件 8 MiB / 总量 32 MiB / 512 条目）；
- 仓库：`repo.toml` + `index.json`，可选 Ed25519 签名（TOFU 记录指纹）；
- 预装：`repo_id = "bundled"`，只装不覆盖（已有同版本或更高版本则跳过）。

### 7.3 WIT 契约（`rust/crates/plugin-wasm/wit/source-plugin.wit`）

导入：`fetch` / `store-get` / `store-set` / `log` / `random` / `now-ms` /
`html-select` / `json-path`。导出：`describe` / `categories` / `catalog` /
`fetch-detail` / `search` / `resolve` / `suggestions`。

**v2 相对 v1 的两处扩展**（Core-3）：
- `response.headers: list<tuple<string, string>>` —— 全量响应头（含 `set-cookie`）；
- `media.cookies` / `media.origin` —— CDN 签名凭证。

`content-type` / `etag` 快捷字段保留，已发布插件不失效。

### 7.4 crypto 由插件自带（ADR-12 的正确理解）

插件**携带自己的密码学依赖**，不是手写算法。黄果旧版插件用
`aes` / `sha2` / `base64`（纯 Rust、支持 wasm32-unknown-unknown），
与编译版 `source-huangguo` 同源。

> 这一条是 Core-3 用真实教训换来的：手写 SHA-256 对空输入输出错误哈希，
> 30 分钟无法定位，最终整体换成 crate。详见 `docs/PROGRESS.md` 第三十三轮。

### 7.5 沙箱约束

- 域名白名单来自清单 `permissions.network`，插件无法绕过；
- 存储命名空间来自 `permissions.storage`，宿主加 `plugin/<ns>/` 前缀隔离；
- `fuel` / 内存上限来自清单 `permissions.script`；
- 导入集合经 `wasm-tools component wit` 断言只剩 `guo:source/*`，无 `wasi:*`。

### 7.6 官方插件清单

| 插件 id | 名称 | 验证重点 | 大小 |
| --- | --- | --- | --- |
| `guo.yaguo` | 芽果 | 登录态跨实例复用 | 85 KB |
| `guo.niuguo` | 牛果 | AES-128-ECB 响应解密 | 50 KB |
| `guo.huangju` | 剧果 | CDN 签名 Cookie 透传 | 70 KB |
| `guo.huangguo-video` | 黄果视频 | 宿主 `html_select` 提取 | 34 KB |
| `guo.huangguo-ai` | 黄果 AI | 镜像回退 + 递归 JSON | 65 KB |
| `guo.cloudfront` | 黄果旧版 | 协议提取 + 三层加密 | 96 KB |

> `guo.cloudfront` 的包名与源 id 一致是刻意的：源语义 id 必须是 `cloudfront`
> （旧数据主键），因此包名从 `guo-plugin-huangguo-legacy` 改为 `guo-plugin-cloudfront`。

## 8. 运行时管线

### 8.1 请求与取消

```rust
let ticket = engine.begin(session, request_id);   // 同会话新请求作废旧请求
let result = source.catalog(&env, page, category).await;
engine.cancel_registry().ensure_active(&ticket)?;  // 过期则返回 Cancelled
engine.finish(&ticket);
```

Dart 侧 `request_id` 单调递增，UI 用它丢弃过期回调。

### 8.2 错误模型

`guo_engine_core::EngineError` 11 类：`Unsupported` / `Network` / `Timeout` /
`Http` / `ParseChanged` / `Session` / `Blocked` / `Cancelled` / `Storage` /
`Plugin` / `Internal`。带 `source_id` / `request_id` / `retryable` /
`http_status` / `retry_at_ms`。

FRB 边界用扁平 DTO `EngineFailure`（外部 crate 的类型会被当成不透明句柄，
Dart 读不到字段）。Dart 侧映射为 `EngineException`。

### 8.3 传输

`guo_host::HttpTransport::global()` 单例（连接池 / TLS 会话复用）。
响应头只保留 5 个：`etag` / `last-modified` / `content-type` / `content-length` /
`set-cookie`（最后一个供 CDN 签名源使用）。

### 8.4 缓存

- 目录：`catalogs.json`，键 `source` 或 `source|category`，TTL 15 分钟，
  第 1 页替换 / 后续页按 ID 合并，原子写；
- 封面：`covers/<sha256 前两位>/<哈希>`，单张上限 8 MiB，`force` 绕过、`clear` 清空。

### 8.5 下载

`downloads/index.json` 原子写。状态：`queued` / `running` / `completed` /
`failed` / `paused`。

| 行为 | 语义 |
| --- | --- |
| 暂停 | 在**分片边界**停下，已写分片与元数据保留 |
| 恢复 | 状态回 `queued`，从记录分片续传 |
| 重启 | `running` 视为中断并重新排队；`paused` 原样保留 |
| 并发 | 运行期可调；缩容只回收空闲许可 |
| 旧索引 | `<旧下载目录>/index.json` 只读导入，幂等 |

### 8.6 设置与限流

`settings.json`（原子写，损坏回落默认）：目录并发（1–6）、目录最小间隔
（0–5000 ms）、下载并发（1–6）。越界值**夹取**而非报错——输入框有中间态。
间隔在拿到并发许可之后计算，否则排队时间会被误当成「已经等过」。

## 9. FRB 边界

53 个函数按域划分：

| 域 | 函数 |
| --- | --- |
| 引擎 | `init_engine` / `init_engine_with_directory` / `engine_version` / `engine_diagnostics` / `reload_sources` |
| 源 | `source_catalog` / `fetch_categories` / `check_source` / `cancel_request` / `clear_source_session` |
| 目录 | `fetch_catalog` / `cached_catalog` / `catalog_is_fresh` / `clear_catalog` |
| 详情 | `fetch_detail` |
| 搜索 | `fetch_search` / `fetch_suggestions` |
| 播放 | `fetch_media` / `local_playback` |
| 发现 | `fetch_ranking_boards` / `fetch_ranking` / `fetch_recommend` / `fetch_danmaku` / `fetch_seasons` |
| 下载 | `enqueue_download` / `run_download` / `download_snapshot` / `control_download` / `control_downloads` / `control_download_batch` / `download_progress_stream` / `import_legacy_downloads` |
| 封面 | `fetch_cover` / `clear_cover_cache` |
| 设置 | `resource_settings` / `save_resource_settings` |
| 规则调试 | `parse_catalog_with_rule` / `parse_detail_with_rule` / `validate_rule` / `fetch_catalog_with_rule` |
| 插件 | `parse_repository` / `parse_repository_index` / `install_plugin` / `installed_plugins` / `uninstall_plugin` / `set_plugin_enabled` / `rollback_plugin` / `remember_repository` / `plugin_load_report` / `install_from_repo` / `list_repo_plugins` |

两处返回结构与旧文档不同：
- `check_source(source_id, request_id, playback)` 返回 `SourceHealth`（四步各自的状态 / 耗时 / HTTP 状态），挂在 `health-<source>` 会话上，可被 `cancel_request` 中止；
- `fetch_danmaku(source_id, chapter, start_ms, request_id)` 返回 `DanmakuPageResult { items, end_ms, has_more }`。`end_ms` 是服务端窗口游标，调用方**必须**用它推进，不能按 60s 估算（服务端按 30s 分段）。

## 10. 构建与交付

- **工具链**：`rust/rust-toolchain.toml` 钉 1.99.1 + 七个交付目标；
- **构建后端**：native-assets（`hook/build.dart` → `flutter_rust_bridge_hooks`），
  `flutter build` / `flutter test` 自动用 Cargo 构建并注册代码资产；
- **CI**：6 job —— `rust`（fmt / clippy / test / 依赖守卫 / bench 护栏）/
  `flutter`（analyze / test）/ `windows` / `macos` / `android` / `ios`；
- **脚本**：`check_perf_budget.py`（性能护栏）、`measure_size.py`（体积）、
  `smoke_windows.py`（Windows 冒烟）。

## 11. 存储布局

```text
<app support>/engine/          # EngineConfig::data_directory
├── catalogs.json              目录缓存
├── sessions.json              会话（令牌 / 设备号 / Cookie），按 source_id 命名空间
├── settings.json              资源设置
├── downloads/index.json       下载任务索引
├── covers/<xx>/<hash>         封面缓存
└── plugins/                   插件仓库
```

## 12. 已知限制

| 限制 | 影响 | 出处 |
| --- | --- | --- |
| 内存基线未做 | 无法发现内存回归 | `PERFORMANCE.md` §5 |
| 红果推荐接口返回空响应 | 推荐流无法在线验证 | `PROGRESS.md` 环境事实 |
| 黄果 AI / 视频站点超时 | 只有离线对拍 | 同上 |
| 剧果详情 404 | Cookie 透传只能离线验证 | 同上 |
| 编译源与插件源并存 | 双轨期维护成本 | `PLUGIN-BOUNDARY.md` |
| 站源诊断不可用 | 源健康 / 扫描入口隐藏 | 暂缓项 |
