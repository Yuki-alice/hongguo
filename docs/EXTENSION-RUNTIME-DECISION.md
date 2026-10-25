# 决策：扩展运行时选型（ADR-13）

> 提出：2026-10-24 · 状态：**建议采纳，待确认**
> 关联：`docs/ARCHITECTURE.md` §3（ADR 表）、`docs/PLUGIN-BOUNDARY.md`、
> `docs/EXTENSION-ARCHITECTURE.md`（仓库与 UX 设计，本文只讲「扩展代码用什么跑」）

---

## 1. 背景与痛点

- `reference/guoapp2` 的站源是 `native/core/provider_*.go`，**13.7k 行 Go 写死代码**。
  站点一改版就要改 Go、发版——这是重写的原始动因，成立。
- Flutter + Rust 的选择是对的：HTTP、解析、HLS、下载、缓存、并发都在宿主侧，
  Rust 比 Go 更适合做单进程嵌入式引擎。**这一点不因本文改变。**
- 但「扩展代码用什么语言跑」这个子决策走偏了：Wasm 组件模型投入很大，
  **至今没有可用雏形**，且卡在「补齐 6 个 WIT 导出」这一步动不了。

## 1.1 实证：guoapp2 站源逐个拆解（2026-10-24）

不看框架看代码。把 `reference/guoapp2/native/core/provider_*.go`（12,001 行，不含测试）
按「请求要什么、响应怎么解、要不要状态」拆开：

| 站源 | 行数 | 请求侧 | 响应侧 | 密码学 | 归层 |
| --- | --- | --- | --- | --- | --- |
| 红果 App | ~700 | MD5 + 位运算混淆 → `X-Gorgon`；评论签名 SM3 / Argus / Ladon | JSON | 自定义混淆 + 设备号 | **内置 Rust** |
| 红果 Web | ~900 | GET | `_ROUTER_DATA` 内嵌 JSON | 无 | L0（`kind = "next"`） |
| 帝果 dsd | 923 | GET | HTML DOM + base64 播放地址 | 无 | **L0**（`rules/dsd.json` 已在跑） |
| 黄果 | 1306 | GET | HTML，**12+ 个 regexp** | 无 | L0 **+ 需 regex 提取器** |
| 黄果旧版 cloudfront | 732 | POST | AES-CBC 密文 | AES-CBC + hex + 会话 | **L1**（transform） |
| 黄豆 | 425 | 签名请求体 | AES-CBC 密文 | AES-CBC + **HMAC-SHA256** + rand IV + gzip | **L1**（sign + transform） |
| 野果 | 636 | 多步：发现 transit 站点 → 取 script 配置 → 请求 | AES-CBC | AES-CBC + base64 + rand | **L1 + 多步编排** |
| 剧果 | 357+ | 访客令牌 | JSON | 无（但要透传 CloudFront 签名 Cookie） | **L1**（凭据透传） |
| 猫果 / 短剧框架 | ~2800 | MD5 + base64 + **字符映射表** | JSON / HTML | MD5 + base64 | L0（maccms）/ **L1**（猫果） |
| **Wasm 需求** | — | — | — | — | **0 个源** |

**结论：guoapp2 里没有任何一个站源需要 Wasm。** 最复杂的是黄豆
（AES-CBC + HMAC-SHA256 派生密钥 + gzip），crypto-js 加一个 transform 钩子即可覆盖。

真正的能力缺口只有两个，且都比 Wasm 便宜一个数量级：

1. **正则提取**——黄果 1306 行全靠 `regexp`，而 `rule-engine` 目前只有
   CSS 选择器（`RuleKind::Html`）、JSONPath（`Json`）、内嵌 JSON（`Next`），
   正则只出现在 `idPattern` 一处。补一个 `regex` 提取方式即可。
2. **多步请求编排**——野果一个 catalog 动作要发 2–3 个请求（发现站点 → 取配置 → 取数）。
   规则需要一个 `preflight` 步骤列表，把前置请求的结果放进后续模板的上下文。

## 2. 结论

**扩展默认用「声明式规则 + 可选 JS 钩子」，Wasm 降级为可选通道并冻结。**

| 层 | 形态 | 定位 |
| --- | --- | --- |
| 内置 | 红果 Rust 编译 | 性能敏感 + 签名复杂（Argus / Ladon / SM3），不插件化 |
| L0 | 纯 `rules.json` | 默认形态，覆盖大多数站点 |
| L1 | `rules.json` + `hooks.js` | 需要签名 / 解密 / 复杂推导时加一个 JS 文件 |
| L2 | Wasm 组件包 | 现有 7 个插件**冻结维护**，主线不依赖它 |

---

