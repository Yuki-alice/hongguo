# 扩展仓库架构设计：内置红果 + 其余扩展化

> 制定：2026-10-24 · 依据当前代码与 Kazumi 参考实现核实
> 关联：`docs/PLUGIN-BOUNDARY.md`（迁移清单，本文是它的落地设计）、
> `docs/ARCHITECTURE.md`、`docs/RUST-ENGINE-REVIEW.md`（前置阻塞项）

---

## 0. 目标

**内置源只剩红果，其余站源一律通过扩展仓库安装。**

- 首次启动装上就能看（红果保底）；
- 其余源在「扩展」页一键安装 / 更新 / 启用 / 回滚；
- 站点改版只改插件仓库，宿主不发版；
- 宿主仓库不含任何具体站源的知识。

---

## 1. 与 Kazumi 的对照：抄什么、不抄什么

Kazumi 的机制（`lib/plugins/`、`lib/request/apis/plugin_catalog_api.dart`）：

| 机制 | Kazumi 做法 | 本项目现状 | 结论 |
| --- | --- | --- | --- |
| 分发形态 | GitHub raw 静态仓库，`index.json` + `<name>.json` | `repo.toml` + `index.json` + zip 包，字段注释已写明「与 Kazumi 保持同构」 | **同构，直接沿用** |
| 抗封锁 | 4 条镜像（gh-proxy / ghfast / gitcode / raw） | 无，只有单 URL | **抄**：加镜像链 |
| 版本门控 | `apiLevel`；`requiresNewerClient` 拒绝安装 | 有 `api` / `minHost` 字段 + `CURRENT_API_LEVEL` 校验 | 已有，UI 补展示 |
| 状态三态 | `install` / `installed` / `update` | `PluginSummary.installed/enabled` | 已有，需补 `updateAvailable` |
| 更新检查 | 5 分钟 TTL + single-flight 刷新目录 | 无缓存，每次全量拉 | **抄**：TTL + 单飞 |
| 引导安装 | `onboarding/steps/plugin_shop_step.dart` 首次启动装规则 | 无（靠 `assets/bundled_plugins` 预装） | **抄**：改为引导页 |
| 完整性 | 无签名，靠 GitHub 信任 | Ed25519 签名 + TOFU 指纹 + 包 sha256 | **比它强，保留** |
| 沙箱 | 无（纯 XPath 规则，Dart 直接跑） | Wasm 组件沙箱（域名白名单 / 存储命名空间 / fuel） | **比它强，保留** |
| 回滚 | 无 | `rollback_plugin`，版本目录 | **比它强，保留** |
| 状态管理 | MobX | Riverpod | 不抄 |
| 落盘 | 单文件 `plugins/v2/plugins.json` | 插件目录 + 版本子目录 | 不抄（单文件无法回滚） |

**一句话**：Kazumi 值得抄的是**分发与 UX**（静态仓库、镜像、门控、更新徽标、引导安装），
不是解析层。本项目的包格式与沙箱已经比它强，不要为了对齐而降级。

---

## 2. 仓库协议（在现有 `spec = 1` 上增量扩展）

### 2.1 目录布局

```
hoshi-plugins/                    # 独立仓库
├── repo.toml
├── index.json
├── index.json.sig
├── packages/
│   ├── guo.maoguo-1.2.0.zip
│   └── guo.niuguo-0.9.1.zip
├── rules/
│   └── wuguo-1.0.0.zip
└── sources/                      # 插件源码（各独立 workspace）
```

### 2.2 `repo.toml`（不变）

```toml
spec = 1
id = "official"
name = "官方扩展仓库"
index = "index.json"
public_key = "base64:<ed25519 公钥>"   # 可选；有则强校验 .sig
```

### 2.3 `index.json`：在现有 `RepoIndexEntry` 上加 3 个字段

```json
[
  {
    "id": "guo.maoguo",
    "name": "猫果",
    "version": "1.2.0",
    "kind": "component",
    "api": 1,
    "minHost": "0.3.0",
    "author": "hoshi",
    "updatedAt": "2026-10-24",
    "size": 71680,
    "sha256": "…",
    "path": "packages/guo.maoguo-1.2.0.zip",
    "changelog": "修复签名过期",
    "network": ["api.maoguo.example"],
    "capabilities": ["catalog", "detail", "search", "resolve"],
    "recommended": true
  }
]
```

| 新增字段 | 用途 |
| --- | --- |
| `network` | 安装确认页展示「该扩展会访问这些域名」。与沙箱白名单同源，但**在安装前**就让用户看见 |
| `capabilities` | 商店卡片显示「支持榜单 / 弹幕」；安装后与 `describe()` 返回值对拍，不一致即拒绝加载 |
| `recommended` | 首次启动引导页默认勾选，对齐 Kazumi 的 onboarding |

