# 交接任务书：红果协议层与下载 worker 收尾

> 生成：2026-10-24 · 依据当前工作区实况（未提交改动 65 个文件）
> 交给：接手实现的 agent
> 前置阅读：`docs/ARCHITECTURE.md`（架构与 ADR）、`docs/PLAN.md`（路线图）
> 本文档自包含：所有结论都有实测依据，所有任务都有验收标准。

---

## 0. 怎么使用这份文档

1. 先读 §2「当前工作区状态」，**必须先完成 T0（修复三个堵点）**，否则测试套件编不过。
2. 按任务编号顺序做（T0 → T1 → …）。每个任务自带涉及文件、做法、验收。
3. 改 Rust 桥接层（`rust/bridge/src/api/`）后必须重新生成 FRB 绑定（§4.3）。
4. 验收统一用 §5 的命令清单。**不要跳过实网验证**——这个项目最大的教训就是「离线测试全绿、生产端到端是坏的」。

---

## 1. 已定性的实测事实（2026-10-24，全部实网验证）

这些结论花费了大量探测，**不要重新推导，直接引用**。

### 1.1 红果 App 接口（api5-normal-sinfonlineb.fqnovel.com）

| 端点 | 状态 | 说明 |
| --- | --- | --- |
| `/novel/player/video_detail/v1/`（POST） | ✅ 可用 | **必须带 X-Argus/X-Ladon 评论签名**。返回 ~261KB：全量 `video_data`（标题/简介/封面/集数/热度）+ `video_list[308]`（每集 vid/vid_index/duration）。 |
| `/novel/commentapi/comment/list/<vid>/v1/`（POST） | ✅ 可用 | **必须带评论签名 + `Comment-Source: 601` + `Server-Channel: 1000` 头**。返回真实弹幕（`data.data_list[]`，`data_type=4`，`expand.offset_time` 毫秒）。缺签名 → `{"Code":110001}`。 |
| `/novel/player/video_model/v1/`（POST/GET） | ❌ 已死 | 一律 `200` + **空响应体**。已排除的变量：仅 Gorgon、评论签名、content_type 1/1004、有无 biz_param、Comment 头、换设备号、HTTP/1.1/2、域名变体（sinonlinea / snssdk.com——后者返回头条主页 HTML）。**匿名全量画质通道已被服务端关闭**，不要再花时间试。 |
| `/service/2/device_register/` | ❌ 404 | 参考实现（Go）从未调用过它；Rust 注释里「设备注册未接」是误解。 |

### 1.2 红果网页（hongguoduanju.com）

| 通道 | 状态 |
| --- | --- |
| 目录页（`/category/<route>?page=N`） | ✅ `_ROUTER_DATA` 仍在，96 条/页 |
| 详情页（`/detail?series_id=`） | ✅ `vid_list` 全量分集仍在 |
| 播放页（`/player/<sid>/<vid>`） | ⚠️ 不再下发 `video_player_info`；`protectedPlayback: true`、`pcPlaybackAuthState: "guest"`。只剩 `publicVideoSeo` 公开试看通道：`/video/public/<vid>/360p.mp4`，**固定 360p，多数剧只有第 1 集可用**（实测 ep1 200，ep2 起多数 404/401），且仅 360p 一档（480p/540p/720p/1080p 全 404）。 |
| 榜单页（`/rank/<path>`） | ✅ 行数据改由 `data-fn-name="r"` + `data-script-src="modern-run-router-data-fn"` 的脚本承载，**属性用单引号**；同页 `mergeLoaderData` 段是占位（无 rankList）。已在本轮修好（`rankings.rs`）。 |
| 搜索页（`/search/<kw>`） | ❌ 改客户端渲染，无 `_ROUTER_DATA`。已改走联想接口（见下）。 |
| 联想接口（`/incent_resource/suggestion`） | ✅ `word_type=short_play_name` 的行带完整 `video_data`（series_id/封面/集数/简介），能直接构造可点开条目，是最可用的搜索数据源 |

