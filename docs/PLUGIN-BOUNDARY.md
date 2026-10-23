# 应用仓库 / 插件仓库边界

> 更新：2026-10-23 · 状态：**边界已定，双轨仍在，迁移未开始**
> 本文是插件迁移的执行清单，也是两个仓库各自「该放什么」的判据。
> 上游计划见 `docs/PLAN.md` §3 P0。

## 1. 当前实际状态（2026-10-23 核实）

| 项 | 现状 |
| --- | --- |
| 编译代码源 | 7 个：`source-maoguo` / `source-niuguo` / `source-yaguo` / `source-huangju` / `source-huangguo`（三源） |
| 编译主源 | 1 个：`source-hongguo`（永久保留编译） |
| 随包声明式规则 | 9 条，`rust/rules/*.json`，`include_str!` 进二进制 |
| 官方 Wasm 插件 | 7 个，`assets/bundled_plugins/*.zip`，合计 469 KB |
| 双轨重叠 | 猫果 / 牛果 / 芽果 / 剧果 / 黄果三源**同时**有编译版与插件版 |
| 插件源码 | `rust/examples/plugins/<name>/`（各自独立 workspace） |
| 打包器 | `pack_component`（组件）+ `pack_rules`（规则），均在 `plugin-host/src/bin/` |

> **双轨是当前最大的技术债**：同一份站点知识维护两遍。插件内单测与编译版测试
> 互为镜像（签名串、URL 形态、字段路径），就是为了防两侧漂移——这本身就是成本。

## 2. 职责划分

| 仓库 | 职责 | 不该有的东西 |
| --- | --- | --- |
| **hoshi**（本仓库） | App（Flutter）+ 引擎（Rust 宿主）+ 内置主源 + 插件宿主能力：包格式、安装器、仓库客户端、沙箱、打包器 | 具体站源的规则 JSON、第三方站源 crate、站源测试夹具 |
| **hoshi-plugins**（待建） | 站源插件包（规则型 `rules/*.json` 与组件型 `.wasm`）、插件仓库索引 `index.json` + `repo.toml` + 签名、站源回归测试 | 任何 App / 引擎代码 |

依赖方向铁律：插件**只依赖** `source-api` 契约（trait / 模型 / 能力位 / 错误），
不依赖 `runtime` / `bridge` / `plugin-host` 等宿主内部 crate；宿主**不依赖**具体站源。

守卫已在跑：

- `rust/crates/source-api/tests/dependency_direction.rs` —— 契约层不得引入
  tokio / reqwest / wasmtime / rquickjs；
- CI `rust` job 的依赖方向检查。

## 3. 插件包契约（已实现，`rust/crates/plugin-host/`）

- **清单** `plugin.toml`：`spec = 1`，`api.level <= CURRENT_API_LEVEL = 1`，
  id 形如 `[a-z0-9][a-z0-9._-]{2,63}`；`kind` 区分 `declarative` / `component`。
- **包**：zip，SHA-256 校验，解包上限见 `PackageLimits`
  （单文件 8 MiB / 总量 32 MiB / 512 条目）。
- **仓库**：`repo.toml` + `index.json`，可选 Ed25519 签名（TOFU 记录指纹）。
- **预装**：随包插件走 `assets/bundled_plugins/`，由 `BundledPlugins`（Dart）
  读取字节 → 引擎 `preinstall` 按同一套安装器导入。预装列表是**宿主侧白名单**，
  不是插件仓库的一部分；`repo_id = "bundled"` 用于区分来源。
- **WIT**：`rust/crates/plugin-wasm/wit/source-plugin.wit`（v2，见 ARCHITECTURE §7.3）。

### 3.1 两条必须遵守的约束（都踩过坑）

1. **插件包 id 必须等于 `describe()` 返回的 id**。注册表按描述符 id 记源；
   不一致会出现「预装报告说装好了、引擎清单里却没有」。
2. **`--network` 必须逐插件声明**。`pack_component` 的 `--plugin <wasm> --network <hosts>`
   成对出现；共用一个白名单会让每个插件拿到全部主机，违反最小权限。

## 4. 迁移清单（P0 执行项）

| 资产 | 现状 | 迁移后 |
| --- | --- | --- |
| `rust/rules/*.json`（9 条） | `include_str!` 编译进二进制 | 打包为规则型插件进仓库；宿主不再内置 |
| `rust/crates/source-maoguo` 等 5 个 crate | 随 workspace 编译 | 删除；只保留 `source-hongguo` |
| 各源码 crate 的 `tests/fixtures` | 站源对拍夹具 | 随插件仓库走；宿主只留 `source-api` 契约测试 |
| `rust/examples/plugins/*` | 宿主仓库内的插件源码 | 移入 `hoshi-plugins` 仓库 |
| `pack_rules` / `pack_component` | 宿主仓库内 | **保留**（发布工具），由插件仓库 CI 调用 |
| `assets/bundled_plugins/` | 7 个预装包 | 只留主源相关；其余改为首次启动从默认仓库拉取 |

### 迁移顺序

1. 建 `hoshi-plugins` 仓库，把 7 个插件源码 + 9 条规则 + 夹具迁过去，
   跑通 `pack_component` / `pack_rules` + 端到端测试；
2. 宿主 `BundledPlugins` 白名单收缩，规则改为从默认仓库拉取；
3. 逐个删除 `source-*` crate 与 `register_builtin_sources` 的注册行；
4. 删除 `bridge/Cargo.toml` 里对应的依赖。

### 验收

- `rust/crates/` 只剩 `source-hongguo` 一个站源 crate；
- 引擎清单仍列出 17 个源（红果 + 9 规则 + 7 插件）；
- `cargo test --workspace` 与插件端到端测试全绿；
- 启停 / 回滚插件不丢会话与下载任务（现有 `plugin_toggle.rs` 已覆盖）。

## 5. 已完成的部分

- 单版本命名：应用名固定「星」，`ALL_SOURCES` 只决定编译进哪些站源。
- 插件宿主与打包器：`plugin-host` / `plugin-wasm` 已完整，无需改动。
- 站源展示层已按插件抽象：UI 只消费 `SourceDescriptor` / 能力位，
  不按 id 硬编码（`lib/domain/models.dart`）。
- WIT v2：响应头（含 `set-cookie`）与 `media.cookies` / `origin` 已落地。
- 宿主提取原语：`html_select` / `json_path` 已实现（黄果视频插件在用）。
