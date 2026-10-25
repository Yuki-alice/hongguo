# Rust 引擎评审与优化方案

> 评审日期：2026-10-24 · 依据当前工作区代码实测（非文档转述）
> 关联：`docs/ARCHITECTURE.md`（设计）、`docs/HANDOFF-BACKEND-TASKS.md`（交接任务）、
> `docs/PERFORMANCE.md`（基线）
> 本文只讲**当前代码里真实存在的问题**与可执行改法，不复述架构文档。

---

## 0. 一句话结论

架构方向是对的（契约层 + 单例引擎 + 能力层拆分 + 依赖铁律有测试守卫），
但**收敛没做完**：站源双轨删不掉的根因是 Wasm 宿主能力不全；
**观测没接线**：`record_error` 无人调用；
**落盘与内存有几处放大**：整文件下载不分片缓冲、每次 `set` 全量重写、锁内同步 IO；
**门禁当前是红的**：`worker_probe.rs` 4 个编译错误。

---

## 1. 现状实测

### 1.1 规模（`find rust -name '*.rs'`，不含 target 与 `frb_generated.rs`）

| crate | 文件 | 行 | 内联用例 | 集成测试 |
| --- | --- | --- | --- | --- |
| `engine` | 12 | 3183 | 49 | 1 |
| `plugin-wasm` | 15 | 3079 | 13 | 10 |
| `plugin-host` | 10 | 2693 | 47 | 1 |
| `runtime` | 7 | 3046 | 55 | 0 |
| `rule-engine` | 7 | 3368 | 52 | 0 |
| `source-hongguo` | 11 | 3938 | 56 | 5 |
| `source-api` | 9 | 1126 | 14 | 1（依赖方向守卫） |
| `host` / `media` | 4 | 920 | 24 | 0 |
| `source-*`（其余 5 个） | 12 | 3357 | 47 | 0 |
| `bridge` | 38（含 14 个 example） | 6518 | — | 19 |

合计约 31.2k 行（含 example 与 `frb_generated.rs`）。非测试代码里
`.unwrap()` / `.expect()` **310 处**，`unwrap_or*` 237 处。

### 1.2 编译门禁（实测）

```bash
cd rust && cargo check --workspace --all-targets
```

结果：**失败**。`bridge/examples/worker_probe.rs` 4 个错误，与交接文档 §2.3 预判完全一致：

```
worker_probe.rs:3:5  error[E0432]: unresolved import `guo_engine::pump_downloads`
worker_probe.rs:68:72 error[E0277]: Vec<String> cannot be built from Iterator<Item=JobState>
worker_probe.rs:70:43 error[E0308]: expected `JobState`, found `&str`
worker_probe.rs:73:44 error[E0308]: expected `JobState`, found `&str`
```

根因不是探针本身，而是**桥接层的导出面不完整**：`pump_downloads` 由
`guo-engine-core` 导出，`bridge/src/lib.rs` 的 re-export 列表里没有它。
`cargo test` 会编译 examples，因此这一条足以让整个 Rust CI 变红。

---

## 2. 应当保留的设计（不要动）

1. **`source-api` 零 IO 契约 + `tests/dependency_direction.rs` 守卫**——
   用测试把「契约层不许出现 tokio/reqwest/wasmtime」固化下来，比人工评审可靠。
2. **注册表重建不碰会话 / 缓存 / 下载**（`rebuild_registry`）—
   插件装卸不影响登录态与任务表，这条有测试兜底，是插件化的前提。
3. **`EngineError` 11 类 + 边界扁平 DTO `EngineFailure`**——
   避免外部 crate 类型在 Dart 侧退化为不透明句柄，方向正确。
4. **取消代次（`session` + `sequence`）**——服务端不可取消，用代次作废替代，是正确取舍。
5. **下载索引原子写 + 缩容只回收空闲许可**（`set_concurrency`）——
   不会掐断在途任务，也不存在半截 JSON。
6. **插件沙箱三层约束**：导入白名单（只许 `guo:source/*`）、域名/存储命名空间、
   fuel 与内存上限。

---

## 3. 问题清单

### P0-1 门禁是红的：桥接层导出面不完整

**证据**：见 §1.2。
**影响**：`cargo test --workspace` 编不过，CI 全红；任何后续改动都无法验证。
**改法**（二选一，推荐 a）：
- a. `bridge/src/lib.rs` 的 `pub use guo_engine_core::{...}` 补上 `pump_downloads`，
  并把 `worker_probe` 里三处 `job.state` 的比较改成 `JobState` 枚举比较；
- b. 直接删掉 `worker_probe.rs`，把它的本地 HTTP 服务器思路转成
  `bridge/tests/download_worker_test.rs`（交接文档 T1.3 已列）。
**注意**：选 a 之后 `pump_downloads` 就在公开 API 上了，它接受 `&Arc<Engine>`，
必须在文档里写明「这不是 FRB 可调用函数」，否则下次 codegen 会被误当成绑定入口。

### P0-2 站源双轨删不掉，根因在 Wasm 宿主能力不全

