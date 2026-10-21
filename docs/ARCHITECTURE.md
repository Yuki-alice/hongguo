# 真果鉴 Rust 引擎与插件系统架构（2026-10-19 设计）

本文是重写目标架构的**唯一设计基线**。它回答四件事：Rust 引擎怎么分层、规则源怎么与应用分离、
社区插件生态（仓库 / 包格式 / 版本 / 信任）怎么设计、从当前快照迁移要分几步。

现状逐项核对见同目录 `AUDIT.md`。本文中标注「已核实」的内容来自本机源码与依赖实测；
标注「待验证」的内容必须在对应阶段用真实构建或真机确认后才能升级为结论。

---

## 0. 结论摘要

1. **Rust 引擎已经具备可用的骨架，但不是插件系统**：现有「规则」是编译期 `include_str!`
   进二进制的 6 个 JSON，加 1 个 Rust 硬编码签名源；安装、卸载、仓库、签名、版本兼容全部不存在。
   目标架构的第一步不是再写一个源，而是把「规则如何进来」这条路修好。
2. **插件分两类，且共享同一套调度与权限模型**：声明式规则插件（纯数据，宿主执行）与代码插件
   （WebAssembly 组件，WASI Preview 2，插件只做纯函数，网络与存储全部经宿主能力）。
   **两类都在 P1 交付**（D1 已定）：声明式覆盖网页源，代码插件覆盖签名 / 加解密 / 非标准分页。
   iOS 不执行 JIT，代码插件统一走 wasmtime 的 Pulley 解释器目标（见 §9.3），
   插件里只做轻量计算，HTML/JSON 解析留在宿主。
3. **主源（红果）不进插件**：它是随应用编译的官方源，可以调用宿主内部能力（签名、会话游标、
   榜单、弹幕、系列剧），但必须与插件实现同一个 `SourcePlugin` trait，禁止第二条特殊通道。
4. **社区生态对齐 Kazumi 与 Mihon/Komikku 的已验证形态，而不是照抄**：
   仓库根放索引、索引列插件条目、客户端按需下载单个包；官方仓库默认内置、可按需安装；
   第三方仓库由用户添加；包格式采用 zip + 清单 + 逐包 SHA-256，签名可选（D3 已定：不强制）。
   这两家的共同点（「仓库是 HTTP 静态目录」「安装的是带版本的数据/代码包」「客户端校验并缓存」）
   才是要复用的部分。**规则格式不兼容 Kazumi**（D2 已定）：不实现 XPath 方言、不提供导入器，
   插件只认本标准 DSL 与 WASM 组件。
5. **Go 后端整体删除，不做长期双栈**（D5 已定）：Go 只作为迁移期的只读参考与行为规格来源，
   不继续维护、不并行发版；P4 结束时 `native/` 与全部 Go 构建链从仓库移除。
6. **迁移按 4 个可验收阶段推进**，任何阶段结束时都必须保证旧数据可读、构建脚本与
   `sync_source.py` 同步更新、CI 覆盖 Rust 测试。当前快照的 CI 里**没有任何 Rust 步骤**，
   也没有任何 Flutter 步骤会构建 Rust 测试，必须先补。

---

## 1. 现状与约束

### 1.1 已核实的资产与规模

| 项 | 数据 | 说明 |
| --- | --- | --- |
| Go 后端 | 非测试 20,893 行；测试 5,090 行 / 125 个测试函数 | `native/core` 共 128 个文件 |
| Rust 引擎 | 8,831 行（含 1,869 行 FRB 生成代码） | 156 个测试通过（`cargo test --offline`） |
| Flutter 应用 | `lib` 34,122 行；测试 8,185 行 / 177 个用例 | 引擎相关 10 个测试文件 |
| 内置规则 | 6 个 / 827 行 | 伍果、花果、饭果、观果、星果、河果 |
| 代码源 | 1 个 | 猫果（七猫签名接口，572 行） |
| Go 依赖 | `tls-client` + `utls` | 仅黄果视频 / 皮果需要浏览器 TLS 指纹 |
| 构建 | cargokit 已被本地打补丁 | Android / macOS 通过，iOS 受既有 Go 核心缺失阻塞 |
| 仓库状态 | `rust/`、`rust_builder/`、`reference/` 均未被 Git 跟踪 | 当前 `pubspec 0.2.56+62`，README 仍写 `0.2.55+61` |

### 1.2 硬约束

- **端侧完成一切**：请求、解析、播放、下载、合并都在设备上；不引入自建服务端。
- **平台优先级**：Android 手机 = Windows 电脑 > Android TV > iOS。
- **iOS 不允许动态原生库**：插件只能是数据或 WASM；不能走 dylib / JIT。
- **不请求站源图片**做开发验证（既有约定），海报只处理地址。
- **不新建零散 docs**：本文与 `AUDIT.md` 是引擎目录下的设计资料，用户可见说明仍在根 `README.md`。
- **同步脚本白名单**：`scripts/sync_source.py` 的 `SOURCE_DIRECTORIES` 已包含 `rust`，
  新增 crate 目录无需改脚本；但新增**根级**目录必须同步维护。
- **cargokit 只认 `package.name` 与 `manifestDir/src`、`Cargo.toml`、`Cargo.lock`、`build.rs`**。
  工作区化会带来三个真实风险，见 §6.6。
- **Go 只作只读规格来源（D5）**：`native/` 与 `reference/guoapp` 内容完全一致，
  迁移期可以随时查阅、可以复制夹具，但**不接受任何新修复**；Rust 侧不得依赖 Go 产物运行。

### 1.3 生态事实（已抓取核对）

- Kazumi：仓库是 GitHub 静态目录，根放 `index.json`（数组），每条含
  `name / version / useNativePlayer / author / lastUpdate[/antiCrawlerConfig]`；单条规则是
  `<name>.json`，字段为 `api / type / name / version / muliSources / useWebview / useNativePlayer /
  userAgent / baseURL / searchURL / searchList / searchName / searchResult / chapterRoads /
  chapterResult`，XPath 表达式，`api` 是规则级别号（当前 9）。
  `<https://github.com/Predidit/Kazumi>`
- Mihon / Komikku：仓库根 `repo.json` 指向索引（`index.min.json` 或 protobuf），索引条目含
  `name / pkg / apk / lang / code / version / nsfw / sources[]`；扩展以 APK 分发，仓库可带
  `signingKeyFingerprint`。`<https://github.com/keiyoushi/extensions>`
- 我方不采用 APK / 原生代码分发（iOS 不允许、安全面过大），采用 WASM 组件 + JSON 数据。

---

## 2. 设计目标与非目标

### 目标

1. 主源红果的行为可迁移、可回归（目录分页、搜索补漏、详情、取流、弹幕、榜单、推荐、系列剧）。
2. 其余站源**零编译**接入：新增源 = 仓库里多一个 zip；用户按需安装、更新、卸载。
3. 官方仓库内置、开箱可用；第三方仓库可添加；离线可导入单包。
4. 插件不可越权：只能访问声明过的域名与存储命名空间，不能读文件、不能起进程、不能直连网络。
5. 解析、下载、播放共用一条传输链路（限流、重试、冷却、Cookie、代理、指纹策略）。
6. 旧数据（目录缓存、下载索引、追剧 / 历史、局域网身份）升级后仍可读。
7. 引擎可脱离 Flutter 独立测试；Dart 层不感知 Go / Rust 差异。

### 非目标

1. 不复刻 Go 版的 `nativeInput` 巨型 JSON 报文；Dart 侧改为类型化调用。
2. 不追求插件热更新绕过版本检查；不追求运行时加载原生库。
3. 不把 LAN 协议放进插件；局域网互联属于引擎核心服务。
4. 不在本阶段引入服务端、账号体系或云端同步。

---

## 3. 关键决策（ADR）

| 编号 | 决策 | 理由 | 替代方案与否决原因 |
| --- | --- | --- | --- |
| ADR-1 | 插件**必须**是 Wasm 组件或声明式数据，禁止原生库 | iOS 禁止动态库；原生库无法做权限边界 | dylib：iOS 不可行、审核风险 |
| ADR-2 | 代码插件采用 **WASI Preview 2 组件模型**，图灵完备但纯函数 | 标准化、可组合、宿主能力显式注入；运行时可选 wasmtime（Pulley 解释器可跨 iOS） | 自研 ABI：无生态；WASI Preview 1：无接口类型 |
| ADR-3 | 网络、存储、脚本、日志**只经宿主**，插件不链接 `wasi:http` / `wasi:filesystem` | 限流、冷却、代理、指纹、证书校验必须集中 | 直连：绕过限流与 CF 冷却，且无法统一审计 |
| ADR-4 | 声明式规则采用**版本化 JSON 规格**（`spec: 2`），动作化组织 | 现有 `schema 1.0` 已能表达 6 源，但缺会话、权限、签名前置与失败语义 | 直接复用 Kazumi XPath：表达力不足且跨源脆弱 |
| ADR-5 | 仓库是**静态 HTTP 目录**：`repo.toml` + `index.json` + `plugins/<id>/<file>.zip` | 与 Kazumi / Mihon 一致，零运维；可放 GitHub Pages | 自建 API：违背端侧独立目标 |
| ADR-5b | **不兼容 Kazumi 规则**：不实现 XPath 方言、不提供导入器（D2） | Kazumi 规则以页面绝对路径为主、依赖 WebView；维护两套方言会长期拖慢迭代 | 导入器：转换成功率低、失败即静默坏源；兼容层：XPath 依赖已停更的 `sxd-xpath` |
| ADR-5c | **Go 后端整体移除**，不并行发版（D5） | 双栈意味着两套站源实现、两套夹具、两倍回归面，且行为漂移无人负责 | 长期共存：维护成本线性增长 |
| ADR-6 | 完整性两级：**逐包 SHA-256 强制** + **仓库 Ed25519 签名可选**（D3） | 哈希保证包未被篡改；签名作为仓库信任加成，不阻塞第三方仓库 | 强制签名：社区仓库门槛过高、会把绝大多数个人仓库挡在门外 |
| ADR-7 | 主源与插件实现**同一个 trait**，主源可额外声明内部能力 | 防止主源走第二套路径导致插件侧缺能力时无人发现 | 主源独立接口：两套调度长期分叉 |
| ADR-8 | Dart 与引擎之间**不再用字符串错误**，改为结构化 `EngineError` | 现有 21 个 FRB 函数全部 `Result<_, String>`，UI 无法区分可重试 | 保持 String：无法做退避与提示分级 |
| ADR-9 | 请求可取消（`request_id` + `sequence`），进度用 Stream | 对齐 Go 的 `beginRead` 语义；避免切页后旧结果覆盖 | 不可取消：切换站源时浪费流量并产生竞态 |
| ADR-10 | 虚工作区 + 桥接 crate 移到 `rust/bridge/`，包名仍是 `guo_engine` | cargokit 只扫描 `manifestDir` 下的 `src`、`Cargo.toml`、`Cargo.lock`，且按 `package.name` 找产物 | 见 §6.6 的三个具体故障 |
| ADR-11 | 代码插件统一目标为 **Pulley 字节码**（`pulley64`），且**关闭 wasmtime `async` 特性** | iOS 禁止 JIT；Pulley 是 wasmtime 的便携解释器，特性覆盖与 Cranelift 等价、约 10× 慢；关闭 async 可避免 `wasmtime-fiber` 的协程栈（正是 iOS 编译失败源头） | per-OS 双运行时：两条路径、两份测试；开 async：把 fiber 重新引进来 |
| ADR-12 | 宿主向插件提供 `html_select` / `json_path` 提取原语，插件不内嵌解析器 | 重解析留在 Rust 原生侧，抵消 Pulley 约 10× 的解释开销；插件体积与 ABI 也保持稳定 | 让插件自带 HTML/JSON 解析：插件包膨胀、Pulley 下明显变慢 |
| ADR-13 | 规则方言只有 **CSS + `@attr`** 与 **JSONPath** 两种 | 覆盖全部 20 个已知站源；两套方言都成熟、可校验、可在加载期静态检查 | 引入 XPath：依赖 2018 年后停更的 `sxd-xpath`，且无法覆盖 Kazumi 的 WebView 规则 |

