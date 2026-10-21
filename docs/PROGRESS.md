# Rust 引擎重写进度

## 状态总览

| 阶段 | 状态 |
| --- | --- |
| POC-1 rquickjs on iOS | ✅ 通过 |
| POC-2 FRB 四端 | ✅ 通过（Windows 待 CI 补验） |
| POC-3 TLS 指纹 / CF | ✅ 通过（wreq 可过 CF） |
| 契约层 | ✅ `guo-source-api`：模型、错误、请求/响应、`SourcePlugin` trait、MD5 原语 |
| 声明式规则引擎 | ✅ `guo-rule-engine`：HTML / JSON / 内嵌 JSON 三类取数，加载期校验 |
| HTTP 传输层 | ✅ `guo-host`：reqwest + 流式截断，live 请求验证 |
| 代码插件层 | ✅ 猫果签名源；✅ WASM 组件宿主（真实组件端到端） |
| 站源迁移 | 🔄 16/20（红果主源、伍果、花果、饭果、观果、星果、河果、猫果、帝果、发果、牛果、剧果、芽果、黄果三源） |
| 取流（resolve） | ✅ 引擎接管，含 HLS 解析与回退 |
| 下载引擎 | ✅ 断点续传 + HLS 分片 + AES-128 解密 |
| 目录缓存 | ✅ 版本化落盘 + TTL + 分页游标合并 |
| 插件仓库 / 安装器 | ✅ `guo-plugin-host`：清单、zip 防护、SHA-256、Ed25519、TOFU、原子安装 |
| Flutter 接入 | ✅ 装饰器架构 + 真实调度；插件 API 已生成 Dart 绑定 |
| 对拍验收 | ✅ Go 夹具 + Dart 模型跨层对拍；✅ X-Gorgon 签名 Go↔Rust 对拍 |
| **P0 基线** | ✅ 2026-10-19：工作区 + CI + 构建验证 + 插件运行时探针（见第十二轮） |
| **P1 地基** | ✅ 2026-10-20：9 crate 工作区、插件宿主、红果主源、真实组件链路（见第十三轮） |
| **插件生态闭环** | ✅ 2026-10-20：仓库客户端 + 官方规则包 + 插件管理 UI（见第十四轮） |
| **D4 主源能力面** | ✅ 2026-10-20：榜单 / 推荐 / 联想 / 弹幕 / 系列剧（见第十五轮） |
| **P2 站源迁移** | 🔄 16/20（芽果；剩皮果 / 黄豆 / 野果） |
| **Core-0 切轨** | ✅ 2026-10-21：源身份统一 `dsd`、源列表引擎驱动、删除路由开关与 Go 构建链（第二十一轮）；D4 能力接管 + 诊断页（第二十二轮） |
| **Core-1 运行时内核** | ✅ 2026-10-21：`Engine` 单例、磁盘会话、类型化错误、取消、进度流、诊断（见第二十一轮） |
| **Core-2 播放与下载** | ✅ 2026-10-21：播放计划、弹幕、下载索引、离线播放（二十三）；暂停/续传（二十四）；旧索引迁移（二十五）；批量控制、封面缓存、重启列表（二十六） |
| **Core-3 Wasm 源运行时** | 🔄 2026-10-21：WIT v2、响应头透传、猫果插件打样（二十七）；其余 6 源与预装待完成 |

## 第二十七轮：Core-3 打样 —— WIT v2 + 猫果插件（2026-10-21）

目标：验证「带签名的代码源能否完全跑在 Wasm 沙箱里」（PLAN.md Core-3 第一步）。

### WIT v2

| 记录 | 新增字段 |
| --- | --- |
| `media` | `cookies` / `origin` —— CDN 签名源把播放凭证带回宿主 |
| `response` | `headers: list<tuple<string, string>>` —— 全量响应头（键小写，多值换行拼接） |

`content-type` / `etag` 两个快捷字段保留，已发布的插件不会因此失效。

### 宿主

- `fetch` 把 `FetchResponse.headers` 全量转成 WIT 头；传输层的白名单已包含
  `set-cookie`，插件因此能拿到 CDN 下发的 Cookie。
- `media_from_wit` 透传 `cookies` / `origin`。

### 修掉的两个宿主缺陷

1. **源标识错乱**。`drama_from_wit` 把 WIT 的 `drama.source_id`（站点内 id）
   当成宿主 `Drama.source`（源名），且 `id` 没加源前缀。所有插件源的
   `source` 会变成站点 id、`id` 变成裸 id，UI 的源分组与旧数据主键全会失效。
   改为 `drama_from_wit_for(drama, source)`，由调用方用清单里的源名填充。
2. **`Unsupported` 被映射成 `Rule`**。插件声明「不支持联想」会在 UI 上显示成
   「解析失败，请重试」。改为映射到 `SourceError::Unsupported`；
   `Blocked` 也改成带冷却时间的 `blocked_for`，而不是解析错误。

### 猫果插件打样

新增 `rust/examples/plugins/maoguo`（独立 workspace，`cargo component` 风格）：

| 项 | 说明 |
| --- | --- |
| 签名 | 三个签名串（目录 / 详情 / 搜索）与编译版逐字一致，由单元测试锁定 |
| crypto | MD5 与 Base64 自带（WIT 不暴露 crypto，ADR-12 约定由插件负责） |
| `qm-params` | JSON → Base64 → 字符映射，与编译版同表 |
| 传输 | 只走 `host::fetch`，域名白名单由清单约束 |
| 详情解析 | `play_list` + `sort` 集号，id 形如 `{source_id}:{number}`，与编译版一致 |
| 产物 | `guo_plugin_maoguo.component.wasm`，168 KB |

导入集合经 `wasm-tools component wit` 确认只剩 `guo:source/types` 与
`guo:source/host`，没有 `wasi:*`。

### 验证

| 项目 | 结果 |
| --- | --- |
| `cargo fmt --all --check` | 通过 |
| `cargo clippy --workspace --all-targets -- -D warnings` | 通过 |
| `cargo test --workspace` | 480 通过（新增 9 项：插件 7 + 宿主 ABI 3，含 1 项替换） |
| `dart analyze lib test integration_test` | 错误 0 |
| `flutter test --exclude-tags engine` | 308 通过 / 1 跳过 |

插件侧 7 项单测（MD5 向量、Base64、三个签名、字符映射、URL 编码、分页 URL）
+ 宿主侧 6 项集成测试（描述符、目录、详情、取流、空关键词、白名单）。

### Core-3 剩余

- 芽果 / 剧果 / 牛果 / 黄果三源的插件化（猫果已打样）。
- 官方插件预装：随包资源安装到插件仓库。
- 插件工具链：打包、校验、签名、仓库索引生成。
- `cursor` 用于分页 / 推荐（当前 `query.cursor` 存在但未使用）。
- 首屏 P95 基线（Pulley vs 编译源）。

## 第二十六轮：Core-2 收口 —— 批量控制、封面缓存、重启列表（2026-10-21）

目标：补完 Core-2 剩余三项，让下载链路不再依赖 Go 的队列语义。

### 批量控制

新增 `control_download_batch(command, ids, expectedVersions)`：

| 语义 | 说明 |
| --- | --- |
| 逐任务执行 | 单个失败不中断其余，失败原因逐条返回 |
| 版本门控 | `expectedVersions` 与任务 `revision` 不一致时跳过，用于「合并后清理原分集」 |
| 结果 | `completed` + `failures`，Dart 侧直接映射为 `DownloadBatchResult` |

Dart 侧按「本进程登记过的 id」分流：引擎任务走引擎，其余（旧 Go 记录）交给下层，
两边结果合并后返回。

### 封面缓存

新增 `guo-engine-core::cover`：

- 按 URL 的 SHA-256 命名，`<data>/covers/<前两位>/<哈希>`，两级目录避免单目录膨胀；
- 临时文件 + rename，中途被杀不会留下半张图被当成有效缓存；
- 单张上限 8 MiB，空内容与 HTTP 错误都明确报错；
- `force` 绕过缓存（对应 UI 的重试），`clear` 清空缓存。

不做图片解码 / 转码（Dart 侧已有 `CoverDecoder` 处理 HEIC），也不做容量淘汰。

### 修掉的缺陷：重启后下载列表消失

`downloads()` 以前依赖进程内 `_downloads` 映射来补 `Drama` / `Episode`。
重启后映射为空，引擎索引里的任务全部被 `continue` 跳过——**任务还在磁盘上，
但列表里看不见了**。

修法：给 `Job` 增加 `drama_title` / `episode_index` / `cover_url`，
索引落盘时一并保存；`downloads()` 在没有内存上下文时从快照重建。

### 预加载

`preload` 改为引擎内提前 `resolve`。失败返回 `null`——预加载是优化，
不该把错误抛给正在浏览的用户。

### 验证

| 项目 | 结果 |
| --- | --- |
| `cargo fmt --all --check` | 通过 |
| `cargo clippy --workspace --all-targets -- -D warnings` | 通过 |
| `cargo test --workspace` | 471 通过（新增 7 项封面缓存） |
| `dart analyze lib test integration_test` | 0 error / 0 warning |
| `flutter test --exclude-tags engine` | 308 通过 / 1 跳过 |
| `flutter test --tags engine` | 57 通过（新增 `engine_cover_test.dart` 3 项） |

### Core-2 状态：已完成

首发功能矩阵里的下载、离线播放、弹幕、封面现在都由引擎承担。
仍在 Go 侧的只剩：下载目录迁移（暂缓）、站源诊断（暂缓）、资源设置（暂缓）、LAN（Core-4 删除）。

## 第二十五轮：Core-2 旧下载索引只读迁移（2026-10-21）

目标：让用户切到引擎后，**已经下载好的剧还能播**（PLAN.md 完成定义第 6 条）。

### 做法

新增 `guo-engine-core::migrate`，只读旧版 `index.json`：

| 规则 | 说明 |
| --- | --- |
| 只读 | 不修改、不删除旧索引与文件；迁移失败用户仍可回退旧版本 |
| 只迁移已完成 | `state == "completed"` 且未归档、有文件名、文件确实存在 |
| 目录布局 | 与旧版一致：`<root>/<folder 或 jobId>/<file>` |
| 幂等 | 任务表按 id 去重，重复导入不产生重复任务 |
| 损坏不拦启动 | 索引缺失 / 超过 32 MiB / JSON 损坏 → `found: false`，不抛错 |

跳过的原因会分类统计（未完成 / 已归档 / 无媒体文件 / 文件不存在），
经 FRB `import_legacy_downloads` 返回给 Dart，供诊断页展示。

### 启动接线

`EngineBackedRepository.initialize` 先初始化下层，再用下层报告的下载目录
调用导入；失败只 `debugPrint`，不阻断启动。结果保留在
`legacyMigration` 上供诊断。

### 验证

| 用例 | 断言 |
| --- | --- |
| `imports_completed_records_with_existing_files` | 已完成 + 文件存在 → 登记为 completed |
| `skips_unfinished_archived_and_missing_files` | 四类跳过原因都被正确归类 |
| `missing_index_is_not_an_error` | 无索引不报错 |
| `corrupt_index_is_not_an_error` | 损坏不报错 |
| `migration_is_idempotent` | 两次导入仍只有一条任务 |
| `uses_folder_layout_when_recorded` | `folder` 字段生效 |

| 项目 | 结果 |
| --- | --- |
| `cargo fmt --all --check` | 通过 |
| `cargo clippy --workspace --all-targets -- -D warnings` | 通过 |
| `cargo test --workspace` | 464 通过（新增 6 项） |
| `dart analyze lib test integration_test` | 0 error / 0 warning |
| `flutter test --exclude-tags engine` | 306 通过 / 1 跳过 |

### 仍未完成（Core-2 剩余）

- 批量下载控制（`controlDownloadBatch`）与「校验后清理」仍走 Go。
- 封面缓存、预加载仍走 Go。

## 第二十四轮：Core-2 下载控制与暂停续传（2026-10-21）

目标：让「暂停」真正停下来，而不是只改一个状态字段。

### 修掉的缺陷

原来 `Scheduler::run` 在开始时把状态改成 `running` 之后就不再检查，
`control("pause")` 只是把状态标记成 `paused`，下载线程照样把整集下完。
表现为「点了暂停，进度条还在涨」。

### 改动