三个字段全部 `#[serde(default)]`，老索引不受影响。

### 2.4 镜像

```rust
pub struct RepoSource {
    pub id: String,
    pub mirrors: Vec<String>,      // 有序：主源在前
    cursor: AtomicUsize,           // 最近一次成功的镜像
}
```

`fetch_index` 从 `cursor` 开始依次尝试，成功即停并记住位置；
**验签失败不算「成功」**——否则镜像投毒会被当成网络问题静默吞掉。

官方仓库的三条镜像（与 Kazumi 同思路）：

```
https://raw.githubusercontent.com/<org>/hoshi-plugins/main/
https://raw.gitcode.com/gh_mirrors/<org>/hoshi-plugins/raw/main/
https://ghfast.top/https://raw.githubusercontent.com/<org>/hoshi-plugins/main/
```

---

## 3. Rust 侧改动清单

| 文件 | 改动 | 说明 |
| --- | --- | --- |
| `bridge/src/sources/builtin.rs` | 只保留 `HongguoSource` | 一行事的收口点，唯一决定「编译进哪些源」 |
| `engine/src/engine.rs` | 删 `BUNDLED_RULES` 常量与其加载循环 | 9 条规则不再 `include_str!` |
| `engine/src/engine.rs` | `install_bundled` 保留入口，默认传空数组 | 预装通道留作应急，日常不走 |
| `plugin-host/src/repository.rs` | `RepoIndexEntry` 加 `network` / `capabilities` / `recommended` | 全部 `serde(default)` |
| `plugin-host/src/repository.rs` | `RepositoryIndex` 增加 `latest_under(id, host_version)` | 让「宿主要升级才能装」可判定 |
| `runtime/src/repo_client.rs` | 新增 `RepoSource` 镜像链 + cursor | 见 §2.4 |
| `runtime/src/repo_client.rs` | 索引条件请求（ETag / If-None-Match）+ 内存缓存 | 对齐 Kazumi 的 5 分钟 TTL |
| `runtime/src/repo_client.rs` | 新增 `check_updates(installed) -> Vec<UpdateCandidate>` | 一次调用算完所有可更新项，UI 只需一次 FRB 往返 |
| `plugin-wasm/src/component.rs` + WIT | 补齐 6 个导出 | **前置阻塞，见 §6** |
| `bridge/src/api/` | 新增 `repo_list` / `repo_add` / `repo_remove` / `repo_refresh` / `extension_catalog` / `check_updates` / `install_many` | 现有 `install_from_repo` / `list_repo_plugins` / `rollback_plugin` 保留 |
| `rust/rules/*.json`（9 条） | 迁出 | 打包为规则型插件 |
| `crates/source-{maoguo,niuguo,yaguo,huangju,huangguo}` | 删除 | 只留 `source-hongguo` |
| `assets/bundled_plugins/*`（7 个 zip + index.json） | 删除 | 改为引导安装 |
| `rust/examples/plugins/*` | 迁出到插件仓库 | 宿主不持有插件源码 |

---

## 4. Dart 侧改动清单

```
lib/data/
  extension_repository.dart      # 新；替代 plugin_repository.dart
                                 #  保留旧文件做一版薄适配，避免一次性大改
lib/ui/features/extensions/
  views/
    extensions_shop_view.dart    # 商店：远端目录 + 三态按钮
    extensions_manage_view.dart  # 已安装：启停 / 更新 / 回滚 / 卸载
  controllers/
    extensions_controller.dart   # AsyncNotifier；持仓库列表 + 目录 + 已安装快照
  widgets/
    extension_card.dart          # 名称 / 版本 / 大小 / 能力标签 / 状态按钮
    permission_sheet.dart        # 安装前展示 network 与 capabilities
lib/ui/features/onboarding/      # 首次启动引导（对齐 Kazumi 的 plugin_shop_step）
```

### 4.1 状态模型（与状态机图一致）

```dart
enum ExtensionState { notInstalled, installing, enabled, disabled, updateAvailable, incompatible }

class ExtensionEntry {
  final String id;            // 恒定：收藏 / 历史 / 下载都按它做主键
  final String name, version, remoteVersion;
  final bool isCode;          // component
  final List<String> network;
  final List<String> capabilities;
  final bool recommended;

  ExtensionState get state {
    if (remoteApiLevel > hostApiLevel) return ExtensionState.incompatible;
    if (!installed) return ExtensionState.notInstalled;
    if (installed && remoteIsNewer) return ExtensionState.updateAvailable;
    return enabled ? ExtensionState.enabled : ExtensionState.disabled;
  }
}
```

