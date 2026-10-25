# 扩展模型与社区生态设计

> 制定：2026-10-25 · 依据新增约束（多内容类型 + 社区作者）修订
> 关联：`docs/EXTENSION-RUNTIME-DECISION.md`（运行时选型 ADR-13）、
> `docs/EXTENSION-ARCHITECTURE.md`（仓库与 UX）

---

## 0. 新增约束带来的修正

> **2026-10-25 再修订**：当前**没有社区作者**。所以
> **「把扩展做满」是当前目标，「兼容第三方编写」是契约纪律，社区配套（试跑页 / 模板仓库 /
> 文档站）现在做是浪费**。等真有第三方作者出现时，那些设施的成本会低得多——
> 因为契约和能力那时已经稳定。
>
> 一句话：**现在自己写满，但每一步都按「外部人只靠文档也能写」的标准来做。**

上一版把 JS 定位成「规则包的附属钩子」——这个定位偏保守。修正如下：

| 项 | 上一版 | 本版 |
| --- | --- | --- |
| JS 的定位 | 规则的补充钩子 | **一等公民**，纯脚本包可独立存在 |
| 包形态 | L0 规则 / L1 规则+钩子 / L2 Wasm | **`rules.json` 与 `*.js` 自由组合**，Wasm 冻结 |
| 设计目标 | 覆盖现有 guoapp2 站源 | **让外部作者能低成本写出可用插件** |

**核心原则：能力渐进披露。** 作者按自己会的东西选路径，三条路都能交付可用插件，
且共用同一套打包、签名、分发、回滚机制。

---

## 1. 多内容类型：改标签，不改模型

### 1.1 现状（已核实）

`source-api/src/model.rs` 的 `Drama` + `Chapter` 已经足够通用：

- 电影 = `episodes: 1` 的 `Drama`；
- 剧集 / 动漫 = 多 `Chapter` + `seasons()` 返回的 `SeriesSeason`；
- `tags` / `release_status` / `online_date` 已能承载类型特有信息的主体。

### 1.2 要做的

```rust
// source-api/src/plugin.rs
pub enum ContentType {
    ShortDrama, Movie, Tv, Anime, Variety, Documentary,
}

pub struct SourceMeta {
    // ... 现有字段
    #[serde(default)]
    pub content_types: Vec<ContentType>,   // 新增；空表示未标注
}
```

宿主用它做三件事：商店分类筛选、发现页按类型聚合、能力位之外的一层粗分类。

**A6 已落地**（2026-10-25）：

| 位置 | 字段 | 说明 |
| --- | --- | --- |
| `rules.json` | `contentTypes: ["short-drama"]` | 作者唯一输入 |
| `main.js` | `describe().contentTypes` | 脚本包同款 |
| `plugin.toml` | `content_types = [...]` | 分发展示副本，`pack_rules` 从规则派生 |
| `index.json` | `contentTypes` | 商店在下载前即可筛选 |
| `SourceMeta` | `content_types` | 运行期真相，桥接层以字符串暴露给 Dart |

纪律：清单 / 索引与包内声明不一致时**安装即失败**（`PluginError::Integrity`），
离线工具同样报错。理由很简单——分类错了用户找不到插件，且无法靠「重新拉仓库」修复。

下游怎么用（2026-10-25 补）：

| 位置 | 行为 |
| --- | --- |
| `sourceCatalog()` | `SourceSummary.contentTypes` 把运行期真相送到 Dart |
| `SourceSite.contentTypes` | **类型取引擎、文案取编译期**；插件装的源也带类型 |
| 发现页源菜单 | 多类型时顶部出现类型筛选行（单类型时不显示，避免死选项） |
| 商店 | 可安装区筛选片 + 卡片类型标签 + `n/m` 计数 |

`CatalogController.contentTypesOf` / `sourcesOfType` 是纯函数，由
`test/domain/source_content_types_test.dart` 10 条用例覆盖（顺序稳定、去重、
未知类型排后、未标注不落入任何类型）。

### 1.3 明确不做