**证据**：`crates/plugin-wasm/src/component.rs` 的 `impl SourcePlugin for ComponentSource`
只实现了 `categories` / `catalog` / `detail` / `search` / `resolve` **5 个方法**；
而 `SourcePlugin` trait 有 10 个方法，WIT 还声明了 `suggestions` 导出。

**影响**：编译版有、插件版没有的能力——`ranking_boards` / `ranking` /
`recommend` / `suggestions` / `danmaku` / `seasons`——插件一律返回 `Unsupported`。
所以 `source-maoguo` / `niuguo` / `yaguo` / `huangju` / `huangguo` 这 6 个源的编译版
**现在删不掉**，PLAN §3 P0「消除双轨」事实上被这条卡住。双轨意味着同一份站点知识维护两遍。

**改法**（顺序不能反）：
1. WIT 补齐 6 个导出，7 个官方插件逐个实现（红果不涉及）；
2. `ComponentSource` 补齐对应方法，与编译版做对拍测试（复用现有 fixture）；
3. 确认能力矩阵一致后，再逐个删 `source-*` crate 与 `register_builtin_sources` 注册行。

### P0-3 观测断链：诊断页「最近错误」永远为空

**证据**：`Engine::record_error` 只有 `engine/src/engine.rs` 的测试调用；
`bridge/src/api/mod.rs` 里唯一的错误收口是 `run()`，`Ok(Err(error))` 与超时分支
都直接转 `EngineFailure` 返回，没有写入 `recent_errors`。

**影响**：出错只能靠 stderr，用户侧诊断页失效，线上问题无法自助定位。
**改法**：`run()` 是唯一收口，改一处即可。但它目前只有 `source_id` 字符串，
拿不到 `Arc<Engine>`——把签名改成 `run(engine: &Arc<Engine>, ...)` 或在函数内
`guo_engine_core::require()` 取一次单例，两处错误分支各加一行 `record_error`。

### P1-1 整文件下载不分片，峰值内存 = 文件大小 × 并发数

**证据**：`crates/runtime/src/download.rs` 只有 `download_file_with` / `download_hls_with`
两个入口，内部都是 `env.transport.fetch(...)` 拿到**完整 `response.body`**，
再一次性 `write_atomic(&part_path, &body)` 或 `append`。全文件没有 `chunk()` 流式路径。
HLS 路径按分片走，天然安全；**单文件（MP4）路径是整块缓冲**。

**影响**：`Scheduler` 并发上限 6，理论峰值 = 6 × 单集大小。一集 1 GiB 就是 6 GiB RSS。
这与 `PERFORMANCE.md` §3「内存基线未做」叠加，是移动端 OOM 的高风险区。

**改法**：给 `FetchRequest` 增加「流式落盘」模式（宿主侧 `bytes_stream()` 边收边写，
`max_bytes` 语义改为上限而非预分配），`download_file_with` 走这条路；
或者退一步——把单文件下载拆成 Range 分片（每片 8–16 MiB）串行拉取，
复用 HLS 的分片写盘与续传逻辑，改动最小且立刻拥有断点续传精度。

### P1-2 每次 `set` / `update` 都是全量序列化 + 写临时文件 + rename

**证据**：
- `DiskSourceStore::set`（`engine/src/store.rs`）：持锁 → 改内存 → `write_disk` 全量写；
- `CatalogCache`：目录更新时全量写 `catalogs.json`（上限 32 MiB）；
- `Scheduler::update`：`recorder` 闭包在每个分片完成时调用一次，
  每次都是全量写 `downloads/index.json`。

**影响**：三处都是「改一个字段，重写整个文件」，且**同步 IO 发生在 `std::sync::Mutex`
临界区内**，会阻塞 tokio 工作线程。下载一个 300 分片的剧 = 300 次全量索引重写。

**改法**（按性价比排序）：
1. 下载索引的进度更新节流：内存里更新 `bytes`，落盘走「≥1 s 或状态迁移才写」的
   dirty flag + 后台任务合并写；
2. 把三处 `write_disk` 从锁内挪到锁外（先 clone 快照、释放锁、再写），
   或用 `tokio::task::spawn_blocking` 承载同步写；
3. 会话存储量小，可暂不优化，但同样应移出临界区。

### P1-3 rule-engine 的选择器在热路径上重复编译

**证据**：`crates/rule-engine/src/executor.rs` 的 `select_and_read`
对每个节点、每个字段都调用一次 `Selector::parse(selector)`；
`extract_items` 与 `has_selector` 同样现编现用。

**影响**：`guo-bench` 的 `catalog_html/wuguo` P50 是 2436 µs（51 KB HTML）。
一份 50 条 × 8 字段的目录 = 400 次选择器编译，这部分是纯浪费。

**改法**：`RuleSource::from_json` 时把规则里的选择器**预编译**一次，
存进 `Arc<CompiledRule>`；或加一个 `OnceLock<Mutex<HashMap<String, Selector>>>`
全局选择器缓存。改完用 `cargo run --release -p guo-bench` 对比，
预期 wuguo / wangguo 两条用例有可观测下降，并同步更新 `PERFORMANCE.md` 基线。

### P1-4 Wasm 插件的三重执行代价

