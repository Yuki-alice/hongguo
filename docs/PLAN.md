# 核心引擎重排计划（Engine-only）

> 状态：Core-0 / Core-1 已完成，正在推进 Core-2
> 制定：2026-10-21 · 修订：2026-10-21（按实际落地情况重写）
> 关联：`docs/ARCHITECTURE.md`（ADR-5c / 7 / 8 / 9 / 11 / 12）、`docs/PROGRESS.md`、`docs/HANDOFF.md`

## 0. 决策记录

2026-10-21 与项目负责人确认：

| 决策 | 结论 |
| --- | --- |
| 站源适配 | **暂停**。黄豆 / 野果 / 皮果不迁移，直到核心引擎完成 |
| 优先级 | 架构与状态正确性优先于功能数量 |
| Go 后端 | **停止演进**；已退出构建链、CI 与 Dart 主调用链。`native/` 只读留档，Core-4 物理删除 |
| 第一方代码源 | 除红果主源外，**全部改为官方 Wasm 插件** |
| 红果主源 | 保持编译进 Rust（默认源、D4 能力、离线可用、性能敏感） |
| LAN | **不再投入**，入口已隐藏；底层协议文件随 Core-4 一起删除 |
| 首发能力 | 基础浏览与播放、下载与离线播放、红果 D4 |
| 暂缓 | 封面修复、源健康 / 批量扫描、代理 / DNS / CDN 高级设置、下载合集 |

> 首个可发布 engine-only 版本以 Core-2 完成为门槛，避免在下载 / 播放未就绪时对外发版。

## 1. 当前真实状态（2026-10-21 核实）

### 1.1 已完成

| 里程碑 | 状态 | 关键证据 |
| --- | --- | --- |
| Core-0 切轨 | ✅ | 源身份 `diguo`→`dsd`；源列表由引擎清单驱动；删除 `ENGINE_ROUTE`；Go 退出 CI / 构建脚本 / 打包要求 |
| Core-1 运行时内核 | ✅ | `guo-engine-core` 单例；磁盘 `sessions.json`；`EngineError` + `EngineFailure`；`request_id` + 取消；进度 Stream；`engine_diagnostics` |
| D4 能力接管 | ✅ | 榜单 / 推荐 / 联想 / 元数据补全由引擎直出（第二十二轮） |
| 诊断页 | ✅ | `/settings/diagnostics`，能力矩阵显式标注不支持项 |

### 1.2 引擎注册的站源（17 个）

红果主源（编译）+ 8 个编译代码源（猫果 / 牛果 / 芽果 / 剧果 / 黄果旧版 / 黄果 AI / 黄果视频）+ 9 条声明式规则（伍果 / 花果 / 饭果 / 观果 / 星果 / 河果 / 网果 / 帝果 `dsd` / 发果）。

黄豆 / 野果 / 皮果不在注册表内，因此在 UI 中自然隐藏；`SourceSite.isKnown` 仍认这些旧 id，历史与档案数据不会报格式错误。

### 1.3 Core-2 已完成部分（第二十三轮）

| 项 | 状态 |
| --- | --- |
| `Media.cookies` / `origin` → `PlaybackPlan.headers` | ✅ 已透传（剧果签名源可用） |
| `PlaybackPlan.source` / `sourceId` / `danmakuId` | ✅ 已补，弹幕门槛成立 |
| 弹幕 | ✅ 引擎按分集返回，Dart 补 60 秒窗口；`capabilities.danmaku` 已打开 |
| 下载索引落盘 | ✅ `<data>/downloads/index.json`，启动恢复，运行中任务重新排队 |
| 离线播放 | ✅ `local_playback` 把已完成任务映射为本地路径 |
| 下载暂停 / 恢复 / 续传 | ✅ 分片边界暂停，续传跳过已完成分片 |
| Go 旧下载索引只读迁移 | ✅ `migrate` 模块，幂等且损坏不拦启动 |
| 批量控制（含版本门控） | ✅ 引擎执行，Dart 按任务归属分流 |
| 封面缓存 | ✅ `<data>/covers/<hash>`，8 MiB 上限，force / clear |
| 预加载 | ✅ 引擎提前 resolve，失败返回 null |
| 重启后下载列表 | ✅ 索引带剧名 / 集号 / 封面，列表不再消失 |

### 1.4 仍在 Go 侧的能力（Core-2 的边界）

`EngineBackedRepository` 仍有 5 个文件直接引用 `NativeRepository`：

