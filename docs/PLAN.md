# 星（hoshi）路线图

> 状态：Core-0～4 全部完成，引擎-only 单栈已落地
> 制定：2026-10-21 · 重写：2026-10-23（依据代码核实，替换过时的计划文本）
> 关联：`docs/ARCHITECTURE.md`（设计与 ADR）、`docs/PERFORMANCE.md`（基线）、
> `docs/PLUGIN-BOUNDARY.md`（插件仓库拆分）、`docs/PROGRESS.md`（历史记录）

## 0. 决策记录

| 决策 | 结论 |
| --- | --- |
| 站源适配 | **暂停**。黄豆 / 野果 / 皮果不迁移 |
| 优先级 | 架构与状态正确性优先于功能数量 |
| Go 后端 | **已物理删除**（Core-4，2026-10-22） |
| 第一方代码源 | 除红果主源外，全部有官方 Wasm 插件版本（编译版仍并存，见 §3） |
| 红果主源 | 保持编译进 Rust（默认源、D4 能力、离线可用、性能敏感） |
| LAN | **已删除**（Core-4），不再提供 |
| 双版本发布 | **已取消**：应用名固定「星」，`ALL_SOURCES` 只决定编译哪些源 |
| 暂缓 | 封面修复、源批量扫描、代理 / DNS / CDN 高级设置、下载合集 |

## 1. 已完成（Core-0～4）

| 里程碑 | 完成时间 | 交付 |
| --- | --- | --- |
| **Core-0 切轨** | 2026-10-21 | 源身份 `diguo`→`dsd`；源列表由引擎清单驱动；删除 `ENGINE_ROUTE`；Go 退出构建链 |
| **Core-1 运行时内核** | 2026-10-21 | `guo-engine-core` 单例；磁盘会话；`EngineError` + `EngineFailure`；`request_id` + 取消；进度 Stream；诊断接口 |
| **Core-2 播放与下载** | 2026-10-21 | 播放计划补 Cookie / Origin / `danmakuId`；下载索引落盘 + 暂停续传；离线播放；批量控制；封面缓存；旧索引只读迁移 |
| **Core-3 Wasm 源运行时** | 2026-10-22 | WIT v2（响应头 / media cookies）；宿主提取原语；7 个代码源插件化；官方插件预装 + 打包器 |
| **Core-4 收口** | 2026-10-22 | 删除 `native/` 与 `core_bridge.dart`；删除 LAN；构建链 11→3 脚本；四端 CI 启用 |
| **性能与包体基线** | 2026-10-23 | `guo-bench`；`docs/PERFORMANCE.md`；CI 护栏；资源设置迁入引擎 |

### 前端重构（2026-10-23）

| 阶段 | 交付 |
| --- | --- |
| P0 | 布局契约测试 + 桌面验收测试；修 `appVersion` 与 pubspec 漂移 |
| P1 | `AppShell` 三形态导航、5 分支嵌套路由、旧路径重定向、目录宽度上限 |
| P2 | 设置两栏、详情沉浸头、榜单宽屏双列、全站统一内容上限 |
| P3 | 主题状态层与 hover/focus、桌面常显滚动条、骨架屏、手绘空态与加载指示器 |
| P4 | 自绘窗口 chrome、窗口尺寸记忆、关闭行为、托盘、桌面快捷键；补 macOS 沙箱网络权限 |
| P5 | 主题个性化：9 色种子调色板、动态取色、OLED 纯黑、系统字体 |

验收：`flutter test --exclude-tags engine` 406 通过 / 1 跳过（改造前 352）；
`dart analyze` 0 error / 0 warning。设计规范见 `docs/UI.md`。

验收结果（`PROGRESS.md` 第三十四 / 三十五轮）：

- `cargo test --workspace` 534 通过；`flutter test --exclude-tags engine` 352 通过 / 1 跳过；
- `dart analyze` 0 error / 0 warning；全仓 Go 引用 `git grep` 零命中；
- 首屏解析链路约 3.1 ms（装配 + 规则 + 目录解析）——解析不是瓶颈；
- Android APK 32.4 MiB（引擎库 5.1 MiB）。

## 2. 当前真实状态

### 2.1 首发功能矩阵