| 层 | 改动 |
| --- | --- |
| `download.rs` | 新增 `DownloadOutcome::Paused`；`download_hls_with` / `download_file_with` 接受 `should_continue` 回调，在分片边界与请求前询问 |
| `scheduler.rs` | `run` 传入「当前任务是否非 paused」的判定；收到 `Paused` 时保留 `.part` 与元数据，状态回到 `paused` |
| 兼容 | 原 `download_hls` / `download_file` 签名不变，内部转发到 `_with` 版本并恒返回 `true` |
| FRB | `run_download` 把 `Paused` 与 `Restart` 一并映射为 0 字节，状态由索引与进度流承载 |

### 语义

- **暂停**：在下一个分片前停下；已写入的分片与 `completed_segments` 保留。
- **恢复**：`resume` 把状态改回 `queued`，再次 `run` 时从记录的分片继续，
  不会重下已完成部分。
- **重启**：`running` 视为中断并重新排队；`paused` 原样保留，不会被误当成中断。

### 验证

新增 4 项回归：

| 用例 | 断言 |
| --- | --- |
| `pause_stops_before_next_segment` | 暂停判定在分片边界生效 |
| `paused_job_survives_restart_as_paused` | 暂停状态跨重启保留 |
| `hls_stops_at_segment_boundary_when_paused` | 暂停后只请求了 1 个分片 |
| `hls_resumes_from_recorded_segment` | 续传只请求剩余分片，总字节数正确 |

| 项目 | 结果 |
| --- | --- |
| `cargo fmt --all --check` | 通过 |
| `cargo clippy --workspace --all-targets -- -D warnings` | 通过 |
| `cargo test --workspace` | 458 通过 |
| `dart analyze lib test integration_test` | 0 error / 0 warning |
| `flutter test --exclude-tags engine` | 305 通过 / 1 跳过 |

### 仍未完成（Core-2 剩余）

- 批量下载控制（`controlDownloadBatch`）仍走 Go：引擎侧只有逐任务控制，
  批量语义与「校验后清理」还没迁。
- 封面缓存、预加载、Go 旧索引只读迁移。

## 第二十三轮：Core-2 起步 —— 播放计划字段 + 下载索引 + 离线播放（2026-10-21）

目标：按修订后的 `docs/PLAN.md` §9 开工，先打通「播放计划 → 下载 → 离线播放」的最小闭环。

### 播放计划补字段

| 字段 | 之前 | 现在 |
| --- | --- | --- |
| `Media.cookies` | 字段存在，但剧果之外无人填；Dart 侧**完全丢弃** | 引擎 `MediaResult` 透传，Dart 写入 `PlaybackPlan.headers['Cookie']` |
| `Media.origin` | 不存在 | 新增字段；剧果填充，Dart 写入 `headers['Origin']` |
| `PlaybackPlan.source` / `sourceId` | 不存在 | 新增；弹幕、下载、离线播放靠它定位，不再从 URL 反推 |
| `PlaybackPlan.danmakuId` | 只有 Go 会填 | 引擎 `resolve` 用分集 id 填充 |

> 剧果这类 CDN 签名源的 Cookie 以前到不了播放器，Core-2 验收项「签名 Cookie
> 能到达播放器」的前提条件现在成立。

### 弹幕接入

- 引擎 `fetchDanmaku` 按分集返回原始条目；Dart 侧补 60 秒分页窗口
  （`nextMs = min(startMs + 60s, durationMs)`）并过滤越界条目。
- `DanmakuController.supported` 去掉 `plan.session` 门槛：那是 Go 播放会话的
  产物，引擎取流不产出，保留会让弹幕永远不可用。
- `capabilities.danmaku` 打开。

### 下载索引落盘

`Scheduler` 从纯内存改为可选落盘：

| 行为 | 语义 |
| --- | --- |
| 写盘 | 每次 `enqueue` / `update` / `delete` 都原子写 `<data>/downloads/index.json`（临时文件 + rename） |
| 恢复 | `Scheduler::open` 启动时读回；`running` 视为中断，回到 `queued` 并写入原因 |
| 损坏 | 文件缺失 / 损坏 / 版本不符时静默返回空表，不拦启动 |
| 纯内存 | `index_path` 为空时行为不变（测试与校验工具用） |

### 离线播放

新增 `local_playback(drama_id, episode_id)`：把已完成任务映射为本地路径。
Dart 侧 `EngineBackedRepository.localPlayback` 先查引擎索引，未下载完成时
回退下层旧记录。`downloads()` 也改为优先读引擎索引——引擎有任何任务时
不再混入下层队列，避免两套队列同时出现。

### 验证

| 项目 | 结果 |
| --- | --- |
| `cargo fmt --all --check` | 通过 |
| `cargo clippy --workspace --all-targets -- -D warnings` | 通过 |
| `cargo test --workspace` | 454 通过（新增 5 项：索引落盘 / 恢复 / 删除 / 损坏 / 纯内存） |
| `dart analyze lib test integration_test` | 0 error / 0 warning |
| `flutter test --exclude-tags engine` | 305 通过 / 1 跳过 / 0 失败 |
| `flutter test --tags engine` | 54 通过（新增 `engine_playback_plan_test.dart` 3 项） |

### 环境事实

- 红果个别剧集的播放页缺少 `video_player_info`（站点侧），在线用例对
  `parseChanged` 做跳过处理。
- 剧果详情接口当前返回 HTTP 404（`api.huangju.net/dramas/...`），Cookie 透传
  只能离线验证。
- 猫果取流稳定，作为播放计划字段的在线验证源。

### 仍未完成（Core-2 剩余）

- 下载控制的主路径仍在 Go（`controlDownloadBatch` / `enqueueDownloads` 的
  队列语义）；引擎侧只有单任务控制。
- 断点续传已由 `download_hls` 支持，但「暂停后恢复」的调度语义还没接线。
- 封面缓存、预加载、Go 旧索引只读迁移未开始。

## 第二十二轮：Core-0 收口 —— D4 能力接管 + 站点结构修复（2026-10-21）

目标：把 Core-0 的剩余项做完——引擎已实现的 D4 能力不再绕 Go，
未支持能力对用户可见。

### 引擎接管的能力

| 能力 | 之前 | 现在 |
| --- | --- | --- |
| 榜单看板 / 榜单 | 委托 Go | `rankingBoards` 按能力位向每个源询问；`rankings` 用 `RankingBoard.sourceForID` 反查源后交给引擎 |
| 推荐流 | 委托 Go | 引擎主源直出；Dart 侧按 `genre` 维护 `(offset, sessionId)` 游标并累积条目 |
| 搜索联想 | 委托 Go | 引擎主源直出；非主源返回空而不是抛错 |
| 元数据补全 | 委托 Go（含已停用的黄豆分支） | 复用引擎详情结果补红果 `onlineDate`，不再单发一次请求 |

能力矩阵成为唯一真相：`supportsDownloads` / `supportsSourceManagement` 都从
`RepositoryCapabilities` 派生，不再与下层实现各说一套。

### 修掉的两个真实站点结构变更

这两处都是**引擎解析落后于站点**，属于实现缺陷而不是环境问题：

1. **榜单行数据位置变了**。原来从 `_ROUTER_DATA.fnArgs` 取，2026-10 起站点改成
   `<script data-fn-name="mergeLoaderData" data-fn-args="[route, [{key, routerDataFnName,
   routerDataFnArgs}]]">`，真正的 JSON 在 `routerDataFnArgs[0]` 里且被 HTML 实体转义。
   新增 `merge_loader_content()`，三种承载形态按顺序回落。
2. **联想外层键名变了**。`data` / `suggest_words` → `suggest_list`。行结构
   （`name` + `word_type`）未变，因此只补键名，旧键继续可用。

两个夹具都取自真实响应，放在
`rust/bridge/tests/fixtures/hongguo_ranking.html` 与
`rust/crates/source-hongguo/tests/fixtures/suggestions.json`。

### 诊断页

新增 `/settings/diagnostics`（设置页入口「引擎诊断」），展示：

- 运行状态：版本、数据/插件目录、运行时长、请求计数、会话数、缓存键数、任务计数；
- **能力矩阵**：每一项都显式写出「支持 / 当前版本不支持」，包括下载、弹幕、
  站源诊断、高级网络设置、LAN —— 用户能看懂入口为什么不见了；
- 站源能力：引擎清单里每个源的能力位；
- 插件加载结果（含失败原因）与最近 20 条错误。

入口按能力矩阵隐藏的三处也补齐了：LAN（设置 / 发现页）、资源设置（设置页）、
诊断页本身始终可达。

### 未接入项与原因

| 项 | 原因 |
| --- | --- |
| 弹幕 | 依赖 `PlaybackPlan.session` / `danmakuId`，引擎 `resolve` 不产出这两个字段；属于 Core-2 的播放会话 |
| 下载 / 离线播放 / 媒体处理 | 需要引擎侧下载索引与断点续传，Core-2 |
| 封面缓存 | 需要引擎侧下载与图片缓存，Core-2 |
| 站源诊断 / 健康检查 | PLAN.md §5 暂缓 |
| 高级网络设置 | 首发仅直连 |

### 验证

| 项目 | 结果 |
| --- | --- |
| `cargo fmt --all --check` | 通过 |
| `cargo clippy --workspace --all-targets -- -D warnings` | 通过 |
| `cargo test --workspace` | 449 通过（新增 12 项：榜单夹具 6、联想夹具 6） |
| `dart analyze lib test integration_test` | 0 error / 0 warning |
| `flutter test --exclude-tags engine` | 305 通过 / 1 跳过 / 0 失败（新增 12 项：诊断页 5、能力接管 7） |
| `flutter test --tags engine` | 51 通过（含新增 `engine_capabilities_live_test.dart` 7 项） |

### 环境事实

推荐流走 App 接口（`api5-normal-sinfonlineb.fqnovel.com`）。该域名在当前网络下
返回 HTTP 200 但**响应体为空**，因此在线用例把推荐失败当作可分类的
`parseChanged` / `network` 处理，而不是当成回归。榜单与联想走网页接口，
本机实测可用。

## 第二十一轮：Core-0 切轨 + Core-1 运行时内核（2026-10-21）

目标：停止双栈，把「状态正确」落到代码里（`docs/PLAN.md` 的 Core-0 / Core-1）。

### Core-0 · 切轨

| 事项 | 结果 |
| --- | --- |
| 源身份统一 | `rules/diguo.json` → `rules/dsd.json`，`id` 改为 `dsd`；夹具与测试同步改名（`dsd_fixtures.rs` / `dsd_catalog.html`）；`rust/dist` 已用 `pack_rules` 重新打包 |
| 源列表 | `SourceSite` 改为**引擎清单为唯一来源**：`reportFromEngine` 直接替换列表，不再「内置 + 追加」；未同步时才用编译期表兜底 |
| 版本开关 | `ALL_SOURCES` 仍决定编译进哪些源；单源构建下 `knownValues` 只有红果 |
| Go-only 源 | 黄豆 / 野果 / 皮果不在引擎注册表里，因此不再出现在 UI；`isKnown` 仍认这些旧 id，历史与档案数据不会因此报格式错误 |
| 路由开关 | 删除 `ENGINE_ROUTE` / `EngineRouting` / `EngineRoute` 与 `test/engine_routing_test.dart` |
| LAN 入口 | 设置页与发现页的入口改由 `RepositoryCapabilities.lan` 门控（当前为 `false`，入口隐藏） |
| Go 构建链 | 删除 CI 的 `go` job；`build_android.py` / `build_windows.py` 不再调 `build_native.py`；`package_release.py` 不再要求 `libduanju_core.so` / `duanju_core.dll` |

### Core-1 · 运行时内核

新增 crate `guo-engine-core`（`rust/crates/engine/`）：

| 模块 | 内容 |
| --- | --- |
| `engine.rs` | 进程级单例：配置、注册表、会话存储、目录缓存、下载调度、事件总线、取消表、诊断计数；`rebuild_registry` 只换注册表，会话与任务保留 |
| `store.rs` | `DiskSourceStore`（`sessions.json`，临时文件 + rename）；`NamespacedStore` 按 `source_id` 加前缀，站源互相看不到 |
| `error.rs` | `EngineError` / `EngineErrorKind`（11 类），带 `source_id` / `request_id` / `retryable` / `http_status` / `retry_at_ms`；站源错误按可重试性原样映射 |
| `cancel.rs` | `CancellationRegistry`：同会话新请求作废旧请求，显式取消与票据回收 |
| `events.rs` | `EventBus`（broadcast + latest）：下载进度推送，迟到订阅者先拿到最新快照 |