| 能力 | 现状 | 归属 |
| --- | --- | --- |
| 下载 / 离线播放 | `delegate.enqueueDownloads` / `downloads` / `localPlayback` / `controlDownloadBatch` | Core-2 |
| 封面缓存 | `delegate.cover` | Core-2 |
| 弹幕 | `delegate.danmaku`，且依赖 `PlaybackPlan.session` / `danmakuId` | Core-2 |
| 预加载 / 投屏准备 | `delegate.preload` / `prepareHandoff` | Core-2 |
| 存储与租约 | `delegate.storage` / `moveDownloads` / `workLease` | Core-2 |
| 站源诊断 | `delegate.sourceStatus` / `startSourceJob` | 暂缓（PLAN §5） |
| 资源设置 | `delegate.resourceSettings` | 暂缓（首发仅直连） |
| LAN | `delegate.lan`，入口已隐藏 | Core-4 删除 |

> `capabilities` 已把这些项如实报告为 `false`，UI 入口隐藏、诊断页可见。
> 也就是说：**当前不会出现「点了才报错」，但也确实还用着 Go 的下载与封面。**

### 1.5 已知外部环境限制

| 事项 | 事实 | 影响 |
| --- | --- | --- |
| 红果推荐接口 | `api5-normal-sinfonlineb.fqnovel.com` 返回 HTTP 200 但**响应体为空** | 推荐流无法在本机在线验证；在线用例断言「必须是可分类的解析/网络错误」 |
| 红果个别播放页 | 缺少 `video_player_info` | 弹幕在线用例对 `parseChanged` 跳过 |
| 剧果详情接口 | `api.huangju.net/dramas/...` 返回 404 | Cookie 透传只能离线验证 |
| 黄果 AI / 视频 | 站点自 2026-10-21 起全部超时 | 只有离线对拍 |
| Android / iOS CI | 仍为 `if: false` | 三端构建未被守护 |

## 2. 目标与非目标

### 2.1 目标

1. **单例运行时**：配置、源注册、会话、缓存、下载、网络、插件全部挂在进程级 `Engine` 上。✅ 已完成
2. **契约正确**：类型化 `EngineError`、request_id、取消、进度流。✅ 已完成
3. **状态可靠**：重启后保留令牌 / Cookie / 目录缓存 / 下载索引；旧 Go 数据可读。⏳ 会话与目录缓存已完成，下载索引待 Core-2
4. **播放与下载闭环**：目录 → 详情 → 播放 → 下载 → 离线播放，全程不依赖 Go。⏳ Core-2
5. **源运行时统一**：非主源代码源最终全部由官方 Wasm 包提供，宿主只做传输与提取。⏳ Core-3
6. **可发布**：三端可构建、可测试、有性能与包体基线。⏳ Core-4

### 2.2 非目标（本阶段不做）

- 剩余站源：黄豆、野果、皮果。
- LAN 设备互联。
- 封面修复、元数据补全、源健康 / 批量扫描。
- 代理 / DNS / CDN 切换与高级网络设置。
- 下载合集、目录迁移、工作租约等高级任务。
- 插件市场与第三方生态扩张（只保证官方源）。
- 红果主源 Wasm 化。

## 3. 目标架构

```text
Flutter UI
  └─ EngineRepository（FRB）
       ├─ 类型化 EngineFailure → EngineException
       ├─ request_id / 取消
       └─ 进度 Stream
            │
            ▼
      Engine（进程级单例，已落地）
       ├─ Config / Paths
       ├─ SourceRegistry
       │    ├─ 红果主源（编译进 Rust）
       │    ├─ 声明式规则（随包）
       │    └─ 官方 Wasm 插件（预装 + 可更新）
       ├─ DiskSourceStore（sessions.json，按 source 命名空间）
       ├─ CatalogCache（catalogs.json，TTL 15 分钟）
       ├─ DownloadScheduler + EventBus
       ├─ HttpTransport（全局单例）
       ├─ CancellationRegistry
       └─ Diagnostics（能力矩阵 / 最近错误 / 计数）
```

### 3.1 边界

| 层 | 负责 | 不负责 |
| --- | --- | --- |
| Dart | UI、本地历史 / 收藏 / 偏好（`LocalStore`） | 网络、解析、会话、媒体 |
| Engine | 源请求、解析、会话、缓存、下载、播放计划、诊断 | 页面状态、文案 |
| 插件 | 站点特有的请求构造与解析 | 传输、限速、存储、提取原语 |