---

## 4. 目标架构总览

```text
┌──────────────────────────────────────────────────────────────────────┐
│ Flutter (lib/)                                                       │
│  ui/ ── features/{sources, catalog, detail, player, downloads,       │
│         library, lan, settings}                                      │
│  domain/ ── 用例：CatalogService / PlaybackService / DownloadService │
│  data/ ── EngineRepository (FRB) · LocalStore · Prefs                 │
│  src/rust/ ── 生成绑定 + 模型映射 + EngineError                         │
└───────────────────────────────┬──────────────────────────────────────┘
                                │ flutter_rust_bridge 2.13
┌───────────────────────────────▼──────────────────────────────────────┐
│ guo_engine  (rust/bridge, cdylib/staticlib)                        │
│  - 初始化、配置、目录根、日志                                          │
│  - 类型化 API + EngineError + 取消 / 进度流                            │
└───────────────────────────────┬──────────────────────────────────────┘
┌───────────────────────────────▼──────────────────────────────────────┐
│ guo_engine_runtime  (编排层)                                          │
│  SourceRegistry · PluginManager · RepositoryClient · Scheduler        │
│  CatalogCache · Limits · Sessions · Downloads · StreamServer · LAN    │
└───────┬───────────────┬───────────────┬───────────────┬──────────────┘
        │               │               │               │
┌───────▼──────┐ ┌──────▼───────┐ ┌─────▼──────┐ ┌──────▼─────────────┐
│ source-api   │ │ host         │ │ plugin-    │ │ rule-engine        │
│ trait/模型   │ │ fetch/store/ │ │ wasm       │ │ 声明式 DSL 执行器   │
│ /能力位      │ │ script/log   │ │ (Pulley)   │ │ (CSS / JSONPath)   │
└──────────────┘ └──────────────┘ └────────────┘ └────────────────────┘
        │
┌───────▼──────────────┐   ┌──────────────────┐   ┌──────────────────┐
│ source-hongguo (主源)│   │ 官方声明式插件包  │   │ 官方/第三方代码插件│
│ 随包编译             │   │ (内置仓库按需安装)│   │ (用户添加仓库)     │
└──────────────────────┘   └──────────────────┘   └──────────────────┘
```

数据流（一次目录请求）：

```text
UI → EngineRepository.catalog(source, page, category, requestId)
   → runtime.catalog(): 查缓存(命中且新鲜→返回) → 取 SourceDescriptor
   → plugin(声明式→RuleEngine；代码→WasmHost；主源→rust 实现)
   → host.fetch(): 限流/冷却/代理/Cookie/指纹策略/重定向校验/大小上限
   → 解析为标准 Drama
   → CatalogCache.store(合并 + 游标 + TTL) → 返回
```

---

## 5. 主源（红果）领域建模

红果是唯一随包源，承担基准行为。它的实现必须覆盖 Go 现有语义，且**不暴露给插件作者**的内部能力
（签名、游标、会话）要通过 trait 的默认实现之外的能力声明表达：

```rust
pub trait SourcePlugin: Send + Sync {
    fn descriptor(&self) -> SourceDescriptor;
    fn categories(&self, ctx: &SourceCtx) -> BoxFuture<'_, Result<Vec<Category>, SourceError>>;
    fn catalog(&self, ctx: &SourceCtx, query: CatalogQuery) -> BoxFuture<'_, Result<Page, SourceError>>;
    fn detail(&self, ctx: &SourceCtx, id: &SourceId) -> BoxFuture<'_, Result<Detail, SourceError>>;
    fn search(&self, ctx: &SourceCtx, query: SearchQuery) -> BoxFuture<'_, Result<Page, SourceError>>;
    fn resolve(&self, ctx: &SourceCtx, req: ResolveRequest) -> BoxFuture<'_, Result<Media, SourceError>>;
    // 可选能力，默认 Unsupported，避免 20 个 impl 重复写
    fn suggestions(&self, _: &SourceCtx, _: &str) -> BoxFuture<'_, Result<Vec<String>, SourceError>> { unsupported("suggestions") }
    fn rankings(&self, _: &SourceCtx, _: RankingQuery) -> BoxFuture<'_, Result<RankingPage, SourceError>> { unsupported("rankings") }
    fn recommendations(&self, _: &SourceCtx, _: &str) -> BoxFuture<'_, Result<Page, SourceError>> { unsupported("recommendations") }
    fn danmaku(&self, _: &SourceCtx, _: DanmakuQuery) -> BoxFuture<'_, Result<DanmakuPage, SourceError>> { unsupported("danmaku") }
    fn media_probe(&self, _: &SourceCtx, _: &MediaRef) -> BoxFuture<'_, Result<MediaProbe, SourceError>> { unsupported("media_probe") }
}
```

红果内部拆为五个私有模块（同一 crate 内）：

| 模块 | 职责 | 迁移来源（Go） |
| --- | --- | --- |
| `catalog` | 游标（offset/session/lastId/pageSignature）、三路 genre 并行、增量合流 | `provider_hongguo_catalog.go`、`provider_hongguo_app.go` |
| `sign` | 请求签名、评论签名、设备 ID | `provider_hongguo_sign.go`、`provider_hongguo_comment_sign.go` |
| `detail` | App 详情 + 网页详情回退、分集 | `provider_hongguo_detail.go`、`provider_hongguo.go` |
| `resolve` | App 原生媒体 / 网页播放页 | `provider_hongguo_native_media.go`、`provider_hongguo_playback.go` |
| `discovery` | 榜单、搜索补漏、联想、推荐、系列剧、弹幕 | `provider_rankings_hongguo.go`、`provider_hongguo_search*.go`、`provider_hongguo_suggestions.go`、`provider_hongguo_recommendations.go`、`app_danmaku.go` |

**系列剧与「新季提醒」**当前在 Dart `hongguo_series.dart` 与 `local_store.dart` 里，属于业务规则而非站源解析。
保留在 Dart 域层，但以 `SourceDescriptor.features.series` 声明开关，而不是 `id == 'hongguo'` 判断。

---

## 6. Rust 工作区拓扑

> **2026-10-21 更新**：构建后端已从 cargokit（`rust_builder/` 插件包，含本地补丁）迁移到
> Dart/Flutter 原生资源机制（native-assets）：根目录 `hook/build.dart` 调
> `flutter_rust_bridge_hooks` 在 `flutter build` / `flutter test` 时自动构建并注册代码资产；
> `rust_builder/` 已删除，`rust/rust-toolchain.toml` 钉住工具链与目标平台。
> 本节及 §6.6 中关于 cargokit 的内容转为历史决策记录，保留备查。

### 6.1 结论：虚工作区，桥接 crate 移到 `rust/bridge/`

选择虚清单（`rust/Cargo.toml` 只含 `[workspace]`）而不是「根包 + 工作区」，理由是后者会让
桥接代码与成员 crate 混在一层，且根包模式下 `cargo build` 只构建根包，所有脚本都得加 `-p` / `--workspace`。
虚清单下 `cargo build` 默认构建全部成员，命令语义更稳定。

代价是 cargokit 与 FRB 的路径要跟着改，这两处**必须在 P0 实施时各验证一次构建**：

| 工具 | 现状 | 改后 | 风险 |
| --- | --- | --- | --- |
| cargokit（Android/Windows CMake/podspec） | `manifestDir = ../../engine`，`cargokit { package = "guo_engine" }` | `manifestDir = ../../rust/bridge` | `CrateHash` 只读 `manifestDir/Cargo.lock`，工作区锁在 `rust/Cargo.lock`，哈希会漏掉锁文件变化（仅影响预编译缓存，本项目未启用）；需在构建脚本里显式纳入 |
| FRB codegen | `rust_root: rust/`，`rust_input: crate::api` | `rust_root: rust/bridge/` | 生成路径 `dart_output: lib/src/rust` 不变 |
| FRB 运行时加载 | `stem: guo_engine` | 不变（**包名必须保持 `guo_engine`**） | 改名会同时破坏 podspec、CMake、Gradle 与 Dart 的 `DynamicLibrary.open` |

拆分触发条件（对应 `rust-workspace` 技能的五个判据）：

1. 插件 ABI 必须能**独立版本化**并被第三方引用（`source-api`）；
2. 规则引擎必须能**脱离 wasm 运行时**单独测试与复用（`rule-engine`）；
3. 需要**编译期禁止**反向依赖：`source-api` 不能依赖 `tokio`/`reqwest`/`wasmtime`；
4. iOS / Android 的构建生命周期与测试生命周期不同，需要 `cargo test -p` 精确执行；
5. 插件宿主与运行时演化速度不同，且 `plugin-wasm` 引入 wasmtime 这一重依赖，
   必须能被单独排除在交叉编译之外（见 §6.6 第 3 条）。