**证据**：`crates/plugin-wasm/src/component.rs` 每个方法都是
`spawn_blocking(|| { 新建 Store → instantiate → call })`；
`crates/plugin-wasm/src/sandbox.rs` 的 `block_on` 自建了一个
**独立的 current-thread runtime**，宿主 `fetch` 全部在它上面 `block_on`。

**影响**：
- 每次调用占一个阻塞线程直到插件返回，而插件内部还在同步等网络；
- 全局只有一个插件 runtime，**所有插件的 HTTP 请求天然串行**；
- 与编译源完全不在同一条执行路径上，性能与并发语义都不同。

**改法**：
1. 短期：明确「插件侧请求串行」是有意语义，写进 `ARCHITECTURE.md` 与插件清单文档；
   给插件调用加 epoch deadline（目前只有 fuel），避免坏插件永久占住阻塞线程；
2. 中期：为插件调用建**有界专用线程池**，不要和 `spawn_blocking` 全局池混用；
3. 长期：ADR-11 关闭 wasmtime `async` 的理由（fiber 协程栈）只在 iOS 成立，
   可在非 iOS 平台按 `cfg` 开启 `async`，让插件请求回到 tokio 生态。

### P2-1 桥接层单文件膨胀

`bridge/src/api/mod.rs` 1829 行，其中 `health_inner` 一个函数约 230 行。
`check_source` 的四步探测（目录→详情→取流→媒体连接）逻辑本身是对的，
但和目录/详情/下载/设置挤在一个文件里，改一处要滚很久。
**改法**：按域拆成 `api/catalog.rs` / `api/detail.rs` / `api/download.rs` /
`api/health.rs` / `api/settings.rs`，`mod.rs` 只留 `run()` `prepare()` 与重导出。
拆完必须重跑 `flutter_rust_bridge_codegen generate`。

### P2-2 310 处 `unwrap` / `expect`

`profile.release` 保留了 `panic = "unwind"`（FRB 依赖它把 panic 转成 Dart 异常），
所以 panic 不会杀进程，但**锁中毒是永久性的**：`store.rs` / `scheduler.rs` /
`cache.rs` 里 `lock().expect(...)` 一旦中毒，该 subsystem 从此全量失败且不恢复。
**改法**：对 `engine` / `runtime` / `bridge` 三个 crate 开
`clippy::unwrap_used` / `expect_used`（warn 起步），存量分批收敛；
`Mutex` 中毒统一改成「返回默认快照 + 记一次 `record_error`」，
与 `engine.rs` 里 `registry()` / `load_report()` 已有的写法保持一致。

### P2-3 测试分布不均，主源没有实网金丝雀

`source-maoguo` 6 / `niuguo` 5 / `yaguo` 6 条内联用例，`runtime` / `rule-engine`
有内联用例但**零集成测试**；红果是主源，却只有 fixture 回放，没有在线用例。
这正是交接文档 §1 说的「测试全绿、生产全坏」事故的成因。
**改法**：T1（红果金丝雀）优先于任何新功能；它必须**不加 `#[ignore]`**，
断网即红，这是金丝雀的全部意义。

---

## 4. 优化路线（按序执行）

| 步骤 | 内容 | 产出 | 预估 |
| --- | --- | --- | --- |
| S1 | 修 P0-1，恢复 `cargo test --workspace` 绿灯 | CI 可验证 | 0.5h |
| S2 | 接线 P0-3 `record_error` | 诊断页可见最近错误 | 1h |
| S3 | 红果实网金丝雀进 CI（T1） | 站点改版当日可发现 | 2h |
| S4 | P1-2 落盘节流 + 锁内 IO 外移 | 下载写盘次数降一个量级 | 1.5h |
| S5 | P1-3 选择器预编译 | bench 数字下降，基线更新 | 1h |
| S6 | P1-1 下载改分片/流式 | 内存峰值可控 | 3h |
| S7 | P0-2 补 WIT 6 个导出 + 7 插件实现 | 解锁双轨清理 | 8h+ |
| S8 | 删除 6 个 `source-*` crate | 单栈达成（PLAN §3 P0） | 2h |
| S9 | P2-1 拆 `api/mod.rs`、P2-2 收敛 unwrap | 可维护性 | 3h |

S7/S8 是唯一的大块工作，但它是 PLAN 里「可发布」定义第 1 条，
做完之前双轨维护成本会一直存在。

---

## 5. 验收命令

```bash
cd rust
cargo check --workspace --all-targets          # S1 后必须全绿
cargo test --workspace                          # 基线 534 通过
cargo clippy --workspace --all-targets -- -D warnings
cargo fmt --all --check
cargo run --release -p guo-bench                # S5 前后对比

cd ..
dart analyze lib                                # 0 error / 0 warning
flutter test --exclude-tags engine
flutter_rust_bridge_codegen generate            # 改过 bridge/src/api 后必须跑
```

内存回归目前没有护栏（`PERFORMANCE.md` §3）。建议在做 S6 的同时，
用 `std::alloc` 计数包装器把「引擎堆占用」暴露到 `engine_diagnostics`，
否则 S6 的效果无法验收。