**不要为每种内容类型建独立模型。** 那会让插件作者为同一个站点写多套适配，
宿主也要维护多套解析与 UI——这正是「兼容大部分网站」的反面。
类型特有元数据（`导演 / 声优 / 放送时间`）先用 `tags` 承载，
等真有需求再按具体字段增量加，不要预先引入 `extra: Map<String, String>`
（它会让所有强类型校验失效）。

---

## 2. 三种包形态（同一套打包与分发）

一个 zip 里 `rules.json` 与 `*.js` 至少有一个，`kind` 由内容推导而非作者声明。

| 形态 | 内容 | 作者需要会 | 覆盖场景 | 状态 |
| --- | --- | --- | --- | --- |
| 纯规则 | `rules.json` | JSON + CSS / 正则 | 静态页、公开 API、maccms 系 | ✅（含 `kind = "regex"`） |
| 规则 + 钩子 | `rules.json` + `hooks.js` | 上面 + 抄一段 JS | 需要签名 / 解密（黄豆、cloudfront、猫果） | 待做 |
| 纯脚本 | `main.js` | JS（可自带 crypto-js） | 登录、多步编排、验证码兜底（野果） | **✅ 已完成**（见 §2.3） |

### 2.1 纯脚本包契约

宿主注入的 `ctx` **全部同步**（见 §2.2），作者写同步代码：

```js
function describe() {
  return {
    id: 'guo.example',
    name: '示例',
    group: 'movie',
    apiLevel: 1,
    contentTypes: ['movie'],
    capabilities: ['catalog', 'detail', 'search', 'resolve'],
  };
}

function catalog(ctx, page, category) {
  const res = ctx.fetch({ url: `https://example.test/page/${page}` });
  return { items: parse(res.body), hasMore: true, page };
}

function detail(ctx, sourceId) { /* → { drama, chapters } */ }
function search(ctx, query, page) { /* → 同 catalog */ }
function resolve(ctx, drama, chapter) { /* → { url, headers, keyUri, keyIv } */ }
```

`ctx` 表面：

```js
ctx.fetch({ url, method, headers, body })  // → { status, body, headers, finalUrl }
ctx.store.get(key)                          // 会话存储，按插件命名空间隔离
ctx.store.set(key, value)
ctx.log(message)
ctx.now()                                   // 毫秒时间戳
```

网络域名仍受清单 `permissions.network` 白名单约束——**JS 拿不到白名单之外的域名**，
与 Wasm 沙箱同一套策略。

### 2.2 为什么宿主 API 设计成同步

- 作者心智负担最低：不需要理解 async / Promise；
- 宿主可复用现有机制：在 `spawn_blocking` 里 eval，内部 `block_on`
  （与 `plugin-wasm/src/sandbox.rs::block_on` 同款）；
- 代价是插件侧请求串行——与现有 Wasm 插件一致，已被接受。

---

### 2.3 纯脚本包已落地（2026-10-25）

`kind = "script"`，`entry` 指向 `main.js`。脚本是普通 JS，顶层 `function catalog(input) {}`
即为导出；宿主在加载期探一次导出清单，据此生成能力位——**新增一个方法不用改任何 IDL**，
这正是 Wasm 路线卡住的地方（WIT 加 6 个导出 = 8h+，这里 = 0）。

作者看到的全部接口：

```js
function describe() { return { id, name, group, apiLevel }; }

