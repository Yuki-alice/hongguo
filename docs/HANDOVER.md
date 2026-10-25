# 星（hoshi）工程交接文档

> 交接时间：2026-10-25
> 适用对象：接手继续编码的工程师 / 编码 agent
> 交接范围：扩展（插件）体系的设计与实施进度、当前代码事实、下一步工作

本文档只写**当前代码事实**与**可执行步骤**。设计动机在 `docs/EXTENSION-ECOSYSTEM.md`，
不要在这里重复论证；如果两者冲突，以本文档描述的代码为准，并顺手修正生态文档。

> 与本目录另一份交接文档的关系：`HANDOFF-BACKEND-TASKS.md`（2026-10-24）是**红果协议层
> 与下载 worker** 的任务书，任务已完成，保留它的价值在于「红果接口哪些端点活着/死了」
> 的实测结论——做红果相关改动时读它，做扩展体系改动时读本文档。

---

## 0. 三分钟读懂

**项目**：Flutter + Rust 的视频聚合客户端（短剧为主，未来扩电影/剧集/动漫）。
单机应用，**没有自建服务端**；Rust 侧是本地引擎，Dart 侧是 UI，通过
`flutter_rust_bridge`（FRB）通信。

**为什么这么选**：项目最初基于 `reference/guoapp2`（Go 写死站源）重写。
写死站源的后果是「站点一变就得改代码、重新发版」。现在的目标是
**应用与站源解耦**——站点变了只更新扩展包，不发版。

**当前阶段**：

| 编号 | 内容 | 状态 |
| --- | --- | --- |
| A1 | 规则引擎补 regex 提取 | ✅ |
| A2 | JS 脚本扩展升为一等公民 | ✅ |
| A3 | 多步编排 `preflight` | ✅ |
| A4 | **把站源从编译代码搬到扩展包** | 🚧 进行中（猫果、芽果、剧果全链路完成：随包分发 + crate 下线；牛果复测解析服务仍挂已跳过；剩黄果三入口） |
| A5 | 离线校验 / 冒烟工具 `check_plugin` | ✅ |
| A6 | 内容类型标注 + 商店/发现页筛选 | ✅ |

一句话：**能力齐了，内容没搬完。** 接手后的主线就是 A4。

---

## 1. 必读顺序

1. `docs/ARCHITECTURE.md` — 分层、Core-1 单例、FRB 边界
2. `docs/EXTENSION-RUNTIME-DECISION.md` — **ADR-13，已冻结的决策**。
   读它就不会走「要不要上 Wasm」这条回头路。
3. `docs/EXTENSION-ECOSYSTEM.md` — 当前权威：三种包形态、仓库协议（签名/TOFU/回滚）、
   路线 A1–A6、契约纪律、§3 已落地细节
4. `docs/PROGRESS.md` 第十二～十五轮 — 最近四轮做了什么、踩了什么坑
5. `docs/RUST-ENGINE-REVIEW.md` — 历史问题清单（多数已修，可当背景）

---

## 2. 目录地图

```
rust/
  crates/
    source-api/      契约层：Capability / ContentType / SourceMeta / SourcePlugin /
                     SourceEnv / Transport / 数据模型。**零 IO**，有守卫测试禁止
                     引入 tokio / reqwest / wasmtime（dependency_direction.rs）
    host/            HTTP 传输（重试、超时）、QuickJS 宿主（JsPluginHost）
    rule-engine/     声明式规则：RuleDocument / RuleExecutor / regex 提取 / preflight
    runtime/         把「规则」与「脚本」包装成 SourcePlugin：
                     rule_source.rs / script_source.rs / plugins.rs（加载器）/ check.rs
    plugin-host/     包格式与仓库：manifest / package(zip) / repository / store /
                     installer / pack_rules(bin) / pack_script(bin)
    plugin-wasm/     L2 Wasm 组件宿主（**已冻结**，只维护不加功能）
    engine/          进程级单例：注册表装配、插件加载、缓存、下载调度、诊断
    source-hongguo/  主源（永久内置，字节签名 SM3/Argus/Ladon）
    source-huangguo/ 黄果三入口（cloudfront / ai / video）
    source-niuguo/   牛果（Base64 + AES-ECB，密钥=请求 URI 前 16 字节；**解析服务仍挂，迁移暂缓**）
    bench/           热路径基准（guo-bench）
  bridge/            FRB 桥接层（crate 名 guo_engine）
    src/api/         sourceCatalog / 插件管理 / 目录与详情等对外 API
    src/sources/     builtin.rs —— **哪些源随包编译**，只在这一个文件决定
    tests/           集成测试，含 * _live.rs（真网络，默认 #[ignore]）
  rules/             9 条声明式规则（同时被 include_str! 进二进制）
  dist/rules/        官方仓库：index.json + repo.toml + plugins/*.zip
  examples/extensions/maoguo/  脚本扩展样本（main.js + plugin.toml）

lib/                 Dart 侧
  domain/models.dart           SourceSite（源清单）、Drama 等域模型
  data/                        engine_repository / plugin_repository / bundled_plugins
  ui/features/discover/        发现页（CatalogController 持有源与类型筛选）
  ui/features/plugins/         商店（筛选片 + 类型标签）
  ui/features/sources/         源管理页
  l10n/app_zh.arb              文案（改完要 flutter gen-l10n）

test/                Dart 测试（2026-10-25 新建，目前只有纯逻辑用例）
assets/bundled_plugins/  随包预装的官方插件（zip + index.json）
```

