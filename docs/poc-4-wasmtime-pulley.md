# P0 探针：wasmtime + Pulley 三端可行性

日期：2026-10-19（测量）· 2026-10-20（决策）
结论：**技术可行；体积超出软预算，已决定采用 A（接受增量）**。
关联：`ARCHITECTURE.md` §9.3、决策 D1、D7（本轮新增）。

---

## 1. 验证环境

| 项 | 值 |
| --- | --- |
| 主机 | macOS / Apple Silicon |
| Rust | 1.97.1 |
| wasmtime | `=49.0.2`（本地缓存已存在，锁定该版本） |
| 特性 | `component-model, cranelift, runtime, pulley, std`（**不含 `async`**） |
| 目标 | `aarch64-apple-darwin`、`aarch64-apple-ios`、`aarch64-linux-android` |
| Android NDK | 28.2.13676358（`aarch64-linux-android26-clang`） |

关闭 `async` 是本轮的关键设计（`ARCHITECTURE.md` ADR-11）：它避免拉入 `wasmtime-fiber`，
而 fiber 的协程栈正是 wasmtime 在 iOS 上编译失败的源头。

---

## 2. 编译结果

| 目标 | 结果 | 说明 |
| --- | --- | --- |
| `aarch64-apple-darwin` | ✅ 2m16s | 宿主基线 |
| `aarch64-apple-ios` | ✅ 2m44s | **D1 的关键验证通过**，无需 patched wasmtime |
| `aarch64-linux-android` | ✅ 2m37s | 需显式提供 NDK clang / ar |

三个目标都是**首次冷编译**耗时，增量构建约 10–20 秒。

---

## 3. 体积（真实链接，非 rlib 估算）

测量方法：给 `guo-plugin-wasm` 临时加 `cdylib` 产物与 `#[no_mangle]` 入口，
让链接器无法把运行时裁掉；`release` 配置与桥接一致（`opt-level="z"`、`lto=true`、`codegen-units=1`）。

| 目标 | 空运行时不链接 wasmtime | 链接后 | 增量 |
| --- | --- | --- | --- |
| macOS（dylib） | 6.87 MiB | 8.90 MiB | **+2.03 MiB**（独立 cdylib） |
| iOS（dylib） | — | 8.82 MiB | **+8.8 MiB**（静态链接进主二进制） |
| Android arm64（.so） | — | 11.87 MiB | **+11.9 MiB** |

桥接层真实测量（同一份 `libguo_engine.dylib`）：

| 配置 | 体积 |
| --- | --- |
| 不含 wasmtime | 7,204,656 字节（6.87 MiB） |
| 含 wasmtime（真实调用点） | 18,182,768 字节（17.34 MiB） |
| **增量** | **10,978,112 字节 ≈ 10.47 MiB** |

> 只声明依赖而不调用时，LTO 会把整个 wasmtime 裁掉，体积只涨 64 字节——
> 这类「看起来没影响」的测量是无效的，必须保留真实调用点才能得到上表数字。

### 与预算对比

`ARCHITECTURE.md` §9.3 设的软上限：iOS 单架构 +8 MB、Android 每 ABI +6 MB。

| 平台 | 实测增量 | 软上限 | 结论 |
| --- | --- | --- | --- |
| iOS | 8.8 MiB（≈9.2 MB） | +8 MB | 超出约 15% |
| Android arm64 | 11.9 MiB（≈12.5 MB） | +6 MB | 超出约 108% |
| macOS | 2.03 MiB（独立 cdylib） | — | 可接受 |

APK 三 ABI 合计新增约 25–30 MB（arm64 12.5 + armv7 估 9 + x86_64 13），
安装包会从 136 MB（debug）继续增大。**这对 Android 是需要正视的成本。**

---

## 4. 冷启动

用最小组件（`\0asm` + 组件层头）测量：

```
engine=1.09ms compile=1.01ms instantiate=0.03ms
```

| 指标 | 实测 | 门槛 | 结论 |
| --- | --- | --- | --- |
| 引擎创建 | 1.09 ms | — | 可忽略 |
| 组件编译 | 1.01 ms | < 150 ms | ✅ 远低于门槛 |
| 实例化 | 0.03 ms | < 30 ms | ✅ |

注：真实的插件组件（几十 KB）编译会慢一些，但仍远低于门槛；
且 P1 计划把预编译产物（`.cwasm`）缓存到磁盘，二次启动可省去编译。

---

## 5. 未验证项

| 项 | 状态 | 说明 |
| --- | --- | --- |
| iOS 真机运行 | ⬜ | 只验证了交叉编译，未在设备上实例化 |
| 真实插件组件（带 import） | ⬜ | 本轮是空组件，未测 WIT 绑定生成的胶水开销 |
| 宿主能力注入（fetch / store） | ⬜ | P1 实现 |
| Pulley 下实际业务耗时 | ⬜ | 需要真实规则跑一遍才有数字 |
| 包体对最终 APK/IPA 的影响 | ⬜ | 需带 wasmtime 完整构建一次三端产物 |