FRB 边界：

- 所有函数从 `Result<_, String>` 改为 `Result<_, EngineFailure>`；`EngineFailure` 是扁平 DTO（外部 crate 的类型会被 FRB 当成不透明句柄，Dart 读不到字段）
- 目录 / 详情 / 搜索 / 分类 / 取流都带 `request_id`；目录额外带 `session`，切页时旧结果返回 `Cancelled`
- 新增：`init_engine_with_directory`、`engine_diagnostics`、`cancel_request`、`clear_source_session`、`reload_sources`、`control_downloads`、`download_progress_stream`

Dart 侧：

- 新增 `lib/data/engine_failure.dart`（`EngineException` / `EngineFailureKind`）与 `lib/data/repository_capabilities.dart`
- `EngineRepository` 全面切到新 API，所有 FRB 失败统一转 `EngineException`
- `EngineBackedRepository` 去掉路由参数，失败不再静默回退到 Go
- 插件安装 / 卸载 / 启停后调用 `reload_sources` 再同步源清单

### 芽果令牌落盘

原来令牌只存在源实例的 `Mutex` 里，进程重启即丢。现在按三级回落：
内存 → `SourceStore`（`token` 键，存值与获取时间）→ 登录。401 时同时清内存与磁盘。

### 验证

| 项目 | 结果 |
| --- | --- |
| `cargo fmt --all --check` | 通过 |
| `cargo clippy --workspace --all-targets -- -D warnings` | 通过 |
| `cargo test --workspace` | 431 通过（新增 28 项：引擎单例 22、Core-1 回归 6） |
| `dart analyze lib test integration_test` | 0 error / 0 warning |
| `flutter test --exclude-tags engine` | 278 通过 / 1 跳过 / 0 失败 |
| `flutter test --tags engine`（新增 `engine_singleton_test.dart`） | 5 通过（真实请求芽果，验证会话落盘与诊断） |
| `python3 -m unittest discover -s scripts` | 9 通过 |

### 已知缺口

- 下载、媒体处理、LAN 协议仍在 Go 侧（`NativeRepository`），Core-2 才迁完
- `EngineBackedRepository.capabilities` 目前如实报告 `sourceManagement` / `resourceSettings` / `lan` 为 `false`
- 声明式插件包已按 `dsd` 重新打包，但尚未做预装分发（Core-3）

## 第二十轮：P2 第五个站源 —— 芽果（2026-10-21）

目标：迁移一个「设备登录 + 顶层分组 + 榜单分类」的接口源，同时修掉 Go 侧
分类读取的失效路径。

### 链路特点

| 环节 | 事实 |
| --- | --- |
| 会话 | `POST /user/v1/account/login`，请求体 `{"device": <固定设备号>}`，令牌在 `data.token`；业务接口用 `authorization` 头，6 小时有效，失效返回 401 |
| 分类 | `/cloud/v2/theater/classes` 的**顶层分组**：剧场(1) / 新剧(3) / 排行榜(9) / 热播剧(2) / 星选好剧(7) |
| 榜单 | 分类 `9` 走 `/cloud/v1/first_level_ranking/detail?id=1`，不分页 |
| 目录 | `/cloud/v2/theater/home_page`，`theater_class_id` 接分组 id，每页 24 条 |
| 详情 | `/v2/theater_parent/detail`，分集直接给 `son_video_url`（MP4），取流只做透传 |
| 搜索 | `POST /v3/search`，请求体 `{"text": ...}`，结果在 `data.theater.search_data` |

### 修掉的 Go 缺陷

Go 的 `fetchYaguoCategories` 把响应 `data` 当数组遍历
（`duanjuFindList(response, "data")`），而真实响应是 `data.list`。该函数从未成功过，
分类一直退回写死的「剧场 / 榜单」两项。Rust 按真实结构读取顶层分组，
得到完整五项，且分类 `9` 自动走榜单接口。

### 并发登录限流

同一设备号并发登录时服务端返回 `2010007`（system busy）。登录阶段最多重试 3 次、
间隔 250ms，并把服务端 `msg` 带进错误信息。在线用例并发执行时由 2 项失败转为全部通过。

### 交付

| 文件 | 内容 |
| --- | --- |
| `rust/crates/source-yaguo/` | 目录 / 榜单分类 / 详情 / 搜索 / 分类 / 直链取流 |
| `rust/bridge/tests/yaguo_fixtures.rs` | 11 项：登录先行、令牌复用、401 重登、繁忙重试、分类分组、榜单分类、详情、搜索、空搜索、直链取流、能力位 |
| `rust/bridge/tests/yaguo_live.rs` | 3 项在线验证（`#[ignore]`） |
| `rust/bridge/tests/fixtures/yaguo_{classes,catalog,ranking,detail,search}.json` | 2026-10-21 真实响应裁剪 |

### 验证

| 项 | 结果 |
| --- | --- |
| `cargo test --workspace` | ✅ 407 项通过（本轮新增 17），9 项在线用例默认忽略 |
| `cargo fmt --check` / `clippy -D warnings` | ✅ 干净 |
| 在线目录 / 详情 / 取流 / 分类 / 搜索 | ✅ 全部通过（取流返回真实 MP4 直链） |
| Dart 引擎站源清单 | ✅ 新增 `yaguo`，能力位 `catalog/detail/search/categories/resolve` |
| `flutter test --exclude-tags engine` | ✅ 289 通过 / 1 跳过（native-assets 钩子成功编入新 crate） |
| `dart format --set-exit-if-changed` | ✅ 185 文件无改动 |

### 未做

- 皮果 / 黄豆 / 野果仍待迁移；
- 芽果的 VIP 标记未解析（详情里有 `vip` / `pay_type`，Go 版未使用）；
- 分类以接口返回为准：Go 静态表只有「剧场 / 榜单」，Rust 返回站点完整五个分组。

## 第十九轮：黄果三源接线 + CI 补回 Dart 校验（2026-10-21）

本轮不是新增站源，而是把上一轮遗留的**半成品接线**修好，并把 CI 的
Dart 校验补回来。

### 黄果三源接线

`source-huangguo` 之前只有 `Cargo.toml` 与 `src/`，`bridge` 没依赖它、
`builtin_registry()` 也没注册——它只是因为 workspace 的 `members = ["crates/*"]`
被 `cargo check` 顺带编译，站源实际不可用。

修的三处：

| 文件 | 改动 |
| --- | --- |
| `bridge/Cargo.toml` | 增加 `guo-source-huangguo` 依赖 |
| `bridge/src/sources/builtin.rs` | 注册 `LegacySource` / `HuangguoAiSource` / `HuangguoVideoSource` |
| `crates/source-huangguo/src/lib.rs` | 补 `mod legacy;` 并导出三源 |

### 修掉的三个真实缺陷

1. **`legacy.rs` 是孤儿模块**（719 行）：`lib.rs` 只声明了 `mod ai; mod video;`，
   整个文件不参与编译，里面的 7 个测试从未运行。补上 `mod legacy;` 后
   立刻暴露一个失败用例（见下条）。
2. **协议解析器不认无引号键**：`script_value` 只处理 `"interfaceKey":"..."`，
   而前端是压缩后的 JS，`{interfaceKey:"..."}` 这种写法更常见。且原实现在
   循环里用 `?`，遇到第一个不匹配的位置就整体返回 `None` 而不是继续搜索。
   重写为同时接受带引号/不带引号两种键形态，并保证不匹配时继续扫描。
3. **能力位与实现不符**：`ai.rs` 与 `legacy.rs` 都声明了 `Capability::Categories`，
   但都没实现 `categories()`——trait 默认返回空列表。后果是 UI 显示分类筛选
   入口、点开却是空的。两个源都补上实现（`ai` 用固定分类表，`legacy` 复用
   已有的 `tabs()`）。

### 验证状态

| 站源 | id | 在线验证 |
| --- | --- | --- |
| 黄果旧版 | `cloudfront` | ✅ 官网前端与 API 可达，具备在线验证条件 |
| 黄果 AI | `huangguoai` | ⬜ 站点与六个镜像全部超时，仅离线对拍 |
| 黄果视频 | `huangguo-video` | ⬜ 同上 |

### CI：补回 Dart 校验

`checks` job 自 2026-09-30 的 `e2da550`（「临时仅跑 windows」）起一直是 `if: false`，
`flutter test` 与 `dart analyze` 三周多没有自动守护。本轮拆成三个独立 job：

| job | 内容 |
| --- | --- |
| `flutter` | format（`--set-exit-if-changed`）/ analyze / test / test（ALL_SOURCES） |
| `go` | `go test -race` 两轮 |
| `scripts` | `scripts/test_*.py` |
| `engine-online` | 真实站点用例，`continue-on-error` |

两个细节：

- 原 `dart format` 不带 `--set-exit-if-changed`，会就地改写文件并返回 0，
  格式漂移被静默吞掉；已加。
- `test/engine_*.dart` 里 9 个文件请求真实站点，不能进必过路径。
  加了 `engine` tag（`dart_test.yaml` + 文件头 `@Tags(['engine'])`），
  CI 用 `--exclude-tags engine` 跑离线套件，在线用例单独由非阻断 job 跑。

`flutter` job 必须先跑 `python scripts/prepare_engine.py`：FRB 生成代码把
`ioDirectory` 写死为 `rust/target/release/`，全新 checkout 里没有该目录。

### 验证

| 项 | 结果 |
| --- | --- |
| `cargo test --workspace` | ✅ 全绿（黄果 crate 20 项，原 12 项） |
| `cargo clippy --workspace --all-targets -D warnings` | ✅ 零告警 |
| `cargo fmt --all --check` | ✅ 干净 |
| 引擎站源清单 | ✅ 16 个（原 13，新增黄果三源） |
| `flutter test --exclude-tags engine` | ✅ 289 通过 / 1 跳过 |
| `dart analyze` | ✅ 0 error / 0 warning |
| `dart format --set-exit-if-changed` | ✅ 190 文件无改动 |


## 第十八轮：P2 第四个站源 —— 剧果（2026-10-21）

目标：迁移一个「接口干净但要会话与播放凭证」的站源，顺带补齐传输层
一直缺的一项能力。

### 链路的三个特点

| 环节 | 事实 |
| --- | --- |
| 会话 | 所有接口要访客令牌：`POST /auth/guest` 带 `deviceId`（UUID v4），返回 `token`；失效返回 401 |
| 主键 | 列表给 `id` 与 `slug`，**详情必须用 slug**（`/dramas/yanyu-2788`），数字 id 一律 404 |
| 取流 | `/play/{episodeId}` 返回 m3u8 地址，同时在响应头下发 `CloudFront-Policy` / `Signature` / `Key-Pair-Id` 三个 Cookie |

### 补的底层能力

`FetchResponse.headers` 原本只保留 `etag` / `last-modified` / `content-type` /
`content-length` 四个头，`Set-Cookie` 被直接丢掉，导致任何走 CDN 签名的站源
都无法播放。本轮：

1. `capture_headers` 增加 `set-cookie`，同名多值用换行拼进同一个键；
2. 契约层 `Media` 新增 `cookies` 字段（`#[serde(default)]`，不影响既有站源）；
3. 剧果取流把响应头里的 `name=value` 解析出来，写进 `Media.cookies`。

### 修掉的缺陷

- **401 重试判定用字符串匹配**，`format!("{error:?}").contains("401")` 这种写法
  在错误文案变化时静默失效。改用契约层已有的 `http_status()` 类型化判断。

### 交付

| 文件 | 内容 |
| --- | --- |
| `rust/crates/source-huangju/` | 目录 / 详情 / 搜索 / 取流 + 访客令牌复用 |
| `rust/bridge/tests/huangju_fixtures.rs` | 6 项：令牌先行、令牌复用、401 重登、slug 详情、签名 Cookie、能力位 |
| `rust/bridge/tests/huangju_live.rs` | 2 项在线验证（`#[ignore]`） |
| `rust/bridge/tests/fixtures/huangju_{list,detail,play}.json` | 2026-10-21 真实响应 |

### 验证

| 项 | 结果 |
| --- | --- |
| `cargo test --workspace` | ✅ 367 项（原 354，新增 13） |
| `cargo fmt --check` / `clippy -D warnings` | ✅ 干净 |
| 在线目录 / 详情 / 取流 | ✅ 目录 20 条、详情分集、取流返回 m3u8 + 签名 Cookie |
| Dart 引擎站源清单 | ✅ 13 个，剧果能力位 `catalog/detail/search/categories` |
| `flutter test` | ✅ 328 通过 / 0 失败 |