---

## 3. 扩展体系：三层形态（已冻结，别推翻）

| 层 | 形态 | 用来做什么 | 例子 |
| --- | --- | --- | --- |
| **L0** | 声明式规则 JSON（`kind: html/json/next/regex`） | 纯抓取+解析，无加密无会话 | 帝果、发果、饭果、观果、河果、花果、网果、伍果、星果 |
| **L1** | 脚本包（`main.js`，QuickJS 沙箱） | 需要签名、加密、多步会话 | 猫果、芽果（已完成） |
| **L2** | Wasm 组件 | 需要重计算或强沙箱 | **冻结**，只在老包上维护 |

**判断顺序**（新源一律从这里起步）：

1. 只要「抓 HTML/JSON → 提字段」→ **L0**。成本最低，改一次 JSON 就行。
2. 需要算签名 / 加密 / 拿 token / 多步请求 → **L1**。
3. 只有在 L1 的 QuickJS 撑不住（CPU 密集、需要二进制协议）时才考虑 L2，
   并且先回来改 ADR-13。

**为什么 Wasm 被冻结**：`ScriptSource` 实现 `SourcePlugin` 的 12 个方法用 JS 只需
一个 `__host_call(kind, payload)` 分发点；Wasm 需要补 6 个 WIT 导出，估算 8h+，
且社区作者写 WAT/Rust 的门槛远高于 JS。ADR-13 有完整的逐源实证表。

---

## 4. 当前源形态分布（**接手第一件事就是看懂这张表**）

### 4.1 三条随包通道并存

| 通道 | 位置 | 数量 | 说明 |
| --- | --- | --- | --- |
| 编译 crate | `bridge/src/sources/builtin.rs` | 5 个源 | 红果（主源，永久）、牛果、黄果三入口 |
| 编译进二进制的规则 | `engine/src/engine.rs` 的 `BUILTIN_RULES`（`include_str!`） | 9 条 | 迁移期保留 |
| 随包扩展 | `assets/bundled_plugins/*.zip` | 4 个 Wasm + 3 个脚本（猫果 / 芽果 / 剧果 1.1.0） | Wasm 是**历史遗留，见 4.3** |

另有仓库通道：`rust/dist/rules/`（官方仓库，9 条规则插件包），供「从仓库安装/更新」用。

### 4.2 L0 已覆盖的 9 个源

`dsd`(帝果) / `faguo`(发果) / `fanguo`(饭果) / `guanguo`(观果) / `heguo`(河果) /
`huaguo`(花果) / `wangguo`(网果) / `wuguo`(伍果) / `xingguo`(星果)

全部在 `rust/rules/*.json`，同时被 `include_str!` 编进二进制、也被 `pack_rules`
打成 `dist/rules/plugins/*.zip`。

### 4.3 ⚠️ 同 id 重复注册是现状，不是设计

`SourceRegistry::register` 只是 `push`，`get` 取**第一个**匹配，`metas()` **不去重**。

- 装配顺序：编译 crate → `BUILTIN_RULES` → 已安装插件。
- 所以同名 id 时**编译版永远生效**，`assets/bundled_plugins` 里那 4 个 Wasm 包
  （cloudfront / huangguo-ai / huangguo-video / niuguo）
  实际是**死重**（每个 34–180KB 白打进行安装包）。