### 1.3 第三方与其余源

- 参考 Go 实现的备用解析接口 `https://djapi.999888456.xyz/api/hongguo/play`：**已死**（`v2.` 加密协议仍可解密，但内容恒为 `{"parse":0,"url":""}`）。
- 全源取流实测：**可用** maoguo / yaguo / heguo / wangguo / huangguoai；**不可用** hongguo(仅试看) / niuguo(解析服务器挂) / huangju(404) / cloudfront(4001) / huangguo-video(403) / huaguo(403) / fanguo(解析失败) / guanguo / xingguo / wuguo(空) / dsd(空)。

### 1.4 关键架构结论（沿用自上一轮评审）

- 红果被从「协议客户端」降级成「网页爬虫」是重写最大的失误；**Argus/Ladon 评论签名是当前 App 接口的准入门槛**，本轮已完成 Rust 移植与 Go 向量对拍。
- `video_model` 死了意味着 CENC 密钥（`spade_a`）目前没有数据来源；契约字段（`Media.cenc_key`）本轮已铺好，`hongguoContentKey`（Go 版 `provider_hongguo_playback.go` 里的解密函数）**尚未移植**——将来该接口恢复时再移植，不要现在做无用功。

---

## 2. 当前工作区状态

### 2.1 已完成（本轮未提交改动，全部在位）

**Rust — 红果签名与协议（`rust/crates/source-hongguo/`）**

| 文件 | 内容 |
| --- | --- |
| `src/argus.rs`（新增） | SM3 / Argus / Ladon / 评论版 Gorgon，逐字节对齐 Go 参考实现。含三个关键坑的修正（见 §4.1）。导出：`comment_headers` / `sm3` / `CommentHeaders` / `CommentNonce`。 |
| `tests/hongguo_argus_parity.rs`（新增） | 对拍测试：18 组签名向量 + 4 组 SM3 向量 + SM3 标准向量。**全绿**。 |
| `tests/hongguo_sign_vectors.json`（新增） | Go 参考实现生成的黄金向量。 |
| `src/sign.rs` | `md5_bytes` 改为 `pub(crate)`（argus.rs 复用）。 |
| `src/source.rs` | ①`danmaku()` 重写：评论签名 + Go 版 payload（`comment_source=601/group_type=30/comment_type=20/book_id=series_id/start_offset_time/need_danmaku_guide_type`）+ 新解析器；②`signed_comment_request()` 新增（镜像 `signed_app_request`，评论头 + 空的 X-SS-STUB）；③取流降级链：`video_player_info` → `publicVideoSeo` 公开试看（带明确错误文案）；④推荐改走网页分类页；⑤搜索改走联想接口（`search_by_suggestion` + `parse_suggestion_dramas`）；⑥榜单承载形态修复在 `rankings.rs`（三种 `data-fn-name` + 单双引号 + 取内容更全的一段）。 |
| `src/capabilities.rs` | `parse_danmaku(body, video_id, start_ms)` 全新解析器（`data_list`/`next_query_danmaku_list_time`/status 过滤/去重/180 字截断）+ `parse_suggestion_dramas`（联想行 → 完整 `Drama`）。测试已重写，**全绿（56 通过）**。 |
| `Cargo.toml` | 新增 `aes` 依赖（`source-huangguo` 已有先例）。 |

**Rust — 契约与引擎**

