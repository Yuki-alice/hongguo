# 核心引擎重排计划（Engine-only）

> 状态：已定稿，等待执行
> 制定：2026-10-21
> 关联：`docs/ARCHITECTURE.md`（ADR-5c / 7 / 8 / 9 / 11 / 12）、`docs/PROGRESS.md`、`docs/HANDOFF.md`

## 0. 决策记录

2026-10-21 与项目负责人确认：

| 决策 | 结论 |
| --- | --- |
| 站源适配 | **暂停**。黄豆 / 野果 / 皮果不迁移，直到核心引擎完成 |
| 优先级 | 架构与状态正确性优先于功能数量 |
| Go 后端 | **立即停止演进并退出构建与 Dart 调用链**；`native/` 只读留档，Core-4 物理删除 |
| 第一方代码源 | 除红果主源外，**全部改为官方 Wasm 插件** |
| 红果主源 | 保持编译进 Rust（默认源、D4 能力、离线可用、性能敏感） |
| LAN | **不再投入**，移除入口、调用与测试 |
| 首发能力 | 基础浏览与播放、下载与离线播放、红果 D4 |
| 暂缓 | 封面修复、源健康 / 批量扫描、代理 / DNS / CDN 高级设置、下载合集 |

> “立即停用 Go”指工程方向与构建链立即切换。首个可发布 engine-only 版本以
> Core-2 完成为门槛，避免在下载 / 播放未就绪时对外发版。

## 1. 现状缺口

| 问题 | 证据 | 影响 |
| --- | --- | --- |
| 运行时每次调用重建 | `rust/bridge/src/api/mod.rs` 每个 API 都调用 `builtin_registry()` | 令牌 / Cookie / 会话 / 限流 / 健康状态跨调用丢失；芽果每次请求重新登录 |
| 错误契约未类型化 | 所有 FRB 函数仍是 `Result<_, String>`（ADR-8 未落地） | UI 无法区分可重试错误；无法做退避与分级提示 |
| 无取消与进度流 | 没有 request_id / sequence；下载只能轮询快照（ADR-9 未落地） | 切页竞态、无法取消、下载体验受限 |
| 播放链路在 Go | Rust 只有 `resolve`；播放会话、线路、Cookie / 质量由 Go 负责 | 播放无法脱离 Go 验收 |
| Cookie 未进播放计划 | `lib/data/engine_repository.dart` 的 `resolve` 只带 Referer / UA | 剧果等 CDN 签名源无法播放 |
| 下载接入是半套 | 引擎只处理已接管源；批量控制、合集、索引持久化仍走 Go | 双队列、重启丢任务、状态不一致 |
| LAN 完全在 Go | `app_lan.go` / `app_lan_http.go` | 本次决策：不迁移，直接移除 |
| 网络策略在 Go | 代理 / DNS / CDN / 限速均在 `native/core/network_*` | Rust 只有全局 reqwest；首版仅支持直连 |
| 旧数据无法迁移 | 无 `downloads/index.json` 读取；目录缓存格式未对齐 | 切引擎会丢下载记录 |
| 代码源仍编译进二进制 | 猫果 / 牛果 / 剧果 / 芽果 / 黄果三源 | 与“代码源全部 Wasm”的目标架构不一致 |
| WIT 能力不足 | `media` 无 cookies；`response` 无响应头 | 剧果等需要 Set-Cookie 的源无法插件化 |
| 源身份存在重复 | Go / Dart 用 `dsd`，Rust 规则用 `diguo`，指向同一站点 | 引擎源列表会出现两个“帝果”；旧数据引用断链 |
| 源列表仍有 Go-only 项 | Dart `SourceSite` 内置清单包含黄豆 / 野果 / 皮果 / dsd | 停用 Go 后这些入口必然失败 |
| 交付门槛不足 | Android / iOS CI 仍为 `if: false`；无性能 / 包体基线 | “完美核心”无法被证明 |

## 2. 目标与非目标

### 2.1 目标

