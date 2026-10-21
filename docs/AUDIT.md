# 迁移现状审计（对照目标架构）

日期：2026-10-19
基线：工作区快照 `pubspec 0.2.56+62`（未提交），`rust/` 8,831 行 / 156 项测试通过。
目标架构见 [`ARCHITECTURE.md`](ARCHITECTURE.md)。

本文件只记录**已核实**的事实与缺陷，按严重度排序，供实施排期使用。每条给出证据位置；
凡未实测的标注「待验证」。

---

## 0. 一句话结论

Rust 引擎已经能证明「可以替代 Go 解析站源」，但**还不是产品级后端**：
它是单一 crate、单例全局状态、全量缓冲、字符串错误、编译期规则、无插件概念；
CI 中没有任何 Rust 步骤（`checks` / `android` / `ios` 三个 job 均为 `if: false`，
`windows` job 亦无 Rust 校验），且 Go 侧参考测试当前是失败状态。
在补上这些之前继续加站源，只会把不可维护的复杂度从 Go 搬到 Rust。

---

## 0.1 修复进度（2026-10-20 更新）

| 条目 | 状态 |
| --- | --- |
| 1.1 CI 不验证 Rust | ✅ 已修：`.github/workflows/build.yml` 新增 `rust` job（fmt / clippy / test / 依赖方向守卫） |
| 1.1 `rust/` 未进 Git | ✅ 已修：`rust/`、`rust_builder/` 已纳入版本管理 |
| 1.2 Go 参考测试失败 | ✅ 已修：`go test ./...` 全绿（33 s）。最后一项 `TestRankingCacheAndStaleRecovery` 是夹具缺陷——第 1 页请求不带 `?page=`，夹具却按 0 处理，于是把 `pageNum: 0` 写进数据；未修改的 `reference/` 仍可复现同一失败，证明是测试侧问题而非实现回归 |
| 2.x 单一 crate / 全局单例 | ✅ 已拆：9 crate 工作区，`bridge` 只留 FRB 边界 |
| 3.1 全量缓冲 | ✅ 已修：`max_bytes` + `chunk()` 流式截断；HLS 探测只读 1 KiB 前缀 |
| 3.2 下载删除路径 | ✅ 已修 |
| 3.3 HLS 断点续传 / validator | ✅ 已修：分片签名 + 已完成数，`If-Range` 有值 |
| 3.4 `panic = "abort"` | ✅ 已修：改回 `unwind` 并注释原因 |
| 4.x 无插件概念 | ✅ 已落地：`plugin-host`（包/仓库/安装器）+ `plugin-wasm`（组件宿主）+ 模板与真实组件测试 |

未完成项见 `PROGRESS.md` 第十三轮「未做」小节。

---

## 1. 阻断级问题（P0，先修）

### 1.1 CI 完全不验证 Rust

- `.github/workflows/build.yml`：`checks`（第 22 行）、`android`（第 49 行）、`ios`（第 148 行）
  均带 `if: false`；唯一启用的 `windows` job（第 102 行）只跑 Go + Flutter 构建。
  文件内**不存在** `cargo`、`rustup`、`clippy`、`cargo test` 任何字样。
- 后果：`rust/` 与 `rust_builder/` 至今未进 Git（`git ls-tree HEAD` 无 `engine`），
  一旦误删无法恢复；Rust 回归只能靠本机手动执行。

**修复**：新增 `rust` job（checkout → rustup 1.97 → `cargo fmt --check` →
`cargo clippy --workspace --all-targets -D warnings` → `cargo test --workspace --offline`），
并把 `rust/`、`rust_builder/` 纳入版本管理。

### 1.2 参考 Go 测试当前失败（迁移对照失去基准）

在 `native/` 与 `reference/guoapp/native/` 两个目录分别执行 `go test ./...`，结果一致
（两目录内容完全相同，`diff -rq` 无输出）：