| 文件 | 内容 |
| --- | --- |
| `crates/source-api/src/model.rs` | `Media` 新增 `cenc_key: String` / `quality: u32` / `qualities: Vec<u32>`（serde default）。注意：`Chapter.vip: bool` **本来就存在**，别再加。全部 18 处 `Media { ... }` 构造点已补齐字段。 |
| `crates/runtime/src/scheduler.rs` | 新增 `claim_next()`（原子认领 Queued→Running）与 `queued_count()`。 |
| `crates/engine/src/engine.rs` | 新增 `pump_downloads(engine: &Arc<Engine>)` 关联函数（worker 循环：认领→执行→再认领，耗尽自然退出）；`Engine` 新增 `download_workers: AtomicUsize` 与 `worker_handle: Option<Handle>`（FRB 同步调用里没有 tokio 上下文时兜底）。 |
| `crates/engine/src/lib.rs` | 导出 `pump_downloads`。 |
| `bridge/src/api/mod.rs` | ①`check_source(source_id, request_id, playback)` 站源健康检测（四步：目录→详情→取流→媒体连接，实测红果/maoguo/yaguo 全 `ok`）；②`MediaResult` + `cenc_key/quality/qualities`；③`ChapterInput`/`ChapterItem` + `vip`；④`fetch_danmaku` 返回 `DanmakuPageResult { items, end_ms, has_more }`（服务端窗口游标过桥——这是修「弹幕跳段」的根因）；⑤`enqueue_download`/`control_download(s)`/`control_download_batch` 在 resume/retry 后调 `pump_downloads`。 |
| FRB 绑定已重新生成 | `lib/src/rust/**` 与 `rust/bridge/src/frb_generated.rs` 同步过一次（在 ①②③④ 之后；⑤ 不改签名无需再生成）。 |

**Dart**

| 文件 | 内容 |
| --- | --- |
| `lib/data/engine_repository.dart` | `danmaku` 返回 `DomainDanmakuPage`（带 `endMs`）；`resolve` 映射 `decryptionKey/quality/qualities`；`_chapterInput` 带 `vip`；`registerDownload`（只登记）/`runDownload`（显式执行，仅诊断用）/`checkSource`/`cancelSourceCheck`。 |
| `lib/data/engine_backed_repository.dart` | 弹幕窗口用服务端游标（`_min(page.endMs, durationMs)`）；下载命令映射（`remove→delete`、`pauseAll→逐任务 pause`、`archive/restore→本地旗标`）；`enqueueDownloads` 改为登记 + 后台执行；`sourceStatus/startSourceJob/cancelSourceJob` 真实现（后台检测 + 轮询可见）；能力位 `sourceManagement: true` 已打开。 |
| `lib/domain/ranking_models.dart` | 新增 `DomainDanmakuPage`。 |
| `lib/domain/source_status.dart` | `SourceStatus`/`SourceHealth` 补直接构造器。 |
| `lib/domain/models.dart` | `DownloadJob.active` 认 `running`；`stateLabel` 补 `running → 正在下载`；快照带 `revision`。 |
| `lib/data/local_store.dart` + `local_snapshot.dart` | 归档任务 id 集合（键 `archivedDownloads`，设备级）。 |
| `lib/data/plugin_repository.dart` + `lib/ui/providers/app_providers.dart` | `PluginRepository.ready()` 修复「插件页永远空列表」。 |
| `lib/ui/features/search/views/search_screen.dart` | 联想词（300ms 防抖，未提交搜索时显示，点击直达）。 |
| `lib/src/rust/**` | FRB 生成物（已含 `checkSource`/`MediaResult.cencKey`/`DanmakuPageResult` 等）。 |

`dart analyze lib`：0 error / 0 warning（24 条 info 与本轮无关）。

### 2.2 实测结论（本轮已完成的部分）

- 弹幕 Rust 全链路（`bridge/examples/hongguo_danmaku_probe.rs`）：`start=0/30000/60000` 分别 83/80/68 条真实弹幕，窗口 `[0,30000)/[30000,60000)/[60000,90000)`，**服务端按 30s 分段**。
- 健康检测（`check_source`）：hongguo/maoguo/yaguo 全 `ok`，四步各自带毫秒耗时。

### 2.3 ⚠️ 三个堵点（T0，必须最先做）

`cargo build --workspace` 通过，但 **`cargo test --workspace` 编不过**：两个未跟踪的临时探针例子有编译错误。