### 4.2 三条硬性约束

1. **源 ID 恒定**。`cloudfront` / `dsd` / `wuguo` … 这些 id 是历史数据主键，
   插件包 id 必须等于 `describe()` 返回的 id（PLUGIN-BOUNDARY §3.1 已踩过坑）。
   迁移后跑一次对拍：列出迁移前后全部源 id，差集必须为空。
2. **不可降级**。`_remoteIsNewer` 只认更高版本，镜像滞后时不能被拉回旧版（Kazumi 同款逻辑）。
3. **更新失败保留上一版**。新包装不上时不能留下半截状态；`rollback_plugin` 已具备。

---

## 5. 分阶段路线

| 阶段 | 内容 | 前置 | 预估 |
| --- | --- | --- | --- |
| **S0** | 修 `cargo check` 门禁（`RUST-ENGINE-REVIEW.md` P0-1） | — | 0.5h |
| **S1** | 补齐 WIT 6 个导出 + `ComponentSource` 实现 + 7 插件对拍 | S0 | 8h |
| **S2** | 建 `hoshi-plugins` 仓库；迁 9 条规则 + 7 个插件源码 + 夹具；CI 打包生成 `index.json` | S1 | 4h |
| **S3** | 宿主：镜像链 + 索引缓存 + `check_updates` + 仓库管理 API | S0 | 6h |
| **S4** | Dart：`ExtensionRepository` / Controller / 商店页 / 管理页 | S3 | 8h |
| **S5** | 引导安装页；官方仓库 URL + 公钥内置 | S4 | 3h |
| **S6** | 删 5 个 `source-*` crate、删 `BUNDLED_RULES`、删 `assets/bundled_plugins` | S2 + S5 | 2h |
| **S7** | 源 ID 对拍 + 收藏 / 历史 / 下载回归 | S6 | 3h |

**S1 之前不要动 S6**。删了编译源、插件又没那 6 个能力，猫果的榜单、红果之外的弹幕会直接消失，
而且因为编译版已经删了，回滚都来不及。

---

## 6. 前置阻塞项（必须先解决）

`crates/plugin-wasm/src/component.rs` 的 `impl SourcePlugin for ComponentSource`
只实现了 5/10 个方法，缺：

```
ranking_boards / ranking / recommend / suggestions / danmaku / seasons
```

WIT 里声明了 `suggestions` 导出但宿主没接。因此**插件版站源现在无法提供榜单、推荐、
联想、弹幕、多季**，而编译版可以。这就是双轨至今删不掉的根因，也是扩展化的唯一硬门槛。

处理方式：先把这 6 个能力补进 WIT 与 `ComponentSource`，用现有编译版做对拍测试
（复用法：两者的 fixture 已经是镜像关系），再谈删除编译源。

---

## 7. 风险与对策

| 风险 | 影响 | 对策 |
| --- | --- | --- |
| 源 ID 变化 | 收藏 / 历史 / 下载全部断裂 | id 恒定 + S7 对拍测试 + 差集为空才允许发版 |
| 首次启动断网 | 只有红果一个源 | 可接受；引导页明示「稍后可在扩展页添加」；缓存上次索引供离线展示 |
| 仓库被墙 | 装不了任何扩展 | 三条镜像 + 允许用户填自定义仓库 URL |
| 镜像投毒 | 恶意包 | 验签失败不得降级为「网络错误」；官方仓库公钥**硬编码**而非 TOFU |
| 第三方未签名仓库 | 供应链风险 | TOFU 记录指纹，指纹变更必须重新确认（`remember_repository` 已实现） |
| 扩展能力退化 | 装了插件但榜单没了 | 安装后比对 `describe().capabilities` 与索引声明，不一致拒绝加载并提示 |
| 插件执行串行 | 扩展源比内置源慢 | `RUST-ENGINE-REVIEW.md` P1-4；扩展页标注「扩展源」以设预期 |

---

## 8. 验收

```bash
# 宿主侧
cd rust && cargo test --workspace && cargo clippy --workspace --all-targets -- -D warnings
cd .. && dart analyze lib && flutter test --exclude-tags engine

# 扩展化验收（手工，S6 后必做）
1. 全新安装启动 → 只有红果 → 引导页可装扩展
2. 装猫果扩展 → 出现在源列表 → 目录 / 详情 / 取流可用
3. 关网重启 → 红果仍可用，已装扩展仍可用
4. 仓库发新版 → 扩展页出现更新徽标 → 更新 → 回滚 → 恢复正常
5. 装一个 api 更高的扩展 → 显示「需要升级应用」且不可安装
6. 迁移前后源 id 列表差集为空；旧收藏 / 历史 / 下载任务全部可见
```