## 3. 为什么 Wasm 不是最优（逐条有依据）

| 维度 | 现状证据 |
| --- | --- |
| iOS 硬约束 | 禁 JIT → 只能 Pulley 解释器（ADR-11）；为绕开 fiber 协程栈**关闭了 wasmtime `async`**，代价是宿主 `fetch` 走 `sandbox.rs::block_on` 的独立单线程 runtime，**插件侧 HTTP 全局串行** |
| 调用开销 | `component.rs` 每个方法都是 `spawn_blocking(‖ 新建 Store → instantiate → call)` |
| 工具链债 | WIT 契约 + `wasm-tools component wit` 断言 + bindgen + 组件模型；`rust/examples/plugins/` 下 7 个插件**各自独立 workspace** |
| 能力缺口 | `ComponentSource` 只实现 10 个 trait 方法里的 5 个，缺 `ranking_boards` / `ranking` / `recommend` / `suggestions` / `danmaku` / `seasons`。补齐要 6 个 WIT 导出 + 7 个插件实现，8h 起步 |
| 翻译成本 | 站点逆向出来的算法**本来就是 JS**（网页里的加密函数），要翻译成 Rust 再编译成 Wasm，多两层转换，且翻译错只能靠对拍发现（Core-3 手写 SHA-256 对空输入输出错哈希的教训） |
| 包体 | `bridge/Cargo.toml` 显式决策「三端全量引入 wasmtime，不为体积做平台分层」；引擎库 Android 5.1 MiB / Windows 14.7 MiB |

## 4. 为什么 JS 是更优解（而且已经就绪）

**不需要新增任何原生依赖**：

- `crates/source-api/src/env.rs`：`SourceEnv.scripts: Option<Arc<dyn ScriptHost>>` 已是契约的一部分；
- `crates/host/src/script.rs`：`QuickJsHost` 已实现 `ScriptHost`，PRELUDE 提供 `crypto.md5` 与 `JSON`；
- `crates/engine/src/engine.rs:285`：`scripts: Some(QuickJsHost::shared())` 已注入；
- `rquickjs` 已在 `guo-host` 依赖里，**早就编译进引擎**。

**其他优势**：

| 项 | 说明 |
| --- | --- |
| iOS | QuickJS 是纯解释器，不 JIT，iOS 上原生合法，无 AOT / 解释器二选一问题 |
| 逆向复用 | 网页里抄下来的 JS 基本可以直接用 |
| 调试 | hooks.js 可以在浏览器 / node 里直接跑，对拍成本接近零 |
| 依赖 | ADR-12 已定「crypto 由插件自带」——JS 扩展直接 bundle 精简 crypto-js 即可，宿主零维护 |
| 工具链 | 无 WIT、无 wasm-tools、无跨 workspace；扩展就是一个 zip 里多一个 `.js` |
| 沙箱 | QuickJS 无网络无文件系统（PRELUDE 只暴露 crypto / JSON），叠加域名白名单与执行超时 |

**Kazumi 的旁证**：它只做 JSON 规则、没有沙箱、没有 Wasm，规则仓库依然有活跃社区贡献。
说明「站点变化只更新规则」这个目标，**规则层就能达成，不需要代码沙箱**。

---

## 5. L1 钩子设计

### 5.1 包结构

> **已修订（2026-10-25）**：面向社区作者时，JS 不应只是规则的附属钩子。
> 完整设计见 `docs/EXTENSION-ECOSYSTEM.md`：三种形态（纯规则 / 规则+钩子 / 纯脚本）平级，
> 共用同一套打包、签名、分发与回滚。下面只保留钩子形态的契约作为其中一种。

```
guo.maoguo-1.2.0.zip
├── plugin.toml     # kind = "rule"；[hooks] 声明钩子
├── rules.json      # 现有 RuleDocument，不变
└── hooks.js        # 可选；自带 crypto 实现
```

`plugin.toml` 新增段：

```toml
[hooks]
sign      = "hooks.js:sign"       # 请求前
transform = "hooks.js:decode"     # 响应后、提取前
resolve   = "hooks.js:resolve"    # 取流，可选
```

值为 `"文件:导出函数名"`，三个都是可选；不声明就走纯 L0 路径。

### 5.2 钩子契约

```js
// sign —— 请求前改写请求
// input: { url, method, headers, body, params, store }
// 返回只含需要改写的字段
function sign(input) {
  const ts = String(Date.now());
  return { url: `${input.url}&t=${ts}`, headers: { 'X-Sign': md5(input.url + ts) } };
}

// transform —— 响应后、选择器提取前替换响应体
// input: { body, status, headers, url }
function transform(input) {
  return { body: decrypt(input.body) };   // crypto 由本文件自带
}

// resolve —— 复杂播放地址推导（可选）
// input: { drama, chapter, store }
function resolve(input) {
  return { url, headers, keyUri, keyIv };
}
```