## 4. 里程碑

### Core-0 · 切轨 ✅ 已完成

- 删除 `ENGINE_ROUTE` 与 `EngineRouting`；Dart 只保留 engine-only 仓库。
- 源列表完全由引擎清单驱动；Go-only 源自动隐藏。
- 统一源身份 `diguo` → `dsd`。
- 移除 LAN 入口（底层文件待 Core-4 删除）。
- 移除 Go 构建 / 打包步骤与 CI job。

**验收结果**

- ✅ 全新构建产物不含 Go（构建脚本与打包要求已移除 Go）。
- ✅ 未支持能力在诊断页可见，点击不崩溃。
- ✅ 目录、详情、搜索、分类、取流在 engine-only 下可用。
- ✅ 源清单中不再出现重复「帝果」，Go-only 源不显示。

### Core-1 · 运行时内核 ✅ 已完成

- `Engine` 单例；源实例跨调用复用；插件装卸只重建注册表。
- 磁盘 `SourceStore`：按 `source_id` 命名空间，原子写。
- `EngineError`：`kind` / `source_id` / `request_id` / `retryable` / `http_status`。
- request_id + 取消；进度 Stream。
- 诊断接口；Dart `EngineException` 映射。

**验收结果**

- ✅ 连续两次独立 FRB 调用复用同一个芽果令牌（令牌已落盘，跨重启有效）。
- ✅ 取消目录请求后旧结果返回 `Cancelled`，不覆盖新结果。
- ✅ 重启后会话、目录缓存仍在。
- ✅ UI 能区分「可重试 / 不可重试 / 不支持」（`EngineFailureKind` + `retryable`）。
- ✅ 全部 FRB 函数不再返回 `String` 错误。

### Core-2 · 播放与下载 ✅ 已完成

**目标**：完成首个可发布 engine-only 版本的核心体验，把 `NativeRepository` 从主路径移除。

**范围**

1. **播放会话**：`MediaResult` 增加 `cookies` / `origin`；`PlaybackPlan` 补 `session` 与 `danmakuId`，让弹幕门槛成立。
2. **直连播放**：mp4 / HLS + UA / Referer / Cookie；加密 HLS 的 key 请求带同一组头。
3. **下载引擎**：任务索引落盘（`downloads/index.json`）、暂停 / 恢复 / 重试 / 删除、断点续传、HLS 分片、AES-128、启动后恢复。
4. **离线播放**：下载完成记录映射到本地文件，返回本地 `PlaybackPlan`。
5. **Go 下载索引只读迁移**：保证旧下载可播放。
6. **封面缓存**：引擎侧下载 + 本地缓存，替换 `delegate.cover`。
7. **弹幕接线**：`resolve` 产出 `danmakuId` 后打开 `capabilities.danmaku`。
8. **预加载 / 投屏准备**：`preload` 走引擎，`prepareHandoff` 在 LAN 移除后一并删除。

**验收**

- 真实源「目录 → 详情 → 播放 → 下载 → 杀掉进程 → 重启续传 → 离线播放」在 macOS / Android 通过。
- 剧果的签名 Cookie 能到达播放器。
- 下载进度通过 Stream 推送；暂停 / 恢复状态正确。
- 旧 Go 下载记录迁移后可播放。
- `EngineBackedRepository` 不再引用 `NativeRepository`（除 `native/` 删除前的只读迁移）。

### Core-3 · Wasm 源运行时 🔄 进行中

**目标**：兑现「第一方代码源全部 Wasm」。

**已完成（第二十七轮）**

- WIT v2：`response.headers`（全量头，含 `set-cookie`）、`media.cookies` / `origin`
- 宿主：`fetch` 全量透传响应头；`media_from_wit` 透传播放凭证
- 猫果插件打样：签名、自带 MD5/Base64、`play_list` 解析、白名单约束全部跑通
- 修掉宿主两个缺陷：源标识错乱（`source` 被塞成站点 id）、`Unsupported` 被映射成 `Rule`

**已完成（第二十八轮）**

- 官方插件预装：随包资源 → 插件仓库，只装不覆盖、失败不拦启动
- 打包工具 `pack_component`：组件 → 官方索引格式，强制网络白名单
- 修掉插件 id 撞名、双前缀、「重试」不重取三个缺陷

**已完成（第二十九轮）**

