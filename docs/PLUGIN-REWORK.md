# 插件系统重构规划——官方仓库化与 Kazumi 式更新体系

> 制定：2026-10-24 · 状态：**设计稿（待评审）**
> 关联：`docs/ARCHITECTURE.md` §7（插件系统现状）、`docs/PLUGIN-BOUNDARY.md`（迁移清单）、
> `docs/PLAN.md` §3 P0（消除双轨）
> 本文是对 PLUGIN-BOUNDARY §4 迁移清单的**上位规划**：把「随包预装 + 双轨编译源」
> 收口成「红果内置 + 独立官方仓库按需安装 + 仓库独立更新」的 Kazumi 式发布模型。
> 实施完成后按惯例回写 ARCHITECTURE / PLAN / PLUGIN-BOUNDARY。

## 0. 一句话

**App 发版只带红果主源；其余 16 个源全部住进独立维护的官方插件仓库，
用户按需安装，App 与仓库各自发版、互不等待；App 能感知并引导安装仓库更新。**

评价先行：本项目的插件**基础设施**（包格式 / 校验 / 原子安装 / 沙箱 / 签名 / 回滚）
已比 Kazumi 完整，真正的缺口在**仓库运营层**（官方仓库还不存在）与**更新体验层**
（自动检查 / 一键更新 / 引导），以及最大的技术债——**双轨制**。

## 1. 现状评价（2026-10-24 依据代码核实）

### 1.1 已有资产：地基完成了 80%

| 能力 | 实现位置 | 状态 | Kazumi 对应物 |
| --- | --- | --- | --- |
| 包格式（`plugin.toml` spec=1，api.level，declarative/component 双形态） | `rust/crates/plugin-host/src/manifest.rs` | ✅ | JSON 规则（无清单概念） |
| zip + 逐包 SHA-256 + 解包限额（8/32 MiB、512 条目） | `plugin-host/src/package.rs` | ✅ | **无**（裸 JSON，不校验） |
| 原子安装（staging→rename）、审计日志、多版本保留、回滚 | `plugin-host/src/store.rs` | ✅ | **无**（覆盖写单文件） |
| 仓库协议 `repo.toml` + `index.json`，**字段名刻意与 Kazumi 同构**（`minHost`/`lastUpdate` 别名） | `plugin-host/src/repository.rs:102-125` | ✅ | `index.json` 数组 |
| Ed25519 索引签名 + TOFU 指纹记录（`repos.json`） | `repository.rs:204-213`、`store.rs:84-96` | ✅ 协议有、**UI 未接** | **无** |
| Wasm 组件沙箱（域名白名单 / 存储命名空间 / fuel / 无 wasi） | `rust/crates/plugin-wasm/` | ✅ | 规则无沙箱（声明式天然安全） |
| 完整网络安装链路（拉清单→索引→包→校验→落盘） | `rust/bridge/src/api/plugins.rs:246-347` | ✅ | ✅ |
| 启停 / 卸载 / 重载注册表且不丢会话与下载 | `api/plugins.rs`、Core-1 验收 | ✅ | ✅（启停排序） |
| 打包器（组件 + 规则） | `plugin-host/src/bin/pack_{component,rules}.rs` | ✅ | 无（人工提交 JSON） |
| 管理页（搜索 / 全部·可更新筛选 / 安装 / 更新 / 卸载 / 启停） | `lib/ui/features/plugins/` | ⚠️ 雏形 | 功能更全（见 §1.2） |

### 1.2 差距清单（按严重度）