---

## 6. 建议

体积超出预算，需要在 P1 开工前定夺三选一：

| 方案 | 做法 | 代价 |
| --- | --- | --- |
| **A. 接受现状** | 三端全量引入 wasmtime | Android 包体 +25–30 MB，iOS +9 MB |
| **B. 平台分层** | Android / Windows 用原生解析 + 少量签名脚本；iOS 用 Pulley | 两条路径，违背「一套代码」原则 |
| **C. 缩小运行时** | 只保留 `pulley`，去掉 `cranelift`；插件在构建期预编译成 Pulley 字节码 | 插件无法在设备上自行编译，必须由仓库分发预编译产物；需验证 `wasm-tools` 侧能否产出 Pulley 目标字节码 |

**倾向 C**：Pulley 解释器本身不需要 Cranelift 的代码生成后端——
Cranelift 只在「把 wasm 编译成目标字节码」时用到。
如果插件包直接分发 Pulley 字节码，设备端可以只要解释器，体积有望显著下降。
但这条路需要先验证 `wasmtime compile --target pulley64` 能在构建机产出可移植产物，
属于 P1 的前置实验，不建议现在拍板。

**在 C 验证失败前，按 A 推进**：先把能力做出来，包体问题在 P1 末用真实 APK 复测再优化。
理由是否决 B 会让 iOS 与其它平台长期分叉，而 C 的不确定性不应阻塞 P1 的插件宿主开发。

---

## 7. 复现命令

```sh
# 宿主
cargo build --release -p guo-plugin-wasm

# iOS（需 Xcode）
cargo build --release -p guo-plugin-wasm --target aarch64-apple-ios

# Android（需 NDK）
NDK=~/Library/Android/sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/darwin-x86_64
export PATH="$NDK/bin:$PATH"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER=$NDK/bin/aarch64-linux-android26-clang
export CC_aarch64_linux_android=$NDK/bin/aarch64-linux-android26-clang
export AR_aarch64_linux_android=$NDK/bin/llvm-ar
cargo build --release -p guo-plugin-wasm --target aarch64-linux-android

# 冷启动
cargo run --release -p guo-plugin-wasm --example measure
```


---

## 8. 决策结果（2026-10-20）：采用 A

**D7 已定：接受 wasmtime 的体积增量，不做平台分层、不做运行时裁剪。**

理由：

1. **一套代码的收益大于包体成本**。B（平台分层）会让 iOS 与其它平台长期分叉，
   插件行为在不同端不一致，后续每次改动都要三份验证；
2. **C 的不确定性太高**。它要求插件由仓库分发 Pulley 预编译字节码，
   等于把「插件作者必须配好工具链」升级成「插件作者必须用我们的构建管线」，
   与「社区可自行发布插件」的目标冲突；
3. **实测增量没有探针阶段担心的那么糟**（见下），且只在安装包含代码插件时才有意义。

### 决策后的复测（真实调用点，非空壳链接）

把 `guo-plugin-wasm` 真正接进 `guo_engine` 的注册表（`builtin_registry()` 会加载已安装的
代码插件）后重新测量。这一步很关键：只声明依赖不建立调用链时，LTO 会把整个运行时裁掉。

| 产物 | 不含 wasmtime | 含 wasmtime | 增量 |
| --- | --- | --- | --- |
| macOS `libguo_engine.dylib` | 8,315,984 B（7.93 MiB） | 20,872,096 B（19.91 MiB） | **+11.97 MiB** |
| iOS `libguo_engine.a`（staticlib） | 15,112,384 B（14.41 MiB） | 26,225,976 B（25.01 MiB） | **+10.60 MiB** |

对比探针阶段的 10.47 MiB / 9.2 MB：接上真实 `ComponentSource` 与 WIT 宿主胶水后，
增量比空壳测量**更大**，说明之前那组数字是偏乐观的估计。

### 已知的构建约束（不是本轮引入）

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `cargo build -p guo_engine --target aarch64-apple-ios`（动态库）链接失败：`___chkstk_darwin` 未定义 | 来自 `rquickjs_sys`（QuickJS），与本轮无关；iOS 实际只需要 `staticlib` | 用 `--crate-type staticlib` 构建；fluter 侧走的也是 staticlib |
| `cargo build --target aarch64-linux-android` 报 `'stdio.h' file not found` | `rquickjs-sys` 的 bindgen 需要 NDK sysroot，命令行交叉编译没带 | 走 `flutter build apk`（Gradle 提供完整 NDK 环境） |

### 后续触发条件

出现下列任一情况时重新评估（而不是现在就优化）：

- 安装包体积成为商店审核或用户投诉的实际问题；
- 代码插件在真实设备上的占比远低于预期（那就该考虑把插件改为可选下载模块）；
- wasmtime 上游提供 feature 级的运行时裁剪（届时 C 的成本会大幅下降）。