### 5.3 宿主执行顺序（每个动作）

```
1. 按 rules.json 渲染 URL / 头 / body
2. hooks.sign   若声明 → QuickJsHost::eval(hooksJs, JSON(input)) → 合并回请求
3. transport.fetch                      ← 域名白名单在此校验
4. hooks.transform 若声明 → 用返回的 body 替换响应体
5. 按 rules.json 的选择器 / JSONPath 提取
```

`resolve` 只在取流时调用，返回结构直接映射到 `Media`。

### 5.4 宿主改动清单（出雏形所需）

| 文件 | 改动 |
| --- | --- |
| `plugin-host/src/manifest.rs` | 解析 `[hooks]` 段；`kind` 保持 `rule` / `component` 不变 |
| `plugin-host/src/package.rs` | 无需改动（zip 里多一个文件，`file()` 已能取） |
| `rule-engine/src/rules.rs` | `RuleDocument` 加 `hooks: Option<HooksSpec>`（三个 `Option<String>`） |
| `rule-engine/src/executor.rs` | 三个 hook 点调用 `env.scripts`；hook 缺失时走原路径 |
| `runtime/src/rule_source.rs` | 包内 `hooks.js` 内容随 `RuleSource` 一起持有 |
| `runtime/src/plugins.rs` | 加载时把 `hooks.js` 传给 `RuleSource` |
| `bridge/src/api/` | **无需新增 API** —— 复用 `install_plugin` / `install_from_repo` |

FRB 边界、仓库协议、安装器、签名、回滚**全部不动**。

### 5.5 错误处理

hook 失败必须给出可定位的信息：`source_id` + hook 名 + 函数名 + JS 异常。
返回值一律严格校验（缺字段 / 类型不符直接 `SourceError::parse`），
不允许「JS 返回 undefined 就静默跳过」——那会让排查回到 Core-3 的困境。

---

## 6. 对现有资产的影响

| 资产 | 处置 |
| --- | --- |
| 7 个 Wasm 插件（`assets/bundled_plugins/`） | **保留并冻结**：能跑，不新增，不补齐能力 |
| `crates/plugin-wasm/`（3079 行） | 保留；不再投入 |
| `plugin-host` 安装器 / 仓库协议 / 签名 | **全部保留**，L0/L1 复用同一套打包与分发 |
| `docs/EXTENSION-ARCHITECTURE.md` 的仓库与 UX 设计 | **完全有效**，只是扩展包内容变了 |
| 5 个 `source-*` 编译源 | 按原计划用 L0/L1 重写后删除；**不再依赖 Wasm 补齐能力** |

**关键收益**：`EXTENSION-ARCHITECTURE.md` 里的 S1（补 WIT 6 个导出，8h+）从关键路径上消失了。
双轨清理不再被 Wasm 卡住。

---

## 7. 工作量对比

| 路线 | 出雏形所需 |
| --- | --- |
| 继续 Wasm | 6 个 WIT 导出 + `ComponentSource` 实现 + 7 个插件改写 + 对拍 ≈ **8h+**，且只解决「能装」，不解决「好写」 |
| 转 L0/L1 | `rules.rs` 加 hooks 字段 + `executor.rs` 三个调用点 + `rule_source.rs` 传递 ≈ **1.5 天**，且扩展作者门槛从「会 Rust + 会 wasm 工具链」降到「会写 JSON，必要时抄一段 JS」 |

## 8. 风险

| 风险 | 对策 |
| --- | --- |
| JS 无类型，错误难定位 | hook 返回值严格校验 + 错误信息带 source_id / hook / 函数名 |
| 站点 JS 体量大或混淆 | `PackageLimits` 单文件 8 MiB；超大包在商店页标注体积 |
| QuickJS 每次新建 Runtime | `script.rs` 注释已评估「毫秒级纯计算，创建开销可忽略」；先不引入 Runtime 池，避免状态泄漏 |
| 某个源 JS 也搞不定 | 那就是内置源（红果就是这个定位），接受这一层上限 |
| 已有 Wasm 投入显得白费 | 不删；它验证了「代码扩展可行」，且是 L2 的现成底座 |

---

## 9. 待确认

1. 是否采纳 ADR-13（L0/L1 主线 + L2 冻结）？
2. 若采纳，第一个用 L1 重写的试点源建议选**牛果**（`source-niuguo` 433 行，
   只做 AES-ECB 响应解密，一个 `transform` 钩子即可覆盖，半天能验证全链路）。