### 已知限制

- 列表里存在**已下架的条目**，详情返回 404。站源按接口语义如实报错，
  在线用例改为在前几条里挑可用的一条。是否要在列表阶段过滤掉这些条目，
  需要看主项目对「不可播条目」的处理约定，本轮不改。
- `video.huangju.net` 在本机网络不可达，因此在线验证止于「拿到签名地址」，
  没有拉分片。

---

## 第十七轮：P2 第三个站源 —— 牛果（2026-10-21）

目标：迁移第一个「不能用声明式规则表达」的站源，把代码源 crate 的
写法与测试套路固定下来。

### 为什么必须是代码源

牛果两处超出规则表达能力：

1. **响应体是 AES-ECB 密文**，不是明文 JSON。密钥取**实际发出的请求 URI
   前 16 字节**（路径 + 查询串，不含协议域名），只补零到 16 字节不补满块。
   参数顺序一变密钥就变，所以解密必须紧贴真正发出去的那个地址，不能用
   规则模板重拼一次——这是最易错的一点。
2. **分集里的 `url` 不是播放地址**，是内部分集 ID，要再经第三方解析服务
   （`/jx/qy.php`、`/jx/dj.php`）换取真实地址，主域名失败要回退备域名。

### 交付

| 文件 | 内容 |
| --- | --- |
| `rust/crates/source-niuguo/` | 新 crate：目录 / 详情 / 搜索 / 取流 + 解密与去填充 |
| `rust/bridge/tests/niuguo_fixtures.rs` | 5 项：真实密文解密、详情分集、解析服务回退顺序、空 ID 报错、能力位 |
| `rust/bridge/tests/niuguo_live.rs` | 2 项在线验证（`#[ignore]`） |
| `rust/bridge/tests/fixtures/niuguo_{list,detail}.b64` | 2026-10-21 的真实加密响应 |

设计要点：

- 解密与解析走同一个 `fetch_json`，密钥由 URL 现算，不存在「规则算一遍、
  解密用另一份」的分叉；
- `unpad` 严格校验填充字节全部等于填充长度，不只信长度；
- 解析服务按 `[主域名, 备域名] × [qy.php, dj.php]` 顺序尝试，把最后一个错误
  抛出去，而不是吞掉换一个笼统文案。

### 验证

| 项 | 结果 |
| --- | --- |
| `cargo test --workspace` | ✅ 354 项（原 344，新增 10） |
| `cargo fmt --check` / `clippy -D warnings` | ✅ 干净 |
| 在线目录与详情 | ✅ 解密成功，目录 12 条、详情 75 集 |
| 在线取流 | ⚠️ 第三方解析服务两个域名均连接超时（2026-10-21 实测），非本站源缺陷 |
| Dart 引擎站源清单 | ✅ 12 个，牛果能力位 `catalog/detail/search` |
| `flutter test` | ✅ 328 通过 / 0 失败 |

### 未做

- 取流的在线验收要等解析服务恢复；离线已用夹具验证回退顺序与地址透传；
- 牛果 VIP 标记未解析（接口只给 `vod_remarks`，没有可靠 VIP 字段）。

---

## 第十六轮：P2 第二个站源 —— 发果（2026-10-21）

目标：用一个真实站点把「声明式规则从取证到上线」的流程走完整，
并留下可复跑的在线验证手段。

### 为什么选发果

| 候选 | 结论 |
| --- | --- |
| 发果 | 标准 `stui-vodlist` 模板，`player_aaaa` 直链 m3u8，页面可访问 → 本轮做 |
| 皮果 | `ptt.red` 当前不可达，抓不到结构。凭猜测写规则违反「先取真实夹具再写规则」的既有教训 → 推迟 |
| 芽果 / 牛果 | 芽果要登录令牌、牛果要 AES 解密，属代码插件，不是声明式规则的适用范围 |
| 黄豆 / 剧果 / 野果 / 黄果三源 | 各自需要签名或专属客户端，留待后续 |

### 站点结构（实测）

```
目录   /xzyxvt/{slug}n.html?page={page}    卡片  div.stui-vodlist__box
详情   /xzyxvd/{id}.html                   分集  ul.stui-content__playlist li a
分集   /xzyxvp/{id}n{n}m{m}.html           取流  player_aaaa 变量的 url 字段
搜索   /xzyxvc/{keyword}-wdyswzqun1num.html
```

两个必须记住的坑：

1. **类名带随机后缀**。页面里 `stui-vodlist__box` 与 `k0btppvloj vqh3my5ckr …`
   这类随机串混在同一个 `class` 属性里，每页还不一样。规则只能依赖
   `stui-vodlist__*` / `stui-content__playlist` 这些稳定钩子；夹具保留了原始
   随机类名，测试因此能守住这条不变量。
2. **页码走查询串，且 slug 拼接方式特殊**。分类地址是
   `duanju` + `n` + `.html`（`/xzyxvt/duanjun.html`），不是 `duanju.html`。
   第 2 页是 `?page=2` 而不是 `/xzyxvt/duanju2n.html`（后者 302）。

### 交付

| 文件 | 内容 |
| --- | --- |
| `rust/rules/faguo.json` | 目录 / 详情 / 搜索 / 取流规则，11 个分类 |
| `rust/bridge/tests/faguo_fixtures.rs` | 7 项离线对拍：元数据、目录卡片、分类地址、分集、搜索编码、取流、详情模板 |
| `rust/bridge/tests/faguo_live.rs` | 2 项在线验证（`#[ignore]`）：真实目录 ≥10 条；详情 → 分集 → 取到 `.m3u8` |
| `rust/bridge/tests/fixtures/faguo_{catalog,detail,play}.html` | 真实响应裁剪：3 张卡片、完整分集、`player_aaaa` |

`builtin_registry_loads_every_shipped_rule` 的清单补上了此前漏掉的
`wangguo` / `diguo`，再加 `faguo`。

### 验证

| 项 | 结果 |
| --- | --- |
| `cargo test --workspace` | ✅ 344 项（原 337，新增 7） |
| `cargo fmt --check` / `clippy -D warnings` | ✅ 干净 |
| 在线验证 `--ignored` | ✅ 2 项：目录 ≥10 条、取到 `index.m3u8` |
| 官方规则仓库重打包 | ✅ 9 个包（新增 `guo.faguo`） |
| Dart 引擎站源清单 | ✅ 11 个，发果能力位 `catalog/detail/search/resolve/categories` |
| `flutter test` | ✅ 328 通过 / 0 失败 |

### 未做

- 皮果：站点不可达，没有真实结构就不写规则；
- 发果的 VIP 判定：页面没有稳定的 VIP 标记，暂时全部按免费处理；
- 发果分类清单只覆盖首页可见的 11 个主分类，二级分类未展开。

---

## 第十五轮：D4 收尾 + P2 首源（2026-10-20）

目标：补齐主源 D4 的差异化能力，并开始 P2 的站源迁移。

### 一个必须先纠正的事实

我之前说「红果 App 接口需要设备注册」——**这是错的**。查 `native/core` 后确认：
Go 版没有独立的设备注册请求，`newHongguoDeviceID()` 只在本地生成两个 19 位数字串
（`device_id` / `iid`）就直接使用。真正的缺口是「App 接口取数路径根本没接」，
不是缺一个注册步骤。

### D4 五项能力

| 能力 | 数据来源 | 实现 |
| --- | --- | --- |
| 榜单 | 网页 `/rank/<path>` | `rankings.rs`：四个看板、名次窗口校验、跨榜与跨页拒绝 |
| 推荐 | App `/reading/distribution/category/landpage/v/` | `capabilities.rs`：`offset` + `session_id` 游标，首屏 `client_req_type=3`、翻页 `2` |
| 联想 | 网页 `/incent_resource/suggestion` | 去重、词性白名单、上限 10 |
| 弹幕 | App `/novel/commentapi/comment/list/<vid>/v1/` | 60 秒分段、窗口过滤、按时间排序、上限 90 |
| 系列剧 | 复用搜索 | 标题季号识别（`第2季`/`第二季`/`Season 2`/`S2`），按主标题聚合 |

契约层新增 `RankingBoard` / `RankingPage` / `RecommendCursor` / `RecommendPage` /
`DanmakuPage` / `SeriesSeason` / `Suggestion`，`SourcePlugin` 增加五个带默认实现的
可选方法（默认返回 `Unsupported` 或空），因此**已有站源一行都不用改**。

设备身份改为**落盘持久化**：Go 版进程重启就换新 ID，会让服务端当成新设备、
游标全失效；这里存到 `SourceStore`，重启后仍可续用。

### P2 首源：帝果（声明式）

帝果是标准 HTML + CSS 结构，用声明式规则即可，无需代码插件：

```text
rules/diguo.json  →  index.php/vod/type/id/{category}/page/1.html
                     卡片：a.video-item / a.video-surface
                     详情：index.php/vod/detail/id/{id}.html
                     搜索：index.php/vod/search/page/1/wd/{keyword}.html
```

### 规则引擎补的两项能力（都是被帝果逼出来的）

1. **`idPattern`**：站点把 id 藏在路径里（`/vod/play/id/456/sid/1/nid/1.html`）。
   直接拿整段 URL 当主键，同一部剧在目录与详情会得到两个 id。
   抽取时**只在路径段里找数字**——域名（`dsd.com.se`）和查询串里的数字会先命中，
   拿它们当主键会让所有条目撞成同一个 id。
2. **逗号选择器加载期拒绝**：`"a@href, b@href"` 会被当成**一个**选择器，
   `@` 之后的部分全变成属性名（`"data-src, img@src"`），取到的永远是空串。
   这类静默空值极难查，现在加载期直接报错并提示「候选选择器请写成数组」。

### 验证

| 项 | 结果 |
| --- | --- |
| `cargo test --workspace` | ✅ **337 项**（本轮 +34） |
| `cargo fmt --check` / `clippy -D warnings` | ✅ 干净 |
| Dart 全量测试 | 280 通过 / 41 失败（基线 253 / 42，**净增 27、0 回归**） |
| `flutter analyze` | ✅ 0 error / 0 warning |
| `flutter build macos --debug` / `apk` | ✅ |
| 官方规则仓库 | 8 个包，端到端安装测试通过 |

### 未做

- P2 其余四源（黄豆 / 剧果 / 野果 / 黄果）：黄豆是 AES-CBC + gzip + SHA256 签名，
  属代码插件；剧果与野果需先确认页面结构；黄果有旧 API 兼容问题；
- 弹幕与推荐的真实站点验证：本机代理关闭后站点不可达，只做了结构级测试；
- 榜单与联想的真实请求同样未验证（同上）。

---

## 第十四轮：插件生态闭环（2026-10-20）

目标：把「插件宿主」从能加载组件，推进到**用户真的能装、能管、能卸**。

### 决策 A 落地（D7）

`bridge` 现在真正依赖 `guo-plugin-wasm`，`builtin_registry()` 会加载已安装插件。
这一步是决策 A 的实质：只声明依赖不建立调用链时，LTO 会把整个运行时裁掉，
体积测量与功能验证都会失真。

| 项 | 实测 |
| --- | --- |
| macOS dylib | 8,315,984 → 20,872,096 B（+11.97 MiB） |
| iOS staticlib | 15,112,384 → 26,225,976 B（+10.60 MiB） |
| Android arm64（debug 构建） | 16,330,952 → 44,996,304 B（debug 无 LTO，不代表发布体积） |

### 修掉的缺陷

| 缺陷 | 影响 | 修法 |
| --- | --- | --- |
| `PluginState` 用 `derive(Default)` | `enabled` 恒为 `false`，**新装插件默认停用**，装完不能用 | 手写 `Default`，补两条回归测试 |
| 插件目录状态存了两份 | `api::plugins` 与 `sources::builtin` 各一个 `OnceLock`，设置一处另一处看不见 | 收敛到 `sources::builtin` 一处 |
| `PluginManifest` 公钥错误丢上下文 | 只报「base64 解码失败」，用户不知道改哪个字段 | 包装成「仓库公钥」 |

### 仓库客户端（`runtime/repo_client.rs`）