function catalog(input) {              // input: { page, category }
    const res = ctx.fetch({ url: 'https://x.test/list?page=' + input.page });
    return { items: [{ sourceId: '7', title: '剧名' }], hasMore: false, page: input.page };
}
```

`ctx` 只有四个成员，全部同步：`fetch` / `store`（`get` / `set`）/ `log` / `now`。

三条硬约束已经实现并有测试守着：

1. **域名白名单**——`ctx.fetch` 只放行清单 `permissions.network` 声明的主机，
   清单没声明任何主机时一律拒绝（避免「忘写配置 = 全放行」）。与 Wasm 沙箱同一策略。
2. **执行上限**——`[permissions.script]` 的 `timeout_ms` / `memory_kb` 经中断处理器与
   内存上限生效；死循环会被掐断而不是拖死进程（有测试）。
3. **错误可定位**——rquickjs 抛出的异常只剩 `Exception`，宿主把真实原因留在
   `globalThis.__last_host_error` 再取回，作者看到的是「请求了未声明的域名：…」这种话。

已知取舍：脚本侧请求是**串行**的（宿主在阻塞线程里同步驱动异步请求，与 Wasm 插件同款），
与 §2.2 一致。

### 2.4 试点对拍：猫果脚本包 vs 编译源（2026-10-25）

第一个真实脚本扩展：`rust/examples/extensions/maoguo/`（`main.js` + `plugin.toml`，
约 130 行 JS），对拍测试 `bridge/tests/script_maoguo_golden.rs`（原名 script_maoguo_parity，编译版删除后改金标准）——同一个 `ScriptEnv`
下，脚本源与 `source-maoguo` 编译源各自解析**同一份离线夹具**，逐字段断言相等。

| 对拍项 | 结果 |
| --- | --- |
| 签名（`sign` + MD5 拼串，含中文 UTF-8） | ✅ 逐字节一致 |
| 详情（标题/封面/分集标题/播放地址） | ✅ 全字段一致 |
| 搜索条目 | ✅ 一致 |
| 目录条目 | ✅ 一致；`category` 脚本版**更全**（编译版丢弃字符串形态的 tags） |

结论：**`main.js` 能无损替代一个 683 行的编译 crate**。签名、解析、分集构造全链路
验证通过。插件能力缺口（P0-2：`ComponentSource` 5/10 方法）在脚本路径下不存在——
`ScriptSource` 实现全部方法，不需要动任何 IDL。

对拍还修出一个契约设计问题：作者不该被迫知道宿主 id 规则（`maoguo:21277`）。
脚本返回**全可选字段**的宽松结构，归属字段（`source` / 复合 id）由宿主补齐
（`runtime/src/script_source.rs` 的 `RawDrama` / `into_page` / `into_detail`）。

## 3. 要补齐的提取与编排能力（面向「兼容大部分网站」）

现有 `RuleKind` 只有 `Html`（CSS）/ `Json`（JSONPath）/ `Next`（内嵌 JSON），
正则只在 `idPattern` 一处。缺口：

| 缺口 | 触发它的真实站点 | 改动 | 状态 |
| --- | --- | --- | --- |
| **正则提取** | 黄果 1306 行全靠 `regexp` | `RuleKind` 增加 `regex` 提取方式；加 `regex` 依赖 | **✅ 已完成**（2026-10-25，见 §3.1） |
| **多步编排** | 野果：发现站点 → 取 script 配置 → 请求 | 规则增加 `preflight` 步骤列表，前置结果注入后续模板上下文 | **✅ 已完成**（2026-10-25，见 §3.2） |
| 登录 / 会话 | 芽果设备令牌 | 已有 `store`，JS 可直接读写 |
| Cookie / Origin 透传 | 剧果 CloudFront 签名 | `Media.cookies` / `Media.origin` 已有 |
| 多画质 / 多线路 | 通用 | `Media.qualities` / `quality` 已有 |
| 验证码兜底 | 少数站点 | 参照 Kazumi 的 webview harvest，**暂缓**，但契约留口子 |

前两项曾是唯一阻塞项（合计约 2.5 天），现已全部落地。

### 3.1 正则提取已落地（2026-10-25）

`kind = "regex"` 的语义固定在这一层，规则作者只依赖三条：

- `item`：全局匹配，**每个完整匹配是一个条目的原文块**；
- 字段：块内第一个匹配，有捕获组取**第 1 个捕获组**，无捕获组取整段匹配；
- 内联 flag 可用（`(?is)` 等），与 Go `regexp` 语法基本一致，
  所以 guoapp2 的规则能近乎原样搬过来。

新增面：`RuleKind::Regex`、`EpisodesSpec::Regex`（`pattern` / `titleGroup` /
`titleTemplate`）、`ResolveRule.urlRegex`（候选列表）、`RuleDocument::validate_regexes`
（**加载期**编译全部正则，写错就报错而不是静默空结果）。

实现要点：所有正则在**一次解析开始时编译一次**，不是每个条目一次——
站点改版时最容易出现的就是「一条正则 × 几百个条目」，编译放进条目循环
会把成本放大几百倍（`regex_executor.rs::CompiledFields`）。

验收：`crates/rule-engine/tests/regex_source.rs` 用 guoapp2 里黄果的**原始正则**
跑通目录 / 分集 / 详情补全 / 三候选取流，5 条用例全绿。

### 3.2 多步编排已落地（2026-10-25）

规则增加顶层 `preflight` 步骤列表：主请求之前按顺序取会话 / 配置，把结果注入后续模板。

```jsonc
{
  "preflightTtl": 300,                    // 复用秒数；0 = 每次重跑；缺省 300
  "preflight": [
    { "name": "站点", "url": "{base}/api/site",
      "extract": { "vars": { "site": "$.data.site" } } },
    { "name": "配置", "url": "{var:site}/api/config",
      "headers": { "X-Token": "{var:token}" },
      "extract": { "vars": { "token": "$.token", "host": "$.host" } } }
  ],
  "catalog": { "url": "{var:host}/list?page={page}&t={var:token}", "items": ["data.list"] }
}
```

语义与纪律（全部有测试守着）：

| 项 | 规则 |
| --- | --- |
| 变量作用域 | 第 N 步只能引用第 1..N-1 步的变量；主动作段可用全部变量。**逆序引用在加载期报错** |
| 未声明变量 | `{var:x}` 而没有任何步骤声明 `x` → 加载期报错（不会渲染成空串发出坏请求） |
| 提取方式 | `json`（JSONPath，缺省）/ `next`（内嵌 JSON）/ `html`（CSS，支持 `a@href`）/ `regex`（第 1 捕获组） |
| 提取为空 | 视为失败并**带上变量名**报错——空串注入地址是最难查的一类静默故障 |
| 失败定位 | `preflight 步骤 #1 配置 失败：…`（步骤名可读，序号可定位） |
| 复用 | 结果按 `preflightTtl` 缓存（`RuleSource` 内，锁只在读写缓存时持有，网络请求不持锁） |
| 请求体 | 步骤的 `body` 里同样可以写 `{var:…}`，`{"$int":"{var:n}"}` 输出数字 |