```
--- FAIL: TestNativeCatalogCacheFreshnessPagingAndRefresh        (app_cache_test.go:187/216)
--- FAIL: TestNativeHongguoCursorRestartsPerCatalog              (游标 offset 序列不符)
--- FAIL: TestNativeHongguoCursorRecoversSessionsAfterRestart    (子用例 expired)
--- FAIL: TestNativeHongguoStalledCursorKeepsPartialItems        (calls = [0 18 18 18 18])
--- FAIL: TestNativeCatalogSaveFailureRetriesWithoutAdvancing     (内存数据被丢弃)
--- FAIL: TestNativeCatalogMetadataSaveExcludesInFlightCursor    (20.01s 超时)
panic: close of closed channel                                    ← 测试自身崩溃
```

逐个定位到的根因分三类：

1. **测试夹具与站点结构脱节**：`app_cache_test.go:187` 期望只请求
   `/api/videos/category/ai-duanju`，实际请求了 `ai-mogai` / `ai-huanlian` / `ai-manju`；
   同一用例第 216 行还把 `AI 漫剧: 127.0.0.1 HTTP 404` 当作失败原因。
   说明黄果 AI 的分类发现逻辑改了，测试的假服务器没跟上。
2. **行为回退**：`StalledCursorKeepsPartialItems` 期望 3 次请求，实际 4 次，
   即「分页未前进」被重试而不是立即停止；`SaveFailureRetriesWithoutAdvancing`
   期望保存失败后内存仍保留 3 条，实际被丢弃——正是 README 里 P1-R8 声称已修复的路径。
3. **测试自身缺陷**：`app_catalog_persistence_test.go:355` 的协程在没有同步保护的情况下
   `close(paused)`，多个请求到达时二次关闭触发 panic，导致整个包无法完成测试。

**影响**：这些测试本应是 P1「红果主源迁移」的对拍基准，现在必须先修复或重写，
否则无法证明迁移前后行为一致。修复顺序建议：先修 3（纯测试缺陷）→ 再修 1（夹具）→
最后定位 2 是产品缺陷还是测试期望过时。

### 1.3 同步脚本仍要求 Go 核心存在（D5 已改为「完全移除 Go」，此项从「可选」升级为「必做」）

`scripts/sync_source.py` 的 `REQUIRED_FILES` 包含 `native/go.mod`、`native/go.sum`、
`native/bridge/main.go`、`scripts/build_native.py`。P4 删除 Go 时若不同步修改，
`finish_task.py` 会直接报「源码缺少必要文件」而拒绝同步。

D5 定案后这条不再有「保留一个版本周期」的缓冲：**删除 Go 与修改必选清单必须在同一次收尾内完成**，
否则仓库会进入「删了源码、同步失败」的半坏状态。实施建议：先在 `REQUIRED_FILES` 里
加入 Rust 侧的等价必选文件（`rust/bridge/Cargo.toml`、`rust/Cargo.toml`、
`rust_builder/pubspec.yaml`、`flutter_rust_bridge.yaml`），确认同步通过后，再移除 Go 的四项。

### 1.4 版本号不一致（README 已在本轮修正）

| 位置 | 值 | 状态 |
| --- | --- | --- |
| `pubspec.yaml:4` | `0.2.56+62` | 基线 |
| `README.md` 第 3 段 | `0.2.56+62` | ✅ 本轮已对齐 |
| `rust/Cargo.toml` | `0.1.0` | ⬜ 未对齐（P0） |

---

## 2. 架构级缺陷（P1）

### 2.1 规则「源」与应用没有分离

- 规则通过 `include_str!` 编进二进制：`rust/bridge/src/sources/mod.rs` 的 `BUILTIN_RULES` 与
  `sources/rule_source.rs`。
- 新增/修改一个源必须重新发版；用户无法安装、更新、卸载。
- 与目标（仓库 + 包 + 按需安装）完全不同。

### 2.2 没有插件概念，只有「编译期源 + 硬编码代码源」