1. `rust/bridge/examples/worker_probe.rs`：
   - `use guo_engine::pump_downloads;` —— 解析失败。原因：`pump_downloads` 由 **`guo-engine-core`** crate 导出，bridge crate（`guo_engine`）没有 re-export。改 `use guo_engine_core::pump_downloads;`（bridge 的 Cargo.toml 已依赖 guo-engine-core）。
   - `job.state` 是 `JobState` 枚举不是 `String`：三处（68/70/73 行）改为 `job.state.as_str()` / 直接比较 `JobState::Completed`。
2. `rust/bridge/examples/hongguo_danmaku_probe.rs`：本身能跑，但按 T1 应**转正为金丝雀测试后删除**。
3. `/tmp/vectorgen2/`（向量生成器）是临时目录，**会丢**。见 §4.2 的复现流程，把生成器落进仓库。

---

## 3. 任务清单

### T0 · 清理堵点，恢复测试绿灯（必做，预计 0.5h）

**做法**
1. 修复或删除 `rust/bridge/examples/worker_probe.rs`（推荐：修好后保留，它是 worker 行为的唯一可跑演示；或者直接删掉，由 T1.3 的测试替代）。
2. `hongguo_danmaku_probe.rs` 暂留（T1.1 要用它的内容）。

**验收**：`cargo test --workspace` 全绿（上一轮基线 65 个 suite 全 ok）。

### T1 · 红果实网金丝雀进 CI（P0，预计 2h）

**这是全项目最缺的一块**：红果是主源，却是唯一没有实网测试的源（只有 fixture 回放）。站点再改版时，当前这类「测试全绿、生产全坏」的事故必须被 CI 拦住。

**做法**
1. 新建 `rust/bridge/tests/hongguo_live.rs`，把 `hongguo_danmaku_probe.rs` 的链路转成测试（参考 `bridge/tests/maoguo_live.rs` 的结构：`NoopStore`/`NoopLog` + `#[tokio::test]`）：
   - `catalog_and_detail_live`：目录 ≥ 10 条；详情分集 ≥ 1 且 `video_url` 以 `hongguo-cenc://` 开头、`source` 是纯数字 series_id。
   - `danmaku_live`：取目录第一部剧第一集，`danmaku(env, chapter, 0)` 成功；断言 `end_ms > 0`（游标存在）。**不要**断言条目数 ≥ 1（冷门剧可能没弹幕）；可对榜单第一部（有 1394 条评论的量级）断言 ≥ 1。
   - `suggestions_live`：`suggestions(env, "总裁")` ≥ 1。
   - `ranking_live`：四个榜单第 1 页各 20 条（分页语义靠名次区间校验，解析器已内建）。
2. 删除 `hongguo_danmaku_probe.rs`（内容已转正）。
3. （可选加固）engine worker 行为测试：登记两个任务 → `pump_downloads` → 轮询快照直到 completed（用 `worker_probe.rs` 的本地 HTTP 服务器思路，放 `bridge/tests/download_worker_test.rs`；参考 `download_resume_test.rs` 已有的测试基建）。

**验收**：`cargo test -p guo-engine --test hongguo_live` 通过；断网时失败信息可读（失败即红——这就是金丝雀的意义，不要加 `#[ignore]`）。

### T2 · Dart 下载路径去双跑（P0，预计 1h）

引擎 worker 已接管执行，但 Dart 仍在手动驱动，会**双跑**同一任务（`run()` 从断点续传重入）。

**做法**
1. `lib/data/engine_backed_repository.dart` 的 `enqueueDownloads`：删除 `unawaited(_runDownload(id));` 与 `_runDownload` 方法（bridge 的 `enqueue_download` 内部已 `pump_downloads`）。
2. `lib/data/engine_repository.dart`：保留 `runDownload` 但加注释「仅诊断用，生产路径由引擎 worker 驱动」。
3. 检查 `resume` 路径：`controlDownloadBatch('resume')` → bridge 已 pump，Dart 无需再动。

**验收**：`dart analyze lib` 0 error；下载一个多集剧，观察任务列表从 queued→running→completed 全程无重复字节跳变（快照 bytes 单调）。

