# Rust 引擎重写进度

## 状态总览

| 阶段 | 状态 |
| --- | --- |
| POC-1 rquickjs on iOS | ✅ 通过 |
| POC-2 FRB 四端 | ✅ 通过（Windows 待 CI 补验） |
| POC-3 TLS 指纹 / CF | ✅ 通过（wreq 可过 CF） |
| 契约层 | ✅ 落地 |
| 声明式规则引擎 | ✅ 落地，HTML / JSON / 内嵌 JSON 三类取数 |
| HTTP 传输层 | ✅ reqwest 实现，live 请求验证 |
| 代码插件层 | ✅ 猫果签名源端到端跑通 |
| 站源迁移 | 🔄 6/20（伍果、花果、饭果、观果、星果、河果声明式；猫果签名）—— 新增四源为开发快照，未做真实站点验证 |
| 取流（resolve） | ✅ 引擎接管，含 HLS 解析与回退 |
| 下载引擎 | ✅ 断点续传 + HLS 分片 + AES-128 解密 |
| 目录缓存 | ✅ 版本化落盘 + TTL + 分页游标合并 |
| Flutter 接入 | ✅ 装饰器架构 + 真实调度（16 项测试） |
| 对拍验收 | ✅ Go 夹具 + Dart 模型跨层对拍 |
| **P0 基线** | ✅ 2026-10-19：工作区 + CI + 构建验证 + 插件运行时探针（见第十二轮） |

## 第十二轮：P0 基线（2026-10-19）

目标：把重写前的地基打完 —— 质量门禁、工作区、构建验证、插件运行时探针。

### 落地内容

| 项 | 结果 |
| --- | --- |
| 格式化 / 静态检查 | `cargo fmt --all --check`、`cargo clippy --workspace --all-targets -D warnings` 全绿 |
| 测试 | 163 项（原 156，新增 7 项） |
| CI | `.github/workflows/build.yml` 新增 `rust` job：fmt + clippy + test + 依赖方向守卫 |
| 工作区 | 虚清单 + `bridge/` 桥接 + `crates/source-api` + `crates/plugin-wasm` |
| 构建验证 | macOS `flutter build macos` 成功；Android `flutter build apk` 产出含三 ABI 的 `libguo_engine.so` |
| 插件运行时 | wasmtime 49.0.2 + Pulley，三端交叉编译通过，冷启动约 2 ms |

### 修复的缺陷（对应 `AUDIT.md`）

| 编号 | 问题 | 处理 |
| --- | --- | --- |
| 3.4 | `panic = "abort"` 与 FRB 的 `catch_unwind` 冲突 | 改回 `unwind`，注释说明原因 |
| 3.2 | 下载删除先 `remove` 后取 target，导致删不掉文件 | 先取 target 再删，补注释 |
| 3.3 | HLS 每次从零开始，宣称的断点续传不存在 | 按分片签名 + 已完成数续传，每片落元数据 |
| 3.3 | `FileState.validator` 从未写入，`If-Range` 永远为空 | 从响应采集 ETag / Last-Modified |
| 3.1 | 非 HLS 媒体也被整段读入内存 | 先读 1 KiB 前缀判断 `#EXTM3U`，确认后再拉全量 |
| 新增 | 续传时服务器返回空 206 被当成错误 | 识别为「已完整」直接成功 |

### 工作区迁移的两个坑

1. **`include_str!` 路径**：`rules/` 留在 `engine/` 根，桥接 crate 下移一层后，
   `src/sources/mod.rs`、`src/api.rs`、集成测试、examples 的四处相对路径全部要跟着改；
   Dart 测试 `test/engine_bridge_test.dart` 引用的 `engine/tests/fixtures/` 也变成
   `engine/bridge/tests/fixtures/`。
2. **podspec 缓存**：改完 `manifestDir` 后必须先 `pod install`，否则 Xcode 仍用旧参数
   （报错 `BuildTool arguments: [build-pod, ../../engine, ...]`），看起来像路径改错了。

### 体积探针结论

详见 `poc-4-wasmtime-pulley.md`。要点：

- 三端均可编译（iOS 首次验证通过），冷启动 1–2 ms；
- 但**真实链接增量** iOS ≈ 9.2 MB、Android arm64 ≈ 12.5 MB、宿主 dylib +10.5 MB；
- 只声明依赖不调用时，LTO 会把整个运行时裁掉（体积只涨 64 字节），
  这类测量无效，必须保留真实调用点。