- `metas()` 不去重 → `sourceCatalog()` 里同名 id 会出现两条；Dart 侧
  `SourceSite.reportFromEngine` 用 Map 去重（后者覆盖），所以 UI 上看不出来。

**这不是可以放着不管的小问题**：它是「迁移完成度」的自检指标。A4 做完时，
这三条通道应该收敛成一条（L0/L1 扩展包 + 主源红果），`assets/bundled_plugins`
里的 Wasm 包应当清空。

### 4.4 迁移动进度

| 源 | 形态 | 行数 | 迁移建议 |
| --- | --- | --- | --- |
| 红果 hongguo | crate | 3698 | **不迁移**。主源永久内置（ARCHITECTURE §5） |
| 猫果 maoguo | L1 脚本 | 脚本 322 | ✅ **已完成**（第十六轮：随包 1.1.0，crate 已删） |
| 芽果 yaguo | L1 脚本 | 脚本 ~330 | ✅ **已完成**（第十七轮：随包 1.1.0，crate 已删；令牌走 `ctx.store`） |
| 牛果 niuguo | crate | 434 | AES-ECB，密钥=请求 URI 前 16 字节 → L1（脚本里自带 AES） |
| 剧果 huangju | L1 脚本 | 脚本 ~250 | ✅ **已完成**（第十八轮：随包 1.1.0，crate 已删；CDN Cookie 走 `res.headers`） |
| 黄果 huangguo ×3 | crate | 1929 | AES-CBC + HMAC-SHA256 → L1，**最难的一个** |
| 9 个规则源 | L0 | — | 已经是最便宜形态，不用动 |

---

## 5. 契约纪律（改动前必读，破了会有测试拦你）

1. **`source-api` 零 IO**：不许引入 tokio / reqwest / wasmtime。
   `dependency_direction.rs` 会失败。
2. **`RuleKind` / `EpisodesSpec` 的 untagged 顺序**：字段全 `#[serde(default)]` 的变体
   会静默吞掉别的形态。新增变体时把「字段最少的」放后面，并补一条守护测试
   （参考 `episodes_regex_is_not_swallowed_by_json_variant`）。
3. **脚本必须声明能力位**：一个导出都没有的脚本在加载期就被拒。
4. **脚本网络白名单是硬约束**：清单 `[permissions] network` 没写的主机，
   `ctx.fetch` 直接拒绝，不会「先发再说」。
5. **类型取引擎、文案取编译期**：`SourceSite.reportFromEngine` 已按此实现。
   不要在 `SourceSite.allKnownValues` 里写死内容类型——那样装个动漫源会显示成短剧，
   而且**没法靠更新扩展修好**。
6. **清单/索引与包内声明不一致 → 安装即失败**（`PluginError::Integrity`）。
7. **`ctx.fetch` 是墙钟等待**：`permissions.script.timeout_ms` 上限 30s（不是 5s）。
   按 CPU 时间设上限会把合法脚本判死。
8. **工具不许比宿主宽松**：`check_plugin` 必须走宿主同一条加载路径，
   不能为「方便通过」写第二套校验。

---

## 6. 环境与命令

### 6.1 Rust

```bash
cd rust

cargo test --workspace -- --skip live     # 全量离线测试：当前 590 通过 / 0 失败
cargo clippy --workspace --all-targets -- -D warnings   # 必须零告警
cargo fmt --all --check                   # 必须干净

# 性能回归（改动 rule-engine / 解析路径后跑）
cargo run --release -p guo-bench -- --iterations 500 --json > bench.json
python ../scripts/check_perf_budget.py bench.json

# 真网络用例（默认 #[ignore]，改动源后必须手动跑）
cargo test -p guo_engine --test maoguo_live -- --ignored --nocapture
```

### 6.2 扩展校验工具（A5）

```bash
cd rust
cargo run -q -p guo-runtime --bin check_plugin -- examples/extensions/maoguo
cargo run -q -p guo-runtime --bin check_plugin -- dist/rules/plugins/guo.dsd/guo.dsd-1.0.0.zip
cargo run -q -p guo-runtime --bin check_plugin -- <包> --live        # 真发一次目录/搜索
cargo run -q -p guo-runtime --bin check_plugin -- <包> --live -k 都市  # 指定搜索词
cargo run -q -p guo-runtime --bin check_plugin -- <包> --json        # CI 断言
```

退出码非 0 = 有阻塞性问题。实现放在 `runtime/src/check.rs`（库），bin 只是薄壳。