| # | 差距 | 证据 | 后果 |
| --- | --- | --- | --- |
| G1 | **双轨制**：5 个 crate（猫果/牛果/芽果/剧果/黄果三源）编译版与插件版并存；9 条声明式规则 `include_str!` 进二进制 | `rust/crates/source-*`、`rust/rules/*.json` | 站源改一行要发 App 版本——正是本重构要消除的痛点 |
| G2 | **官方仓库不存在**：UI 默认地址指向 `guoapp-rules/repo`（GitHub 上未见此仓库），PLUGIN-BOUNDARY 的 `hoshi-plugins` 待建，两处命名还不一致 | `plugins_screen.dart:28`、`PLUGIN-BOUNDARY.md` §1 | 「按需安装」没有安装来源 |
| G3 | **无默认仓库概念**：仓库 URL 只活在 `TextEditingController` 里，不持久化、不预置；`repos.json` 支持多仓库但既无多仓库 API 也无 UI | `plugins_screen.dart:27-29` | 每次进页面重新填地址 |
| G4 | **无自动检查更新 / 一键更新**：`hasUpdate` 仅在手动「载入仓库」后对单条生效（注释自述此缺陷）；无启动检查、无批量更新 | `plugins_controller.dart:30-39` | 用户感知不到源已修复 |
| G5 | **更新体验缺环**：changelog 字段不展示；`minHost`/api 不满足时 UI 无「请升级 App」提示（引擎 `precheck_entry` 已拒绝）；回滚有 API 无入口（菜单只有卸载，`plugins_screen.dart:341-347`）；TOFU 指纹变化无确认弹层 | 各处 | 安全与信任机制形同虚设 |
| G6 | **大陆可达性未设计**：默认 URL 是 `raw.githubusercontent.com`（大陆基本不可达），无镜像机制 | `plugins_screen.dart:28` | 目标用户（短剧受众，以大陆为主）装不上源 |
| G7 | **首启无引导**：新装用户只有红果，没有「去仓库添加更多源」的指引 | — | Kazumi 有首启向导补位 |
| G8 | 硬编码与语义分叉：控制器写死 `repoId: 'official'`、`repoSigned: false`；Dart `_compareVersion` 与引擎 semver 语义不一致 | `plugins_controller.dart:82`、`plugin_repository.dart:149` | 未签名仓库被标成已签名的反例路径 |

### 1.3 总评

方向选对了（索引字段同构 Kazumi、安装链路全走引擎校验、TOFU/签名协议齐备），
且若干设计**强于** Kazumi（哈希校验、原子安装、回滚、能力位门控、Wasm 沙箱）。
当前是「三明治」状态：底层（plugin-host/plugin-wasm）和顶层（管理页骨架）都在，
**中间的仓库运营与更新闭环是空的**。重构不是推倒重来，是补中间层 + 拆双轨。

## 2. 对标 Kazumi：借鉴什么、不借鉴什么