体积超预算，P1 开工前需在「接受 / 平台分层 / 缩小运行时」三者间决策。

### 未做

- 未在设备上运行插件（仅交叉编译）；
- 未测真实插件组件的 WIT 胶水开销；
- Go 参考测试仍失败（P0 的另一项，留待下一轮）；
- `guo-host` / `guo-rule-engine` / `plugin-host` 尚未建立。

---

## 已落地代码

```
engine/
  src/model.rs        Drama/Chapter/Page/Media/Detail
  src/error.rs        SourceError 类型化错误（替代 Go 的 472 处字符串错误）
  src/env.rs          SourceEnv + Transport/Store/ScriptHost 能力白名单
  src/source.rs       SourcePlugin trait + SourceRegistry
  src/crypto.rs       纯 Rust MD5（猫果签名、观果 clientInfo 共用）
  src/rule/rules.rs   规则 schema + 加载期校验（html / json / next 三类）
  src/rule/executor.rs CSS 提取引擎（支持候选选择器）+ 按 kind 分发
  src/rule/jsonpath.rs 接口 JSON 路径取值（`a.b[]`、`a[2]`、`$`）
  src/rule/json_executor.rs 接口站源与内嵌 JSON 取数
  src/rule/embedded.rs 页面内嵌 `__NEXT_DATA__` 提取
  src/transport.rs    reqwest 传输层
  rules/wuguo.json    伍果真实规则（20 行）
  rules/huaguo.json   花果：哈希 class 名前缀用属性子串匹配
  rules/fanguo.json   饭果：接口 + 复合主键 `{id}#{source}`
  rules/guanguo.json  观果：POST JSON 体 + `{md5:{ts10}}` + 多清晰度取高
  rules/xingguo.json  星果：固定鉴权参数 + 递归查找分集地址
  rules/heguo.json    河果：`__NEXT_DATA__` 页面 + 分集页面延迟取流
  tests/real_sites.rs 真实站点 fixture 测试
  tests/json_site_rules.rs 声明式站源离线夹具对拍（含内置规则加载校验）
  tests/fixtures/     伍果 / 皮果真实页面快照