### T3 · 合并清理的版本闸门修复（P0，预计 1.5h）

**现状 bug**：`lib/data/media/media_merge_queue.dart:466` 传的 `expectedVersions` 是 `library._sourceVersion(job)` 生成的复合串（`"created-bytes-quality"`），`engine_backed_repository.controlDownloadBatch` 里 `int.tryParse(...) ?? 0` 解析恒为 0 → 与引擎真实 `revision`（≥1）永不相等 → 「合并后清理原分集」永远整批失败（报「任务已被更新，已跳过」）。

**做法**（推荐 b 案）
- a. 最小改：`media_merge_queue` 的 `task.versions` 直接存 `job.revision.toString()`（`DownloadJob.revision` 本轮已从快照透传）。
- b. 正确改：`_sourceVersion` 拆两件事——展示去重用复合串；版本闸门单用 `revision`。`MediaLibrary._sourceVersion` 保留展示用途，`MergeQueueJob.versions` 改存 `Map<String, int>`（revision），`controlDownloadBatch` 的 `expectedVersions` 类型随之改或由调用方转字符串。
- 全链路跑一遍：下载 2 集 → 本地媒体合并 → 清理原分集，确认原分集文件真的被删。

**验收**：手动触发一次「合并 + 清理」，引擎返回 `completed` 而非 failures；`downloads/` 下原分集文件消失、合并产物在。

### T4 · 观测接线：record_error（P1，预计 1h）

**现状**：`engine.record_error()` 只有测试调用，诊断页「最近错误」永远空。

**做法**：在 `bridge/src/api/mod.rs` 的 `run()` 错误分支（`Ok(Err(error))` 与超时分支）里，把 `EngineError` 记进 `engine.recent_errors()`（注意先取得 `Arc<Engine>`——`run()` 目前只有 source_id 字符串，需要把 engine 传进去或改为 `engine.recent_errors` 可达的调用形态）。同样接 `media_inner`/`detail_inner` 等所有 `run()` 使用点（它们都走同一个 `run()`，改一处即可）。

**验收**：断网点一次目录，诊断页（`/settings/diagnostics`）「最近错误」出现该记录。

### T5 · 站点重探与死源下架（P1，预计 2h）

用 `rust/bridge/examples/` 写一次性探针（用完删），对 §1.3 的死源清单复查一遍；确认仍死的，从 UI 隐藏（`SourceSite.reportFromEngine` 过滤或清单层面下架），避免用户点进必坏源。**不要删源码**——站点经常复活，只隐藏入口并在 `docs/PLAN.md` 登记。

**验收**：发现页/源管理页不再出现「点进去必失败」的源；存活的源全部可浏览。

### T6 · 文档同步（P2，预计 1h）

1. `docs/ARCHITECTURE.md` §9 FRB 函数表更新（新增 `check_source`；`fetch_danmaku` 返回结构变化）。
2. §2.1 能力矩阵更新：弹幕 ✅（评论签名已通）、推荐 ⚠️（网页分类页降级）、搜索 ⚠️（联想降级，≤10 条）、榜单 ✅。
3. `docs/PROGRESS.md` 追加一轮记录（本轮：评论签名移植 + 弹幕恢复 + 下载 worker + 契约扩展）。
4. **明确登记**：`video_model` 匿名通道已死（§1.1），全量画质需要登录态或渠道接口，属产品决策，不是工程待办。

---

## 4. 陷阱清单（每个都是真实踩过的坑）

### 4.1 评论签名的三处易错点（改 `argus.rs` 前必读）