实现位置：`rule-engine/src/preflight.rs`（纯提取，零 IO）+ `runtime/src/rule_source.rs`
（驱动请求与缓存）。规则引擎的零 IO 纪律没有被破坏——请求仍由 runtime 层发出。

---

### 3.3 离线校验已落地（A5）

`cargo run -p guo-runtime --bin check_plugin -- <包路径>`，实现放在
`runtime/src/check.rs`（库），CLI 只是薄壳——这样校验逻辑能被普通集成测试覆盖。

| 模式 | 行为 | 用途 |
| --- | --- | --- |
| 默认（静态） | 解包 → 清单校验 → 规则 `from_json` / 脚本 `describe()` | 提交前、CI，不联网 |
| `--live` | 再发一次目录 / 搜索请求（单请求 45s 上限） | 发版前确认站点还能取数 |
| `--json` | 单行 JSON | CI 断言 |

输出包含：包 id / 版本 / sha256、每条规则的 id / 名称 / 内容类型 / 能力位 / `preflight` 步数、
以及**阻塞性问题**清单。未标注 `contentTypes`、清单与规则不一致、脚本没导出能力，
都会逐条报出而不是静默通过——「工具比宿主宽松」是这类工具最大的失败模式。

配套测试：`runtime/tests/plugin_check.rs` 8 条（好包 / 未知类型 / 两侧不一致 / 脚本缺
`describe().id` / zip 解析 / JSON 可解析 …）。

### 3.4 现场冒烟咬到的两个真问题（2026-10-25）