```

代码量：引擎侧约 5,400 行，规则清单约 830 行（均不含测试、fixture 与 FRB 生成绑定）。

## 声明式规则的三类取数

| `kind` | 取数方式 | 代表站源 |
| --- | --- | --- |
| `html` | CSS 选择器 | 伍果、花果 |
| `json` | 接口 JSON 路径 | 饭果、观果、星果 |
| `next` | 页面内嵌 `__NEXT_DATA__`，接口回退纯 JSON | 河果 |

规则层为接口站源补齐了这些能力：条件地址候选（`urls[].when`）、POST + JSON 请求体模板
（`{"$int": "{page}"}` 输出数字）、模板 token（`{page}` `{category}` `{keyword}` `{id}`
`{idFirst}` `{idRest}` `{ts10}` `{md5:…}`）、复合主键（`idTemplate`）、
分集地址递归查找与多清晰度取高、播放量与完结状态换算。
`fetch_categories` 把规则里的分类清单暴露给 Dart，装饰器按能力路由，
站源未声明分类时回退 Go 核心。

## 已验证的真实站点

| 站源 | 方式 | 结果 |
| --- | --- | --- |
| 伍果 | 声明式规则 `rules/wuguo.json` | ✅ 首页 30 条 + 分类页 24 条，真实请求端到端 |
| 伍果（live） | `examples/live.rs` 真实网络请求 | ✅ 52 KB → 24 条，ID/标题正确 |
| 皮果 | 声明式规则 | ✅ 页面可解析（推翻了「CF 拦截」的历史判断） |

## 关键设计决策

1. **错误类型化**：`SourceError` 枚举取代字符串匹配，`http_status()` / `is_retryable()` 提供判断依据。
2. **能力白名单**：`SourceEnv` 只暴露 `transport` / `store` / `scripts` / `log`，
   provider 拿不到引擎内部，从类型上杜绝主项目的 50 处封装泄露。
3. **规则加载期校验**：`validate_selectors()` 在加载时拒绝空选择器和括号不配对，
   避免主项目「静默返回空结果」的失败模式。
4. **自匹配支持**：`scraper` 的 `select` 只查后代，`a@href` 作用于 `<a>` 条目时需显式处理。
5. **实体解码**：`&amp;` 等需要手动还原，含二次编码（`&amp;amp;`）。

## 踩过的坑

- `scraper` 对不完整选择器（`a[href`）不报错，因此改为加载期括号配对校验。
- 真实站点结构与推测不同（伍果用 `SecondList_secondListItem`，不是 `module-item`），
  必须先取真实 fixture 再写规则。
- `DynamicLibrary` 无关，但规则里的字段若取不到会静默变空值，需在测试里断言非空。

## 本轮真实站点验证（live）

```
GET https://www.duanju55.com/index.php/vod/type/id/1.html
body: 52408 bytes
parsed: 24 items
  23927 | 一念初见锦衣谣
  56665 | 兴安岭猎人传
  56664 | 撞大运后我在县城买了个院
```

## 多选择器设计（本轮新增）

同一站源不同页面结构差异很大：伍果**首页**用 `SecondList_*` 类名，**分类页**用 `BrowseList_*`。
因此 `item` 与所有字段都支持「字符串或候选数组」，按优先级依次尝试，
这直接对应主项目「一个源多种页面结构」的历史难题。

## 文本提取的两个真实缺陷（已修）

1. 嵌套 `span`（评分「537人在追」）被拼进标题 → 改为取**第一个非空文本节点**。
2. HTML 实体未还原（`&amp;` → 应为 `&`，还有二次编码 `&amp;amp;`）→ 加实体解码。

## 第二轮：脚本层与签名站源

### 脚本层（`src/script.rs`）

- `QuickJsHost` 提供 `crypto.md5` 与 `json` 两个能力，不暴露网络/文件系统。
- `rquickjs::Runtime` 不是 `Send + Sync`，因此不长期持有：每次执行在
  `spawn_blocking` 里新建隔离实例，脚本结束即释放。
- MD5 经 RFC 1321 标准向量校验（空串 / `abc` / quick brown fox）。

### 猫果签名源（`src/sources/maoguo.rs`）

七猫的签名不止 URL 参数，还包括一整套请求头：

1. 设备信息 JSON → Base64 → **字符映射表**（`CHAR_MAP`）得到 `qm-params`；
2. `md5("AUTHORIZATION=app-version=10001...qm-params=<件>reg=<key>")` 得到授权签名；
3. URL 里的 `sign` 是另一条独立签名，目录/详情/搜索各不相同。

实测结果：

| 阶段 | 结果 |
| --- | --- |
| 只带 URL sign | ❌ `{"code":"44010120","title":"验签失败"}` |
| 补齐 qm-params + authorization | ✅ **86,632 字节真实数据** |
| 目录解析 | ✅ 66 部，集数/封面/分类正确 |
| 详情解析 | ✅ 33 集，含真实 CDN 地址 |
| 搜索签名 | ✅ 与脚本实现一致 |

### 跨实现一致性（`tests/signature_parity.rs`）

Rust 原生 MD5 与 JS 脚本层 MD5 必须一致，否则签名会被服务端拒绝。
已验证 6 个用例 + 4 组目录签名 + 3 组搜索签名全部吻合。

### 修掉的生产 bug

`format!("{:x}", u128)` 不补前导零：MD5 以 `0` 开头时只输出 31 位，
签名必然失效。已全部改为 `{:032x}`。

## 第三轮：Go 对拍 + Flutter 接入

### Go 对拍（`tests/go_parity.rs`）

直接复用 `native/core/provider_duanju_test.go` 的 HTML 夹具，逐字段比对：

| 断言 | Go 期望 | Rust 结果 |
| --- | --- | --- |
| 剧目 ID | `wuguo:100` | ✅ |
| Source | `wuguo` | ✅ |
| 封面 | 服务端绝对地址 | ✅ 补全为 `https://.../pic/100.jpg` |
| 标题 | `五五样本`（取自 `a@title`） | ✅ |
| 分集链接 | 绝对地址 | ✅ |
| 分集顺序 | 保持原序 | ✅ |

对拍过程中修掉两个真实缺陷：

1. **cover 相对地址没有补全** —— 会导致 App 里海报裂图。
2. **多候选选择器命中同一节点产生重复分集** —— 加上按链接去重。

### Flutter 接入（FRB 2.13.0）

- `flutter_rust_bridge.yaml` 指向 `engine/`；
- `rust_builder/` 插件从模板复制并改名为 `rust_lib_guo_engine`，
  各平台 `cargokit` 路径改到 `engine`；
- 生成 `lib/src/rust/{api,frb_generated}.dart`。

Dart 侧可调用：

```dart
engineVersion()                       // 引擎版本
sourceCatalog()                       // 内置站源清单（替代硬编码）
parseCatalogWithRule(...)             // 纯函数解析
parseDetailWithRule(...)              // 纯函数解析
validateRule(...)                     // 规则校验
fetchCatalogWithRule(...)             // 真实网络抓取
```

验证方式与结果：

```sh
FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR="$(pwd)/engine/target/release/" \
  flutter test test/engine_bridge_test.dart
# 00:00 +6: All tests passed!
```

纯 Dart 测试默认不构建 Rust 原生库，需用上述环境变量指向已编译的动态库；
在真实 App 构建中由 cargokit 自动产出。

### 踩过的坑

- FRB 不支持零字段结构体（unit struct），会 panic 在 `structure.rs`；
  改为 `struct Foo {}` 并对内部类型加 `#[frb(ignore)]`。
- `#[frb(ignore)]` 加在 `QuickJsHost` 上后，`Self` 构造语法也必须带花括号。
- 规则里的 `a[href*=/play/]` 需要给属性值加引号，`scraper` 会报
  `BadValueInAttr(Delim('/'))`。

## 第四轮：统一调度与跨层对拍

### 统一调度（`src/sources/rule_source.rs`）

把声明式规则包装成 `SourcePlugin`，规则源与代码插件走**同一条调度路径**：

```rust
let registry = builtin_registry();
let source = registry.get(&source_id)?;
source.catalog(&env, page, &category).await
```

实测：

```
=== 站源清单 ===
  maoguo | 猫果 | ["catalog", "detail", "search"]
  wuguo  | 伍果 | ["catalog", "detail", "search"]

=== 规则源：伍果 ===  items: 24
=== 代码插件：猫果 === items: 66
=== 未知站源 === 正确报错: 未知站源：nope
```

### 新增 Dart 可调用入口

```dart
fetchCatalog(sourceId, page, category)   // 统一目录调度
fetchDetail(sourceId, dramaSourceId)     // 统一详情调度
fetchSearch(sourceId, query, page)       // 统一搜索调度
```

### 跨层对拍（`test/engine_model_parity_test.dart`）

这是「UI 不感知后端换语言」的硬约束：

| 断言 | 结果 |
| --- | --- |
| `DramaItem` → `Drama` → `toJson` → `Drama.fromJson` 往返无损 | ✅ |
| ID 格式 `"${source}:${sourceId}"` 与 Go 约定一致 | ✅ |
| 分集至少有 `videoUrl` 或 `pageUrl` | ✅ |

### 真实网络端到端（`test/engine_live_test.dart`）

Dart 直接驱动 Rust 引擎访问真实站点，11 项断言全部通过：

- 伍果（规则源）读到 24 条真实目录
- 猫果（代码插件）读到 66 部 + 真实分集与 CDN 地址

### 本轮修掉的规则缺陷

- `BrowseList_bookType` 实际是「已完结」状态标签，**分类应为 `BrowseList_tagsBox`**；
- 补充 `description` 字段，映射到 `BrowseList_bookIntro`。

这两处只有对照真实页面结构才能发现。

## 第五轮：cargokit 真实构建打通

### 结论

| 平台 | 结果 | 证据 |
| --- | --- | --- |
| Android | ✅ | APK 内含 3 个 ABI 的 `libguo_engine.so`（arm64 12MB / armv7 6.9MB / x86_64 13.8MB） |
| macOS | ✅ | `duanju_app.app` 启动运行无崩溃，二进制含 1,880 个 FRB 符号 |
| iOS | ⚠️ | Rust 静态库已生成（arm64 + x86_64），链接失败源于**既有 Go 核心缺失**，与 Rust 无关 |

iOS 失败的真实原因：`ios/Podfile` 依赖 `DuanjuCore.xcframework`，
而该文件从未生成过（需 `scripts/build_ios.py --core-only`）。
这是主项目既有状态，不是 cargokit 引入的。

### cargokit 的四个真实缺陷（全部已修）

cargokit 是 FRB 官方推荐的构建胶水，但在本机环境下有四处问题：

**1. 环境变量名不匹配 `cc` crate**

`cc` crate 读取 `CC_<target>` 时会把连字符规范化为下划线，
但 cargokit 只设置了带连字符的键（`CC_armv7-linux-androideabi`），
shell 层面这种键名无法被子进程继承。

修复（`android_environment.dart`）：额外下发下划线版本
`CC_/AR_/CXX_/RANLIB_/CFLAGS_/CXXFLAGS_/CARGO_TARGET_*_LINKER`。

**2. bindgen 缺 sysroot**

`rquickjs-sys` 的 bindgen 找不到 `stdio.h`。

修复：下发 `BINDGEN_EXTRA_CLANG_ARGS_<normalized>`，
Android 指向 NDK sysroot，Darwin 指向 Xcode SDK 并显式给出 clang triple。

**3. iOS 模拟器 triple 非法**

直接沿用 rust target 名 `aarch64-apple-ios-sim` 会让 clang 报
`version 'sim' in target triple is invalid`；必须写成
`arm64-apple-ios15.1-simulator`。

**4. 静态库名与 podspec 不一致**

cargokit 用 `crateInfo.packageName`（即 `guo_engine`）作为产物名，
忽略传入的 `libname` 参数，但 FRB 模板的 podspec 写死
`librust_lib_<name>.a`。本项目的 crate 叫 `guo_engine` 而插件叫
`rust_lib_guo_engine`，两者不同，导致链接器找不到文件。

修复：podspec 的 `output_files` 与 `-force_load` 统一改为 `libguo_engine.a`。

**5. `run_build_tool.sh` 相对路径失效**

`BASEDIR=$(dirname "$0")` 在 `cd "$CARGOKIT_TOOL_TEMP_DIR"` 之后失效，
导致 pod 构建报 `build_tool: No such file or directory`（Android 因为路径恰好正确而未暴露）。

修复：`BASEDIR=$(cd "$(dirname "$0")" && pwd -P)`。

### 对方案的意义

cargokit 可用，但需要打补丁。这些补丁可以上游提交，
也可以作为本项目 `rust_builder/` 的定制内容长期维护。

## 第六轮：双后端路由与站源扩充

### 双后端路由（`lib/engine_repository.dart`）

App 现在可以按站源选择后端，Go 路径完全保留：

```dart
NativeRepository(
  engine: EngineRepository,   // null 时全走 Go
  route: EngineRoute,          // 允许的站源集合
)
```

编译期开关（默认关闭，行为与纯 Go 版本一致）：

```sh
flutter run --dart-define=ENGINE_ROUTE=all
flutter run --dart-define=ENGINE_ROUTE=wuguo,maoguo,huaguo
```

安全性：`engineHandles()` 额外检查 `engine.initialized`，
未初始化时自动回退，避免调用 `RustLib` 抛异常拖垮启动。

### 模块布局重构（应用 `rust-module-layout` 技能）

原 `lib.rs` 是技能明确点名的反模式：
「扁平的 lib.rs + 全部 `pub mod` + 通配重导出」。

重构后：

| 项 | 前 | 后 |
| --- | --- | --- |
| `lib.rs` 行数 | 101 | **34** |
| 模块可见性 | 全部 `pub mod` | 私有 `mod` + 根级定向 `pub use` |
| POC 探针代码 | 混在 `lib.rs` | 独立 `probe` 模块 |

调用方通过 facade 访问（`guo_engine::Drama` 而非 `guo_engine::model::Drama`）。

### 站源扩充：花果

新增 `rules/huaguo.json`，实测 36 条真实数据：

```
89346 | 老婆出游不带我却不知整个岛都是我的-动漫合集 | 已完结
89345 | 重生1977开启我的逆袭之路-动漫合集 | 已完结
```

花果的 class 名带哈希前缀（`_9dbe81752a1dbf17-vodlist__item`），
规则用 `[class*=vodlist__item]` 属性子串匹配，**站点换哈希也不会坏**。

### 剩余站源的可迁移性实测

用 `wreq`（Chrome131 指纹）逐个验证：

| 站源 | curl | wreq 指纹 | 结论 |
| --- | --- | --- | --- |
| 花果 | 200 | 200 | ✅ 已迁移 |
| 网果 | CF 拦截 | **仍拦截** | ❌ 需 WebView |
| 发果 | 403 | 403 | ❌ 站点拒绝 |
| 皮果 | 492 | 492 | ❌ |

结论：**TLS 指纹不是万能的**，网果的「Just a moment」仍然拦截。
这部分需要 WebView 方案，与 POC-3 记录一致。

### 当前站源覆盖

| 站源 | 方式 | 状态 |
| --- | --- | --- |
| 伍果 | 声明式规则（24 条） | ✅ |
| 花果 | 声明式规则（36 条） | ✅ |
| 猫果 | 代码插件（66 部 + 33 集） | ✅ |
| 其余 17 个 | — | ⬜ |

## 第七轮：架构重构与质量基线

### 质量基线（按 `rust-code-review` 技能流程）

首次执行完整检查，发现并修复 4 个 clippy error：

| 问题 | 位置 | 处理 |
| --- | --- | --- |
| `not_unsafe_ptr_arg_deref` × 2 | `probe.rs` 的 `guo_eval`/`guo_free` 接收裸指针却未标 `unsafe` | **删除整个 probe 模块**（POC 已被 FRB 取代，无任何调用方） |
| `manual char comparison` | `target.rs` | `clippy --fix` |
| `new_without_default` | `MaoguoSource` | 补 `Default` |
| 列后置定义 | 多个文件 | 整理 |

最终 `cargo clippy --all-targets -- -D warnings` **零告警**。

### C-UNWRAP 违规修复

`api::build_env` 中：

```rust
HttpTransport::new(DEFAULT_USER_AGENT)
    .unwrap_or_else(|_| HttpTransport::new("guo-engine").expect("fallback transport"))
```

这是公开 API 路径上的 `expect`，触发 Rust API Guidelines 的 **C-UNWRAP**。
改为返回 `Result<SourceEnv, String>` 并向上传播，三处调用同步处理 `?`。

### 架构重构：装饰器取代内联分支

**重构前**：引擎逻辑塞在 `NativeRepository` 内部

```dart
class NativeRepository extends AppRepository {
  final EngineRepository? engine;
  final EngineRoute? route;
  Future<CatalogPage> catalog(...) async {
    if (engineHandles(source)) { return engine!.catalog(...); }
    return CatalogPage.fromJson(await _read(...));
  }
}
```

问题：`NativeRepository` 同时知道 Go 与 Rust，两个职责耦合。

**重构后**：`EngineBackedRepository` 作为装饰器

```dart
class EngineBackedRepository extends AppRepository {
  final AppRepository delegate;   // Go 核心
  final EngineRepository engine;  // Rust 引擎
  final EngineRoute route;

  Future<CatalogPage> catalog(...) async {
    if (!handles(source)) return delegate.catalog(...);
    return engine.catalog(...);
  }
}
```

收益：
- `NativeRepository` 恢复单一职责（只做 Go 调用）；
- 引擎接入点集中在装配层（`main.dart::_buildRepository`）；
- 41 个接口方法逐一显式委托，漏掉会编译报错，不会静默走错后端。

### `access` 上提到接口

`access` 原先只在 `NativeRepository` 上，装饰器无法泛化。
已提升到 `AppRepository` 抽象成员，`NativeRepository` 用 getter/setter 实现，
装饰器直接转发。

### 验证

| 项 | 结果 |
| --- | --- |
| `cargo clippy -D warnings` | ✅ 零告警 |
| 引擎测试 | ✅ 61 项 |
| Dart 引擎测试 | ✅ 16 项 |
| macOS 构建（`ENGINE_ROUTE=all`） | ✅ 成功 |
| App 运行 | ✅ 启动无崩溃、无回退提示 |

## 第八轮：取流接管与稳定性

### 媒体解析模块（`src/media.rs`）

新增纯函数解析层，10 项单测覆盖：

| 能力 | 覆盖 |
| --- | --- |
| M3U8 主列表 | `#EXT-X-STREAM-INF` 变体识别 |
| M3U8 媒体列表 | 分片、`#EXT-X-KEY`、累计时长 |
| BOM 处理 | `\u{feff}` 前缀剥离 |
| 播放页提取 | `player_aaaa` 变量 / `<video>` / `<source>` / 内嵌地址 |
| 地址补全 | 相对、根相对、协议相对、无路径四种形态 |

### 取流链路接管（`RuleSource::resolve`）

之前只是透传地址，现在是完整链路：

```text
直链 → 若 .m3u8 则拉列表并校验 → 返回分片
播放页 → 抓页面 → 提取媒体地址 → 同上
主列表 → 自动跟进第一个变体
```

校验失败会明确报「站点未返回有效 M3U8」，不再把无效地址交给播放器。

### HTTP 客户端单例（按 `rust-http-client` 技能）

发现 `build_env` **每次请求都新建 `reqwest::Client`**，连接池、TLS 会话、DNS 缓存全部失效。
改为进程级 `OnceLock` 单例（`HttpTransport::global()`）。

### 并发争用修复

Dart 侧并发跑取流测试时，猫果偶发失败；串行则通过。
根因是七猫接口对并发请求敏感。

处理：`MaoguoSource` 增加一次重试，重试前**刷新会话时间戳**（因此 `qm-params` 与授权签名都会重新生成），间隔 120ms。
修复后并发执行 3 项全部通过。

### 真实站点实测

| 站源 | 结果 |
| --- | --- |
| 猫果 | ✅ 取流成功，返回真实 CDN 地址 |
| 伍果 | ⚠️ 分集 m3u8 本身已 404（源站数据过期，非引擎问题） |
| 花果 | ❌ 详情页 403（目录页 200） |

花果详情页的 403 用 `wreq` Chrome131 指纹同样被拒，说明是站点主动拒绝而非 CF 挑战，引擎侧无法绕过。

### 验证

| 项 | 结果 |
| --- | --- |
| 引擎测试 | ✅ **77 项** |
| Dart 引擎测试 | ✅ **28 项** |
| `cargo clippy -D warnings` | ✅ 零告警 |
| `dart analyze lib/` | ✅ 零 error/warning |

## 第九轮：下载引擎与加密 HLS

### 下载核心（`src/download.rs`）

| 能力 | 实现 |
| --- | --- |
| 断点续传 | `Range` 请求 + `If-Range` 校验 + `.part`/`.json` 元数据 |
| 服务器忽略 Range | 检测 200 响应，整段重写而非污染文件 |
| 数据变化 | 416/412 返回 `Restart`，丢弃中间文件 |
| HLS 分片 | 顺序下载并拼接，中断可续 |
| 提交 | 原子 rename，清理元数据 |

### 下载调度（`src/scheduler.rs`）

- 有界并发：`Semaphore` 限制 1–6，默认 2；
- 状态机：`Queued/Running/Completed/Failed/Paused`；
- 每态变更递增 `revision`，供上层做乐观并发控制；
- 控制命令：pause / resume / retry / delete。

### AES-128 解密（关键突破）

**猫果的 HLS 使用 AES-128 加密**，此前下载的分片是密文，无法播放。

实现 `decrypt_segment()`：
- `cbc::Decryptor<aes::Aes128>` + PKCS#7 填充；
- 支持播放列表显式 `IV=0x...`，缺省时按规范用分片序号（大端）；
- 用 NIST SP 800-38A 的密钥/IV 做加解密往返验证。

### 修掉的两个真实缺陷

**1. 二进制响应被 UTF-8 破坏**

`FetchResponse.body` 原本是 `String`，传输层用 `response.text()` 解码。
媒体二进制经 UTF-8 转换后出现替换字符（`ef bf bd`），文件必然损坏。

改为 `Vec<u8>`，文本调用方按需 `text()` 解码。

**2. HLS 判断只看后缀**

猫果的 CDN 地址不带 `.m3u8` 却返回 HLS 内容。
改为**先探测内容**（`parse_playlist` 是否有效），后缀仅作辅助判断。

### 端到端验证

```
resolve: segments=62, key_uri=有, key_iv=有
download: 62 个分片 → 10,581,956 字节
首字节: 0x47（MPEG-TS 同步字节）
ffprobe: h264 视频 + aac 音频
```

Dart 侧同样验证通过（`test/engine_hls_download_test.dart`）。

### 关于容器格式

HLS 分片拼接后是 **MPEG-TS**，不是 MP4。
播放器可直接播放 TS；若需 MP4 需 FFmpeg 转封装（主项目已有 FFmpegKit）。

### 验证

| 项 | 结果 |
| --- | --- |
| 引擎测试 | ✅ **102 项** |
| Dart 引擎测试 | ✅ **39 项** |
| `cargo clippy -D warnings` | ✅ 零告警 |
| `dart analyze lib/` | ✅ 零 error/warning |

## 第十轮：目录缓存

### 缓存核心（`src/cache.rs`）

| 能力 | 实现 |
| --- | --- |
| 键格式 | `source` 或 `source\|category` |
| TTL | 15 分钟（与 Go 一致） |
| 落盘 | `catalogs.json`，先写临时文件再 rename |
| 上限 | 32 MiB，超限拒绝写入而非截断 |
| 版本 | `version: 1`，不匹配直接丢弃 |

### 合并语义（对齐 Go）

- **第 1 页**：新数据在前，旧数据中未被刷新过的条目追加在后；
- **后续页**：按 ID 合并，保持旧顺序；
- **分类键**：写入后同时汇总到基础源，避免「全部」看不到分类内容；
- **失败页**：保留旧游标，不用失败结果覆盖进度。

### 实测效果

```
首次读取（联网）:  items=24  elapsed=1.90s
缓存读取:          items=24  elapsed=16.5µs   ← 快约 11.5 万倍
落盘:              11,325 字节
分类汇总:          base items=24
```

### 修掉的缺陷

`replace_first_page` 初版把「保留旧条目」的判断写成了与 `merge` 共用，
导致同 ID 条目被重复计入。修正后：新数据在前，已刷新 ID 不再从旧数据追加。

### 接入路径

```dart
// 启动时指定缓存目录（应用数据目录下）
await engine.setCacheDirectory('${support.path}/engine');

// 读取缓存
final page = await repository.cached('wuguo', category: '1');
```

装饰器在引擎缓存为空时回落到 Go，避免切换瞬间出现空列表。

### 验证

| 项 | 结果 |
| --- | --- |
| 引擎测试 | ✅ **113 项** |
| Dart 引擎测试 | ✅ **44 项** |
| `cargo clippy -D warnings` | ✅ 零告警 |

## 第十一轮：接口站源声明式化

停滞原因：规则引擎只能表达「CSS 选择器 + GET」，而 20 个站源里 6 个是接口 / 内嵌 JSON，
只能逐源写 Rust 插件，迁移卡在 3/20。本轮把声明式层补足到能表达接口站源，
新增饭果、星果、观果、河果四个源，全部是数据而非代码。

### 规则层新增的表达力

| 需求 | 规则写法 |
| --- | --- |
| 同一接口按分类切换 | `urls[].when` = `category` / `keyword` / `default` |
| POST + JSON 请求体 | `request.body` + `{"$int": "{page}"}` 输出数字而非字符串 |
| 时间戳签名参数 | `{ts10}`、`{md5:…}` token（观果 `clientInfo`） |
| 复合主键 | `idTemplate` + `idSplit`（饭果 `{id}#{source}`、星果 `{id}@{introduction}`） |
| 分集地址藏在任意层级 | `recurse: true` |
| 多清晰度取高 | `best: { paths, url, rank }` |
| 播放量 / 完结状态换算 | `divide` / `divideFrom` / `highSuffix` / `releaseStatus.total+current` |
| 分集页面延迟取流 | `pageUrlTemplate` + `{chapterId}` |

### 修掉的真实缺陷

1. **`__NEXT_DATA__` 提取器取不到内容**：旧实现把右尖括号的搜索范围放在标记**之前**，
   但标记本身写在 `<script id="__NEXT_DATA__" type="application/json">` 的属性里，
   `>` 只出现在标记之后 → 改为从标记向后定位 `</script>` 再取第一个 `>`。
2. **请求体里的中文关键词被百分号编码**：`{keyword}` 原先无条件走 URL 编码，
   河果的 POST JSON 体里出现 `"keyword":"%E6%B2%B3%E9%A9%AC"` →
   拆成 `render`（URL，编码）与 `render_json`（请求体，原样 UTF-8）。
3. **`{chapterId}` 缺失时拼出坏地址**：分集 id 取不到时直接返回空串，交回递归查找。

### 与 Go 行为对齐的点

饭果缺省分类「都市」、星果固定鉴权参数、观果 `okhttp/5.1.0` UA + 30 条分页 +
空详情文案、河果 `__NEXT_DATA__` 整份文档作根（故路径为 `props.pageProps.*`）、
分集按集数去重、缺集数时回退「第 N 集」、`referer = {base}/`。

### 分类清单接入

`fetch_categories(sourceId)` 返回的**首项固定为「全部」**，与 Go 侧一致；
站源未声明 `categories`（观果、猫果）时报错，装饰器捕获后回退 Go 核心，
因此这一项不产生功能缺失。

### 规则编写陷阱

`kind` 为 `json` / `next` 时，若显式写 `fields` 块则**必须给 `id`**：
serde 默认值是 CSS 写法 `a@href`，会被加载期校验直接拒绝。
整块省略 `fields` 是安全的（默认 id 列表为空）。

### 验证

| 项 | 结果 |
| --- | --- |
| 引擎测试 | ✅ **156 项**（113 单测 + 43 集成） |
| `cargo clippy --all-targets -D warnings` | ✅ 零告警（本轮修掉 6 项新引入的告警） |
| `dart analyze`（引擎 Dart 层） | ✅ 零问题 |
| 四个新增站源的真实站点请求 | ⬜ 未执行，属开发快照 |