### 6.2 目录与 crate

> **实施状态（2026-10-20，第十三轮）**：下方拓扑已按此结构落地，差异只有两处——
> ① 多出 `crates/media`（m3u8 解析与 AES-128 解密，被 rule-engine / runtime / 各代码源共用）；
> ② `SourcePlugin` trait 与 `SourceRegistry` 放在 `source-api` 而不是 `runtime`，
> 因为规则源与组件源都要实现它，放 runtime 会形成反向依赖。
> `edition` 仍为 2021（与 FRB 2.13 生成代码一致），`resolver` 为 2，不是文中的 3/2024。
> `rust-toolchain.toml` 与 `deny.toml` 尚未添加（工具链靠开发者环境，依赖治理待 P2 补）。

```text
rust/
├── Cargo.toml                  # 虚清单：[workspace] only
├── Cargo.lock                  # 工作区共享
├── rust-toolchain.toml         # 锁定 1.97.x（与 POC 一致）
├── deny.toml                   # 依赖治理
├── bridge/                     # 桥接 crate（package name 仍为 guo_engine）
│   ├── Cargo.toml
│   ├── src/
│   │   ├── lib.rs
│   │   ├── api/                # FRB 类型化入口，按域拆文件
│   │   │   ├── catalog.rs detail.rs resolve.rs downloads.rs lan.rs plugins.rs
│   │   ├── error.rs            # EngineError（可序列化）
│   │   └── frb_generated.rs
│   └── tests/                  # 仅桥接层的集成测试
├── crates/
│   ├── source-api/             # 契约：trait、模型、能力、错误（无 IO 依赖）
│   ├── rule-rust/            # 声明式 DSL：schema、模板、CSS/JSON/inline 执行
│   ├── plugin-host/            # 包格式、清单、签名、安装/卸载、仓库客户端
│   ├── plugin-wasm/            # wasmtime + WIT 组件宿主与能力注入
│   ├── host/                   # transport/限流/冷却/代理/Cookie/脚本/存储
│   ├── runtime/                # 注册表、缓存、会话、调度、下载、流服务、LAN
│   └── source-hongguo/         # 主源（唯一随包 rust 源）
├── rules/                      # 迁移期保留；目标为插件包内资源
└── tests/                      # 跨 crate 集成测试与共享夹具
```

根清单：

```toml
# rust/Cargo.toml
[workspace]
resolver = "3"
members = ["bridge", "crates/*"]

[workspace.package]
edition = "2024"
rust-version = "1.97"
version = "0.3.0"

[workspace.dependencies]
reqwest = { version = "0.13", default-features = false, features = ["rustls-tls", "gzip", "brotli", "cookies", "stream"] }
rquickjs = { version = "0.14", features = ["bindgen", "loader"] }
scraper = "0.27"
serde_json_path = "0.7"          # 标准 JSONPath，替换自研子集
wasmtime = { version = "49", default-features = false, features = ["component-model", "cranelift", "runtime", "pulley", "std"] }
# 注意：不要启用 "async"（会拉入 wasmtime-fiber 的协程栈，iOS 编译失败的主因）；
# 插件调用走同步 host 函数 + spawn_blocking，见 §9.3。
ed25519-dalek = "3"
sha2 = "0.11"
```

桥接清单：

```toml
# rust/bridge/Cargo.toml
[package]
name = "guo_engine"               # 不可改：cargokit 与 Dart 加载都依赖它
version = "0.3.0"
edition = "2021"                  # 与 FRB 2.13 生成的代码保持一致

[lib]
crate-type = ["staticlib", "cdylib", "rlib"]

[dependencies]
flutter_rust_bridge = "=2.13.0"
guo-runtime = { path = "../crates/runtime" }
guo-source-api = { path = "../crates/source-api" }
```

> 迁移顺序：先只移动目录、保持 `src/` 内容不变，验证 Android + macOS 构建通过；
> 再开始拆分 crate。不要同时做「移动 + 拆分」，否则构建失败时无法判断原因。

### 6.3 依赖方向

```text
source-api  ←  rule-engine    ←  runtime  ←  bridge
    ↑            plugin-wasm  ↗
    ↑            plugin-host  ↗
    ↑            source-hongguo
    ↑            host（实现 api 中定义的 trait）
```

`source-api` 的 `Cargo.toml` 只允许 `serde` / `thiserror` / `bytes`；出现 `reqwest`、`tokio`、`wasmtime`
即视为越界，用 CI 的 `cargo tree -p guo-source-api` 断言。

### 6.4 命名（D6 未定，以下为占位）

crate 名统一 `guo-` 前缀（kebab-case 目录、下划线包名由 Cargo 自动处理）：
`guo-source-api`、`guo-rule-engine`、`guo-plugin-host`、`guo-plugin-wasm`、`guo-host`、
`guo-runtime`、`guo-source-hongguo`、`guo-engine`（桥接）。

`guo` 是暂用前缀，不是项目定名。正式命名确定后需要一次性替换的位置：

| 位置 | 是否可安全改名 | 备注 |
| --- | --- | --- |
| `crates/guo-*` 目录与 `Cargo.toml` 的 `name` | 可 | 纯内部依赖，改完全仓 `cargo check` 即可 |
| WIT 包名 `guo:source@1.0.0` | **需谨慎** | 已发布插件会绑定旧包名，改名等于破坏 ABI；应在有插件发布前定名 |
| 插件 id 前缀 `guo.*` | **需谨慎** | 已安装插件的目录与 `state.json` 记录都带 id |
| 仓库名 `guoapp-rules` | 可 | 仅是文档示例 |
| 桥接包名 `guo_engine` | **不可随意改** | cargokit 与 `DynamicLibrary.open` 都按它找产物（§6.6 第 2 条） |

**建议**：D6 在 P1 开始前定案，最迟不晚于「首批插件发布」。WIT 包名一旦有外部插件引用，
改名成本远高于现在。

### 6.5 模块布局

每个 crate 用 `src/lib.rs` 作为**薄索引**：只写 `mod` 与定向 `pub use`，禁止 `pub use *`。
测试放 `src/**/tests.rs`（单元）与 crate 级 `tests/`（集成）；跨 crate 夹具放 `tests/support`（dev-dependency）。

### 6.6 cargokit 的三个真实故障点（必须按此设计）

1. **构建哈希不覆盖 `crates/`，也读不到工作区锁文件**：
   `CrateHash.getFiles()` 只遍历 `manifestDir/src`，再追加 `manifestDir/Cargo.toml`、
   `manifestDir/Cargo.lock`、`build.rs`、`cargokit.yaml`。
   桥接 crate 移到 `rust/bridge/` 后，`rust/Cargo.lock` **不在** `manifestDir` 下，
   因此依赖版本变化不会进入哈希；`rust/crates/*` 的源码变化同样不会。
   影响面：`_getPrecompiledArtifacts` 的缓存目录（本项目未启用 precompiled 下载，风险低）；
   真正的问题是**增量构建时 Gradle / CMake 的产物判定**可能沿用旧的 `.so` / `.a`。
   → 对策：桥接 crate 保持极薄（只含 FRB API 与生成代码），逻辑全部在 `crates/`；
   构建脚本在每次构建前 `touch rust/bridge/src/lib.rs`，或直接用
   `cargo build -p guo_engine` 的 fingerprint 判定；CI 做一次「改 crates 后重建，产物 mtime 必须变化」的检查。
2. **产物名取 `package.name`**：`ArtifactProvider.getArtifactNames` 用
   `lib$libraryName.a` / `lib$libraryName.so` / `$libraryName.dll`，`build_pod.dart` 用
   `lib$libName.a`。Dart 侧 `DynamicLibrary.open` 与 podspec 的 `-force_load` 都按这个名字找文件
   （当前 `libguo_engine.so` / `libguo_engine.a`）。
   → 对策：桥接包**继续叫 `guo_engine`**，目录可以变、名字不变；podspec / CMake / Gradle
   的 `libname` 参数与 `output_files` 保持 `libguo_engine.*`。
3. **工作区成员会被 `cargo build` 一并构建，但 cargokit 只取一个产物**：
   虚清单下 `cargo build --manifest-path rust/bridge/Cargo.toml -p guo_engine` 只构建桥接包及其依赖，
   行为正确；但若脚本误用 `cargo build --workspace`，移动端交叉编译会连带构建
   `plugin-wasm`（wasmtime 体积大、iOS 编译慢）。
   → 对策：所有平台脚本显式使用 `-p guo_engine` 与固定 target；CI 校验产物里不含 wasmtime 符号。
   注意 `guo-runtime` 依赖 `plugin-wasm` 是**必需**的（P1 要执行代码插件），
   因此 wasmtime 一定会进最终产物——这里要防的是「重复构建 / 构建错目标」，
   而不是「避免引入」。体积预算见 §9.3。

另外：`rust_builder/cargokit` 已有五处本地补丁（Android 环境变量下划线化、bindgen sysroot、
iOS 模拟器 triple、静态库名、`run_build_tool.sh` 路径）。**这些补丁必须随仓库维护并写入 CI 注释**，
否则换机 / 换 CI 会再次失败。

---

## 7. 插件系统

### 7.1 两类插件

| | 声明式规则插件 | 代码插件（WASM 组件） |
| --- | --- | --- |
| 形态 | `rules/*.json`（1..N 个站点） | `plugin.wasm` + 清单 |
| 能做什么 | Fetch 计划、CSS/JSONPath 提取、模板、签名脚本 | 任意纯函数逻辑（签名、加解密、特殊分页、非标准结构） |
| 适合 | 90% 网页站源、标准 JSON 接口 | 七猫类多签名、牛果类 AES、需要逐字节处理 |
| 安全面 | 只发宿主允许的请求 | 沙箱内计算，无 IO |
| 升级 | 改 JSON | 重新编译 + 版本 |
| 迁移成本 | 低（现有 6 条规则可直接转换） | 中（需 Rust 编写 + wasm 工具链） |
| 交付阶段 | **P1** | **P1**（D1） |

**官方内置仓库首发至少包含 12 个短剧源的声明式包**（芽、猫、饭、观、河、星、花、牛、网、发、皮、伍），
其中猫果若脚本能力足够也用声明式 + JS 签名，只有无法表达时才写代码插件。
代码插件在 P1 与声明式同批交付，用于覆盖「声明式表达不了」的部分：