Kazumi 模式（[官方文档](https://kazumi.app/docs/rules/introduce-rules)、
[规则仓库](https://github.com/Predidit/KazumiRules)）核心是三件事：
**App 零内置规则**、**社区仓库 + CI 生成 index.json + 大陆镜像默认启用**、
**启动自动检查更新 + 一键更新全部**。逐项对照：

| Kazumi 设计 | 本项目决策 | 理由 |
| --- | --- | --- |
| App 零内置规则，首启向导引导添加 | **红果主源编译内置**（不变），其余源仓库化，首启轻引导 | 红果是产品默认源，须离线可用、性能敏感、D4 能力（榜单/推荐/弹幕）随引擎演进（PLAN §0 已决策） |
| 规则 = 纯 JSON（XPath / JSONPath 可视化编辑） | **双形态保留**：声明式规则（`pack_rules` 打包）+ Wasm 组件 | 猫果签名、牛果 AES 解密等逻辑 JSON 表达不了；已有 WIT v2 契约与沙箱 |
| index.json 由仓库 CI 自动生成，贡献者只提交规则 | **照抄**：官方仓库 CI 打包 + 生成索引 + 签名 | 人写索引必然漂移（哈希/大小/版本） |
| `index.json` 字段：name/version("1.5" 宽松)/author/lastUpdate | 保留现有更严格式（semver + sha256 + kind + api + minHost），**新增可选 `status` 字段** | 宽松版本无法比较先后；哈希与宿主版本门控是本项目优势 |
| 规则仓库镜像默认启用（大陆） | **照抄**：默认仓库地址内置 + 镜像回退链 | `raw.githubusercontent.com` 在大陆不可达，这是硬前提 |
| 启动自动检查更新（默认开）+ 一键更新全部 + 单条检查 | **照抄，但自动更新默认关**：启动只**提示**，安装须用户确认 | 我们有 Wasm 代码插件（Kazumi 规则无代码），静默换代码的信任门槛更高；单个包 ≤100 KB，确认成本可忽略 |
| 剪贴板 `kazumi://` 链接分享 / 本地文件导入 / 可视化规则编辑器 | 后置（Phase D）：`hoshi://` 链接 + 文件导入 UI（字节安装 API 已有）；编辑器不做 | 现阶段只保证官方源（ARCHITECTURE 非目标）；声明式 DSL 复杂度高，编辑器投入产出比低 |
| 规则排序（拖动）决定搜索优先级 | **不借鉴** | 站源选择已有独立交互（源切换按能力位驱动），引入排序会与「源清单由引擎注册表唯一驱动」冲突 |
| WebDAV 同步观看记录 / 收藏 | 不在本文范围 | 那是用户数据同步，与插件体系正交（可另立项） |

## 3. 目标架构

### 3.1 发布模型：三方各自发版

```text
┌─ hoshi（本仓库，App 发版）───────────────────┐
│  Flutter UI + Rust 引擎 + plugin-host/plugin-wasm │  ← 宿主能力随 App 更新
│  source-hongguo（唯一编译源）                     │
│  内置默认仓库地址 + 公钥（见 ADR-15/16）           │
└──────────────────────────────────────────────┘
                │ repo.toml / index.json(.sig) / plugins/**.zip
                ▼
┌─ hoshi-plugins（独立仓库，随时发版）───────────┐
│  rules/*.json            声明式规则源            │
│  plugins/<id>/           Wasm 组件插件源码        │
│  fixtures/               站源对拍夹具            │
│  CI：build → pack → index.json → sign → publish  │
│  发布通道：GitHub Release / gh-pages + 镜像       │
└──────────────────────────────────────────────┘
                │ 首启预置 / 按需安装 / 更新检查
                ▼
┌─ 设备（<app support>/engine/plugins/）────────┐
│  installed/<id>/<version>/    装过即离线可用      │
│  state.json / repos.json / install.log          │
└──────────────────────────────────────────────┘
```

铁律不变：插件只依赖 `source-api` 契约；宿主不依赖任何站源 crate
（PLUGIN-BOUNDARY §2）。仓库更新插件 ≠ 更新 App；App 升级引擎后旧插件凭
`api.level <= 1` 门控继续可用，新插件要求更高 api 时老 App 明确报「请升级应用」。

### 3.2 官方仓库 `hoshi-plugins` 设计

统一命名（修 G2）：仓库定名 **`hoshi-plugins`**，GitHub org 随发版主体定，
`repo.toml` 里 `id = "official"` 作为机器标识（与控制器现状恰好一致）。

```text
hoshi-plugins/
├── repo.toml                 # spec=1, id="official", index="index.json",
│                             # public_key="ed25519:…"（见 ADR-14）
├── index.json                # CI 生成，禁止手改（同 KazumiRules 约定）
├── index.json.sig            # CI 用私钥签 index.json 原始字节
├── plugins/
│   ├── guo.maoguo/           # 组件插件源码（自 rust/examples/plugins/ 迁入）
│   │   ├── Cargo.toml        #   独立 workspace，只依赖 source-api
│   │   └── src/…
│   └── …
├── rules/
│   ├── wuguo.json            # 声明式规则（自 rust/rules/ 迁入）
│   └── …
├── dist/                     # CI 产物（或挂 Release assets）：
│                             #   plugins/<id>/<id>-<ver>.zip + 打包后的规则包
├── fixtures/                 # 对拍夹具（自各 source crate tests/ 迁入）
└── .github/workflows/
    ├── ci.yml                # 插件单测 + 与 fixtures 对拍
    └── release.yml           # 打包 → 生成 index.json → 签名 → 发布
```

CI 关键步骤（`release.yml`）：

1. `cargo build --target wasm32-unknown-unknown`（Pulley 字节码，ADR-11）；
2. 逐插件 `pack_component --plugin <wasm> --network <hosts>`（白名单逐插件声明，
   PLUGIN-BOUNDARY §3.1 约束 2）；规则批量 `pack_rules`；
3. 计算 `sha256`/`size`，汇入 `index.json`（字段沿用 `RepoIndexEntry`：
   id/name/version/kind/api/minHost/author/updatedAt/size/sha256/path/changelog，
   新增可选 `status: "ok" | "broken" | "deprecated"`，serde default 向后兼容）；
4. Ed25519 私钥（GitHub Secret）签 `index.json` 原始字节 → `index.json.sig`；
5. 发布到 gh-pages 分支（`raw.githubusercontent.com` 直读）+ Release assets
   （供镜像与 CDN 回源）。

**发布纪律**（写进仓库 CONTRIBUTING）：改插件只提 PR 到插件源码，版本号 semver
递增；`index.json`/`dist/` 由 CI 全量再生，PR 里出现手改即拒。

### 3.3 镜像与可达性（修 G6）

默认仓库地址内置为**回退链**而非单地址，Dart 侧按序尝试，全部失败才报错：

```text
1. https://raw.githubusercontent.com/<org>/hoshi-plugins/gh-pages/repo.toml   （源站）
2. https://cdn.jsdelivr.net/gh/<org>/hoshi-plugins@gh-pages/repo.toml         （jsDelivr）
3. https://<gh-proxy 前缀>/https://raw.githubusercontent.com/…/repo.toml      （自建/公益代理）
```

- 设置页提供「仓库镜像」开关与手动选择（参照 Kazumi「规则仓库镜像」，默认**自动**：
  首个成功的地址记入 `repos.json` 的 `url`，下次优先）；
- `RepoClient` 已按「repo.toml 地址 → 相对路径」解析，镜像只需替换基地址，
  引擎协议零改动；
- 尊重现有节流与超时（`EngineConfig`），回退尝试总预算 ≤ 10 s。

### 3.4 App 侧接线（修 G3/G7/G8）

| 变更 | 位置 | 内容 |
| --- | --- | --- |
| 默认仓库常量 | 新 `lib/data/default_repo.dart` | 回退链地址 + 官方公钥指纹（与仓库 `repo.toml` 对齐） |
| 仓库持久化 | `plugin_repository.dart` + 引擎 `repos.json` | 启动时确保 `official` 仓库在册（`remember_repository`）；设置页可增删第三方仓库 |
| 预装收缩 | `lib/data/bundled_plugins.dart`、`assets/bundled_plugins/` | Phase C 清空随包 zip；`BundledPlugins.load` 保留接口返回空（向后兼容启动装配 `main.dart:132`） |
| 去硬编码 | `plugins_controller.dart:82`、`plugin_repository.dart:149` | `repoId`/`repoSigned` 由仓库清单回填（桥接层 `install_from_repo` 已用 manifest 纠正 repo_id，Dart 侧同步） |
| 版本比较统一 | `plugins_controller.dart:160` | 删除 Dart `_compareVersion`，一律走引擎 semver（新 API，见 §5） |
| 首启引导 | `discover_view.dart` 或插件页空态 | 已装源数 ≤ 1 时展示「添加更多站源」卡片，一键跳插件页并预载官方仓库 |

### 3.5 更新数据流

```text
启动完成 ──(延迟 10 s, 距上次检查 ≥ 24 h)──▶ check_updates(official)
   │                                              │ 引擎：拉 repo.toml+index(.sig 验签)
   │                                              │ 对比 installed/ 与索引（semver + minHost/api）
   ▼                                              ▼
UI 徽标「N 个可更新」 ──用户点开──▶ 更新面板（changelog / 状态 / 需升级 App 的置灰）
   │ 一键更新 / 单条更新
   ▼
update_plugins(ids) ──▶ 逐条 install_from_repo（staging 原子安装，失败自动保持旧版本）
   │ 完成后 reload_sources + syncSourceCatalog（源清单刷新，会话/下载不动）
   ▼
结果汇总：成功 N / 失败 M（失败项保留旧版本并可查看原因）
```

自动**检查**默认开（成本 = 一次 index.json 请求，几 KB）；自动**安装**默认关
（ADR-17）。指纹变化（`remember_repository` 返回 true）时：拒绝本次更新，
弹层要求用户确认新指纹，确认后才放行（修 G5 的 TOFU 环节）。

## 4. 分阶段实施

### Phase A · 建仓与默认仓库接线（先行，不动 App 行为）

| # | 任务 | 涉及 |
| --- | --- | --- |
| A1 | 建 `hoshi-plugins` 仓库：迁入 `rust/examples/plugins/*`、`rust/rules/*.json`、各源 fixtures | 新仓库 |
| A2 | CI：ci.yml（测试+对拍）、release.yml（打包→index→签名→发布 gh-pages） | 新仓库 |
| A3 | 生成 Ed25519 密钥对：公钥入 `repo.toml` 与 App 常量，私钥入 GitHub Secret | 双仓 |
| A4 | App 默认仓库常量 + 镜像回退链 + 启动 `remember_repository("official")` | `lib/data/default_repo.dart`、`plugin_repository.dart` |
| A5 | 去硬编码 G8、统一命名（UI 默认地址改指 `hoshi-plugins`） | `plugins_screen.dart:28` 等 |

**验收**：真机冷启动后，插件页自动列出官方仓库可装条目；断网直连 GitHub 的环境下
走镜像仍可完成「载入仓库 + 安装 + 源出现在清单」。

### Phase B · 更新闭环

| # | 任务 | 涉及 |
| --- | --- | --- |
| B1 | 引擎新增 `check_updates` / `update_plugins` / `list_repositories` / `remove_repository`（§5） | `rust/bridge/src/api/plugins.rs`、`plugin-host` |
| B2 | `RepoIndexEntry` 增加可选 `status` 字段；`PluginSummary` 带上 `minHostOk`/`changelog` | `repository.rs`、FRB DTO |
| B3 | 启动后台检查（延迟 + 24 h 节流 + 静默失败），设置项「自动检查更新」「自动安装」 | `main.dart`、设置页 |
| B4 | 更新面板 UI：一键更新 / 单条更新 / changelog / 「需升级 App」置灰 / 失败重试 | `plugins_screen.dart`、controller |
| B5 | 已装卡片菜单补「回滚到 vN」（API 已有 `rollback_plugin`）；TOFU 指纹变化确认弹层 | `plugins_screen.dart` |

**验收**：装 1.0.0 → 仓库发 1.1.0 → 启动出徽标 → 一键更新成功且源会话/下载不丢；
仓库推一个 `minHost` 高于当前 App 版本的条目 → UI 置灰并提示升级；
篡改索引 → 验签失败并提示。

### Phase C · 双轨收敛（PLUGIN-BOUNDARY §4 执行）

| # | 任务 | 涉及 |
| --- | --- | --- |
| C1 | `assets/bundled_plugins/` 清空（老设备已装件在 `installed/` 本地保留，不受影响） | assets、`bundled_plugins.dart` |
| C2 | 9 条规则迁出二进制：删 `include_str!` 与随包注册，规则以插件包形态只存在于仓库 | `rust/crates/engine`、`rust/rules/` |
| C3 | 删 `source-maoguo/niuguo/yaguo/huangju/huangguo` 5 个 crate + `register_builtin_sources` 注册行 + `bridge` 依赖 | `rust/crates/`、`rust/bridge/Cargo.toml` |
| C4 | 首启引导卡片（§3.4）；源清单空态文案 | `discover_view.dart`、`sources_screen.dart` |

**验收**：`rust/crates/` 只剩 `source-hongguo`；`cargo test --workspace` 与
`flutter test` 全绿；**存量设备**源清单不缩水（16 个非红果源已装于本地）；
**全新设备**清单 = 红果 + 用户自装；从仓库可一次装回全部官方源。

### Phase D · 体验增强（可选，按需排期）

- `hoshi://` 规则分享链接 + 剪贴板/本地文件导入 UI（`install_plugin` 字节通道现成）；
- 多仓库管理 UI（`repos.json` 本就多条目；对齐 Kazumi 社区诉求 issue #2485）；
- 插件更新后的源健康抽查（`source_health` API 已在，badge 标注「更新后异常可回滚」）；
- beta 通道（同仓库 `index-beta.json` 或独立 repo，协议无需改）。

## 5. API 变更清单（FRB 边界）

新增 4 个函数，全部走引擎（校验唯一真相，Dart 不自行比较版本）：

```rust
/// 检查仓库更新：已装 vs 索引（semver + minHost + api 三重门控）。
/// 返回每条：id / 本地版本 / 远端版本 / changelog / min_host_ok / status。
pub async fn check_updates(repo_url: String) -> Result<Vec<PluginUpdate>, EngineFailure>;

/// 批量更新：逐条走 install_from_repo（原子、失败保旧版），返回汇总报告。
pub async fn update_plugins(
    repo_url: String,
    plugin_ids: Vec<String>,
) -> Result<UpdateReport, EngineFailure>;

/// 已登记仓库列表（读 repos.json，含指纹与最近拉取时间）。
pub fn list_repositories() -> Result<Vec<RepoSummary>, EngineFailure>;

/// 移除一个仓库记录（不动已装插件，仅忘记 URL/指纹）。
pub fn remove_repository(repo_id: String) -> Result<(), EngineFailure>;
```

调整 2 处：`PluginSummary` 增加 `min_host_ok: bool`、`changelog: Option<String>`、
`status: Option<String>`；`parse_repository` 返回值带 `public_key`（已有）供 TOFU 比对。
`repo.toml` / `index.json` / `plugin.toml` 协议**零破坏性变更**（新字段全部可选）。

## 6. 新增决策（ADR-13～17，并入 ARCHITECTURE §3）

| # | 决策 | 理由 |
| --- | --- | --- |
| ADR-13 | 红果主源永久编译内置，不做插件化 | 默认源必须离线可用；D4 能力（榜单/推荐/弹幕）随引擎演进；性能敏感路径不走解释器（重申 PLAN §0，非新决策） |
| ADR-14 | **官方仓库启用 Ed25519 签名**；第三方仓库允许不签（TOFU + 用户逐次确认） | 基础设施已建、成本仅一把密钥；镜像/代理层再多一层也不怕被篡改。私钥轮换 = 换 `public_key` + 全端「签名已变更」弹层公告，作为已知成本接受 |
| ADR-15 | 默认仓库地址与公钥**内置进 App**，用户可在设置覆盖；镜像回退链自动探测 | 修 G2/G3/G6；Kazumi 同款「镜像默认启用」的可达性优先 |
| ADR-16 | 官方仓库索引由 CI 全量生成，禁止手改 | 哈希/大小/版本人工维护必然漂移；KazumiRules 同款纪律 |
| ADR-17 | 启动**自动检查**更新默认开（24 h 节流、静默失败），**自动安装**默认关；版本比较只在引擎侧 | 检查成本几 KB；静默更换 Wasm 代码的信任门槛高于 Kazumi 的纯 JSON 规则；Dart 与 Rust 双份 semver 语义会分叉（G8 教训） |

## 7. 风险与缓解

| 风险 | 缓解 |
| --- | --- |
| GitHub / 镜像同时不可达 | 回退链 + 设置页手动填第三方仓库地址；**已装插件本地完整可用**，仓库失联只影响「装新/更新」，不影响看片 |
| 官方仓库发版把源改坏 | staging 原子安装失败自动保旧版；成功但行为异常 → 回滚菜单（B5）+ `plugin_load_report` 诊断；`status` 字段可把已知坏版本标 `broken`，UI 直接隐藏 |
| 老设备升级 App 后旧插件不兼容 | `api.level`/`minHost` 双门控：旧插件对新宿主向后兼容（WIT 只增字段）；新插件对老宿主明确报「请升级应用」而非装完打不开 |
| 密钥泄露 / 被迫轮换 | ADR-14 已列：换公钥 → 全端 TOFU 弹层 → 官方渠道公告指纹。可接受，不做双公钥过渡 |
| `raw.githubusercontent.com` 被污染 | 逐包 SHA-256 + 索引签名双层校验，镜像只当传输层，不参与信任 |
| 仓库地址硬编码过期 | 地址与公钥进设置可改；大版本迁移时 App 更新覆盖默认值，用户自定义不覆盖 |

## 8. 总验收清单

- [ ] 全新设备：开箱仅红果可用；插件页自动载入官方仓库；装任意源 → 榜单/搜索/播放正常；
- [ ] 存量设备：升级 App 后源清单与会话、下载任务零丢失；
- [ ] 更新：仓库发新版 → 启动 24 h 内出提示 → 一键更新 → 引擎清单刷新；
- [ ] 信任：未签名第三方仓库安装需逐次确认；官方仓库索引被篡改 → 验签拒绝；
      指纹变更 → 弹层阻断；
- [ ] 可达性：大陆网络环境默认回退链可完成安装与更新；
- [ ] 收敛：`rust/crates/` 站源只剩 `source-hongguo`；`assets/bundled_plugins/` 清空；
      `cargo test --workspace` / `flutter test --exclude-tags engine` / `dart analyze` 全绿；
- [ ] 文档回写：ARCHITECTURE §7 三类站源表、PLAN §3 P0、PLUGIN-BOUNDARY 状态行。