1. **RC4 不是交换，是单向赋值**。Go 参考实现是 `box[i] = box[j]`（两处循环都是），不是标准 RC4 的 `swap(i, j)`。按「典型 RC4」写会得到完全不同的 seed，且**服务端不校验 Gorgon 所以不会当场报错**——只会更晚发现 Argus/Ladon 也被连坐校验失败。对拍测试是唯一防线。
2. **最终混淆循环读的是本轮已改写的值**。`seed[i] = rev(rotl(seed[i],4) ^ seed[(i+1)%20]) ^ 0xeb`，原地改写意味着最后一轮（i=19）读到的是**已改写**的 `seed[0]`；先存副本再算就错了。
3. **Argus 轮函数的操作数顺序**。Go：`left, right = right, left^(rotl(right,1)&rotl(right,8))^rotl(right,2)^round`——右侧三个 rotate 全部作用在**旧的 right** 上，同时求值再落盘。先 `swap` 再写会把 rotate 作用到错误操作数。
4. **Ladon 的 aid 取查询串实际值**（`aid=8662` → `"8662"`；无 aid → 空串），不要写死。

### 4.2 向量再生成流程（`tests/hongguo_sign_vectors.json` 过期时）

```bash
mkdir -p /tmp/vectorgen && cd /tmp/vectorgen
cp reference/guoapp/native/core/provider_hongguo_comment_sign.go ./comment_sign.go
sed -i '' 's/^package core$/package main/' comment_sign.go   # darwin；Linux 用 sed -i
# 写 main.go：固定 (query, nonce, timestamp) 三元组，构造 http.Request，
# 调 signHongguoCommentRequest，把 X-Gorgon/X-Khronos/X-Ladon/X-Argus 打成 JSON；
# SM3 向量直接调 hongguoSM3。生成器源码在本次会话的 /tmp/vectorgen2/main.go，
# 仓库里没有——**建议顺手把它落进
# rust/crates/source-hongguo/tests/tools/vectorgen/main.go**（T1 可一并做）。
go mod init vectorgen && go run . > rust/crates/source-hongguo/tests/hongguo_sign_vectors.json
```

### 4.3 FRB 再生成

```bash
flutter_rust_bridge_codegen generate   # 仓库根目录，读 flutter_rust_bridge.yaml
```
改 `rust/bridge/src/api/` 的**任何**签名/结构体后都要跑；忘了跑的典型症状是 `frb_generated.rs` 报 `SseEncode` not satisfied。生成后 `dart analyze lib` 必须复查（Dart 侧签名可能变）。

### 4.4 FRB 同步函数里没有 tokio 上下文

`enqueue_download` 等同步函数运行在 FRB 的工作线程，`tokio::spawn` 会 panic 或无 runtime。已用 `Engine.worker_handle`（构造时 `Handle::try_current()` 捕获）兜底——**新增任何「同步桥接函数里起后台任务」的代码都必须走 `pump_downloads` 同款模式**。

### 4.5 弹幕窗口是 30 秒不是 60 秒

服务端按 30s 分段（`next_query_danmaku_list_time`）。任何「自己按 60s 估算窗口」的代码都会整段跳过弹幕。Dart 侧已经全部改为消费 `page.endMs`，别改回去。

### 4.6 下载命令词表

引擎只认 `pause` / `resume` / `retry` / `delete`。UI 的 `remove`/`archive`/`restore`/`pauseAll` 在 `engine_backed_repository.dart` 的 `_engineCommand` / `controlDownloads` 里映射，**新增命令必须两端同步改**（这正是当初断链的根源）。

---

## 5. 验证手册

```bash
# Rust 全量（含实网金丝雀——T1 完成后）
cd rust && cargo test --workspace

# Dart 静态检查 + CI 同款格式检查
cd .. && dart analyze lib
dart format --output=none --set-exit-if-changed lib

# 单独跑对拍（改过 argus.rs 必须）
cd rust && cargo test -p guo-source-hongguo --test hongguo_argus_parity

# 实网手工抽查（写一次性 example，用完删）
cargo run --example <probe>   # 模板见 bridge/examples/hongguo_danmaku_probe.rs
```

**提交前自检**：
1. `git status` 里不应有 `examples/*probe*.rs` 残留（转正或删除）。
2. FRB 生成物与 `rust/bridge/src/api/` 一致（改过桥接就重新 generate）。
3. 实网验证过至少一条：弹幕窗口推进 / 下载后台执行 / 榜单分页。