| 场景 | 代表源 | 为什么必须代码 |
| --- | --- | --- |
| 多套签名 + 请求头 | 猫果 | `qm-params` 字符映射 + 授权签名 + 三个不同 `sign` |
| 响应解密 | 牛果 | 按实际 URI 前 16 字节做 AES-ECB，密钥随参数顺序变化 |
| 播放器参数解码 | 帝果 | `player_aaaa` 变量 + vplayer 的 aaencode |
| 数字签名链路 | 红果（主源）、黄果 | X-Gorgon / X-Argus / X-Ladon 等字节级混淆 |

P1 的代码插件**不替代**声明式：能用 JSON 表达的仍然用 JSON，因为规则可热修、可审阅、可被社区直接改。

### 7.2 核心接口（宿主视角）

```rust
pub struct PluginManifest {
    pub spec: u32,                    // 包格式版本，当前 1
    pub id: PluginId,                 // [a-z0-9][a-z0-9._-]{2,63}
    pub name: String,
    pub version: semver::Version,
    pub kind: PluginKind,             // Declarative { rules: Vec<PathBuf> } | Component { entry: PathBuf }
    pub api: ApiRequirement,          // { level: u32, min_host: Version, max_host: Option<Version> }
    pub permissions: Permissions,     // network hosts / storage namespaces / script budget
    pub description: String,
    pub authors: Vec<String>,
    pub homepage: Option<String>,
    pub license: Option<String>,
}

#[async_trait]
pub trait PluginInstaller {
    async fn fetch_index(&self, repo: &Repository) -> Result<RepositoryIndex, PluginError>;
    async fn install(&self, repo: &Repository, id: &PluginId, version: Option<&Version>) -> Result<InstalledPlugin, PluginError>;
    async fn update(&self, id: &PluginId) -> Result<UpdateOutcome, PluginError>;
    async fn uninstall(&self, id: &PluginId) -> Result<(), PluginError>;
    fn installed(&self) -> Vec<InstalledPlugin>;
}
```

### 7.3 包格式（`spec = 1`）

声明式与代码插件共用同一个 zip 容器，只是内容不同：

```text
<plugin-id>-<version>.zip
├── plugin.toml            # 清单（见下）
├── rules/                 # 声明式插件
│   ├── site-a.json
│   └── site-b.json
├── plugin.wasm            # 代码插件（唯一入口，WASM 组件）
├── assets/
│   └── icon.png           # 可选，≤ 64 KiB
└── LICENSE                # 可选
```

代码插件的 `plugin.wasm` 必须是 **component**（不是 core module），
且只导出 `guo:source/source@1.0.0` 世界、只导入 `guo:source/host@1.0.0`；
打包前用 `wasm-tools component wit` 检查导出与导入，构建脚本自动拦截不合规产物。

```toml
# plugin.toml
spec = 1
id = "guo.fanguo"
name = "饭果"
version = "1.0.0"
kind = "declarative"
api = { level = 1, min_host = "0.3.0" }
description = "西饭短剧搜索接口"
authors = ["community"]
license = "MIT"

[permissions]
network = ["xifan-api-cn.youlishipin.com"]
storage = ["session"]          # 仅命名空间，不是文件路径
script = { timeout_ms = 200, memory_kb = 4096 }

[[rules]]
path = "rules/fanguo.json"
site = "fanguo"
```

```toml
# 代码插件
spec = 1
id = "guo.maoguo"
name = "猫果"
version = "1.0.0"
kind = "component"
entry = "plugin.wasm"
api = { level = 1, min_host = "0.3.0" }

[permissions]
network = ["api-store.qmplaylet.com", "api-read.qmplaylet.com"]
storage = []
```

安装目录：

```text
<data>/engine/plugins/installed/<plugin-id>/<version>/…
<data>/engine/plugins/state.json          # 启用状态、排序、每插件设置、当前版本指针
<data>/engine/plugins/repos.json          # 仓库列表 + 信任指纹 + 最近拉取时间
<data>/engine/plugins/cache/<repo-id>/    # index 快照、图标
```

**安装流程**（全部在设备内）：

1. 拉 `repo.toml` → 校验结构 → 取 `index` 路径与可选的 `public_key`；
2. 首次添加：若仓库带 `public_key`，展示指纹并由用户确认（TOFU）；不带则标记「未签名仓库」，
   用户确认后添加。已信任的仓库若指纹变化，**拒绝并提示**，不自动接受；
3. 拉 `index.json`；仓库声明了公钥时，同时拉 `index.json.sig` 并校验 Ed25519 签名，签名缺失或不符即拒绝该仓库；
4. 选目标插件 → 下载 zip → **强制**校验 SHA-256 与大小 → 解压到临时目录 → 校验
   `plugin.toml`、路径穿越、条目数量、单文件与总大小上限 → 校验 API 版本 → 原子 rename 到 `installed/`；
5. 若为代码插件：校验 `plugin.wasm` 的 import/export 世界符合 §9，再预编译为 Pulley
   （`Config::target("pulley64")`）缓存到 `plugins/cache/wasm/<sha256>.cwasm`；
   **不缓存可执行内存页**——iOS 上本就不允许，其他平台也统一用解释器，避免双路径；
6. 注册到运行时；若同 id 已存在，按版本覆盖并保留旧目录一版用于回滚；
7. 记录 `install.log`：`id / version / sha256 / repo / signed / 时间`，供诊断与回滚追溯。

**卸载**：删 `installed/<id>` 全部版本、清 `state.json` 条目、清 wasm 缓存引用；
用户数据（追剧、历史、下载）**保留**，源消失时列表标记为「源已卸载」，允许用户恢复插件或删除数据。

### 7.4 仓库协议（`repo.toml` + `index.json`）

```toml
# repo.toml —— 仓库根
spec = 1
id = "official"
name = "真果鉴官方规则仓库"
description = "官方维护的短剧站源规则"
homepage = "https://github.com/<org>/<repo>"
index = "index.json"                 # 相对路径或绝对 URL
public_key = "ed25519:<base64>"      # 可选：声明后索引必须带有效签名
issued_at = "2026-10-19T00:00:00Z"
```

```json
// index.json —— 数组，与 Kazumi 保持同构，便于工具链复用
[
  {
    "id": "guo.wuguo",
    "name": "伍果",
    "version": "1.2.0",
    "kind": "declarative",
    "api": 1,
    "minHost": "0.3.0",
    "author": "official",
    "updatedAt": "2026-10-18T12:00:00Z",
    "size": 4096,
    "sha256": "…",
    "path": "plugins/guo.wuguo/guo.wuguo-1.2.0.zip",
    "changelog": "修复分类页选择器"
  },
  {
    "id": "guo.maoguo",
    "name": "猫果",
    "version": "1.0.0",
    "kind": "component",
    "api": 1,
    "minHost": "0.3.0",
    "author": "official",
    "size": 65536,
    "sha256": "…",
    "path": "plugins/guo.maoguo/guo.maoguo-1.0.0.zip"
  }
]
```

**签名策略（D3：不强制）**

| 仓库类型 | `public_key` | 索引签名 | 包哈希 | 客户端行为 |
| --- | --- | --- | --- | --- |
| 官方 | 内置 | 必须 | 必须 | 自动校验；失败拒绝加载 |
| 第三方已签名 | 提供 | 必须 | 必须 | TOFU 记指纹，变化时拒绝并提示 |
| 第三方未签名 | 不提供 | 忽略 | **必须** | 允许添加，卡片标「未签名」，每次更新仍需用户确认 |

逐包 SHA-256 在任何情况下都不能省略——它防的是「下载到损坏或被替换的包」，
而签名防的是「仓库本身被冒充」，两者不能互相替代。

若某仓库的索引沿用 Kazumi 的 `name/version/author/lastUpdate` 字段名（只改字段，不改规则格式），
客户端按别名做字段映射即可读取；但**规则内容本身仍必须是本标准 DSL**，不做 XPath 转换。

**第三方仓库**：

- 用户在「站源 → 插件仓库 → 添加」输入 URL；支持 `https://` 与本地 `content://` / `file://`（移动端文件选择器）。
- 仓库可禁用/删除；删除时已安装插件保留，只停止更新检查。
- 自动检查更新：启动后延迟 + 前台每小时最多一次，复用 `AsyncSingleFlight` 语义，失败静默。

### 7.5 官方仓库分发

- 仓库内容放独立仓库（例如 `guoapp-rules`），GitHub Actions 在打包时生成 `index.json` + 签名；
  客户端内置其仓库 URL 与公钥。
- 应用随包内置**仓库地址与公钥**，不内置全部规则包；首启显示官方仓库可安装列表。
- 为保证「红果可用、其他源离线可用」，允许把官方仓库的最新索引快照打进应用资源作为降级
  （`assets/plugin-index.snapshot.json`），仅在首次且网络失败时展示，不自动安装。
- 内置快照同样是**数据不是代码**：官方仓库被篡改而快照过期时，最坏情况是少几个可安装源，
  不会执行非预期代码；代码插件部分仍逐包哈希、且只在该仓库签名通过时安装。

### 7.6 与 Kazumi / Mihon 的对照

| 维度 | Kazumi | Mihon / Komikku | 本设计 |
| --- | --- | --- | --- |
| 仓库索引 | `index.json` 数组 | `repo.json` → `index.min.json` / protobuf | `repo.toml` → `index.json`（字段对 Kazumi 做映射，格式不兼容） |
| 规则格式 | XPath + 少量 API 配置 | Kotlin 代码 + APK | JSON DSL（CSS / JSONPath）+ WASM 组件 |
| 分发单元 | 单个 JSON 文件 | APK | zip 包（可含多站点） |
| 校验 | 无（依赖 GitHub） | 可选 `signingKeyFingerprint` | 包 SHA-256 强制；仓库 Ed25519 可选（D3） |
| 更新 | 版本号比较 + 规则目录 | 版本号 + 仓库 | 语义化版本 + api level + 主机版本区间 |
| 插件隔离 | 无（Dart 进程内） | 进程内（Android 插件） | WASM 沙箱 + 宿主能力 |
| 官方仓库 | 内置 | 需手动添加 | 内置、可禁用 |

**不兼容 Kazumi 规则（D2 已定）**：其规则以页面绝对路径 `//div[2]/…` 为主，站点改版即全坏；
且大量规则依赖 WebView 抓取，与本项目「纯 HTTP + 设备端」目标冲突。
因此**不实现 XPath 方言、不提供导入器**。引一个转换成功率不高的转换器，
等于长期维护两套方言和一批「转换后静默不工作」的源；需要接入时按本标准 DSL 重写，
成本低于调试转换结果。