- `SourceRegistry`（`rust/bridge/src/source.rs`）只在进程内注册 `Arc<dyn SourcePlugin>`；
  无清单、无版本、无权限、无安装路径。
- 猫果（`rust/bridge/src/sources/maoguo.rs`，572 行）是唯一的「代码插件」，但它直接调用
  `crate::crypto`、写死字符映射表与密钥，无法分发给第三方。

### 2.3 单一 crate 承担全部职责

`rust/bridge/src` 的模块清单：`api`、`cache`、`crypto`、`download`、`env`、`error`、`media`、`model`、
`rule`、`scheduler`、`script`、`source`、`sources`、`transport`，外加 1,869 行生成代码。
- `source-api`、`rule-engine`、`host`、`runtime`、`plugin` 全部混在一起；
- `source-api` 这类本应零 IO 的契约层无法被独立复用或做依赖越界检查；
- cargokit 的哈希只覆盖 `manifestDir/src`，任何拆分都必须先确认构建缓存行为（见架构文档 §6.6）。
  已在 P0 处理：桥接 crate 下移到 `rust/bridge` 并把 `manifestDir` 指向它，实测 macOS / Android 构建均通过。

### 2.4 全局单例 + 不可配置

- `api.rs:105` 的 `cache()` 使用 `OnceLock`，目录必须在**首次调用前**设置，之后 `set_cache_directory` 永远返回 `false`；
- `api.rs:317` 的 `scheduler()` 固定并发 2，无接口调整；
- `build_env()`（`api.rs:548`）每次构造新的 `MemoryStore` 与 `QuickJsHost`；
  `SourceStore` 在生产路径上**从未被真正使用**（全仓只有 `MemoryStore` 实现）。
- 没有实例句柄，无法在测试或「切换用户」时重建上下文。

### 2.5 错误模型退化为字符串

`rust/bridge/src/api.rs` 的 21 个公开函数**全部**是 `Result<T, String>` 或 `bool`；
`SourceError`（`error.rs`）虽然类型化，但在 FRB 边界被 `err.to_string()` 抹平，
Dart 端只能显示中文文本，无法判断是否可重试、是否需要冷却、是否结构变化。

同时 `SourceError::EmptyRequest` 与 `Blocked` 变体在生产路径**没有构造点**
（`blocked_for` 只出现在测试 `error.rs:104`），即「站点限制」语义尚未实现。

### 2.6 没有取消 / 会话 / 优先级

- 无 `cancel` / `session` / `sequence`；切页或切换站源后旧请求继续跑，
  即 Go 版 `beginRead`（`app_requests.go`）解决过的问题在 Rust 侧重新出现。
- `RequestPriority` 定义了（`env.rs:24`）但只在下载里赋值，传输层不读取，等于死代码。

### 2.7 传输层是「全量缓冲」而非流

- `transport.rs:85` 使用 `response.bytes().await`，整段读入内存；
- `download.rs` 的 `download_file` 与 `download_hls` 都基于该缓冲；
- 无 `Content-Length` 上限校验、无 `bytes_stream()`、无 Range 以外的断点语义；
- 大文件（数百 MB）与弱网下会显著抬高内存峰值，Android 低端机风险最大。

### 2.8 缺少网络治理（限流 / 冷却 / Cookie / 代理 / 指纹）

| 能力 | Go 版 | Rust 现状 |
| --- | --- | --- |
| 域名级并发与间隔 | `network_limiter.go`（1–6 并发、0–5000ms、前后台优先级） | 无 |
| 403/429/CF 冷却 | `catalogResponseBlockReason` + `Retry-After` 上限 30 分钟 | 无 |
| Cookie 会话 | `tls-client` CookieJar + 黄果预览令牌 | 无（`reqwest` 未启用 `cookies`） |
| 代理（系统/手动/PAC） | `proxy_system.go`、`proxyRouter` | 无 |
| 浏览器 TLS 指纹 | `tls-client` Chrome150（黄果视频必需） | 无（`wreq` 仍是 rc，未纳入） |
| 系统代理热更新 | `updateSystemProxy` action | 无 |

