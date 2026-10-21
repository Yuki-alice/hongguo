# 代码插件模板

一个最小但**可真实运行**的 WASM 代码插件：实现 `guo:source` 契约的
`describe / categories / catalog / fetch-detail / search / resolve / suggestions`。

## 构建

```bash
./build.sh
```

产物 `guo_plugin_template.component.wasm`（约 42 KiB）。

## 为什么必须两步编译

`wasm32-wasip2` 直接编译最省事，但 `wit-bindgen` 会连 `wasi:cli`、`wasi:io`、
`wasi:clocks` 一起导入；宿主的能力白名单只允许 `guo:source/*`，这样的组件会在
**安装期**被拒绝（不是运行时报错，这是刻意设计）。

因此标准路径是：

```bash
cargo build --target wasm32-unknown-unknown --release
wasm-tools component new target/wasm32-unknown-unknown/release/guo_plugin_template.wasm \
  -o guo_plugin_template.component.wasm
```

组件化后的导入集合只剩 `guo:source/types@1.0.0`，
`rust/crates/plugin-wasm/tests/component_host.rs` 会断言这一点。

## 打包

插件包是 zip，结构见 ARCHITECTURE.md §7.3：

```text
guo.template-0.1.0.zip
├── plugin.toml
└── plugin.wasm        # 即上面的 component 产物
```

`plugin.toml`：

```toml
spec = 1
id = "guo.template"
name = "模板站源"
version = "0.1.0"
kind = "component"
entry = "plugin.wasm"
api = { level = 1, min_host = "0.3.0" }

[permissions]
network = ["example.test"]
```

## 宿主内置的原语

插件不需要自己解析 HTML / JSON，宿主提供：

| 原语 | 用途 |
| --- | --- |
| `fetch` | 唯一的出网口，按 `permissions.network` 白名单 |
| `html-select` | CSS 选择器提取（ADR-12：解析留在宿主） |
| `json-path` | JSONPath 提取 |
| `store-get` / `store-set` | 命名空间隔离的键值存储 |
| `random` / `now-ms` | 签名所需的 nonce 与时间戳 |
| `log` | 写入宿主日志（`debug` / `warn`） |