**对 Kazumi 只借鉴结构与分发**：静态目录仓库、按需装包、索引带版本——这些形态照搬，规则本身不复用。

### 7.7 安全模型

| 威胁 | 对策 |
| --- | --- |
| 插件读取本地文件 | WASM 无 `wasi:filesystem`；声明式无代码 |
| 插件直连网络 / 绕过限流 | 不链接 `wasi:http`；所有请求走宿主 `fetch`，按 `permissions.network` 白名单校验 host |
| 请求内部地址（SSRF） | host 拒绝 `127.0.0.0/8`、`169.254.0.0/16`、`::1`、私网段与 `.local`，除非用户显式允许局域网 |
| 响应炸弹 | 单响应上限（目录 8 MiB、媒体分片 64 MiB），解压上限（单文件 8 MiB、总 32 MiB、≤ 512 条目），JSON 深度上限 |
| 插件无限循环 | WASM fuel / 时间上限；JS `set_memory_limit` + `set_interrupt_handler` |
| 签名缺失（第三方仓库） | 逐包 SHA-256 仍强制；仓库无签名时卡片标注「未签名」，**每次版本变更都要求用户确认** |
| 签名密钥泄露 | 仓库可轮换公钥；客户端变更指纹时拒绝并要求用户重新确认 |
| 供应链替换 | 逐包 SHA-256 强校验 + `install.log`（id/version/hash/repo/signed/时间）可回滚追溯 |
| 信息泄露 | 日志默认脱敏 `authorization`、`cookie`、`sign`、`token`；诊断导出需用户确认 |

**插件永远不能**：读取应用配置、访问用户目录、发起局域网请求（除非 manifest 声明且用户授权）、
调用另一个插件、注册全局钩子。

---

## 8. 声明式规则规范（`spec = 2`）

### 8.1 相对 `schema 1.0` 的增补

| 现状 | 问题 | spec 2 |
| --- | --- | --- |
| `schema: "1.0"` 字符串 | 无法表达能力与限制 | `spec: 2` 整数 + `api` 段 |
| `capabilities` 字段**被忽略**（能力由段是否存在推导） | 声明与实现不一致 | 显式 `actions` 决定能力，加载期交叉校验 |
| 只有 GET/POST | 无法表达会话预取、先登录后请求 | `session: [Request]` 串行前置请求 + `store` 取用 |
| 无 Cookie 语义 | 需要 `Set-Cookie` 的源无法迁移 | `session.persist_cookies: true`（host 侧 CookieJar，作用域限声明域名） |
| 仅 `{page}/{category}/{keyword}/{id}/{base}/{ts}/{md5}` | 无法做 HMAC、时间格式化、随机 nonce | 增加 `{ts:fmt}`、`{uuid}`、`{rand:n}`、`{nonce}`、`{hmac:sha256:key:input}` |
| 搜索与目录字段重复 | 维护成本 | `defaults` 段合并（catalog/search/detail 共用 `fields`） |
| 无失败语义 | 空结果无法区分「无内容」与「改版」 | 每个动作 `assert: { min_items, required_fields }`，不满足即 `ParseChanged` |
| 无分页游标 | 只能靠页码 | `pagination: { cursor: jsonpath, next: [{when, url}], exhausted: bool }` |
| 无媒体探测 | 取流前无法区分 HLS/MP4 | `resolve: { inspect: "content" }` + `variants` 选择规则 |

### 8.2 结构

```json
{
  "spec": 2,
  "site": {
    "id": "fanguo",
    "name": "饭果",
    "group": "duanju",
    "base": "https://xifan-api-cn.youlishipin.com",
    "headers": { "User-Agent": "okhttp/5.1.0" },
    "idSplit": "#"
  },
  "limits": { "timeoutMs": 20000, "maxBytes": 8388608 },
  "categories": [{ "id": "都市", "name": "都市" }],
  "actions": {
    "catalog": {
      "request": {
        "url": "{base}/xifan/search/getSearchList",
        "query": {
          "reqType": "search",
          "offset": "0",
          "keyword": "{category|都市}",
          "quickEngineVersion": "-1",
          "scene": ""
        },
        "referer": "{base}/"
      },
      "items": ["result.elements[].contents[].duanjuVo"],
      "fields": {
        "id": ["duanjuId", "duanju_id", "id"],
        "idTemplate": "{id}#{source}",
        "title": ["title", "name"],
        "cover": ["coverImageUrl", "cover"],
        "episodes": ["total", "totalEpisodeNum"],
        "tags": ["categories"],
        "description": ["description", "desc"]
      },
      "assert": { "minItems": 1 }
    },
    "detail": {
      "request": {
        "url": "{base}/xifan/drama/getDuanjuInfo",
        "query": { "duanjuId": "{idFirst}", "source": "{idRest}" }
      },
      "meta": ["result"],
      "episodes": {
        "from": "result.episodeList",
        "videoUrl": ["playUrl", "play_url", "videoUrl"],
        "number": ["index", "episode", "sort"],
        "title": ["title", "name"]
      }
    },
    "resolve": { "mode": "direct" }
  }
}
```

### 8.3 执行语义（不可含糊）

1. **单一入口**：`RuleEngine::run(action, ctx)`，动作名只能是 `catalog/detail/search/resolve/categories/suggestions`。
2. **请求构建**：先合并 `site.headers` → `request.headers`；`query` 走 `form_urlencoded`（UTF-8），
   `body` 走原样模板；关键词**只做一次**编码，禁止双重编码（当前实现已在 POST JSON 体修复）。
3. **会话**：`session` 数组按序执行，响应可 `store: {cookie: true}`；后续请求自动带 Cookie。
   会话失败不回退到无会话请求，直接报 `SessionFailed`。
4. **提取**：`items` 命中的每个节点按 `fields` 取候选，第一个非空胜出；`@attr` 表示属性，否则取首个非空文本节点。
5. **去重与主键**：按 `idTemplate` 渲染后去重；`id` 为空即丢弃该条并计数，`assert.minItems` 判定失败。
6. **断言**：`required_fields` 为每条的必填字段；任何一条缺失只记 warning，缺失比例 > 50% 报 `ParseChanged`。
7. **分页**：显式 `hasMore`（minItems / total+current）或 `pagination.next`；两者都无则 `hasMore=false`。
8. **取流**：`direct`（分集地址即媒体）、`page`（抓页面后按 `media` 规则提取）、`variants`（主列表选清晰度）；
   `inspect: content` 时先读前 1024 字节判断 HLS，后缀只作提示。
9. **错误分类**：`Network / Http(status) / Blocked(retryAt) / SessionFailed / ParseChanged / Empty / Unsupported`。
   UI 只依赖这 7 类，不再解析中文字符串。

### 8.4 表达式方言（只有两种）

| 方言 | 用途 | 实现 | 写法 |
| --- | --- | --- | --- |
| **CSS 选择器 + `@attr`** | HTML 页面 | `scraper` | `{"css": "a.x@href"}` |
| **JSONPath** | 接口 JSON / `__NEXT_DATA__` | `serde_json_path` | `{"json": "$.data[*].id"}` |

- 字符串简写一律解析为 CSS，保持与现有规则兼容；**没有第三种方言**。
- XPath 不实现（D2）：依赖的 `sxd-xpath` 最后一次发布停在 2018 年，且 Kazumi 规则
  本身依赖 WebView，转换后多数不可用。承认不支持，好过提供半可用的兼容层。
- 两种方言都必须在**加载期**完成语法校验，运行时不再解析失败（见 §8.5）。

### 8.5 加载期校验清单（防止「静默空结果」）

- 选择器/路径语法可解析；`url` 与 `urls` 至少其一；`detail.episodes` 必须有地址来源；
- 模板 token 必须在白名单内，未知 token 直接拒绝（当前实现是原样保留 `{foo}`）；
- `when` 取值必须是 `category/keyword/default`；
- `idTemplate` 引用的 `{source}` 等字段必须在 `fields` 中存在；
- `assert` 数值合法；`limits` 不超过宿主上限。

---

## 9. 代码插件 ABI 与运行时机（P1）

### 9.1 WIT 世界

```wit
// wit/source-plugin.wit
package guo:source@1.0.0;

interface types {
  record category { id: string, name: string }
  record drama {
    id: string,
    source-id: string,
    title: string,
    description: string,
    cover: string,
    episodes: u32,
    category: string,
    tags: list<string>,
    views: string,
    heat: string,
    release-status: string,
  }
  record query { page: u32, category: string, keyword: string, cursor: string }
  record chapter { id: string, title: string, video-url: string, page-url: string, referer: string, vip: bool }
  record detail { drama: drama, chapters: list<chapter> }
  record page { items: list<drama>, has-more: bool, page: u32, cursor: string }
  record resolve-request { source-id: string, chapter: chapter }
  record media { url: string, referer: string, segments: list<string>, key-uri: string, key-iv: string }
  record descriptor {
    id: string,
    name: string,
    group: string,
    api-level: u32,
    capabilities: list<string>,
  }
  variant error {
    unsupported(string),
    network(string),
    http(u16),
    blocked(string),
    session-failed(string),
    parse-changed(string),
    empty,
  }
}

interface host {
  // 唯一的出网口；host 负责白名单、限流、冷却、代理、Cookie、指纹
  fetch: func(method: string, url: string, headers: list<tuple<string,string>>, body: option<list<u8>>)
    -> result<response, types.error>;
  store-get: func(namespace: string, key: string) -> option<string>;
  store-set: func(namespace: string, key: string, value: string) -> result<_, types.error>;
  log: func(level: string, message: string);
  random: func(len: u32) -> list<u8>;
  now-ms: func() -> u64;
  // 提取原语：解析留在宿主原生代码（ADR-12）
  html-select: func(html: string, selector: string, attr: option<string>) -> list<string>;
  json-path: func(json: string, path: string) -> list<string>;
}

interface source {
  descriptor: func() -> types.descriptor;
  categories: func() -> result<list<types.category>, types.error>;
  catalog: func(query: types.query) -> result<types.page, types.error>;
  detail: func(source-id: string) -> result<types.detail, types.error>;
  search: func(query: types.query) -> result<types.page, types.error>;
  resolve: func(request: types.resolve-request) -> result<types.media, types.error>;
  suggestions: func(keyword: string) -> result<list<string>, types.error>;
}

world plugin {
  import host;
  export source;
}
```