这意味着「12 短剧源之外的源」在 Rust 侧**根本不具备迁移条件**，
也是当前进度停在 6/20 的真实原因之一。

### 2.9 规则引擎的表达力与校验仍不足

- `RuleDocument.capabilities` 字段被反序列化但**从不参与能力计算**
  （能力由 `catalog/detail/search` 是否存在推导，见 `rule_source.rs:18-40`）；
  规则写错能力声明不会报错。
- 模板 token 未知时**原样保留**（`rules.rs` 的 `token_value` 返回 `None` → 输出 `{token}`），
  拼出的坏地址会一直发到网络上，而不是加载期拒绝。
- JSONPath 是自研子集（`rule/jsonpath.rs`，仅字段/下标/展开），
  不支持过滤、通配、递归下降；`serde_json_path` 已是成熟替代。
- 规则文件不支持 `query` 对象（只能把参数拼进 `url` 字符串），
  中文与特殊字符依赖 `{keyword}` 的单次编码约定，容易再次出现双重编码。
- 无 `spec`/`api` 版本协商、无签名、无权限声明。

### 2.10 声明式源与代码源的「能力」不对齐

- `Capability::Resolve` 只在规则含 `resolve` 段时声明，但 `RuleSource::resolve`
  对 HTML 源同样可用（页面扫描），因此 `supports(Resolve)` 与实际能力不一致；
- `fetch_media`（`api.rs:264`）的 `chapter.source_id` 被同时写入 `Drama.source_id` 与
  `Chapter.source`（`api.rs:276`、`api.rs:282`），语义混乱。

### 2.11 FRB 面过窄，无法支撑完整应用

现有 21 个入口缺少：preload、fallback、播放会话释放、榜单、推荐、联想、弹幕、
下载批量控制、存储迁移、LAN、设置、插件管理。
Dart 的 `EngineBackedRepository` 共 44 个 `@override`，其中 49 处 `delegate.` 调用、仅 10 处 `engine.`
（`lib/engine_backed_repository.dart`）；`resolve` 还在异常时静默回退（第 118–126 行）——
出问题时会掩盖引擎缺陷。

### 2.12 `Media` 模型与 Dart `PlaybackPlan` 不匹配

| Dart `PlaybackPlan` | Rust `Media` |
| --- | --- |
| `session`、`routeIndex`、`routeCount`、`hasAlternative` | 无 |
| `qualities: List<int>`、`quality` | 无 |
| `expiresAt`、`prefetchedBytes`、`danmakuId` | 无 |
| `local`（本地文件播放） | 无 |
| `headers: Map<String,String>` | 仅 `referer` |

即「自动切线 / 画质切换 / 预加载复用 / 本地播放」在引擎侧没有承载结构。

---

## 3. 正确性缺陷（P2）

> **2026-10-19 更新**：§3.1–§3.4 与 §2.11 的部分问题已在 P0 修复，
> 逐项状态见 `PROGRESS.md` 第十二轮。以下保留原始记录作为问题依据。

### 3.1 非 HLS 媒体也被整段下载

`rust/bridge/src/sources/rule_source.rs` 的 `finish_media`（第 234 行起）对**任何**地址先执行
`env.text(...)`（第 243–245 行）再判断是否 HLS。`resolve()` 在地址像媒体时也会走这里（第 196–199 行）。
后果：MP4 直链在取流阶段被完整读入并做 UTF-8 解码，既浪费流量与内存，也可能因解码失败报错。

**修复**：先发 `HEAD` 或带 `Range: bytes=0-1023` 的 `GET`，只在前缀确认为 `#EXTM3U` 时拉全量播放列表。

### 3.2 下载删除会误删其它任务

`rust/bridge/src/scheduler.rs` 的 `"delete"` 分支先 `jobs.remove(id)`，随后
`self.target_of(id)` 已取不到目标，得到空路径 `""`，`discard(PathBuf::from(""))`
实际清理的是 `.part` / `.json` 相对路径，**目标文件不会被删**；
若当前工作目录恰好有同名文件，存在误删风险。