### 6.3 重新打包官方规则仓库

```bash
cd rust
cargo run -q -p guo-plugin-host --bin pack_rules -- dist/rules rules
```

会重写 `dist/rules/index.json`（含 sha256 / size / contentTypes）与各 zip。
**改了任何 `rust/rules/*.json` 都要重跑**，否则索引哈希对不上，安装会被拒。

### 6.4 Dart

⚠️ **本机有两个坑，不处理的话测试根本跑不起来**：

```bash
# 坑 1：默认 flutter 是 3.38.5（Dart 3.11），项目要求 Dart >= 3.12
#       必须显式用 3.47.7 那份：
FLUTTER=/e/Flutter/flutter_windows_3.47.7-stable/flutter/bin/flutter

# 坑 2：本机有 http_proxy，flutter_tester 的 WebSocket 握手会被拦，
#       报 "Invalid WebSocket upgrade request"。必须绕过 localhost：
NO_PROXY=localhost,127.0.0.1 no_proxy=localhost,127.0.0.1 $FLUTTER test

$FLUTTER gen-l10n          # 改过 lib/l10n/app_zh.arb 之后
dart analyze lib test      # 当前 23 条既有 info，无 error / warning
```

改过 Rust 的 FRB 接口（`bridge/src/api` 里带 `#[frb]` 或对外结构体）后：

```bash
cd /e/hongguo && flutter_rust_bridge_codegen generate
```

### 6.5 常见失败对照

| 症状 | 原因 | 动作 |
| --- | --- | --- |
| `version solving failed ... requires SDK >=3.12.0` | 用了默认 flutter 3.38.5 | 换 3.47.7 路径 |
| `Unable to connect to flutter_tester ... Invalid WebSocket upgrade` | 代理拦了 localhost | 加 `NO_PROXY` |
| `cargo test` 报 `dependency_direction` 失败 | 有人往 `source-api` 加了 IO 依赖 | 把实现挪到 `host` / `runtime` |
| `check_plugin` 报「索引内容类型与包内不一致」 | 改了规则没重跑 `pack_rules` | 重跑打包 |
| 插件的 `timeout_ms` 校验失败 | 上限 30s | 检查清单 |

---

## 7. 已完成工作要点（A1–A6，供快速定位）

### A1 regex 提取
`rule-engine/src/regex_executor.rs`。`kind: "regex"` 时 `item` 做全局匹配切块，
字段取第 1 捕获组。`(?is)` 内联 flag 与 Go `regexp` 基本一致，guoapp2 的正则近乎原样搬运。
验收：`rule-engine/tests/regex_source.rs`（黄果原始正则端到端）。

### A2 JS 一等公民
- `host/src/js_host.rs`：`JsPluginHost`、`ScriptLimits`、`HostState{network}`、
  `invoke` / `invoke_sync`、无 runtime 回退（FRB 同步桥接里不能 `spawn_blocking`）。
- `runtime/src/script_source.rs`：`ScriptSource` 实现全部 12 个方法，
  宽松 `RawDrama` 全字段 `serde(default)`，`source` / 复合 id 由宿主补齐——
  **脚本不需要知道宿主 id 规则**。
- PRELUDE 提供 `crypto.md5`；没有 btoa，需要 Base64 就随包自带。

### A3 preflight
`rule-engine/src/preflight.rs` + `rules.rs` 的 `PreflightStep` / `preflightTtl`。
加载期校验：作用域按步收窄、未声明变量、重复声明、正则/选择器可编译。
提取为空 = 失败并报变量名；失败带步骤名。TTL 缓存（默认 300s，0 = 每次重跑）。

### A5 check_plugin
`runtime/src/check.rs`（库）+ `bin/check_plugin.rs`（薄壳）+ `tests/plugin_check.rs`（8 条）。

### A6 contentTypes
链路：`rules.json` / `main.js describe()` → `plugin.toml` → `index.json` →
`SourceMeta.content_types` → `SourceSummary.content_types` → `SourceSite.contentTypes`。
商店有筛选片；发现页源菜单在多类型时出现类型行（`CatalogController.contentTypesOf`，
纯函数，`test/domain/source_content_types_test.dart` 10 条覆盖）。

---

## 8. 下一步：A4 逐源迁移手册

### 8.0 前置任务：让 L1 脚本包真正随包分发 —— ✅ 已完成（第十六轮）