| 能力 | 说明 |
| --- | --- |
| `fetch_manifest` / `fetch_index` | `repo.toml` → `index.json`，相对路径按仓库目录解析 |
| 验签顺序 | **先取签名并校验，再解析结构**——先解析后验签等于信任了未验证数据 |
| `download_package` | 返回前就校验大小与 SHA-256，调用方没有机会跳过 |
| `.sig` 两种形态 | 裸 64 字节与 base64 文本都接受（很多人用 `base64 > file`） |
| 错误可测 | 用假 `Transport` 驱动，12 项测试覆盖签名缺失/错误/顺序/哈希不符/尺寸不符 |

### 官方规则仓库

`cargo run -p guo-plugin-host --bin pack_rules -- dist/rules rules` 把 7 条随包规则
打成标准插件包，同时生成 `index.json` 与 `repo.toml`。产物不进版本管理
（改规则后忘记重新打包是常见事故）。

`tests/official_repo.rs` 用**同一套安装器**逐个安装生成物，并断言：

1. 索引声明的 `size` 与实际字节一致；
2. 每个包都能安装、默认启用、出现在已安装列表；
3. **包内规则与 `rust/rules/*.json` 逐字节相同**（防止改了规则没重新打包）。

### 插件管理 UI

| 文件 | 职责 |
| --- | --- |
| `lib/data/plugin_repository.dart` | 引擎插件的 Dart 入口（解析、安装、卸载、启停、回滚） |
| `lib/ui/features/plugins/controllers/plugins_controller.dart` | 状态与动作；版本比较、错误归一、站源同步 |
| `lib/ui/features/plugins/views/plugins_screen.dart` | 仓库地址输入、可安装列表、已安装列表（开关/卸载） |

站源页右上角新增入口（`/sources/plugins`）。插件管理单独成页而不是塞进站源页：
站源页看「当前能用什么」，插件页管「从哪装、装哪个版本」，两者失败域不同——
插件装坏了不该让站源列表也起不来。

`test/plugins_controller_test.dart` 12 项覆盖：版本比较（含 `1.9.0 < 1.10.0` 这类字符串比较陷阱）、
仓库不可用、安装失败、卸载后站源失效。

### 验证

| 项 | 结果 |
| --- | --- |
| `cargo test --workspace` | ✅ **303 项** |
| `cargo fmt --check` / `clippy -D warnings` | ✅ 干净 |
| Dart 全量测试 | 274 通过 / 41 失败（基线 253 / 42，**净增 21 项、0 回归**） |
| `flutter analyze` | ✅ 0 error / 0 warning |
| `flutter build macos --debug` | ✅ |
| `flutter build apk --debug` | ✅ |

### 未做

- 插件更新的批量检查与灰度（P2）；
- 卸载插件后的本地数据清理策略（当前只从列表消失，数据保留）；
- 官方仓库的真实发布（需要一个独立 Git 仓库与 CI 打包）。

---

## 第十三轮：P1 地基（2026-10-20）

目标：把「一个 crate 里堆所有东西」拆成可维护的边界，并让插件体系从纸面变成能跑的代码。

### 工作区拆分（`bridge` 只留桥接）

| crate | 职责 | 依赖方向 |
| --- | --- | --- |
| `guo-source-api` | 模型、错误、`FetchRequest/Response`、`SourcePlugin`、MD5 | 零 IO（async-trait / serde / serde_json） |
| `guo-media` | m3u8 解析、AES-128 分片解密 | 纯计算 |
| `guo-rule-engine` | 规则 schema、模板渲染、CSS / JSONPath 提取 | → source-api |
| `guo-host` | reqwest 传输层、QuickJS 沙箱 | → source-api |
| `guo-plugin-host` | 清单、zip 解包防护、仓库协议、Ed25519、安装落盘 | → source-api |
| `guo-plugin-wasm` | wasmtime + WIT 组件宿主、能力注入、资源上限 | → source-api |
| `guo-runtime` | 目录缓存、下载调度、规则源适配 | → host / media / rule-engine |
| `guo-source-maoguo` / `guo-source-hongguo` | 代码站源 | → source-api / media |
| `guo_engine`（`bridge/`） | FRB 边界与内置装配 | → 全部 |

依赖方向由 `crates/source-api/tests/dependency_direction.rs` 断言：清单里出现
`tokio` / `reqwest` / `wasmtime` / `rquickjs` / `scraper` / `cssparser` 即失败。

### 插件体系（从设计到可运行）

| 模块 | 内容 |
| --- | --- |
| `manifest` | `plugin.toml` 解析 + 加载期校验（id 正则、kind/entry/rules 互斥、路径穿越、网络白名单、脚本预算） |
| `package` | zip 解包：条目数 / 单文件 / 总量上限、路径穿越、重复条目、清单声明文件必须存在、SHA-256（**强制**） |
| `repository` | `repo.toml` + `index.json`（Kazumi 字段别名）、每 id 取最高版本、Ed25519 校验、三种信任标签 |
| `installer` | 索引 ↔ 包交叉校验（id / 版本 / 类型 / API level / 大小 / 哈希）、宿主版本区间、code 插件 `\0asm` 头 |
| `store` | `installed/<id>/<version>/`、`state.json`、`repos.json`、`install.log`；staging + 原子 rename；损坏状态文件降级 |

### 代码插件宿主

- WIT 契约落盘 `crates/plugin-wasm/wit/source-plugin.wit`，`bindgen!` 直接生成绑定；
- `ComponentSource` 把组件包装成 `SourcePlugin`：每次调用新建 store（fuel / 内存 / epoch 预算按调用重置），
  `Component` 与 `InstancePre` 复用；
- 能力注入：`fetch` 走 `permissions.network` 白名单，`Host`/`Cookie`/`Content-Length` 等头被丢弃，
  `store-*` 走命名空间白名单，`random` / `now-ms` 由宿主提供；
- 导入白名单 `guo:source/*`：`wasi:*` 在**加载期**拒绝，不是运行时。

### 插件模板的两步编译（踩坑记录）

`wasm32-wasip2` 直接编译最省事，但 `wit-bindgen` 会拖进 `wasi:cli` / `wasi:io` / `wasi:clocks`
共 15 个导入，宿主白名单会拒绝。实测有效的路径是：

```bash
cargo build --target wasm32-unknown-unknown --release
wasm-tools component new target/.../guo_plugin_template.wasm -o plugin.wasm
```

组件化后导入集合只剩 `guo:source/types@1.0.0`，产物 43,234 字节。
`examples/plugin-template/build.sh` 固化此流程，`tests/component_host.rs` 断言导入集合。

### 红果主源（D4 的能力面）

| 能力 | 实现 | 与 Go 的一致点 |
| --- | --- | --- |
| X-Gorgon 签名 | `sign.rs`，纯函数 | 5 组固定向量对拍（含中文 query、带/不带 body） |
| 网页目录 | `_ROUTER_DATA` → `category_page` | 四路由聚合、按标题排序、`totalPages` 决定 `hasMore` |
| 网页详情 | `detail_page.seriesDetail` | `vid_list` → `hongguo-cenc://<vid>`，空 vid 跳过，无 ID 报错 |
| 取流 | `player_page.video_player_info` | **vid/series 不一致即拒绝**，避免把试看集当目标集 |
| 字段映射 | `router.rs` | `video_data` 优先、`series_id` 必须纯数字、完结状态/热度/上线日期换算 |

App 接口（`api5-normal-sinfonlineb.fqnovel.com`）的签名与请求构造已实现
（`signed_app_request`，含 20 个公共参数与 `_rticket`），但设备注册状态机尚未接入，
因此 `catalog()` 目前只走网页路径，App 路径留到 P2。

### 模板 token 白名单（`spec 2` 的第一块）

之前未知 token 会被原样保留，`{foo}` 直接发到站点，返回 200 + 空列表，
看起来像「源站改版」——最难查的一类静默失败。本轮改成**加载期拒绝**：

| token | 说明 |
| --- | --- |
| `{page}` `{category}` `{keyword}` `{id}` `{idFirst}` `{idRest}` `{base}` | 原有 |
| `{ts}` `{ts10}` | 毫秒 / 秒级时间戳 |
| `{md5:<inner>}` `{sha256:<inner>}` | 摘要，inner 先递归渲染 |
| `{upper:<inner>}` `{lower:<inner>}` `{trim:<inner>}` | 文本变换（签名常需大小写归一） |
| `{hmac:sha256:<key>:<inner>}` | HMAC-SHA256，key 走 UTF-8 字节 |

配套的三条约束：

1. `base` 里出现任何占位符即报错（它是常量前缀，`{base}` 只应出现在请求模板里）；
2. `id` 必须是小写字母 / 数字 / `_` / `-`（插件 id 与规则 id 共用一套命名）；
3. 校验覆盖 catalog / search / detail / resolve 四个动作的地址候选、Referer 与请求头值。

SHA-256 实现在 `guo-source-api`（手写，`crates/source-api/src/sha256.rs`），
理由与 MD5 相同：契约层只允许 `async-trait` / `serde` / `serde_json`，
加 `sha2` 会让依赖方向守卫失败。HMAC 按 RFC 2104 实现，测试用 RFC 4231 Case 2 向量。

### Dart 站源列表接入引擎

`SourceSite.values` 从 `static const` 改成 getter，合并两部分：

- `SourceSite.builtins`：编译期常量（`ALL_SOURCES` 开关在这里生效），离线可用；
- 引擎上报：`EngineRepository.syncSourceCatalog()` 把 `source_catalog()` 里
  **内置清单之外**的 id 登记进来（即插件安装的源）。

内置 id 不会被引擎覆盖名称——那是产品文案，不该被技术标识替换。
`test/plugin_repository_test.dart` 覆盖了追加、去重、内置保护与清空五条路径。

`main.dart` 启动时新增两件事：`setPluginDirectory('${support.path}/rust/plugins')`
与 `syncSourceCatalog()`。插件目录与缓存同级但不叫 cache：它随应用数据清理，
不该被「清理缓存」按钮删掉。

### 验证

| 项 | 结果 |
| --- | --- |
| `cargo test --workspace` | ✅ **278 项** |
| `cargo fmt --all --check` | ✅ |
| `cargo clippy --workspace --all-targets -D warnings` | ✅ 零告警 |
| Dart 引擎测试 | ✅ 15 项（`engine_bridge_test` + `engine_model_parity_test` + `plugin_repository_test`） |
| Dart 全量测试 | 262 通过 / 41 失败（基线 253 / 42，**净增 9 项通过、0 回归**） |
| `flutter build macos --debug` | ✅ `duanju_app.app` 内含新 `rust_lib_guo_engine.framework` |
| `flutter build apk --debug` | ✅ `libguo_engine.so`：arm64 16,300,888 B / v7a 6,906,360 B / x86_64 18,940,520 B |
| 代码插件真实链路 | ✅ 模板组件加载 → `describe` / `catalog` / `detail` / `resolve` 全通 |
| Go 参考测试 | ✅ `go test ./...` 全绿（33 s）；最后一项为夹具缺陷，已修 |

### Dart 全量测试的 41 项失败（既有问题，非本轮引入）

用「回退我的三处 Dart 改动再跑一遍」的方式做了对照：

| 状态 | 通过 | 失败 |
| --- | --- | --- |
| 回退 `models.dart` / `engine_repository.dart` / `main.dart` 的改动 | 253 | 42 |
| 保留本轮改动 | **262** | **41** |

失败集中在 `interface_test`（`catalog-refresh` 找不到、`DownloadsScreen` 的
`Null check operator used on a null value`）、`cover_image_test` 与
`app_build_test` 的 edition 过滤——都属于「UI 组件重构后测试选择器/空断言未同步」，
与本轮引擎改动无关，也没有因为这些失败而降低任何门禁。**修它们属于独立任务**，
不应混进引擎迁移里，否则无法判断引擎改动是否引入回归。

### 踩坑记录

1. **`bindgen!` 的 WIT 语法**：`types.response` 这种「接口.类型」引用不被接受，必须
   在每个接口里写 `use types.{response, error};`；导出函数不能与类型同名
   （`descriptor` → `describe`，`detail` → `fetch-detail`）。
2. **`wasm32-unknown-unknown` 产物是 core module**，不是 component；
   直接喂给 `Component::from_binary` 会报 "attempted to parse a wasm module with a component parser"。
3. **`wasm32-wasip2` 产物带 wasi 导入**，必须拒绝——否则插件能绕开宿主的网络白名单。
4. **Dart 侧 `ioDirectory`**：codegen 按 `rust_root` 推出 `rust/bridge/target/release/`，
   但工作区共享 `rust/target/`。已由 `scripts/prepare_engine.py` 把产物同步到两侧，
   重新生成后不再需要手工修改生成文件。