**修复**：在 `remove` 前取出 `target`。

### 3.3 下载任务无取消、无重定向续传校验

- `Scheduler::run` 全程不可取消；`pause` 只改状态，正在跑的任务继续下载到结束；
- `download_file` 用 `If-Range` 传 `state.validator`，但 `FileState.validator` **从未被写入**
  （没有读取 `ETag`/`Last-Modified`），因此续传无法发现服务器内容变化；
- HLS 下载每次 `download_hls` 都 `remove_file(part_path)` 从零开始（`download.rs:65`），
  与文档宣称的「断点续传」不符。

### 3.4 `panic = "abort"` 与 FRB 的 catch_unwind 冲突

`rust/Cargo.toml` 的 `[profile.release] panic = "abort"`；
`flutter_rust_bridge` 依赖 `catch_unwind` 把 Rust panic 转成 Dart 异常。
在 abort 模式下任何 `expect`（如 `cache.rs` 的 `Mutex` 中毒分支）都会直接终止进程，
且生成的绑定无法兜底。**需改为 `unwind` 并补 `panic::set_hook` 上报。**

### 3.5 `init_engine` 从未被调用

FRB 导出了 `initEngine()`，但 `EngineRepository.create()` 只调用 `RustLib.init()`，
`lib/` 内没有任何地方调用 `initEngine()`，日志与 `setup_default_user_utils()` 未生效。

### 3.6 规则解析每次重新编译选择器

`rust/bridge/src/rule/executor.rs` 的 `select_and_read`（第 275 行起）对**每条记录、每个字段**
都执行 `Selector::parse`。200 条 × 8 字段 = 1600 次解析/页，属于可避免的开销；
`RuleDocument` 也没有选择器缓存。

### 3.7 `validate_rule` 只返回 id

`api.rs:74` 的 `validateRule` 仅返回 `rule.id`，没有任何诊断信息（哪一行、哪个字段、为什么），
无法支撑目标中的「规则编辑器即时提示」。

---

## 4. 缺失的迁移资产

### 4.1 Go 版功能分布（非测试 20,893 行）

| 领域 | 行数 | Rust 现状 |
| --- | --- | --- |
| 红果主源（12 文件） | 2,421 | 无 |
| 榜单（4 文件） | 734 | 无 |
| 12 个合作短剧源（8 文件） | 2,986 | 6 个声明式 + 猫果 |
| 其它站源（黄豆/剧果/野果/帝果/黄果/旧版，15 文件） | 5,196 | 无 |
| 取数公共层 | 520 | 无 |
| 播放 / 取流 / 本地流服务 | 843 | 仅取流解析，无流服务 |
| 下载 / 合并 / 导出 | 1,243 | 基础下载 |
| 目录 / 缓存 / 站源任务 | 1,543 | 缓存合并，无任务系统 |
| 网络 / 代理 / DNS / 限流 | 1,304 | 无 |
| 局域网互联 | 699 | 无 |
| 封面 / 图片 | 1,000 | 无 |
| 弹幕 | 308 | 无 |
| 引擎外壳 / 设置 / 诊断 | 1,641 | 无 |
| 其它（推荐 / 联想 / 榜单入口 / 存储平台） | 455 | 无 |

### 4.2 Dart 侧与站源耦合的硬编码

- `lib/models.dart:74`：`SourceSite.values = allSourcesEnabled ? knownValues : [hongguo]`，
  站源可用性由**编译开关**决定；`ProfilesScreen` / `LocalStore` 均从该常量表派生。
- 22 处 `'hongguo'` 字面量判断（`core_bridge.dart`、`player_screen.dart`、`home_screen.dart`、
  `ranking_models.dart`、`local_store.dart`、`follow_state.dart`、`hongguo_series.dart`、`lan_models.dart`）。