猫果已走完全链路：`pack_script` 打包（`plugin-host/src/bin/pack_script.rs`，
哈希/大小/索引条目由同一段代码生成，杜绝手算 sha256）→
`assets/bundled_plugins/guo.maoguo-1.1.0.zip`（4.9KB，替换 71KB 的 Wasm 包，
索引条目改 `kind: "script"`）→ `builtin.rs` 删注册 → 删依赖 →
删 `rust/crates/source-maoguo/`。对拍测试改为金标准
（`bridge/tests/script_maoguo_golden.rs`），实网金丝雀 `maoguo_live.rs`
改走 ScriptSource。

**给后续源复用的 SOP**：把 `examples/extensions/<id>/` 的版本号 +1
（预装是「只装不覆盖」，被替换的 Wasm 包都是 1.0.0）→
`cargo run -q -p guo-plugin-host --bin pack_script -- examples/extensions/<id> ../assets/bundled_plugins`
→ 把 stdout 的 JSON 粘进 `assets/bundled_plugins/index.json` →
`check_plugin` 校验 → 删 crate（金标准先行：删之前先把关键输出抓成金标准）。

注意一个语义差异：Wasm 包的 `describe()` 返回包 id（`guo.yaguo` 这类），
脚本包返回**源语义 id**（`maoguo`，与原编译版一致，收藏/历史/下载主键无缝延续）。
`PluginStore::set_enabled` 用**包 id**，注册表查**源 id**——写测试时别混。

### 8.1 单源迁移 SOP（每迁一个源照这个走）

1. **先确认真实可用性**：写 `bridge/tests/<id>_live.rs`（`#[ignore]`），
   用现有 crate 发真请求。**站点已经死了的源不要花时间迁移**。
2. **判断形态**（§3 的判断顺序）：能从 L0 做就绝不写 L1。
3. **写扩展包**：`rust/examples/extensions/<id>/{plugin.toml,main.js}` 或 `rust/rules/<id>.json`。
4. **对拍**（L1 必须做）：`bridge/tests/script_<id>_parity.rs`，夹具放 `bridge/tests/fixtures/`。
   对拍要覆盖：签名串、目录字段、详情分集、搜索、**请求头**（猫果的教训）。
5. **离线校验**：`check_plugin <dir>` 通过。
6. **真网络冒烟**：`check_plugin <dir> --live`，目录/搜索都要出条目。
7. **接进随包**：打包 + 更新 `assets/bundled_plugins/index.json`（版本 +1）。
8. **下线 crate**：删 `builtin.rs` 注册 → 删依赖 → 删目录 → 删对拍里对 crate 的引用。
9. **更新 `SourceSite._offlineIds`**：`lib/domain/models.dart` 里那张表决定哪些源在
   UI 里隐藏。源复活/迁完后要复测并更新，否则用户看不到。
10. **跑全套**：`cargo test --workspace -- --skip live` + clippy + fmt + `flutter test`。

### 8.2 建议顺序（从易到难）

| 顺序 | 源 | 形态 | 关键难点 | 验收 |
| --- | --- | --- | --- | --- |
| 1 | maoguo | L1 | ✅ **已完成**（第十六轮） | `--live` 目录 62 / 搜索 10 |
| 2 | niuguo | L1 | ⚠️ **迁移暂缓**：2026-10-25 复测，两台解析服务仍超时（目录 / 详情正常）；站点复活后再迁 |
| 3 | huangju | L1 | ✅ **已完成**（第十八轮；2026-10-25 复测站点已复活，历史 404 不再成立） | 冷启动拿令牌、过期刷新（夹具 + 实网均验证） |
| 4 | yaguo | L1 | ✅ **已完成**（第十七轮） | token 复用与过期重登（夹具 + 实网均验证） |
| 5 | huangguo ×3 | L1 | AES-CBC + HMAC-SHA256；三个入口 | 先做 cloudfront（唯一可在线验证） |

**不建议迁移的**：红果（主源永久内置，字节签名 SM3/Argus/Ladon，随包更新更安全）。

### 8.3 顺手该做的事（低风险、高收益）

- `SourceRegistry` 加「同 id 只保留第一个」的显式逻辑，或加载器在注册前查重并告警。
  现在 `metas()` 不去重，是潜在 UI 重复项来源。
- 给商店 / 发现页补 widget 测试。当前 `test/` 只有纯逻辑用例；
  要补需要先给 FRB 桥接做一层可注入的假实现（`PluginRepository` 依赖 `api.*` 静态调用）。