5. **Android 插件缓存**：`shared_preferences_android` 的 Kotlin 类未编译时，
   报错表现为 `:app:compileDebugJavaWithJavac` 找不到 `SharedPreferencesPlugin`，
   与 Dart/Rust 改动无关；删掉 `build/shared_preferences_android` 重新构建即恢复。

### Go 侧收尾（D5 的只读规格来源）

`go test ./core` 之前有 6 项失败 + 一次 panic 中止，本轮全部修完：

| 失败 | 根因 | 处理 |
| --- | --- | --- |
| `TestNativeCatalogCacheFreshnessPagingAndRefresh` | mock 只允许 `ai-duanju`，实现聚合四分类 | 夹具补 `aiSlugBase` 与四分类断言 |
| `TestNativeHongguoCursorRestartsPerCatalog` 等三项 | 游标每页写进 `client.state`，`saveCatalogCache` 又用提交前快照覆盖 | 新增 `pendingFeeds`，提交前合并 |
| 目录翻页 offset 飙到 900 | `page` 没传给取数层，首屏翻完 50 页 | `libraryPageKey` + 每请求 `pageLimit = 1`（40 s → 0.59 s） |
| `TestNativeHLSExtensionlessPlaylistsAndRedirectBase` | 无后缀播放列表被当成 `video/mp4` | 按内容前缀 `#EXTM3U` 判定，前缀用 `io.MultiReader` 回放 |
| 审计同期：`TestNativeCatalogCacheFreshnessPagingAndRefresh` 的 `close(paused)` panic | 多个子用例重复关闭同一 channel | `sync.Once` |

`TestRankingCacheAndStaleRecovery` 的失败是夹具问题：第 1 页地址不带 `?page=`，
夹具按 0 处理，于是产生 `pageNum: 0`；未改动的 `reference/` 快照复现同一失败，
证明与实现无关。修完后 `go test ./...` 33 秒全绿。

### 未做

- 12 个官方规则包的打包与仓库发布（P1 剩余项）；
- 红果 App 接口的设备注册与榜单 / 推荐 / 联想 / 弹幕（D4 中依赖 App 接口的部分）；
- 声明式规则从 `schema 1.0` 升级到 `spec 2` 的**动作化结构**（`actions`、`session`、`assert`）；
  本轮只补了模板 token 白名单与 `{sha256:…}` / `{hmac:…}` / `{upper:…}`，结构仍是扁平的；
- Dart 站源列表的「删除插件后清理本地数据」尚未实现（当前只是从列表消失，数据保留）；
- wasmtime 体积决策（A/B/C）仍未拍板，当前按 A 执行。

---

## 第十二轮：P0 基线（2026-10-19）

目标：把重写前的地基打完 —— 质量门禁、工作区、构建验证、插件运行时探针。

### 落地内容

| 项 | 结果 |
| --- | --- |
| 格式化 / 静态检查 | `cargo fmt --all --check`、`cargo clippy --workspace --all-targets -D warnings` 全绿 |
| 测试 | 163 项（原 156，新增 7 项） |
| CI | `.github/workflows/build.yml` 新增 `rust` job：fmt + clippy + test + 依赖方向守卫 |
| 工作区 | 虚清单 + `bridge/` 桥接 + `crates/source-api` + `crates/plugin-wasm` |
| 构建验证 | macOS `flutter build macos` 成功；Android `flutter build apk` 产出含三 ABI 的 `libguo_engine.so` |
| 插件运行时 | wasmtime 49.0.2 + Pulley，三端交叉编译通过，冷启动约 2 ms |

### 修复的缺陷（对应 `AUDIT.md`）

| 编号 | 问题 | 处理 |
| --- | --- | --- |
| 3.4 | `panic = "abort"` 与 FRB 的 `catch_unwind` 冲突 | 改回 `unwind`，注释说明原因 |
| 3.2 | 下载删除先 `remove` 后取 target，导致删不掉文件 | 先取 target 再删，补注释 |
| 3.3 | HLS 每次从零开始，宣称的断点续传不存在 | 按分片签名 + 已完成数续传，每片落元数据 |
| 3.3 | `FileState.validator` 从未写入，`If-Range` 永远为空 | 从响应采集 ETag / Last-Modified |
| 3.1 | 非 HLS 媒体也被整段读入内存 | 先读 1 KiB 前缀判断 `#EXTM3U`，确认后再拉全量 |
| 新增 | 续传时服务器返回空 206 被当成错误 | 识别为「已完整」直接成功 |

### 工作区迁移的两个坑

1. **`include_str!` 路径**：`rules/` 留在 `rust/` 根，桥接 crate 下移一层后，
   `src/sources/mod.rs`、`src/api.rs`、集成测试、examples 的四处相对路径全部要跟着改；
   Dart 测试 `test/engine_bridge_test.dart` 引用的 `rust/tests/fixtures/` 也变成
   `rust/bridge/tests/fixtures/`。
2. **podspec 缓存**：改完 `manifestDir` 后必须先 `pod install`，否则 Xcode 仍用旧参数
   （报错 `BuildTool arguments: [build-pod, ../../rust, ...]`），看起来像路径改错了。

### 体积探针结论

详见 `poc-4-wasmtime-pulley.md`。要点：

- 三端均可编译（iOS 首次验证通过），冷启动 1–2 ms；
- 但**真实链接增量** iOS ≈ 9.2 MB、Android arm64 ≈ 12.5 MB、宿主 dylib +10.5 MB；
- 只声明依赖不调用时，LTO 会把整个运行时裁掉（体积只涨 64 字节），
  这类测量无效，必须保留真实调用点。

体积超预算，P1 开工前需在「接受 / 平台分层 / 缩小运行时」三者间决策。

### 未做

- 未在设备上运行插件（仅交叉编译）；
- 未测真实插件组件的 WIT 胶水开销；
- Go 参考测试仍失败（P0 的另一项，留待下一轮）；
- `guo-host` / `guo-rule-engine` / `plugin-host` 尚未建立。

---

## 已落地代码（截至第十三轮）

```
rust/
  Cargo.toml                    虚清单：member = bridge + crates/*
  bridge/src/
    lib.rs                      薄索引：定向重导出，`mod env` 供 FRB 生成物使用
    api/mod.rs                  FRB 入口：目录/详情/搜索/取流/下载/缓存
    api/plugins.rs              插件安装、启用、回滚、仓库记录
    sources/builtin.rs          内置装配：红果主源 + 猫果 + 7 条随包规则
    frb_generated.rs            生成物（hand-edit 仅 ioDirectory）
  crates/source-api/src/
    model.rs error.rs           数据模型与类型化错误
    request.rs env.rs           FetchRequest/Response、Transport/Store/ScriptHost/LogSink
    plugin.rs                   SourcePlugin trait + SourceRegistry + 能力位
    md5.rs                      纯 Rust MD5（签名与模板共用）
  crates/media/src/lib.rs       m3u8 解析、AES-128 分片解密
  crates/rule-rust/src/
    rules.rs render(内嵌)       规则 schema、模板渲染、加载期校验
    executor.rs                 CSS 提取 + 按 kind 分发
    jsonpath.rs json_executor.rs 接口 JSON 路径与内嵌 JSON 取数
    embedded.rs                 `__NEXT_DATA__` / `_ROUTER_DATA` 提取
  crates/host/src/
    transport.rs                reqwest 传输层（流式截断、连接池单例）
    script.rs                   QuickJS 沙箱（MD5 + JSON 原语）
  crates/plugin-host/src/
    manifest.rs package.rs      清单校验、zip 解包防护、SHA-256
    repository.rs               仓库协议、Ed25519、TOFU 指纹
    installer.rs store.rs       交叉校验、原子安装、状态与日志
  crates/plugin-wasm/
    wit/source-plugin.wit       代码插件 ABI
    src/sandbox.rs              运行时配置、导入白名单、能力注入、资源上限
    src/bindings.rs             host 函数实现（fetch/store/log/random/now）
    src/component.rs            ComponentSource：组件 → SourcePlugin
  crates/runtime/src/
    source.rs(→source-api)      注册表已上移；此处保留装配逻辑
    rule_source.rs              声明式规则 → SourcePlugin
    cache.rs download.rs scheduler.rs  目录缓存、下载、调度
  crates/source-hongguo/src/
    sign.rs                     X-Gorgon 签名（Go 向量对拍）
    router.rs                   `_ROUTER_DATA` 与字段映射
    source.rs                   目录/详情/取流/分类 + App 请求构造
  crates/source-maoguo/src/     猫果签名源
  rules/*.json                  7 条随包声明式规则（迁移期保留）
  examples/plugin-template/     代码插件模板（build.sh 两步编译）
```

代码量：引擎侧约 9,500 行实现（`crates/` + `bridge/`，不含测试与 FRB 生成物；
含测试约 14,700 行），规则清单约 830 行。

## 声明式规则的三类取数

| `kind` | 取数方式 | 代表站源 |
| --- | --- | --- |
| `html` | CSS 选择器 | 伍果、花果 |
| `json` | 接口 JSON 路径 | 饭果、观果、星果 |
| `next` | 页面内嵌 `__NEXT_DATA__`，接口回退纯 JSON | 河果 |

规则层为接口站源补齐了这些能力：条件地址候选（`urls[].when`）、POST + JSON 请求体模板
（`{"$int": "{page}"}` 输出数字）、模板 token（`{page}` `{category}` `{keyword}` `{id}`
`{idFirst}` `{idRest}` `{ts10}` `{md5:…}`）、复合主键（`idTemplate`）、
分集地址递归查找与多清晰度取高、播放量与完结状态换算。
`fetch_categories` 把规则里的分类清单暴露给 Dart，装饰器按能力路由，
站源未声明分类时回退 Go 核心。

## 已验证的真实站点

| 站源 | 方式 | 结果 |
| --- | --- | --- |
| 伍果 | 声明式规则 `rules/wuguo.json` | ✅ 首页 30 条 + 分类页 24 条，真实请求端到端 |
| 伍果（live） | `examples/live.rs` 真实网络请求 | ✅ 52 KB → 24 条，ID/标题正确 |
| 皮果 | 声明式规则 | ✅ 页面可解析（推翻了「CF 拦截」的历史判断） |

## 关键设计决策

1. **错误类型化**：`SourceError` 枚举取代字符串匹配，`http_status()` / `is_retryable()` 提供判断依据。
2. **能力白名单**：`SourceEnv` 只暴露 `transport` / `store` / `scripts` / `log`，
   provider 拿不到引擎内部，从类型上杜绝主项目的 50 处封装泄露。
3. **规则加载期校验**：`validate_selectors()` 在加载时拒绝空选择器和括号不配对，
   避免主项目「静默返回空结果」的失败模式。
4. **自匹配支持**：`scraper` 的 `select` 只查后代，`a@href` 作用于 `<a>` 条目时需显式处理。
5. **实体解码**：`&amp;` 等需要手动还原，含二次编码（`&amp;amp;`）。

## 踩过的坑

- `scraper` 对不完整选择器（`a[href`）不报错，因此改为加载期括号配对校验。
- 真实站点结构与推测不同（伍果用 `SecondList_secondListItem`，不是 `module-item`），
  必须先取真实 fixture 再写规则。
- `DynamicLibrary` 无关，但规则里的字段若取不到会静默变空值，需在测试里断言非空。

## 本轮真实站点验证（live）

```
GET https://www.duanju55.com/index.php/vod/type/id/1.html
body: 52408 bytes
parsed: 24 items
  23927 | 一念初见锦衣谣
  56665 | 兴安岭猎人传
  56664 | 撞大运后我在县城买了个院
```

## 多选择器设计（本轮新增）

同一站源不同页面结构差异很大：伍果**首页**用 `SecondList_*` 类名，**分类页**用 `BrowseList_*`。
因此 `item` 与所有字段都支持「字符串或候选数组」，按优先级依次尝试，
这直接对应主项目「一个源多种页面结构」的历史难题。

## 文本提取的两个真实缺陷（已修）

1. 嵌套 `span`（评分「537人在追」）被拼进标题 → 改为取**第一个非空文本节点**。
2. HTML 实体未还原（`&amp;` → 应为 `&`，还有二次编码 `&amp;amp;`）→ 加实体解码。

## 第二轮：脚本层与签名站源

### 脚本层（`src/script.rs`）