1. **猫果示例包本来装不上**：`plugin.toml` 写 `timeout_ms = 10000`，
   而清单校验上限是 5000——工具第一次跑就报了出来。根因是上限按「CPU 时间」设的，
   但脚本里的 `ctx.fetch` 在 JS 线程上等网络，墙钟才是实际约束。
   上限改为 30s（`manifest.rs`），与 `ScriptLimits` 默认 10s 自洽。
2. **猫果接口现场验签失败 → 查下来是脚本漏了请求头（结论已纠正）**。
   `--live` 返回 `{"errors":{"code":"44010120","title":"验签失败"}}`，
   当时记下的判断是「站点改了签名规则」。**这个判断是错的**：
   补一条 `tests/maoguo_live.rs` 发真请求后，编译源（带全套请求头）目录 / 详情 /
   搜索**全部通过**，700ms 内返回——站点没改任何规则。
   真因在示例脚本：`ctx.fetch({ url })` 只发了地址，没带 `qm-params` 与
   `authorization`。七猫的鉴权是**两层**：URL 里的 `sign` 只是第一层，
   缺了请求头站点会直接拒绝，看起来和「签名算错」一模一样。

   教训有两条，都值得写进排查手册：
   - **对拍只能证明「两边算得一样」，证明不了「站点还认这套」**。所以每个源
     都该有一条 `--ignored` 的真请求用例，结论进文档前先跑它。
   - 「验签失败」这类错误码要区分**算错**与**没带**——先看请求头，再看签名串。

   修复：示例脚本补 `base64`（自带，宿主只保证 `crypto.md5`）+ 字符映射表 +
   `authorization` 签名，`headers({sessionId})` 导出给对拍测试；
   `script_maoguo_golden.rs` 钉住 `qm-params` / `sign` 逐字节相等。
   之后 `check_plugin --live` 实测：目录 62 条、搜索「都市」10 条。

## 4. 社区配套（决定生态成败的部分）

引擎能力只是入场券。**社区作者留不留下来，取决于能不能自己把插件调通。**

### 4.1 当前缺口（已核实）

引擎侧已有 4 个规则调试接口：

```
parse_catalog_with_rule / parse_detail_with_rule / validate_rule / fetch_catalog_with_rule
```

但 `grep lib/ --include=*.dart` **零命中**——Dart 侧完全没接线，**没有试跑页**。
作者写完规则无法验证，只能靠猜。

Kazumi 对应设施：`lib/pages/plugin_editor/plugin_test_page.dart`
+ `RuleSearchTrace` / `RuleChapterTrace`。这是它社区能跑起来的关键。

### 4.2 必备清单

| # | 设施 | 说明 | 优先级 |
| --- | --- | --- | --- |
| 1 | **试跑页 + trace** | 复用现有 4 个调试接口，做一个规则实验室页：粘贴规则 → 逐步展示请求 URL、响应原文、每字段提取结果、失败原因 | **P0** |
| 2 | 模板仓库 `hoshi-plugin-template` | 三个子目录（rule / hybrid / script），各带 README、示例、`package.json`（含 crypto-js） | P0 |
| 3 | 校验 CLI `hoshi-plugin check <dir>` | 离线可跑：清单字段、索引条目、包体上限、权限声明、选择器合法性 | P0 |
| 4 | 文档站 | 契约参考 + 三种模板教程 + 常见站点模式（maccms / XPath / JSON API / 签名站） | P1 |
| 5 | 仓库 CI | PR 跑 `check` + 冒烟对拍；合并后自动打包、更新 `index.json` 与签名 | P1 |
| 6 | 贡献流程 | issue 模板、PR 模板、站源上架检查表（含「站点可达性」实测） | P2 |

### 4.3 API 稳定性承诺（社区生态的前提）

- `apiLevel` 只在**不兼容变更**时递增；
- 新增能力一律 `serde(default)`，老插件不受影响（`RepoIndexEntry` 已是这个风格）；
- 废弃提前**两个版本**公告，并在试跑页对用到废弃字段的插件给出警告；
- 宿主版本低于 `minHost` 时，商店显示「需要升级应用」且不可安装（Kazumi 同款）。