- 目标形态：站源列表来自引擎 `SourceDescriptor`，编译开关在 P4 删除。
  D5 已定「完全移除 Go」，因此这不只是「加一层抽象」：`ALL_SOURCES` 的两套编译版
  本身就是 Go 时代的产物，P4 之后站源集合只由「装了哪些插件」决定，不存在编译期裁剪。

---

## 5. 已完成且可复用的资产

| 资产 | 位置 | 迁移价值 |
| --- | --- | --- |
| 声明式 DSL 雏形（HTML/JSON/inline 三类） | `rust/bridge/src/rule/*` | 直接演进为 `spec 2` |
| 模板渲染（`{page}/{id}/{md5:…}` 等） | `rule/rules.rs` | 保留并扩展 token |
| HLS 解析与 AES-128 解密 | `rust/bridge/src/media.rs` | 直接复用；已用 NIST 向量验证 |
| 断点续传骨架 | `rust/bridge/src/download.rs` | 需修 §3.1–3.3 后复用 |
| 目录缓存合并语义 | `rust/bridge/src/cache.rs` | 与 Go 对齐，可直接复用 |
| FRB + cargokit 构建链 | `rust_builder/` | 已打 5 个补丁，必须保留 |
| 163 项 Rust 测试 | `rust/bridge`、`rust/crates` | 作为迁移基线 |
| Go 帧测试夹具（HTML/JSON） | `rust/bridge/tests/fixtures`、`native/core/*_test.go` | 迁移对拍输入 |
| POC 结论（rquickjs / FRB 四端 / TLS） | `docs/poc-*.md` | 约束依据 |

---

## 6. 本机实测记录（2026-10-19）

| 命令 | 结果 |
| --- | --- |
| `cd rust && cargo test --offline` | ✅ 156 项通过 |
| `cd rust && cargo clippy --offline --all-targets -- -D warnings` | ✅ 零告警（增量缓存，0.7s） |
| `cd native && go test ./...` | ❌ 6 项失败 + 1 次 panic（见 §1.2） |
| `cd reference/guoapp/native && go test ./...` | ❌ 同上（两目录内容一致） |
| `rustup target list --installed` | aarch64-apple-{darwin,ios,ios-sim} / aarch64-linux-android / armv7 / i686 / x86_64-{apple-ios,linux-android,pc-windows-msvc,unknown-linux-gnu} |
| 工具链 | rustc 1.97.1、cargo 1.97.1、Dart 3.13.5、Go 1.26.6、FRB codegen 2.13.0 |
| `rust/target` 体积 | 7.1 GB（未纳入同步，但会持续增长） |

---

## 7. 建议的修复顺序（对应架构文档阶段）

> D1（代码插件进 P1）与 D3（签名不强制）已于 2026-10-19 定案，顺序按此调整。

1. **P0**：补 Rust CI、纳入版本管理、修复 `panic=abort`、同步脚本与版本号。
2. **P0**：修复 Go 参考测试，恢复对拍基准。
3. **P0**：wasmtime + Pulley 三端编译探针（iOS / Android / Windows 各一次空组件实例化），
   记录体积与冷启动；这是 D1 的可行性门槛。
4. **P1**：拆工作区；实现 `source-api` / `rule-engine` / `plugin-host` / `plugin-wasm`；
   迁移 6 条规则到 `spec 2`；类型化错误 + 取消；传输层流化与网络治理；
   官方仓库 + 安装/卸载 + 哈希强制 / 签名可选。
5. **P1**：红果主源迁移（目录游标、详情、取流、搜索、分类），以 Go 夹具对拍。
6. **P1**：猫果代码插件三端跑通；补齐能力位与 `Media` 模型。
7. **P2**：其余 Go 独占源、插件更新通道、性能回归门槛。
8. **P3**：流服务、下载收口、局域网。
9. **P4**：删除 Go、改写构建与 README。

---

*本审计基于工作区当前文件；`rust/target` 与 `reference/` 不计入同步产物。*