约束：

- 插件**不得** import `wasi:http`、`wasi:filesystem`、`wasi:cli`、`wasi:sockets`、`wasi:clocks`；宿主启动时对其
  `Component::imports()` 做白名单断言，不符合即拒绝安装（而不是运行时报错）。
- `fetch` 的 headers 由宿主过滤：`Host`、`Content-Length`、`Connection`、`Accept-Encoding` 禁止设置；
  `Cookie` 由宿主注入，插件不可伪造其它域名的 Cookie。
- 返回体积上限：单次 `catalog/search` 最多 2,000 条、序列化 ≤ 4 MiB。
- 每个动作独立实例化，不在调用间保留全局可变状态（引擎可复用实例，但插件不得依赖）。
- `html-select` / `json-path` 结果上限 1 MiB，超限按 `parse-changed` 处理。

### 9.2 插件负责什么（边界）

| 留给插件（轻量） | 留在宿主（重） |
| --- | --- |
| 拼 URL、算签名、加解密请求体 | HTML/JSON 解析（`html_select` 内部完成） |
| 选择请求方法、头、分页参数 | 限流、冷却、重试、代理、Cookie、TLS 指纹 |
| 从响应中挑出候选字段 | 去重、合并、缓存、游标持久化 |
| 判断「本页是否还有下一页」 | 下载、HLS 解密拼接、流服务、播放 |

这条边界是 **Pulley 解释器可行性的前提**：解释执行比原生慢约一个数量级，
但插件每次调用只做几十次字符串/哈希运算，真正的解析仍由原生 Rust 完成。

### 9.3 iOS 与各端运行方式（已核实上游事实）

| 事实 | 来源 | 对方案的影响 |
| --- | --- | --- |
| iOS 不允许 JIT / 可执行内存 | 平台约束 | Cranelift JIT 不可用 |
| wasmtime 自 2025-01 起把 `aarch64-apple-ios` 纳入平台检查矩阵 | wasmtime PR #9888（合并于 2025-01-06） | 库可编译到 iOS |
| wasmtime 的 **Pulley** 是便携解释器，支持 component-model 与全部 wasm 特性，约 10× 慢于 Cranelift | wasmtime `examples-pulley` 文档 | 解释执行可行 |
| wasmtime 对 iOS 仍是 Tier 3（"not production ready"） | wasmtime `stability-tiers` | 需要自行验证，不假设稳定 |
| wasmi 2.0 **不支持 component-model / WASIp2** | wasmi issue #1665 维护者回复 | 不能作为组件运行时备选 |

**结论**：三端统一使用 wasmtime + Pulley（`Config::target("pulley64")`），不做 per-OS 分叉。
代价是插件执行慢约 10×，用 §9.2 的边界把重活挪回宿主来吸收；
收益是只有一条代码路径、一套测试、一致的沙箱语义。

**关闭 async**：wasmtime 的 `async` 特性依赖 `wasmtime-fiber`（协程栈需要可执行内存，
正是 iOS 上出问题的部分）。因此插件调用一律用**同步** host 函数，
每次调用放到 `spawn_blocking` 的线程里执行，宿主内部照常 `await` 网络请求。
插件看到的是阻塞的 `fetch`，宿主看到的是普通 async——两边都不用 fiber。

**P0 探针结果**（2026-10-19，详见 `poc-4-wasmtime-pulley.md`）：
三端交叉编译全部通过（含 iOS 首次验证），冷启动 engine 1.09 ms / compile 1.01 ms / instantiate 0.03 ms；
但真实链接增量 **iOS ≈ 9.2 MB、Android arm64 ≈ 12.5 MB、宿主 dylib +10.5 MB**，
超出本节软上限（iOS +8 MB、Android +6 MB）。P1 开工前需在「接受现状 / 平台分层 / 缩小运行时」
三者间决策，倾向先按「接受现状」推进并在 P1 末用真实 APK 复测。

以下为原定探针项，保留作为复验清单：

1. `wasmtime` 以
   `default-features = false, features = ["component-model", "cranelift", "runtime", "pulley", "std"]`
   编译到 `aarch64-apple-ios`、`aarch64-apple-ios-sim`、`aarch64-linux-android`、`aarch64-apple-darwin`；
   记录是否出现 `wasmtime-fiber` 的汇编错误（关闭 `async` 后应当不引入）；
2. 包体增量：记录三端 `.so` / `.a` 体积变化（软上限：iOS 单架构 +8 MB，Android 每 ABI +6 MB）；
3. 冷启动：首个组件实例化 + 首次调用 < 150 ms（低端机放宽到 300 ms），
   用预编译 `.cwasm` 缓存后二次启动 < 30 ms；
4. 单次 `catalog`（1 次 `fetch` + 2 次 `html-select`）端到端 < 400 ms，不含网络。

**降级路径**（仅在 P0 探针失败时启用，不默认）：
iOS 上隐藏 `kind = "component"` 的安装入口并提示「当前平台暂不支持代码插件」，
声明式插件与主源不受影响；Android / Windows 继续完整支持。
是否触发降级由实测数据决定，而不是提前分叉。

---

## 10. 运行时管线

### 10.1 注册表与路由

```text
SourceRegistry
  ├── builtin: guo_source_hongguo::HongguoSource   （always）
  └── plugins: Vec<InstalledPlugin>                （declarative → RuleEngine；component → WasmHost）
```

- 一律按 `source_id` 查找；`source_id` 全局唯一，安装时冲突即拒绝。
- 站点 id 来自 `plugin.toml` 的 `[[rules]].site` 或代码插件的 `descriptor.id`，不允许运行时改名。
- 删除插件后，旧数据中的 `source_id` 仍可读；`catalog` 调用返回 `UnknownSource`，UI 提示「源已卸载」。

### 10.2 传输层

```rust
pub struct FetchPolicy {
    pub timeout: Duration,
    pub max_bytes: usize,
    pub redirects: u8,              // 默认 5，跨 host 需在 allowlist
    pub allow_private: bool,        // 默认 false
    pub fingerprint: Fingerprint,   // Default | Chrome131 | ...（仅主源可声明）
    pub priority: Priority,         // Foreground | Background | Media | Preload
}
```

- **单例 Client**（按 `(代理, 指纹, cookie jar)` 组合缓存，最多 8 个），连接池与 TLS 会话复用。
- **每域名令牌桶**：`concurrency` 1–6 与 `interval` 0–5000ms 可配；前台优先，后台在无前台请求时放行。
- **冷却**：403 / 429 / `cf-mitigated: challenge` / `_cf_chl_opt` / `Just a moment` 命中即按
  `Retry-After` 或默认 60s 冷却，返回 `Blocked { retry_at }`。
- **Cookie**：每站源隔离的 `Jar`，落盘到 `<data>/engine/cookies/<source>.json`，不跨源共享。
- **代理**：直连 / 系统 / 手动；局域网地址默认绕过；插件不可选择代理。
- **指纹**：默认 rustls；仅在主源（黄果视频）启用 wreq 的 Chrome150 配置，固定版本，
  并在构建脚本中 `--locked`。**不允许插件请求指纹通道**，防止被第三方规则滥用。

### 10.3 缓存与游标

- 键：`source` 与 `source|category`（与现状一致），TTL 15 分钟。
- 结构：`items[] + cursor{page, hasMore, offset, session, lastId, updatedAt, warning} + categories[]`。
- 语义：第 1 页替换、后续页按 ID 合并；失败页不推进游标；超过 32 MiB 拒绝写入并保留内存态。
- 写盘：临时文件 + rename；版本号不匹配则丢弃（不迁移旧引擎私有格式，见 §12）。
- 红果的 `offset/session/lastId/pageSignature` 放在 `cursor.ext`（`serde_json::Value`），
  由主源自己解释，运行时不感知。

### 10.4 会话与取消

Dart 每次可取消的调用带 `(session_id, sequence)`：

```rust
pub struct RequestToken { pub session_id: String, pub sequence: u64 }

impl Runtime {
    pub fn cancel(&self, token: &RequestToken);
    pub async fn catalog(&self, token: RequestToken, req: CatalogRequest) -> Result<Page, EngineError>;
}
```

- 语义对齐 Go `beginRead`：同 `session_id` 新序列取消旧序列；前台并发上限 16；会话表上限 128；
  空闲 15 分钟回收。
- 返回前再次校验 `sequence`，被取消的请求返回 `EngineError::Cancelled`，Dart 丢弃结果。

### 10.5 下载与流服务

- **下载**：任务持久化（`downloads/index-v2.json`），字段与 Go 对齐（drama/chapter/index/quality/state/bytes/total/error/revision）。
- **流式**：`Transport::fetch_stream` 返回 `(status, headers, impl Stream<Item=Bytes>)`；
  直链下载边下边写 `.part`，HLS 逐分片下载、按需 AES-128 解密、`HlsKey` 缓存。
  **禁止**把整集读进内存（当前 `response.bytes()` 是全量读，见审计）。
- **取消**：`pause/cancel` 立即中断流；`resume` 用 Range 续传；服务器忽略 Range 时整段重写。
- **流服务**（本机播放器）：`127.0.0.1` 随机端口 + 每会话 32 字节 token；支持 GET/HEAD、Range、
  HLS 播放列表重写（把分片与 `EXT-X-KEY` URI 指回本地）、按会话注入 Referer/UA/Cookie；
  会话空闲 10 分钟或超过 8 个时回收。对齐 Go `nativeStreamServer` 的语义。
- **指纹与密钥**：不落盘明文密钥；`key_uri` 只在会话内缓存。

### 10.6 局域网

保留 Go 的协议（`/zgj/v1/*`、TLS 1.3、证书指纹固定、请求 ID、限流 50ms、单请求 768 KiB），
用 Rust 重写为 `runtime/lan`，身份文件 `lan-identity.json` 兼容读取。
Dart 侧 `LanController` 的网络发现（mDNS）保留在 Dart（`nsd` 包），引擎只做证书生成、HTTP 服务与协议编解码。

---

## 11. FRB 边界与 Dart 分层

### 11.1 API 面（按域拆分，约 45 个函数 + 4 个 Stream）