- `QuickJsHost` 提供 `crypto.md5` 与 `json` 两个能力，不暴露网络/文件系统。
- `rquickjs::Runtime` 不是 `Send + Sync`，因此不长期持有：每次执行在
  `spawn_blocking` 里新建隔离实例，脚本结束即释放。
- MD5 经 RFC 1321 标准向量校验（空串 / `abc` / quick brown fox）。

### 猫果签名源（`src/sources/maoguo.rs`）

七猫的签名不止 URL 参数，还包括一整套请求头：

1. 设备信息 JSON → Base64 → **字符映射表**（`CHAR_MAP`）得到 `qm-params`；
2. `md5("AUTHORIZATION=app-version=10001...qm-params=<件>reg=<key>")` 得到授权签名；
3. URL 里的 `sign` 是另一条独立签名，目录/详情/搜索各不相同。

实测结果：

| 阶段 | 结果 |
| --- | --- |
| 只带 URL sign | ❌ `{"code":"44010120","title":"验签失败"}` |
| 补齐 qm-params + authorization | ✅ **86,632 字节真实数据** |
| 目录解析 | ✅ 66 部，集数/封面/分类正确 |
| 详情解析 | ✅ 33 集，含真实 CDN 地址 |
| 搜索签名 | ✅ 与脚本实现一致 |

### 跨实现一致性（`tests/signature_parity.rs`）

Rust 原生 MD5 与 JS 脚本层 MD5 必须一致，否则签名会被服务端拒绝。
已验证 6 个用例 + 4 组目录签名 + 3 组搜索签名全部吻合。

### 修掉的生产 bug

`format!("{:x}", u128)` 不补前导零：MD5 以 `0` 开头时只输出 31 位，
签名必然失效。已全部改为 `{:032x}`。

## 第三轮：Go 对拍 + Flutter 接入

### Go 对拍（`tests/go_parity.rs`）

直接复用 `native/core/provider_duanju_test.go` 的 HTML 夹具，逐字段比对：

| 断言 | Go 期望 | Rust 结果 |
| --- | --- | --- |
| 剧目 ID | `wuguo:100` | ✅ |
| Source | `wuguo` | ✅ |
| 封面 | 服务端绝对地址 | ✅ 补全为 `https://.../pic/100.jpg` |
| 标题 | `五五样本`（取自 `a@title`） | ✅ |
| 分集链接 | 绝对地址 | ✅ |
| 分集顺序 | 保持原序 | ✅ |

对拍过程中修掉两个真实缺陷：

1. **cover 相对地址没有补全** —— 会导致 App 里海报裂图。
2. **多候选选择器命中同一节点产生重复分集** —— 加上按链接去重。

### Flutter 接入（FRB 2.13.0）

- `flutter_rust_bridge.yaml` 指向 `rust/`；
- `rust_builder/` 插件从模板复制并改名为 `rust_lib_guo_engine`，
  各平台 `cargokit` 路径改到 `rust`；
- 生成 `lib/src/rust/{api,frb_generated}.dart`。

Dart 侧可调用：

```dart
engineVersion()                       // 引擎版本
sourceCatalog()                       // 内置站源清单（替代硬编码）
parseCatalogWithRule(...)             // 纯函数解析
parseDetailWithRule(...)              // 纯函数解析
validateRule(...)                     // 规则校验
fetchCatalogWithRule(...)             // 真实网络抓取
```

验证方式与结果：

```sh
FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR="$(pwd)/rust/target/release/" \
  flutter test test/engine_bridge_test.dart
# 00:00 +6: All tests passed!
```

纯 Dart 测试默认不构建 Rust 原生库，需用上述环境变量指向已编译的动态库；
在真实 App 构建中由 cargokit 自动产出。

### 踩过的坑

- FRB 不支持零字段结构体（unit struct），会 panic 在 `structure.rs`；
  改为 `struct Foo {}` 并对内部类型加 `#[frb(ignore)]`。
- `#[frb(ignore)]` 加在 `QuickJsHost` 上后，`Self` 构造语法也必须带花括号。
- 规则里的 `a[href*=/play/]` 需要给属性值加引号，`scraper` 会报
  `BadValueInAttr(Delim('/'))`。

## 第四轮：统一调度与跨层对拍

### 统一调度（`src/sources/rule_source.rs`）

把声明式规则包装成 `SourcePlugin`，规则源与代码插件走**同一条调度路径**：

```rust
let registry = builtin_registry();
let source = registry.get(&source_id)?;
source.catalog(&env, page, &category).await
```

实测：

```
=== 站源清单 ===
  maoguo | 猫果 | ["catalog", "detail", "search"]
  wuguo  | 伍果 | ["catalog", "detail", "search"]

=== 规则源：伍果 ===  items: 24
=== 代码插件：猫果 === items: 66
=== 未知站源 === 正确报错: 未知站源：nope
```

### 新增 Dart 可调用入口

```dart
fetchCatalog(sourceId, page, category)   // 统一目录调度
fetchDetail(sourceId, dramaSourceId)     // 统一详情调度
fetchSearch(sourceId, query, page)       // 统一搜索调度
```

### 跨层对拍（`test/engine_model_parity_test.dart`）

这是「UI 不感知后端换语言」的硬约束：

| 断言 | 结果 |
| --- | --- |
| `DramaItem` → `Drama` → `toJson` → `Drama.fromJson` 往返无损 | ✅ |
| ID 格式 `"${source}:${sourceId}"` 与 Go 约定一致 | ✅ |
| 分集至少有 `videoUrl` 或 `pageUrl` | ✅ |

### 真实网络端到端（`test/engine_live_test.dart`）

Dart 直接驱动 Rust 引擎访问真实站点，11 项断言全部通过：

- 伍果（规则源）读到 24 条真实目录
- 猫果（代码插件）读到 66 部 + 真实分集与 CDN 地址

### 本轮修掉的规则缺陷

- `BrowseList_bookType` 实际是「已完结」状态标签，**分类应为 `BrowseList_tagsBox`**；
- 补充 `description` 字段，映射到 `BrowseList_bookIntro`。

这两处只有对照真实页面结构才能发现。

## 第五轮：cargokit 真实构建打通

### 结论

| 平台 | 结果 | 证据 |
| --- | --- | --- |
| Android | ✅ | APK 内含 3 个 ABI 的 `libguo_engine.so`（arm64 12MB / armv7 6.9MB / x86_64 13.8MB） |
| macOS | ✅ | `duanju_app.app` 启动运行无崩溃，二进制含 1,880 个 FRB 符号 |
| iOS | ⚠️ | Rust 静态库已生成（arm64 + x86_64），链接失败源于**既有 Go 核心缺失**，与 Rust 无关 |

iOS 失败的真实原因：`ios/Podfile` 依赖 `DuanjuCore.xcframework`，
而该文件从未生成过（需 `scripts/build_ios.py --core-only`）。
这是主项目既有状态，不是 cargokit 引入的。

### cargokit 的四个真实缺陷（全部已修）

cargokit 是 FRB 官方推荐的构建胶水，但在本机环境下有四处问题：

**1. 环境变量名不匹配 `cc` crate**

`cc` crate 读取 `CC_<target>` 时会把连字符规范化为下划线，
但 cargokit 只设置了带连字符的键（`CC_armv7-linux-androideabi`），
shell 层面这种键名无法被子进程继承。

修复（`android_environment.dart`）：额外下发下划线版本
`CC_/AR_/CXX_/RANLIB_/CFLAGS_/CXXFLAGS_/CARGO_TARGET_*_LINKER`。

**2. bindgen 缺 sysroot**

`rquickjs-sys` 的 bindgen 找不到 `stdio.h`。

修复：下发 `BINDGEN_EXTRA_CLANG_ARGS_<normalized>`，
Android 指向 NDK sysroot，Darwin 指向 Xcode SDK 并显式给出 clang triple。

**3. iOS 模拟器 triple 非法**

直接沿用 rust target 名 `aarch64-apple-ios-sim` 会让 clang 报
`version 'sim' in target triple is invalid`；必须写成
`arm64-apple-ios15.1-simulator`。

**4. 静态库名与 podspec 不一致**

cargokit 用 `crateInfo.packageName`（即 `guo_engine`）作为产物名，
忽略传入的 `libname` 参数，但 FRB 模板的 podspec 写死
`librust_lib_<name>.a`。本项目的 crate 叫 `guo_engine` 而插件叫
`rust_lib_guo_engine`，两者不同，导致链接器找不到文件。

修复：podspec 的 `output_files` 与 `-force_load` 统一改为 `libguo_engine.a`。

**5. `run_build_tool.sh` 相对路径失效**

`BASEDIR=$(dirname "$0")` 在 `cd "$CARGOKIT_TOOL_TEMP_DIR"` 之后失效，
导致 pod 构建报 `build_tool: No such file or directory`（Android 因为路径恰好正确而未暴露）。

修复：`BASEDIR=$(cd "$(dirname "$0")" && pwd -P)`。

### 对方案的意义

cargokit 可用，但需要打补丁。这些补丁可以上游提交，
也可以作为本项目 `rust_builder/` 的定制内容长期维护。

## 第六轮：双后端路由与站源扩充

### 双后端路由（`lib/engine_repository.dart`）

App 现在可以按站源选择后端，Go 路径完全保留：

```dart
NativeRepository(
  engine: EngineRepository,   // null 时全走 Go
  route: EngineRoute,          // 允许的站源集合
)
```

编译期开关（默认关闭，行为与纯 Go 版本一致）：

```sh
flutter run --dart-define=ENGINE_ROUTE=all
flutter run --dart-define=ENGINE_ROUTE=wuguo,maoguo,huaguo
```

安全性：`engineHandles()` 额外检查 `engine.initialized`，
未初始化时自动回退，避免调用 `RustLib` 抛异常拖垮启动。

### 模块布局重构（应用 `rust-module-layout` 技能）

原 `lib.rs` 是技能明确点名的反模式：
「扁平的 lib.rs + 全部 `pub mod` + 通配重导出」。

重构后：

| 项 | 前 | 后 |
| --- | --- | --- |
| `lib.rs` 行数 | 101 | **34** |
| 模块可见性 | 全部 `pub mod` | 私有 `mod` + 根级定向 `pub use` |
| POC 探针代码 | 混在 `lib.rs` | 独立 `probe` 模块 |

调用方通过 facade 访问（`guo_engine::Drama` 而非 `guo_engine::model::Drama`）。

### 站源扩充：花果

新增 `rules/huaguo.json`，实测 36 条真实数据：

```
89346 | 老婆出游不带我却不知整个岛都是我的-动漫合集 | 已完结
89345 | 重生1977开启我的逆袭之路-动漫合集 | 已完结
```

花果的 class 名带哈希前缀（`_9dbe81752a1dbf17-vodlist__item`），
规则用 `[class*=vodlist__item]` 属性子串匹配，**站点换哈希也不会坏**。

### 剩余站源的可迁移性实测

用 `wreq`（Chrome131 指纹）逐个验证：

| 站源 | curl | wreq 指纹 | 结论 |
| --- | --- | --- | --- |
| 花果 | 200 | 200 | ✅ 已迁移 |
| 网果 | CF 拦截 | **仍拦截** | ❌ 需 WebView |
| 发果 | 403 | 403 | ❌ 站点拒绝 |
| 皮果 | 492 | 492 | ❌ |

结论：**TLS 指纹不是万能的**，网果的「Just a moment」仍然拦截。
这部分需要 WebView 方案，与 POC-3 记录一致。

### 当前站源覆盖

| 站源 | 方式 | 状态 |
| --- | --- | --- |
| 伍果 | 声明式规则（24 条） | ✅ |
| 花果 | 声明式规则（36 条） | ✅ |
| 猫果 | 代码插件（66 部 + 33 集） | ✅ |
| 其余 17 个 | — | ⬜ |

## 第七轮：架构重构与质量基线

### 质量基线（按 `rust-code-review` 技能流程）

首次执行完整检查，发现并修复 4 个 clippy error：

| 问题 | 位置 | 处理 |
| --- | --- | --- |
| `not_unsafe_ptr_arg_deref` × 2 | `probe.rs` 的 `guo_eval`/`guo_free` 接收裸指针却未标 `unsafe` | **删除整个 probe 模块**（POC 已被 FRB 取代，无任何调用方） |
| `manual char comparison` | `target.rs` | `clippy --fix` |
| `new_without_default` | `MaoguoSource` | 补 `Default` |
| 列后置定义 | 多个文件 | 整理 |