- `docs/EXTENSION-ECOSYSTEM.md` 的 §5 路线表与验收段已同步到 A6，A4 状态标了「进行中」。

---

## 9. 已知缺陷与风险（按严重度）

1. **三通道重复注册**（§4.3）：编译版永远赢，Wasm 包是死重，`metas()` 不去重。
   迁移完成后必须收敛，否则包体白增（4 个 Wasm 包合计约 244KB），且 `sourceCatalog()` 有重复 id。
2. **脚本包还没走通分发链路**（§8.0）：猫果脚本只在本仓库 examples 里。
   这是 A4 的硬前置。
3. **`_offlineIds` 是手工维护的黑名单**：11 个源被隐藏（niuguo / huangju / huaguo /
   fanguo / guanguo / xingguo / cloudfront / huangguoai / huangguo-video / wuguo / dsd）。
   源复活后不更新这张表 = 用户永远看不到它。迁移时逐个复测。
4. **多类型菜单没有视觉验证**：本机只有短剧源，发现页的类型筛选行从没在真机上出现过。
   逻辑有单测兜底，UI 没有。
5. **`hongguo_live` 偶发 4/5**：网络抖动集中时重试耗尽。持续出现可把 `GET_ATTEMPTS` 提到 4。
6. **黄果 ai/video 两个入口自 2026-10-21 起全部超时**：只有离线对拍，没有在线验证。

---

## 10. 排查手册

| 症状 | 先看哪里 |
| --- | --- |
| 源在 UI 里消失 | `SourceSite._offlineIds`（`lib/domain/models.dart`） |
| 源列表里同一个源出现两次 | `metas()` 没去重，检查是否有同名 crate + 插件 |
| 装了扩展但没生效 | 编译版优先（§4.3）；或 `builtin.rs` 没删注册 |
| 「验签失败」`44010120` | **先看请求头再怀疑签名**。七猫鉴权是两层，缺 `qm-params`/`authorization` 时错误码与「签名算错」完全一样 |
| 脚本加载失败但不知道原因 | 脚本里读 `globalThis.__last_host_error` |
| 脚本 `ctx.fetch` 被拒 | 清单 `[permissions] network` 没写该主机 |
| 脚本超时 | `timeout_ms` 是否够（墙钟包含网络等待）；`ScriptLimits` 默认 10s |
| 规则提取结果为空 | 该字段为空会被当失败，报错里带变量名与步骤名 |
| 商店筛选片不出现 | `contentTypesOf` 返回「实际出现过的类型」，全未标注时为空表 |
| 安装被拒（Integrity） | 索引 sha256 / size 与包不符 → 重跑 `pack_rules`；或清单与规则的类型声明不一致 |

---

## 11. 接手第一天 checklist

```bash
cd /e/hongguo/rust
cargo test --workspace -- --skip live        # 期望 590 通过 / 0 失败
cargo clippy --workspace --all-targets -- -D warnings   # 期望零告警
cargo run -q -p guo-runtime --bin check_plugin -- examples/extensions/maoguo
cargo run -q -p guo-runtime --bin check_plugin -- examples/extensions/maoguo --live

cd /e/hongguo
NO_PROXY=localhost,127.0.0.1 no_proxy=localhost,127.0.0.1 \
  /e/Flutter/flutter_windows_3.47.7-stable/flutter/bin/flutter test   # 期望 10 通过
dart analyze lib test                        # 期望无 error / warning
```

全绿说明环境正常，可以直接从 §8.0 开始。

**接手时请不要做的事**：

- 不要把 Wasm 解冻（ADR-13）。不要为「统一」把 L0 规则改写成脚本——L0 的成本优势是
  生态的入口。
- 不要为了迁移方便改 `source-api` 的契约（会让所有已发布扩展失效）。
- 不要在 `SourceSite` 编译期常量表里写死内容类型（理由见 §5.5）。
- 不要在没跑 `--live` 的情况下把「站点已失效」写进文档——上一轮就因此误判过一次。

---

## 附：本轮交接时的工作区状态

- 未提交改动 99 个文件（含本文档）。`git status` 里既有本轮改动，也有前几轮未提交的。
- 最近一次提交：`fd3f7b8 feat(engine): 红果评论签名移植与弹幕恢复，下载 worker 接管与契约扩展`
- 最近四轮（第十二～十五轮）的详细记录在 `docs/PROGRESS.md` 尾部。