1. **单例运行时**：配置、源注册、会话、缓存、下载、网络、插件全部挂在进程级 `Engine` 上。
2. **契约正确**：类型化 `EngineError`、request_id、取消、进度流。
3. **状态可靠**：重启后保留令牌 / Cookie / 目录缓存 / 下载索引；旧 Go 数据可读。
4. **播放与下载闭环**：目录 → 详情 → 播放 → 下载 → 离线播放，全程不依赖 Go。
5. **源运行时统一**：非主源代码源最终全部由官方 Wasm 包提供，宿主只做传输与提取。
6. **可发布**：三端可构建、可测试、有性能与包体基线。

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
       ├─ 类型化 EngineError
       ├─ request_id / 取消
       └─ 进度 Stream
            │
            ▼
      Engine（进程级单例）
       ├─ Config / Paths / Feature flags
       ├─ SourceRegistry
       │    ├─ 红果主源（编译进 Rust）
       │    ├─ 声明式规则（随包）
       │    └─ 官方 Wasm 插件（预装 + 可更新）
       ├─ SessionStore（磁盘：令牌 / Cookie / 会话）
       ├─ CatalogCache
       ├─ DownloadScheduler + DownloadStore
       ├─ HttpTransport（全局单例）
       ├─ CancellationRegistry
       ├─ Progress / Event bus
       └─ Diagnostics