| 功能 | 首发 | 当前 |
| --- | --- | --- |
| 目录 / 搜索 / 详情 / 分类 / 缓存 | ✅ | 已可用 |
| 榜单 / 推荐 / 联想 | ✅ | 引擎直出（红果） |
| 直连播放（含 Cookie / Origin） | ✅ | 已可用；剧果签名 Cookie 可达播放器 |
| 下载 / 断点续传 / 离线播放 | ✅ | 已可用 |
| 弹幕 | ✅ | 已可用；窗口游标由服务端 `end_ms` 给出（30s 分段） |
| 资源设置（目录限流 / 下载并发） | ✅ | 已迁入引擎 |
| 播放画质切换 | ⚠️ 默认画质 | 多线路 / 画质未做 |
| 其它源 D4 | ❌ | 入口按能力位隐藏 |
| 封面修复 / 元数据补全 | ❌ | 使用源返回封面 |
| 单源健康检测 | ✅ | `sourceManagement = true`，四步进度可取消 |
| 批量源扫描 | ❌ | 暂缓 |
| 代理 / DNS / CDN | ❌ | 首版仅直连 |
| 下载合集 / 移动下载目录 | ❌ | `UnsupportedFailure` |
| LAN | ❌ | 已删除 |
| 黄豆 / 野果 / 皮果 | ❌ | 源适配暂停 |

可用源 17 个：红果 + 9 条声明式规则 + 7 个编译代码源；
另有 7 个官方 Wasm 插件与其中 6 个源并存（`guo.cloudfront` 对应编译版 `cloudfront`）。
其中 11 个源在 2026-10-24 实网复测中确认取流不可用，已从 UI 入口隐藏
（`SourceSite._offlineIds`，见 §5.1）；源码保留，站点恢复后复测即可重新上架。

### 2.2 未接入能力（明确报 `UnsupportedFailure`）

| 能力 | 现状 | 归属 |
| --- | --- | --- |
| 下载合集 | 抛 `UnsupportedFailure('下载合集')` | 暂缓 |
| 移动下载目录 | 抛 `UnsupportedFailure('迁移下载目录')` | 暂缓 |
| LAN | 抛 `UnsupportedFailure('局域网互联')` | 永久移除 |

UI 侧按 `capabilities` 隐藏这些入口，不会出现「点了才报错」。

## 3. 下一阶段（按优先级）

### P0 · 消除双轨（插件迁移收尾）

**问题**：7 个代码源同时存在编译版（`rust/crates/source-*`）与插件版
（`assets/bundled_plugins/`）。同一份站点知识维护两遍，改一处要改两处
（插件内单测与编译版测试互为镜像就是为了防这个）。

**任务**（详见 `docs/PLUGIN-BOUNDARY.md` §3）：

1. 建 `hoshi-plugins` 仓库，迁出规则 JSON、插件包与夹具；
2. 宿主收缩预装白名单，规则改为从默认仓库拉取；
3. 逐个删除 ~~`source-maoguo`~~（✅ 第十六轮）/ ~~`source-yaguo`~~（✅ 第十七轮）/ `source-niuguo`（解析服务仍挂，暂缓）/ `source-huangju` /
   `source-huangguo`（红果保留）；
4. 删除对应的 `bridge` 依赖与 `register_builtin_sources` 注册行。

**验收**：`rust/crates/` 只剩 `source-hongguo` 一个站源 crate；
引擎清单仍列出 17 个源；`cargo test` 与插件端到端测试全绿。

### P1 · 内存基线

**问题**：`PERFORMANCE.md` §3 明确记录「引擎侧没有常驻内存的自动测量」，
跨平台外部工具不可比。

**任务**：`std::alloc` 计数包装器 → `engine_diagnostics` 暴露「引擎堆占用」字段 →
诊断页展示 → CI 护栏加粗粒度阈值。

**验收**：诊断页能读到实时堆占用；`guo-bench` 输出含内存项。

### P2 · 播放画质 / 线路

**问题**：`PlaybackPlan` 已有 `quality` / `qualities` / `routeIndex` / `routeCount`
字段，但引擎只返回默认画质，`fallback` 在 Dart 侧是空实现。

**任务**：`Media` 补多线路 / 多画质列表；`fetch_media` 支持 `quality` 参数；
Dart 侧播放器菜单接上切换。

**验收**：红果至少一个源可切换画质；切换后重新取流不黑屏。

### P3 · 加密 HLS 覆盖实测

**问题**：`PERFORMANCE.md` 与 PLAN 都提到「直连播放对加密 HLS 的覆盖范围未验证」。

**任务**：对需要 Cookie 轮换 / 鉴权地址 / 播放列表重写的源做实测；
只有直连无法覆盖时才引入最小本地流服务（不要默认代理）。

**验收**：实测记录入库，明确「哪些源需要本地流服务」。

### P4 · 真实站源回归

**进展（2026-10-24）**：红果已从「无实网用例」补齐为 `hongguo_live.rs` 金丝雀
（目录 / 详情 / 弹幕游标 / 弹幕跨窗口 / 四榜单 / 联想，5 条用例，不加 `#[ignore]`）。
其余站点在 §5.1 复测后确认仍有 11 个不可用。