| 域 | 函数 |
| --- | --- |
| 引擎 | `init(config) -> EngineInfo`、`shutdown()`、`health()` |
| 源 | `sources()`、`source_features(id)`、`categories(id, force)` |
| 目录 | `catalog(req, token)`、`cached_catalog(id, category)`、`clear_cache(id, category)`、`suggestions(id, q)` |
| 详情 | `detail(req, token)`、`metadata(req)` |
| 播放 | `resolve(req, token)`、`fallback(session)`、`preload(req)`、`release(session)` |
| 发现 | `rankings(board, page)`、`ranking_boards()`、`recommendations(genre)`、`danmaku(req)` |
| 下载 | `enqueue(req)`、`downloads()`、`download_stream() -> Stream<Event>`、`control(id, cmd)`、`batch_control(ids, cmd)`、`storage()`、`move_dir(path)` |
| 插件 | `repositories()`、`add_repository(url)`、`remove_repository(id)`、`refresh_repository(id)`、`plugin_catalog(repo)`、`install(repo, id, version)`、`uninstall(id)`、`set_plugin_enabled(id, bool)`、`import_plugin_file(path)` |
| 设置 | `resource_settings()`、`save_resource_settings(s)`、`system_proxy(s)` |

**错误模型**：

```rust
#[derive(Debug, thiserror::Error)]
pub enum EngineError {
    #[error("网络错误")] Network { retryable: bool, detail: String },
    #[error("HTTP {status}")] Http { status: u16, retryable: bool },
    #[error("站点限制")] Blocked { retry_at_ms: u64, reason: String },
    #[error("会话失败")] SessionFailed { detail: String },
    #[error("页面结构变化")] ParseChanged { source: String, field: String },
    #[error("无结果")] Empty,
    #[error("不支持")] Unsupported { capability: String },
    #[error("未知源")] UnknownSource { id: String },
    #[error("已取消")] Cancelled,
    #[error("插件错误")] Plugin { code: String, detail: String },
    #[error("内部错误")] Internal { detail: String },
}
```

Dart 映射为 `EngineFailure`（现 `AppFailure` 的超集），UI 直接按 `code` 决定「重试 / 冷却倒计时 / 换源」。

### 11.2 Dart 目录

```text
lib/
├── rust/            # 生成绑定 + EngineRepository + 模型映射 + EngineFailure
├── data/              # LocalStore、Prefs、下载索引只读视图
├── domain/            # CatalogService、PlaybackService、DownloadService、LibraryService、LanService
├── features/          # sources、catalog、detail、player、downloads、library、settings
└── ui/                # 通用组件、主题、布局、遥控
```

硬规则：

- 引擎返回的 `SourceDescriptor` 是站源列表唯一来源；`SourceSite` 常量表降级为**兼容映射**
  （旧 id → 显示名 / 旧分组），不得再决定「是否有该源」「有哪些能力」。
- `id == 'hongguo'` 的判断全部替换为 `descriptor.features.contains(Feature::Danmaku)` 一类能力位。
  迁移期保留 `SourceId::Hongguo` 常量用于业务逻辑（系列剧、榜单分组），但能力判断走 feature。
- UI 不直接调用 `RustLib`，只经 `EngineRepository`，便于测试注入。

---

## 12. 存储与迁移

### 12.1 目标目录

```text
<app support>/guorust/
├── engine.json              # 版本、安装 id、配置快照
├── catalogs-v2.json         # 目录 + 游标 + 分类
├── downloads/
│   ├── index-v2.json
│   └── <job>/<files>
├── plugins/                 # 见 §7.3
├── sessions.json            # 会话游标（红果）
├── cookies/<source>.json
├── identity/lan-identity.json
├── covers/                  # 海报缓存（若迁入引擎）
└── logs/engine.log
```

### 12.2 兼容导入（一次性，只读）

| 旧文件 | 位置 | 处理 |
| --- | --- | --- |
| `catalogs.json`（Go version 2/3） | 应用数据目录 | 读 `catalogs` / `states` / `categories` / `hongguoApp`，按新结构写 `catalogs-v2.json`；旧文件改名 `.bak` |
| `sources.json` | 同上 | 忽略（任务状态不迁移） |
| `downloads/index.json` | 下载根 | 按 `id/drama/chapter/index/quality/state/bytes` 映射；无法映射的条目标记 `orphan` 保留文件 |
| `lan-identity.json` | 应用数据目录 | 原样读取，保留设备 ID 与证书，避免已配对设备失效 |
| 用户/追剧/历史 | SharedPreferences | 不迁移，保持在 Dart `LocalStore` |

导入必须**幂等**：已存在 `catalogs-v2.json` 时不再读旧文件；导入失败保留旧文件并上报 `warning`，不阻塞启动。

---

## 13. 迁移阶段与验收门槛

> 阶段划分遵循「先修路、再搬货」：先把构建 / CI / 审计缺口补上，再迁移主源，
> 然后同批交付两类插件（D1 已定），最后收口播放下载与删除 Go。每阶段结束执行
> `finish_task.py` 并记录版本。

### P0 — 基线与卫生（1 个短周期）

| 任务 | 产出 |
| --- | --- |
| 补 CI：`cargo fmt --check`、`cargo clippy --all-targets -D warnings`、`cargo test --workspace` | `.github/workflows/build.yml` 新增 `rust` job |
| 统一版本：`pubspec 0.2.56+62` / README / `rust/Cargo.toml` 对齐 | 根 README 版本段落 |
| 修复审计中的 P1 级缺陷（见 `AUDIT.md`） | 引擎侧提交 |
| 把 `rust/`、`rust_builder/`、`reference/` 纳入版本管理（`reference/` 保持只读引用或移出同步范围） | `.gitignore` / 仓库 |
| 确立 workspace 并验证 cargokit 构建 | Android + macOS 各一次产物 |
| **wasmtime + Pulley 三端编译探针**（仅编译 + 一个空组件实例化，不做业务） | 体积 / 冷启动基线数据写入 `PROGRESS.md` |

**验收**：CI 全绿；`cargo test --workspace` ≥ 现有 156 项；Android APK 内含新 `.so`；
macOS 启动无回退日志；探针给出三端体积与冷启动数字，作为 P1 是否触发的判据。

> 探针放在 P0 而不是 P1：它是 D1 决策的可行性前提。若探针失败（iOS 编译不过或体积超软上限），
> 需要先回来调整方案，而不是等到 P1 中途才发现。

### P1 — 主源 + 两类插件 + 官方仓库（核心）

| 任务 | 产出 |
| --- | --- |
| `source-api` / `rule-engine` / `plugin-host` / `plugin-wasm` / `runtime` 骨架 | 新 crate |
| 声明式 DSL `spec 2` 与 6 条现有规则迁移 | 规则文件 + 转换测试 |
| 红果主源迁入 `source-hongguo`：目录、详情、取流、搜索、分类 | 对照 Go 的夹具测试 |
| **主源差异化能力（D4）**：榜单、推荐、联想、弹幕、系列剧季识别 | 能力位 + 对照 Go 的夹具测试 |
| **代码插件宿主**：组件加载、能力注入、fuel/内存/时间上限、Pulley 目标 | `plugin-wasm` + 沙箱负测试 |
| **代码插件工具链**：模板 crate、`wasm-tools` 校验、Pulley 预编译 | `examples/plugin-template` |
| **猫果代码插件**（首选落地对象：签名多、逻辑清晰、已有 Rust 实现可对照） | 包 |
| 官方仓库客户端 + 安装/更新/卸载 + 哈希强制 + 签名可选 | `plugin-host` |
| 12 个短剧源发布为官方包（声明式为主，必要时代码插件） | 独立 Git 仓库 |
| Dart 站源列表改为引擎驱动 | `lib/engine` + `features/sources` |
| 旧目录缓存 / 下载索引 / LAN 身份导入 | `runtime/migrate` |

**验收**：

1. 12 源中 ≥ 10 源可安装并完成「目录 → 详情 → 播放」；卸载后 UI 正确降级；
2. 主源四项差异化能力可用（D4）：榜单可切换并翻页、推荐按题材继续、联想出词、
   弹幕按时间轴加载、系列剧能识别「第 N 季」；
3. 猫果代码插件在 **Android / Windows / iOS** 三端均能加载并完成一次真实目录请求；
4. 未签名第三方仓库可添加、可安装、卡片标注正确，且版本变化时要求再次确认；
5. 沙箱负测试全部被拒绝：越权 host、无限循环（fuel 耗尽）、超大返回（> 4 MiB）、
   import 非白名单模块、篡改包哈希；
6. 断网时官方仓库安装列表可用（快照）；旧数据升级后追剧 / 历史可见。

### P2 — 其余 Go 独占源

> D4 已把红果的榜单 / 推荐 / 联想 / 弹幕 / 系列剧放进 P1，本阶段只处理**非主源**的站点。

| 任务 | 产出 |
| --- | --- |
| 黄豆 / 剧果 / 野果 / 帝果 / 黄果（AI、视频、旧 API）迁移 | 6 个源（多为声明式，少数代码插件） |
| 牛果 AES、帝果 vplayer 写为代码插件 | 2 个代码插件包（猫果已在 P1） |
| 非主源站点的榜单入口（黄豆 / 剧果 / 野果 / 帝果） | 能力位 + UI 对接 |
| 插件更新通道：批量检查、灰度、失败回滚 | `plugin-host` |
| 插件开发文档与仓库模板 | 独立仓库 README |

**验收**：至少 3 个原 Go 独占源端到端可用；插件整体执行开销不拖慢首页
（首屏目录 P95 相对 P1 基线退化 < 15%）；插件更新失败可回滚到上一版本。

### P3 — 播放、下载、流服务、局域网收口

| 任务 | 产出 |
| --- | --- |
| 流式传输与 Range 下载 | `host` + `runtime/downloads` |
| 本机流服务（HLS 重写、Header 注入、会话回收） | `runtime/stream` |
| AES-128 / CENC 解密、TS 拼接、合并与 Emby 导出边界确认 | 对齐 Go |
| 局域网协议重写 | `runtime/lan` |
| Dart 侧只保留 UI 与本地偏好 | 删除 `core_bridge.dart` 的 FFI 路径以外的实现 |

**验收**：真实源播放 / 下载 / 断点续传 / 后台任务；双端局域网同步；旧下载记录可播放。

### P4 — 完全移除 Go（D5）

> D5 已定：不并行发版、不留回退后路。删除范围必须一次列清，避免「删一半」导致仓库长期半可用。