```

### 3.1 边界

| 层 | 负责 | 不负责 |
| --- | --- | --- |
| Dart | UI、本地历史 / 收藏 / 偏好（`LocalStore`） | 网络、解析、会话、媒体 |
| Engine | 源请求、解析、会话、缓存、下载、播放计划、诊断 | 页面状态、文案 |
| 插件 | 站点特有的请求构造与解析 | 传输、限速、存储、提取原语 |

### 3.2 源运行时

- **红果主源**：编译进 `guo-source-hongguo`，保留 D4 能力。
- **声明式规则**：迁移期继续随包分发（数据文件，无性能问题）；是否也包成官方插件留待 Core-3 结束前决定。
- **第一方代码源**：猫果、牛果、剧果、芽果、黄果旧版 / AI / 视频，全部打包为官方 Wasm 插件；先做猫果打样。
- **预装策略**：官方插件包随应用资源分发，首次启动安装到插件仓库；之后按仓库更新。

## 4. 里程碑

### Core-0 · 切轨

**目标**：停止双栈，暴露真实缺口，不留下静默回落。

- 删除 `ENGINE_ROUTE` 与 `EngineRouting`；Dart 只保留 engine-only 仓库。
- 移除 `lib/data/core_bridge.dart` 的 Go FFI 路径与 `NativeRepository`。
- `AppRepository` 每个方法：引擎实现，或显式 `Unsupported` + UI 隐藏。
- 源列表改为**完全由引擎清单驱动**；Go-only 源（黄豆 / 野果 / 皮果）自动隐藏。
- **统一源身份**：Rust 规则 `diguo` 改为 `dsd`（名称仍为“帝果”），更新夹具、测试与文档；旧数据以 `dsd:` 前缀继续可用。
- 移除 LAN 入口与相关调用；保留 Dart 本地历史 / 收藏。
- 移除 Go 构建 / 打包步骤；`native/` 只读，不再参与编译。

**验收**

- 全新构建产物不含 Go。
- 未支持能力在诊断页可见，点击不崩溃。
- 目录、详情、搜索、分类、取流在 engine-only 下可用。
- 源清单中不再出现重复“帝果”，Go-only 源不显示。

> 首个可发布版本不在 Core-0 发布，门槛见 Core-2。

### Core-1 · 运行时内核

**目标**：把“状态正确”落到代码里。

- `Engine` 单例：初始化 / 配置 / 关闭；持有注册表、会话、缓存、下载调度、网络、插件。
- 源实例跨调用复用；插件安装 / 卸载后只重建源注册表，不重置会话与任务。
- 磁盘 `SourceStore`：按 `source_id` 命名空间持久化令牌、Cookie、会话与游标；原子写。
- `EngineError`：`kind`（Unsupported / Network / Timeout / Http / ParseChanged / Session / Blocked / Cancelled / Storage / Plugin / Internal）、`source_id`、`request_id`、`retryable`、`http_status`。
- request_id + 取消：目录、详情、搜索、取流、下载；取消后不再回调 UI。
- 进度流：下载进度、长任务状态；替代轮询快照。
- 诊断接口：版本、路径、能力矩阵、插件加载报告、最近错误、请求计数。
- Dart 侧：`EngineException` 映射；删除 `catch (_) => Go` 一类兜底。

**验收**

- 连续两次独立 FRB 调用复用同一个芽果令牌（不是同一个源实例内部复用）。
- 取消目录请求后不再出现旧结果覆盖。
- 重启应用后会话、目录缓存、下载任务仍在。
- UI 能区分“可重试 / 不可重试 / 不支持”。
- 全部 FRB 函数不再返回 `String` 错误。

### Core-2 · 播放与下载

**目标**：完成首个可发布 engine-only 版本的核心体验。

- `PlaybackPlan` 补全：`Cookie`、`Origin`、播放会话、线路 / 画质（按需）；Cookie 必须从 `Media.cookies` 进入播放器请求头。
- 直连播放：mp4 / HLS + UA / Referer / Cookie；加密 HLS 的 key 请求带同一组头。
- 本地流服务仅在直连无法覆盖（Cookie 轮换、鉴权地址、需要重写播放列表）时引入，不默认代理。
- 下载：持久化任务索引、暂停 / 恢复 / 重试 / 删除、断点续传、HLS 分片、AES-128、启动后恢复。
- 离线播放：下载完成记录映射到本地文件，返回本地 `PlaybackPlan`。
- 迁移 Go 的 `downloads/index.json`（只读），保证旧下载可播放。
- 红果 D4 接线：榜单、推荐、联想、弹幕、系列剧从 Rust 直接返回；其它源不显示对应入口。

**验收**

- 真实源「目录 → 详情 → 播放 → 下载 → 杀掉进程 → 重启续传 → 离线播放」在 macOS / Android 通过。
- 剧果的签名 Cookie 能到达播放器。
- 下载进度通过 Stream 推送；暂停 / 恢复状态正确。
- 旧 Go 下载记录迁移后可播放。

### Core-3 · Wasm 源运行时

**目标**：兑现“第一方代码源全部 Wasm”。

- WIT v2：
  - `response` 增加响应头（至少 `set-cookie`）；
  - `media` 增加 `cookies`（或 headers）；
  - 增加 `cursor` 以支持分页 / 推荐；
  - 按需增加 `vip`、`variants`（不在首发强行引入）。
- 宿主能力：保留 ADR-12 的 `html-select` / `json-path`；补 `set-cookie` 透传；crypto 由插件自带（首版）。
- 插件工具链：组件构建、Pulley 预编译、打包、校验、签名、仓库索引；`pack_rules` 扩展为通用打包器。
- 官方插件预装：随包资源安装到插件仓库，可更新 / 回滚。
- 迁移顺序：猫果打样 → 芽果 → 剧果 → 牛果 → 黄果三源；每源复用现有夹具与在线用例。
- 红果保持编译；声明式规则暂随包。

**验收**

- 7 个代码源全部从插件加载，二进制中不再依赖对应 source crate。
- 启用 / 停用 / 回滚插件不丢失会话与下载任务。
- Pulley 下首屏目录 P95 相对编译源劣化 ≤ 15%。
- macOS / Android / iOS 三端构建与加载通过。

### Core-4 · 收口

**目标**：删除 Go 与双栈遗留，建立可发布基线。

- Go 数据迁移：`catalogs.json`（尽力而为）、`downloads/index.json`（必须）。
- 删除 `native/`、`lib/data/core_bridge.dart`、Go 构建脚本与 CI job、`ALL_SOURCES` 编译开关。
- 启用 Android / iOS 构建 job；增加 engine-only 冒烟测试。
- 建立性能 / 包体基线：冷启动、首屏目录 P95、内存、动态库 / 安装包体积。
- 更新 README / ARCHITECTURE / PROGRESS / HANDOFF，移除双栈描述。

**验收**

- 干净 checkout 一条命令构建 macOS / Android / iOS。
- 仓库无 Go 引用；旧数据可读。
- CI 全绿，性能 / 包体基线入库。

## 5. 首发功能矩阵

| 功能 | 首发 | 说明 |
| --- | --- | --- |
| 目录 / 搜索 / 详情 / 分类 / 缓存 | ✅ | 引擎现有能力 |
| 直连播放 | ✅ | 带 UA / Referer / Cookie |
| 下载 / 断点 / 离线播放 | ✅ | Core-2 |
| 红果 D4（榜单 / 推荐 / 联想 / 弹幕 / 系列剧） | ✅ | Rust 已实现，补 Dart 接线 |
| 播放画质切换 | ⚠️ 默认画质 | 多线路 / 画质随后补 |
| 其它源 D4 | ❌ | 隐藏入口 |
| 封面修复 / 元数据补全 | ❌ | 使用源返回封面 |
| 源健康 / 批量扫描 | ❌ | 隐藏入口 |
| 代理 / DNS / CDN / 高级网络设置 | ❌ | 首版仅直连 |
| 下载合集 / 移动下载目录 | ❌ | 基础队列优先 |
| LAN | ❌ | 移除 |
| 黄豆 / 野果 / 皮果 | ❌ | 源适配暂停 |

引擎-only 首发可用源：17 个（红果 + 9 条声明式 + 7 个代码源，其中 `diguo` 统一为 `dsd`）。

## 6. 数据与身份兼容

| 数据 | 迁移策略 |
| --- | --- |
| 历史 / 收藏 / 偏好 | 已在 Dart `LocalStore`（SharedPreferences），不依赖 Go；继续使用 |
| 旧源身份 `dsd` | Rust 规则 `diguo` 重命名为 `dsd`，保证 `dsd:<id>` 主键与旧数据一致 |
| 目录缓存 | Rust 已有 `catalogs.json`；与 Go 格式不一致时直接丢弃（TTL 15 分钟，代价低） |
| 下载索引 | Core-2 只读解析 Go `downloads/index.json`，转换为 Rust 任务存储 |
| LAN 身份 | 不再迁移 |
| 插件状态 | 全新体系，无 Go 遗留 |

## 7. 风险与缓解

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| 无 Go 兜底 | 边界场景直接暴露 | 功能门控 + 诊断页 + 首发门槛放在 Core-2 |
| HLS / Cookie 直连覆盖不足 | 个别源无法播放 | 先实测；不通过再做最小播放列表重写 / 本地流服务 |
| Wasm 性能与 ABI | 首屏变慢、插件化返工 | 猫果单源打样；建立 P95 基线；宿主提取原语 |
| 下载持久化 / 移动端后台 | 重启丢任务、后台被杀 | 原子写索引；首版明确前台下载语义 |
| 红果 D4 接线遗漏 | UI 功能回退 | Core-2 验收包含五项能力 |
| 源身份不一致 | 旧数据断链、重复入口 | Core-0 先统一 `dsd`，源列表由引擎驱动 |
| 三端构建未守护 | 发布阻塞 | Core-4 打开 Android / iOS CI；Core-3 起每阶段构建 |

## 8. 验证与质量门槛

每个里程碑均需满足：

- `cargo fmt --all --check`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo test --workspace`
- `flutter test --exclude-tags engine`
- `dart analyze` 无 error / warning
- 真实站源用例（`--ignored`）在对应阶段手动执行并记录结果
- 新增状态能力必须有回归：跨调用复用、取消、重启恢复、迁移

