# 应用仓库 / 插件仓库边界

状态：**本轮只定边界，不搬文件**（用户决策：先定边界，下轮搬）。
本文件是下轮迁移的执行清单，也是两个仓库各自"该放什么"的判据。

## 1. 职责划分

| 仓库 | 职责 | 不该有的东西 |
| --- | --- | --- |
| **hoshi**（本仓库） | App（Flutter）+ 引擎（Rust 宿主）+ 内置主源 + 插件**宿主**能力：包格式、安装器、仓库客户端、沙箱 | 具体站源的规则 JSON、第三方站源 crate、站源测试夹具 |
| **hoshi-plugins**（下轮新建） | 站源插件包（规则型 `rules/*.json` 与组件型 `.wasm`）、插件仓库索引 `index.json` + `repo.toml` + 签名、站源回归测试 | 任何 App / 引擎代码 |

依赖方向铁律：插件**只依赖** `source-api` 契约（trait / 模型 / 能力位 / 错误），
不依赖 `runtime`、`bridge`、`plugin-host` 等宿主内部 crate；宿主**不依赖**具体站源。
`rust/crates/source-api/tests/dependency_direction.rs` 与 CI 的依赖方向守卫已在守这条线。

## 2. 插件包契约（已实现，位于 `rust/crates/plugin-host/`）

- **清单** `plugin.toml`：`PLUGIN_SPEC = 1`、`api.level <= CURRENT_API_LEVEL = 1`，
  id 形如 `[a-z0-9][a-z0-9._-]{2,63}`；`kind` 区分规则型 / 组件型（见 `manifest.rs`）。
- **包**：zip，`sha256` 校验，解包上限见 `PackageLimits`（`package.rs`）。
- **仓库**：`repo.toml` + `index.json`（字段与 Kazumi 同构，另加 `sha256` 与 `kind`），
  可选 Ed25519 签名（`repository.rs`）。
- **预装**：随包插件走 `assets/bundled_plugins/`，由 `BundledPlugins` 在首次启动时
  按同一套安装器导入；预装列表是**宿主侧白名单**，不是插件仓库的一部分。

## 3. 下轮迁移清单（从本仓库移出）

| 资产 | 现状 | 迁移后 |
| --- | --- | --- |
| `rust/rules/*.json`（9 条声明式源） | 随引擎 `include_str!` 编译进二进制 | 打包为规则型插件，进插件仓库；宿主不再内置 |
| `rust/crates/source-*`（红果 / 猫果 / 牛果 / 剧果 / 黄果…） | 代码源 crate，随 workspace 编译 | 只保留**内置主源**（红果）；其余编译为 `.wasm` 组件型插件，产物进插件仓库 |
| 各源码 crate 的 `tests/fixtures` | 站源对拍夹具 | 随插件仓库走（宿主只保留 `source-api` 契约测试） |
| `pack_rules` 打包器 | `rust/crates/plugin-host/src/bin/pack_rules.rs` | 留在宿主（作为发布工具），由插件仓库 CI 调用 |
| `assets/bundled_plugins/` | 预装插件包 | 只保留 1 个主源插件；其余改为首次启动从默认仓库拉取 |

**迁移顺序（下轮）**：建 `hoshi-plugins` 仓库 → 规则 JSON 与原夹具迁移并在新仓库跑通
`pack_rules` + 端到端测试 → 宿主删 `include_str!` 内置规则、`BundledPlugins` 白名单收缩
→ 组件型源逐个 Wasm 化迁出 → 宿主侧删除 `source-*` crate。

## 4. 本轮已完成的部分

- 单版本命名（不再分「红果鉴 / 真果鉴」）：应用名固定「星」，`ALL_SOURCES`
  只决定编译进哪些站源（iOS 全源，其余平台内置）。
- 插件边界文件即本文件；宿主侧契约（`plugin-host`）与依赖守卫已存在，无需改动。
- 站源相关的展示层已按插件抽象：UI 只消费 `SourceDescriptor` / 能力位，
  不按 id 硬编码（`lib/domain/models.dart`）。