- 芽果插件（登录态存宿主存储，跨实例复用）
- 打包器改为逐插件网络白名单（最小权限）
- 启停 / 回滚不丢会话与下载任务的验收用例

**剩余**

- 剧果 / 牛果 / 黄果三源插件化（牛果需插件自带 AES-128-ECB）
- 工具链：打包、校验、签名、索引生成
- `query.cursor` 的翻页 / 推荐语义
- Pulley 下首屏 P95 相对编译源的基线

- WIT v2：`response` 增加响应头（至少 `set-cookie`）；`media` 增加 `cookies`；增加 `cursor` 支持分页 / 推荐。
- 宿主能力：保留 ADR-12 的 `html-select` / `json-path`；补 `set-cookie` 透传。
- 插件工具链：组件构建、Pulley 预编译、打包、校验、签名、仓库索引。
- 官方插件预装：随包资源安装到插件仓库，可更新 / 回滚。
- 迁移顺序：猫果打样 → 芽果 → 剧果 → 牛果 → 黄果三源。

**验收**

- 7 个代码源全部从插件加载，二进制中不再依赖对应 source crate。
- 启用 / 停用 / 回滚插件不丢失会话与下载任务。
- Pulley 下首屏目录 P95 相对编译源劣化 ≤ 15%。

### Core-4 · 收口

- 删除 `native/`、`lib/data/core_bridge.dart`、Go 构建脚本与 CI job、`ALL_SOURCES` 编译开关。
- 删除 LAN 底层文件（`lib/data/lan/`、`lib/ui/features/lan/`）与相关测试。
- 启用 Android / iOS 构建 job；增加 engine-only 冒烟测试。
- 建立性能 / 包体基线：冷启动、首屏目录 P95、内存、动态库 / 安装包体积。
- 更新 README / ARCHITECTURE / PROGRESS / HANDOFF，移除双栈描述。

**验收**

- 干净 checkout 一条命令构建 macOS / Android / iOS。
- 仓库无 Go 引用；旧数据可读。
- CI 全绿，性能 / 包体基线入库。

## 5. 首发功能矩阵

| 功能 | 首发 | 当前状态 |
| --- | --- | --- |
| 目录 / 搜索 / 详情 / 分类 / 缓存 | ✅ | 已可用 |
| 榜单 / 推荐 / 联想 | ✅ | 已由引擎直出 |
| 直连播放 | ✅ | 已可用（不含 Cookie） |
| 下载 / 断点 / 离线播放 | ✅ | Core-2 |
| 弹幕 | ✅ | Core-2（等 `danmakuId`） |
| 播放画质切换 | ⚠️ 默认画质 | 多线路 / 画质随后补 |
| 其它源 D4 | ❌ | 已隐藏入口 |
| 封面修复 / 元数据补全 | ❌ | 使用源返回封面 |
| 源健康 / 批量扫描 | ❌ | 已隐藏入口 |
| 代理 / DNS / CDN / 高级网络设置 | ❌ | 已隐藏入口，首版仅直连 |
| 下载合集 / 移动下载目录 | ❌ | 基础队列优先 |
| LAN | ❌ | 入口已隐藏，底层待 Core-4 删除 |
| 黄豆 / 野果 / 皮果 | ❌ | 源适配暂停 |

引擎-only 首发可用源：17 个（红果 + 9 条声明式 + 7 个代码源，其中 `diguo` 已统一为 `dsd`）。

## 6. 数据与身份兼容

| 数据 | 迁移策略 | 状态 |
| --- | --- | --- |
| 历史 / 收藏 / 偏好 | 已在 Dart `LocalStore`（SharedPreferences），不依赖 Go | ✅ 继续使用 |
| 旧源身份 `dsd` | Rust 规则 `diguo` 已改名为 `dsd` | ✅ 已完成 |
| 目录缓存 | Rust 已有 `catalogs.json`；与 Go 格式不一致时直接丢弃（TTL 15 分钟） | ✅ 已完成 |
| 下载索引 | Core-2 只读解析 Go `downloads/index.json`，转换为 Rust 任务存储 | ✅ 已完成 |
| LAN 身份 | 不再迁移 | — |
| 插件状态 | 全新体系，无 Go 遗留 | ✅ |