最终 `cargo clippy --all-targets -- -D warnings` **零告警**。

### C-UNWRAP 违规修复

`api::build_env` 中：

```rust
HttpTransport::new(DEFAULT_USER_AGENT)
    .unwrap_or_else(|_| HttpTransport::new("guo-engine").expect("fallback transport"))
```

这是公开 API 路径上的 `expect`，触发 Rust API Guidelines 的 **C-UNWRAP**。
改为返回 `Result<SourceEnv, String>` 并向上传播，三处调用同步处理 `?`。

### 架构重构：装饰器取代内联分支

**重构前**：引擎逻辑塞在 `NativeRepository` 内部

```dart
class NativeRepository extends AppRepository {
  final EngineRepository? engine;
  final EngineRoute? route;
  Future<CatalogPage> catalog(...) async {
    if (engineHandles(source)) { return engine!.catalog(...); }
    return CatalogPage.fromJson(await _read(...));
  }
}
```

问题：`NativeRepository` 同时知道 Go 与 Rust，两个职责耦合。

**重构后**：`EngineBackedRepository` 作为装饰器

```dart
class EngineBackedRepository extends AppRepository {
  final AppRepository delegate;   // Go 核心
  final EngineRepository engine;  // Rust 引擎
  final EngineRoute route;

  Future<CatalogPage> catalog(...) async {
    if (!handles(source)) return delegate.catalog(...);
    return engine.catalog(...);
  }
}
```

收益：
- `NativeRepository` 恢复单一职责（只做 Go 调用）；
- 引擎接入点集中在装配层（`main.dart::_buildRepository`）；
- 41 个接口方法逐一显式委托，漏掉会编译报错，不会静默走错后端。

### `access` 上提到接口

`access` 原先只在 `NativeRepository` 上，装饰器无法泛化。
已提升到 `AppRepository` 抽象成员，`NativeRepository` 用 getter/setter 实现，
装饰器直接转发。

### 验证

| 项 | 结果 |
| --- | --- |
| `cargo clippy -D warnings` | ✅ 零告警 |
| 引擎测试 | ✅ 61 项 |
| Dart 引擎测试 | ✅ 16 项 |
| macOS 构建（`ENGINE_ROUTE=all`） | ✅ 成功 |
| App 运行 | ✅ 启动无崩溃、无回退提示 |

## 第八轮：取流接管与稳定性

### 媒体解析模块（`src/media.rs`）

新增纯函数解析层，10 项单测覆盖：

| 能力 | 覆盖 |
| --- | --- |
| M3U8 主列表 | `#EXT-X-STREAM-INF` 变体识别 |
| M3U8 媒体列表 | 分片、`#EXT-X-KEY`、累计时长 |
| BOM 处理 | `\u{feff}` 前缀剥离 |
| 播放页提取 | `player_aaaa` 变量 / `<video>` / `<source>` / 内嵌地址 |
| 地址补全 | 相对、根相对、协议相对、无路径四种形态 |

### 取流链路接管（`RuleSource::resolve`）

之前只是透传地址，现在是完整链路：

```text
直链 → 若 .m3u8 则拉列表并校验 → 返回分片
播放页 → 抓页面 → 提取媒体地址 → 同上
主列表 → 自动跟进第一个变体
```

校验失败会明确报「站点未返回有效 M3U8」，不再把无效地址交给播放器。

### HTTP 客户端单例（按 `rust-http-client` 技能）

发现 `build_env` **每次请求都新建 `reqwest::Client`**，连接池、TLS 会话、DNS 缓存全部失效。
改为进程级 `OnceLock` 单例（`HttpTransport::global()`）。

### 并发争用修复

Dart 侧并发跑取流测试时，猫果偶发失败；串行则通过。
根因是七猫接口对并发请求敏感。

处理：`MaoguoSource` 增加一次重试，重试前**刷新会话时间戳**（因此 `qm-params` 与授权签名都会重新生成），间隔 120ms。
修复后并发执行 3 项全部通过。

### 真实站点实测

| 站源 | 结果 |
| --- | --- |
| 猫果 | ✅ 取流成功，返回真实 CDN 地址 |
| 伍果 | ⚠️ 分集 m3u8 本身已 404（源站数据过期，非引擎问题） |
| 花果 | ❌ 详情页 403（目录页 200） |

花果详情页的 403 用 `wreq` Chrome131 指纹同样被拒，说明是站点主动拒绝而非 CF 挑战，引擎侧无法绕过。

### 验证

| 项 | 结果 |
| --- | --- |
| 引擎测试 | ✅ **77 项** |
| Dart 引擎测试 | ✅ **28 项** |
| `cargo clippy -D warnings` | ✅ 零告警 |
| `dart analyze lib/` | ✅ 零 error/warning |

## 第九轮：下载引擎与加密 HLS

### 下载核心（`src/download.rs`）

| 能力 | 实现 |
| --- | --- |
| 断点续传 | `Range` 请求 + `If-Range` 校验 + `.part`/`.json` 元数据 |
| 服务器忽略 Range | 检测 200 响应，整段重写而非污染文件 |
| 数据变化 | 416/412 返回 `Restart`，丢弃中间文件 |
| HLS 分片 | 顺序下载并拼接，中断可续 |
| 提交 | 原子 rename，清理元数据 |

### 下载调度（`src/scheduler.rs`）

- 有界并发：`Semaphore` 限制 1–6，默认 2；
- 状态机：`Queued/Running/Completed/Failed/Paused`；
- 每态变更递增 `revision`，供上层做乐观并发控制；
- 控制命令：pause / resume / retry / delete。

### AES-128 解密（关键突破）

**猫果的 HLS 使用 AES-128 加密**，此前下载的分片是密文，无法播放。

实现 `decrypt_segment()`：
- `cbc::Decryptor<aes::Aes128>` + PKCS#7 填充；
- 支持播放列表显式 `IV=0x...`，缺省时按规范用分片序号（大端）；
- 用 NIST SP 800-38A 的密钥/IV 做加解密往返验证。

### 修掉的两个真实缺陷

**1. 二进制响应被 UTF-8 破坏**

`FetchResponse.body` 原本是 `String`，传输层用 `response.text()` 解码。
媒体二进制经 UTF-8 转换后出现替换字符（`ef bf bd`），文件必然损坏。

改为 `Vec<u8>`，文本调用方按需 `text()` 解码。

**2. HLS 判断只看后缀**

猫果的 CDN 地址不带 `.m3u8` 却返回 HLS 内容。
改为**先探测内容**（`parse_playlist` 是否有效），后缀仅作辅助判断。

### 端到端验证

```
resolve: segments=62, key_uri=有, key_iv=有
download: 62 个分片 → 10,581,956 字节
首字节: 0x47（MPEG-TS 同步字节）
ffprobe: h264 视频 + aac 音频
```

Dart 侧同样验证通过（`test/engine_hls_download_test.dart`）。

### 关于容器格式

HLS 分片拼接后是 **MPEG-TS**，不是 MP4。
播放器可直接播放 TS；若需 MP4 需 FFmpeg 转封装（主项目已有 FFmpegKit）。

### 验证

| 项 | 结果 |
| --- | --- |
| 引擎测试 | ✅ **102 项** |
| Dart 引擎测试 | ✅ **39 项** |
| `cargo clippy -D warnings` | ✅ 零告警 |
| `dart analyze lib/` | ✅ 零 error/warning |

## 第十轮：目录缓存

### 缓存核心（`src/cache.rs`）

| 能力 | 实现 |
| --- | --- |
| 键格式 | `source` 或 `source\|category` |
| TTL | 15 分钟（与 Go 一致） |
| 落盘 | `catalogs.json`，先写临时文件再 rename |
| 上限 | 32 MiB，超限拒绝写入而非截断 |
| 版本 | `version: 1`，不匹配直接丢弃 |

### 合并语义（对齐 Go）

- **第 1 页**：新数据在前，旧数据中未被刷新过的条目追加在后；
- **后续页**：按 ID 合并，保持旧顺序；
- **分类键**：写入后同时汇总到基础源，避免「全部」看不到分类内容；
- **失败页**：保留旧游标，不用失败结果覆盖进度。

### 实测效果

```
首次读取（联网）:  items=24  elapsed=1.90s
缓存读取:          items=24  elapsed=16.5µs   ← 快约 11.5 万倍
落盘:              11,325 字节
分类汇总:          base items=24
```

### 修掉的缺陷

`replace_first_page` 初版把「保留旧条目」的判断写成了与 `merge` 共用，
导致同 ID 条目被重复计入。修正后：新数据在前，已刷新 ID 不再从旧数据追加。

### 接入路径

```dart
// 启动时指定缓存目录（应用数据目录下）
await engine.setCacheDirectory('${support.path}/engine');

// 读取缓存
final page = await repository.cached('wuguo', category: '1');
```

装饰器在引擎缓存为空时回落到 Go，避免切换瞬间出现空列表。

### 验证

| 项 | 结果 |
| --- | --- |
| 引擎测试 | ✅ **113 项** |
| Dart 引擎测试 | ✅ **44 项** |
| `cargo clippy -D warnings` | ✅ 零告警 |

## 第十一轮：接口站源声明式化

停滞原因：规则引擎只能表达「CSS 选择器 + GET」，而 20 个站源里 6 个是接口 / 内嵌 JSON，
只能逐源写 Rust 插件，迁移卡在 3/20。本轮把声明式层补足到能表达接口站源，
新增饭果、星果、观果、河果四个源，全部是数据而非代码。

### 规则层新增的表达力

| 需求 | 规则写法 |
| --- | --- |
| 同一接口按分类切换 | `urls[].when` = `category` / `keyword` / `default` |
| POST + JSON 请求体 | `request.body` + `{"$int": "{page}"}` 输出数字而非字符串 |
| 时间戳签名参数 | `{ts10}`、`{md5:…}` token（观果 `clientInfo`） |
| 复合主键 | `idTemplate` + `idSplit`（饭果 `{id}#{source}`、星果 `{id}@{introduction}`） |
| 分集地址藏在任意层级 | `recurse: true` |
| 多清晰度取高 | `best: { paths, url, rank }` |
| 播放量 / 完结状态换算 | `divide` / `divideFrom` / `highSuffix` / `releaseStatus.total+current` |
| 分集页面延迟取流 | `pageUrlTemplate` + `{chapterId}` |

### 修掉的真实缺陷

1. **`__NEXT_DATA__` 提取器取不到内容**：旧实现把右尖括号的搜索范围放在标记**之前**，
   但标记本身写在 `<script id="__NEXT_DATA__" type="application/json">` 的属性里，
   `>` 只出现在标记之后 → 改为从标记向后定位 `</script>` 再取第一个 `>`。
2. **请求体里的中文关键词被百分号编码**：`{keyword}` 原先无条件走 URL 编码，
   河果的 POST JSON 体里出现 `"keyword":"%E6%B2%B3%E9%A9%AC"` →
   拆成 `render`（URL，编码）与 `render_json`（请求体，原样 UTF-8）。
3. **`{chapterId}` 缺失时拼出坏地址**：分集 id 取不到时直接返回空串，交回递归查找。

### 与 Go 行为对齐的点

饭果缺省分类「都市」、星果固定鉴权参数、观果 `okhttp/5.1.0` UA + 30 条分页 +
空详情文案、河果 `__NEXT_DATA__` 整份文档作根（故路径为 `props.pageProps.*`）、
分集按集数去重、缺集数时回退「第 N 集」、`referer = {base}/`。

### 分类清单接入

`fetch_categories(sourceId)` 返回的**首项固定为「全部」**，与 Go 侧一致；
站源未声明 `categories`（观果、猫果）时报错，装饰器捕获后回退 Go 核心，
因此这一项不产生功能缺失。

### 规则编写陷阱

`kind` 为 `json` / `next` 时，若显式写 `fields` 块则**必须给 `id`**：
serde 默认值是 CSS 写法 `a@href`，会被加载期校验直接拒绝。
整块省略 `fields` 是安全的（默认 id 列表为空）。

### 验证

| 项 | 结果 |
| --- | --- |
| 引擎测试 | ✅ **156 项**（113 单测 + 43 集成） |
| `cargo clippy --all-targets -D warnings` | ✅ 零告警（本轮修掉 6 项新引入的告警） |
| `dart analyze`（引擎 Dart 层） | ✅ 零问题 |
| 四个新增站源的真实站点请求 | ⬜ 未执行，属开发快照 |