Core-3 起增加：

- 首屏目录 P95（相对 Core-2 编译源基线，劣化 ≤ 15%）
- 冷启动、内存、动态库 / 安装包体积
- Android / macOS 构建冒烟；Core-4 增加 iOS

## 9. 第一批任务（建议立即开工）

1. **源身份统一**：`rust/rules/diguo.json` 的 `id` 改为 `dsd`，同步 `real_sites.rs` / `builtin.rs` / 文档；确认 Dart 源列表与旧数据主键一致。
2. **源列表引擎驱动**：停用 Dart 静态 `builtins` 的可用性判断，Go-only 源不再显示。
3. **Engine 单例**：新增运行时装配（配置、注册表、存储、缓存、调度、插件），所有 FRB API 改用它。
4. **EngineError**：定义类型化错误并替换全部 `Result<_, String>`；生成 Dart 绑定与异常映射。
5. **磁盘 SourceStore**：先落令牌 / Cookie；用芽果做「两次独立 FRB 调用只登录一次」的回归。
6. **取消 + 进度**：request_id / cancel；下载进度 Stream。
7. **Dart engine-only 仓库**：删除 Go FFI 与路由开关，补功能门控与诊断页。

> 顺序建议：1 → 2 → 3/4 并行 → 5 → 6 → 7。`EngineError` 会触及所有 API，应尽早完成，避免后续改动反复 rebase。

## 10. 未决问题

- 声明式规则是否也迁为官方插件包（当前随包内置）。
- 官方插件签名密钥的生成、保管与预装流程。
- 移动端下载是否需要前台服务 / 后台续传；首版是否只支持前台。
- 直连播放对加密 HLS 的覆盖范围；是否需要最小本地流服务。
- 画质 / 线路切换是否进入首发，还是默认源最高画质。
- 诊断页是否首发，还是先用日志与设置页占位。

## 11. 完成定义

满足以下条件视为“核心引擎搭建完成”：

1. App 只运行 Rust 引擎，构建链无 Go。
2. 首发功能矩阵中的 ✅ 项全部通过真实源验收。
3. 令牌 / 会话 / 缓存 / 下载跨重启保留，取消与错误分级可用。
4. 7 个第一方代码源全部由 Wasm 插件提供，红果保持编译。
5. macOS / Android / iOS 三端可构建、可测试。
6. 旧下载记录可读，旧收藏 / 历史不丢。
7. CI 全绿，性能与包体基线入库，README / ARCHITECTURE / PROGRESS 与实现一致。