## 7. 风险与缓解

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| 站点结构漂移 | 榜单 / 联想曾因站点改版失效（第二十二轮已修） | 每次改版补真实夹具 + 回归；在线用例单独 job |
| 红果 App 接口不可达 | 推荐流无法验证 | 在线用例断言「可分类错误」；发布前人工复核 |
| 下载持久化 / 移动端后台 | 重启丢任务、后台被杀 | 原子写索引；首版明确前台下载语义 |
| HLS / Cookie 直连覆盖不足 | 个别源无法播放 | 先实测；不通过再做最小播放列表重写 / 本地流服务 |
| Wasm 性能与 ABI | 首屏变慢、插件化返工 | 猫果单源打样；建立 P95 基线 |
| 三端构建未守护 | 发布阻塞 | Core-4 打开 Android / iOS CI；Core-3 起每阶段构建 |
| `NativeRepository` 长期滞留 | 双栈成本回升 | Core-2 以「移除主路径依赖」为硬验收 |

## 8. 验证与质量门槛

每个里程碑均需满足：

- `cargo fmt --all --check`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo test --workspace`
- `flutter test --exclude-tags engine`
- `flutter test --tags engine`（真实站源，非阻断）
- `dart analyze lib test integration_test test_driver` 无 error / warning
- `python3 -m unittest discover -s scripts -p 'test_*.py'`
- 新增状态能力必须有回归：跨调用复用、取消、重启恢复、迁移

**当前基线**（2026-10-21，第二十九轮）：cargo 496 通过；flutter 离线 305 通过 / 1 跳过；engine 在线 54 通过；dart analyze 0 error / 0 warning；scripts 9 通过。

Core-3 起增加：

- 首屏目录 P95（相对 Core-2 编译源基线，劣化 ≤ 15%）
- 冷启动、内存、动态库 / 安装包体积
- Android / macOS 构建冒烟；Core-4 增加 iOS

## 9. 第一批任务（Core-2 开工顺序）

1. ~~**播放会话字段**：`MediaResult` 加 `cookies` / `origin`，`PlaybackPlan` 补来源与 `danmakuId`；打开弹幕能力位。~~ ✅ 第二十三轮
2. ~~**下载索引**：`downloads/index.json` 原子写 + 启动恢复。~~ ✅ 第二十三轮
3. ~~**下载控制**：暂停 / 恢复 / 重试 / 删除；断点续传与 HLS 分片在引擎内闭环。~~ ✅ 第二十四轮（批量控制待迁）
4. ~~**离线播放**：完成记录 → 本地 `PlaybackPlan`。~~ ✅ 第二十三轮
5. ~~**Go 索引只读迁移**：解析旧 `downloads/index.json`，转为新任务表。~~ ✅ 第二十五轮
6. ~~**封面缓存**：引擎下载 + 本地缓存，替换 `delegate.cover`。~~ ✅ 第二十六轮
7. **预加载 / 投屏准备**：`preload` 已走引擎（第二十六轮）；`prepareHandoff` 随 LAN 一起删除。
8. **移除主路径 Go 依赖**：`EngineBackedRepository` 不再持有 `NativeRepository`。

> 顺序建议：1 → 2 → 3 → 4 → 5 → 6 → 7 → 8。第 1 步会触及 `PlaybackPlan`
> 与播放器，应尽早完成，避免后续反复 rebase。

## 10. 未决问题

- 声明式规则是否也迁为官方插件包（当前随包内置）。
- 官方插件签名密钥的生成、保管与预装流程。
- 移动端下载是否需要前台服务 / 后台续传；首版是否只支持前台。
- 直连播放对加密 HLS 的覆盖范围；是否需要最小本地流服务。
- 画质 / 线路切换是否进入首发，还是默认源最高画质。

## 11. 完成定义

满足以下条件视为「核心引擎搭建完成」：

1. App 只运行 Rust 引擎，构建链无 Go。⏳ 构建链已无 Go；运行期仍有下载 / 封面走 Go
2. 首发功能矩阵中的 ✅ 项全部通过真实源验收。⏳ 待 Core-2
3. 令牌 / 会话 / 缓存 / 下载跨重启保留，取消与错误分级可用。⏳ 前三项已完成，下载待 Core-2
4. 7 个第一方代码源全部由 Wasm 插件提供，红果保持编译。⏳ Core-3
5. macOS / Android / iOS 三端可构建、可测试。⏳ Core-4
6. 旧下载记录可读，旧收藏 / 历史不丢。⏳ 收藏 / 历史已不丢；下载待 Core-2
7. CI 全绿，性能与包体基线入库，README / ARCHITECTURE / PROGRESS 与实现一致。⏳ Core-4