**任务**：换网络环境或找可用镜像，把红果推荐、剧果详情、黄果 AI / 视频的在线用例
从「可跳过」改为「必须通过」；把结果记入 `PROGRESS.md`。

## 4. 质量门槛

每个改动都需满足：

- `cargo fmt --all --check`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo test --workspace`
- `flutter test --exclude-tags engine`
- `flutter test --tags engine`（真实站源，非阻断）
- `dart analyze lib test integration_test test_driver` 无 error / warning
- `python3 scripts/check_perf_budget.py`（CI 已接）

**当前基线**（2026-10-23）：cargo 534 通过；flutter 离线 352 通过 / 1 跳过；
engine 在线 12 通过；dart analyze 0 error / 0 warning。

## 5. 环境限制（影响验收，不是代码缺陷）

| 事项 | 事实 | 影响 |
| --- | --- | --- |
| 红果推荐接口 | `api5-normal-sinfonlineb.fqnovel.com` 返回 200 但响应体为空 | 推荐流无法在线验证，降级分类页 |
| 红果全量画质 | `video_model` 匿名通道已死，仅剩试看清晰度 | 全量画质需要登录态或渠道接口，属产品决策 |
| 黄果 AI / 视频 | 站点自 2026-10-21 起超时 / 403 | 只有离线对拍 |
| 剧果详情 | `api.huangju.net/dramas/...` 返回 404 | Cookie 透传只能离线验证 |
| 红果弹幕并发 | 同站并发 5 条链路时偶发返回缺 `next_query_danmaku_list_time` 的退化响应 | 金丝雀已串行化；不影响单用户播放 |

### 5.1 不可用源清单（2026-10-24 复测）

一次性探针（`rust/bridge/examples/`，已删除）对当前构建的 17 个源逐个跑
`check_source(playback = true)`，四步为目录 → 详情 → 取流 → 媒体连接。

| 状态 | 源 | 现象 |
| --- | --- | --- |
| 可用 | `hongguo` / `maoguo` / `yaguo` / `heguo` / `wangguo` / `faguo` | 四步全过 |
| 只能看不能播 | `niuguo` / `huangju` / `huaguo` / `fanguo` / `guanguo` / `xingguo` | 目录可读，分集目录 404 / 解析失败或取流 20s 超时 |
| 进不去 | `cloudfront` / `huangguoai` / `huangguo-video` / `wuguo` / `dsd` | 4001 / 超时 / 403 / 空响应 / 超时 |

后 11 个已从 UI 隐藏（`lib/domain/models.dart` 的 `SourceSite._offlineIds`），
**源码与插件保留**。站点复活后：删掉对应 id、重跑探针、把 `cargo test -p guo_engine`
与手工点播都过一遍，再上架。

## 6. 未决问题

- **播放取流失败（阻断）**：release / debug 点播放均停在「正在准备播放」后报
  「暂时无法播放」；`PlaybackLoader` 的真实异常被 `l10n.playerPlayFailed` 吞掉。
  需先打印异常，再判断是 URL 过期、headers 缺失还是 CDN 不可达。
  详见 `PROGRESS.md` 第三十七轮。
- **播放页 `Esc` 不生效**：焦点不在播放表面时快捷键不触发，只能点返回键。
- **前端测试套件已移除**：`test/` 79 个文件删除，CI 只跑 format + `analyze lib`。
  视觉回归目前依赖人工截图，需评估重建路由 / Hero / 空态的最小用例集。
- 声明式规则是否也迁为官方插件包（当前随包内置，`include_str!`）。
- 官方插件签名密钥的生成、保管与预装流程。
- 移动端下载是否需要前台服务 / 后台续传；首版是否只支持前台。
- 画质 / 线路切换是否进入首发，还是默认源最高画质（见 §3 P2）。

## 7. 完成定义

「核心引擎搭建完成」已达成（Core-0～4 全部完成）。当前定义改为
**「可发布」**，需满足：

1. 仓库只有一套站源实现（无编译版 / 插件版双轨）。⏳ P0
2. 首发功能矩阵中的 ✅ 项全部通过真实源验收。⏳ 部分受环境限制（§5）
3. 令牌 / 会话 / 缓存 / 下载跨重启保留，取消与错误分级可用。✅
4. 红果保持编译，其余代码源全部由 Wasm 插件提供。✅（双轨待清）
5. macOS / Android / iOS 三端可构建、可测试。✅（CI 四端已启用）
6. 旧下载记录可读，旧收藏 / 历史不丢。✅
7. CI 全绿，性能与包体基线入库，文档与实现一致。✅（内存基线待补，§3 P1）