---

## 5. 路线（重排：自己做满优先）

**没有社区作者的现实改变了排序。** 目标从「让外部人能写」改成「我们覆盖全部站源」，
但每一格都要满足 §6 的契约纪律。

| 编号 | 内容 | 预估 | 为什么现在做 | 状态 |
| --- | --- | --- | --- | --- |
| **A1** | `rule-engine` 补 regex 提取方式 | 0.5d | 黄果 1306 行全正则，挡住 L0 覆盖 | ✅ 已完成（§3.1） |
| **A2** | JS 一等公民：`main.js` + 同步 `ctx` + 沙箱 | 3d | 决定「能做满」的上限（复杂站点） | ✅ 已完成（§2.3 / §2.4） |
| **A3** | 多步编排 `preflight` | 2d | 野果类站点必需 | ✅ 已完成（§3.2） |
| **A4** | 用新形态重写全部站源（本体工作量） | 量大 | 这就是「做满」 | 🚧 进行中（猫果已用脚本形态重写并实网通过，见 §3.4） |
| **A5** | 离线扩展校验 / 冒烟工具（`cargo test` 驱动） | 1d | **我们自己写扩展时也要能快速验证**，不是社区设施 | **✅ 已完成**（见 §3.3） |
| **A6** | `SourceMeta.content_types` + 商店分类 | 0.5d | 多内容类型的入口 | **✅ 已完成**（见 §1.2 / §3.4） |

**暂缓（等真有第三方作者）**：试跑页 / trace UI、模板仓库、文档站、校验 CLI 的对外包装、
贡献流程。A5 的离线工具是将来 CLI 的种子，但先做成自己能用的测试驱动形态。

顺序理由：A1+A2+A3 是**能力**，A4 是**内容**。能力不齐就动手重写站源，会反复返工——
这正是当前插件模块「至今没有雏形」的另一面教训。

## 6. 契约纪律（现在就要守，否则将来改不动）

自己写扩展最大的风险是**退化成内部格式**：我们自己知道宿主内部细节，会不自觉地依赖它，
等第三方来写时才发现契约全是漏洞。而那时契约上已经挂了 20 个源，改不动了。

五条自检标准：

1. **不读 Rust 源码**。写扩展时如果需要翻 `crates/**` 才能搞明白某个字段，
   说明契约漏了——补文档或补 manifest 声明，而不是靠口口相传。
2. **能力必须声明**。任何权限（域名、存储、能力位）都在清单里显式写出，
   宿主**不靠猜**、不靠隐式默认值。
3. **错误可定位**。每个失败都要带 `source_id` + 步骤名 + 选择器或字段名，
   让不认识宿主代码的人也能自己改。
4. **新增字段一律 `serde(default)`**。老扩展不受影响（`RepoIndexEntry` 已是这个风格）。
5. **只暴露文档化的表面**。扩展拿到的 `ctx` 就是全部——不泄漏宿主内部类型（见 §2.2）。

**验收方式**：把 A4 里写的第一个扩展交给一个没读过引擎代码的人照文档实现一遍。
他卡住的地方就是契约的漏洞。

---

## 7. 验收

1. 一个只会 JSON 的人，照模板 30 分钟内做出一个可用的纯规则插件并自己验证通过；
2. 黄果用它重写后能替代原 1306 行 Go（regex 提取器验收）；
3. 黄豆用纯脚本包实现（AES + HMAC-SHA256），输出与原 Go 实现逐字节对拍一致；
4. `check_plugin` 在离线环境拦住常见错误——**已落地**：包结构 / 清单非法 /
   规则写错 / 未知内容类型 / 清单与规则不一致 / 脚本加载失败 / 脚本零能力；
5. 商店与发现页都按 `contentTypes` 筛选——**已落地**：商店是可安装区筛选片 +
   卡片标签 + `n/m` 计数；发现页是源菜单顶部的类型行（只有一种类型时不出现），
   且切换类型会自动把当前源换成该类型的源。