| 删除项 | 位置 | 说明 |
| --- | --- | --- |
| Go 核心与 C ABI | `native/core`、`native/bridge`、`native/go.mod`、`native/go.sum` | 131 个文件，含 20,893 行实现与 5,090 行测试 |
| Go 构建脚本 | `scripts/build_native.py`、`scripts/build_ios.py --core-only` 分支 | 以及 `.github/workflows` 的 `setup-go`、`go test` 步骤 |
| 编译期版本开关 | `ALL_SOURCES` 的 Dart `dart-define`、Go linker flag、`SourceSite.values` 分支 | 站源启停改为「安装/卸载插件」 |
| FFI 桥接 | `lib/core_bridge.dart` 的 `DynamicLibrary` 加载、`Isolate.run` 调用路径 | 只保留 `EngineRepository` |
| 同步脚本必选校验 | `scripts/sync_source.py` 的 `REQUIRED_FILES`（`native/go.mod`、`native/go.sum`、`native/bridge/main.go`、`scripts/build_native.py`） | 改为校验 `rust/bridge/Cargo.toml` 等 |
| 只读参考快照 | `reference/guoapp` | 可整体移出仓库（另存归档），不进源码压缩包 |
| 文档 | 根 README「开发与构建」「站源」「安装包与平台状态」三节 | 改为 Flutter + Rust 单链 |

| 保留项 | 原因 |
| --- | --- |
| Go 夹具（HTML / JSON 片段） | 已转成 Rust 测试夹具，作为站源结构回归 |
| 数据导入逻辑 | 旧 `catalogs.json` / `downloads/index.json` / `lan-identity.json` 的只读迁移 |
| 用户数据目录约定 | 升级不能要求用户重装 |

**验收**：

1. `git grep -il 'go.mod\|build_native\|libduanju_core\|setup-go'` 在源码内零命中（归档目录除外）；
2. 全新克隆可仅用 Flutter + Rust 构建三端；`flutter test` 无原生库缺失报错；
3. `python3 -m unittest discover -s scripts` 通过；`python3 scripts/sync_source.py --check` 一致；
4. 携带 Go 版时代数据的升级包能正常启动并读到旧目录 / 下载记录。

---

## 14. 风险与缓解

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| wasmtime 在 iOS 编译失败 / 体积超限 | D1 的三端一致性无法兑现 | P0 探针提前暴露；失败则 iOS 暂隐藏 `kind=component`（声明式与主源不受影响），并把实测数据写回本表 |
| Pulley 解释下插件过慢 | 首屏或翻页卡顿 | 插件边界收窄到取数与签名（§9.2）；HTML/JSON 解析走宿主原语；首批以猫果实测 P95 |
| wasmtime iOS 仍是 Tier 3、上游可能回归 | 升级 wasmtime 时突然编译不过 | 锁版本 + CI 固定 target 编译检查；升级单独作为一次变更并跑三端探针 |
| 声明式表达力不足，12 源中部分仍要代码 | 首批插件不全 | D1 已允许代码插件，不再是阻塞；能用 JSON 的仍优先 JSON |
| cargokit 工作区故障 | 构建不可重复 | P0 立即验证；桥接包固定名与位置；保留补丁与注释 |
| 站点改版 | 规则失效 | 断言 + `ParseChanged` 错误 + 仓库快速发版；内置官方仓库索引快照 |
| 未签名第三方仓库投毒 | 设备数据 / 用户风险 | 逐包哈希强制、权限白名单、WASM 沙箱、更新需确认、`install.log` 可追溯 |
| 迁移期双实现漂移 | 行为不一致 | 同一套 Go 夹具驱动 Rust 测试；能力位对齐；每个源迁移后跑 `parity` |
| 版本与服务端数据不兼容 | 用户升级失败 | 一次性只读导入 + `.bak` + 失败不阻塞启动 |

---

## 15. 需要拍板的决策点

| # | 问题 | 结论 |
| --- | --- | --- |
| D1 | 首发是否必须支持代码插件（WASM） | **是（已定 2026-10-19）**：P1 与声明式同批交付；P0 先做三端编译探针，P1 以猫果为首个落地对象 |
| D2 | 是否兼容 Kazumi XPath 规则 | **不兼容（已定 2026-10-19）**：不实现 XPath、不提供导入器；仓库索引字段可做别名映射，规则格式不兼容 |
| D3 | 第三方仓库是否强制签名 | **不强制（已定 2026-10-19）**：逐包 SHA-256 强制；签名作为仓库信任加成，未签名仓库在 UI 标注并要求更新时确认 |
| D4 | 主源红果是否包含弹幕 / 榜单 / 推荐 / 系列剧 | **包含（已定 2026-10-19）**：主源能力位与 Go 版对齐，P1 一并交付，不拆到后续阶段 |
| D5 | 是否保留 Go 版并行发布 | **完全移除（已定 2026-10-19）**：不并行发版；Go 仅作迁移期只读规格来源，P4 删除 `native/` 与全部 Go 构建链 |
| D7 | wasmtime 体积超预算（iOS +9 MB、Android +12 MB） | **接受增量（已定 2026-10-20）**：三端全量引入 wasmtime，不做平台分层（B）、不做运行时裁剪（C）。实测真实调用点下 macOS +11.97 MiB、iOS +10.60 MiB；重建模条件见 `poc-4-wasmtime-pulley.md` §8 |
| D6 | 插件 id 命名空间 | **待定**：`guo.*` 只是暂用示例；项目大概率不采用 `guoapp` 命名，定名后再统一替换（见下方说明） |

D1 连带的三条设计后果（已写进正文，不是待定项）：

1. **运行时不选 JIT**：iOS 禁止可执行内存，三端统一 wasmtime + Pulley 解释器（§9.3）；
2. **插件边界收窄**：解析留在宿主，插件只做取数与签名，用 `html-select` / `json-path` 原语（§9.2）；
3. **P0 增加编译探针**：D1 的可行性必须在 P0 用真实构建数据确认，不能默认成立。

D3 连带的两条设计后果：

1. 签名从「强制」降为「可选加成」，但**逐包哈希在任何情况下都不省略**；
2. 未签名仓库的每次版本变更都要求用户确认，避免「一次同意、长期静默升级」。

D4 连带的一条设计后果：主源的能力面在 P1 就完整，意味着 P1 的验收不能只看「能不能播放」，
还要覆盖榜单、推荐、联想、弹幕与系列剧——否则会把主源拆成两批交付，违背 D4。

D5 连带的三条设计后果：

1. **Go 不再接收功能更新**，任何站源修复只改 Rust；`reference/guoapp` 冻结为规格快照，
   不再同步任何修复（当前它已与 `native/` 完全一致，可原样冻结）；
2. 迁移期依靠**夹具对拍**而不是双实现并行：把 Go 的 HTML/JSON 夹具与断言搬成 Rust 测试，
   对拍完成后即可删除 Go 源码，不留「随时切回去」的退路；
3. P4 的删除范围要一次列清：`native/`、`scripts/build_native.py`、`ALL_SOURCES` 的
   Dart 与 linker 开关、`sync_source.py` 对 `native/go.mod` 等四个文件的必选校验、
   CI 中的 `setup-go` 与 `go test` 步骤、README 的 Go 构建说明。

D6 说明：文中 `guo.*`、`guo-engine`、`guoapp-rules` 等名称都是**占位**。
命名未定时先保持内部一致，避免现在改动波及几十处；定名后一次性替换
（涉及 crate 名、WIT 包名 `guo:source`、插件 id 前缀、仓库名与 `pubspec` 依赖路径）。
注意 `rust/bridge` 的 crate 名 `guo_engine` **不能随命名一起改**——
cargokit 与 Dart 的 `DynamicLibrary.open` 都按它找产物，改名需要同步改 podspec / CMake / Gradle
与 `rust_lib_*` 插件名，属于独立的一次构建验证任务。

---

## 16. 附录

### A. crate 清单

| crate | 行数预估 | 依赖 | 职责 |
| --- | --- | --- | --- |
| `guo-source-api` | 800 | serde, thiserror | trait、模型、能力、错误 |
| `guo-rule-engine` | 2,300 | scraper, serde_json_path | DSL、模板、CSS / JSONPath 执行 |
| `guo-plugin-host` | 2,000 | zip, sha2, ed25519-dalek（可选校验）, semver | 清单、包、哈希、签名、安装、仓库 |
| `guo-plugin-wasm` | 2,000 | wasmtime（component-model + pulley） | 组件宿主、能力注入、资源限制 |
| `guo-host` | 1,800 | reqwest, tokio, rquickjs | 传输、限流、冷却、Cookie、脚本、存储 |
| `guo-runtime` | 3,500 | 以上 | 注册表、缓存、会话、下载、流服务、LAN、迁移 |
| `guo-source-hongguo` | 3,000 | api, host | 主源 |
| `guo-engine` | 1,000 + 生成 | FRB | 类型化桥接 |

### B. 规则动作与错误映射

| 动作 | 成功 | 常见失败 | 建议 UI |
| --- | --- | --- | --- |
| `catalog` | `Page{items,cursor,hasMore}` | `Blocked` / `ParseChanged` | 冷却倒计时 / 「源已更新，请刷新规则」 |
| `detail` | `Detail{drama,chapters}` | `Empty` / `SessionFailed` | 「暂无分集」/「请重试」 |
| `search` | `Page` | `Empty` | 「没有找到」 |
| `resolve` | `Media` | `Http(403)` / `ParseChanged` | 换线路 / 换源 |
| `install` | `InstalledPlugin` | `SignatureInvalid` / `ApiUnsupported` | 明确原因，不自动重试 |

### C. 与 Go 行为对齐清单（迁移验收用）

1. 目录：第 1 页替换、后续页合并、失败不推进游标、32 MiB 上限、15 分钟 TTL。
2. 红果：offset/session/lastId/pageSignature 落盘、会话过期重申请、三路 genre 并行。
3. 搜索：红果补漏季上限 32 次、40 秒总时限；饭果默认分类「都市」；星果固定鉴权参数。
4. 取流：猫果 AES-128、HLS 无后缀探测、主列表选清晰度、`Referer` 继承。
5. 下载：Range/If-Range、416/412 重启、HLS 分片拼接、TS 落盘。
6. 缓存：分类汇总到基础源、空结果不清空旧内容。
7. 局域网：TLS 1.3、指纹固定、768 KiB 上限、50ms 间隔。
8. 数据：`catalogs.json` v2/v3、`downloads/index.json`、`lan-identity.json` 可读。

---

*本文为设计快照。任何标记「待验证」的结论在对应阶段完成后必须回写本文件或 `PROGRESS.md`。*
