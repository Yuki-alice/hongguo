# POC-1：rquickjs 在 iOS 上的可行性

日期：2026-10-18
结论：**通过**

## 验证内容

| 项 | 结果 |
| --- | --- |
| 主机侧编译 + 执行 | ✅ 3 个单元测试通过 |
| `aarch64-apple-ios` 交叉编译 | ✅ 21.6s，产物 `platform 2`（iOS）、`arm64` |
| 真实 iOS 二进制链接 | ✅ 1.1 MB（含 QuickJS C 源码） |
| iOS 模拟器运行时执行 | ✅ 4 个用例全部正确 |

## 执行的 JS 用例

```
test0: {"ok":true,"value":"X"}         // 字符串方法
test1: {"ok":true,"value":"6"}         // 数组 reduce
test2: {"ok":true,"value":"ok"}        // class
test3: {"ok":true,"value":"17862"}     // 位运算循环（签名计算基础）
```

## 关键实现细节

- 依赖：`rquickjs = "0.9"`，features `["bindgen", "loader"]`
- 静态库大小 19 MB 是**未 strip + 含 bitcode** 的假象；链接进可执行文件并 `-dead_strip` 后仅 1.1 MB
- 模拟器目标需覆盖 bindgen 的 triple：
  `BINDGEN_EXTRA_CLANG_ARGS_aarch64_apple_ios_sim="-isysroot $SDK -target arm64-apple-ios15.1-simulator"`
  否则报 `version 'sim' in target triple 'aarch64-apple-ios-sim' is invalid`
- 导出的 C ABI：`guo_eval` / `guo_free`，字符串所有权由调用方持有

## 对方案的意义

12 个需要签名/加解密的站源可以落在脚本插件层，不必写死在 Rust 里。
Go 路线（`goja`）的等价能力不存在不可替代优势，POC-1 不再构成选用 Go 的理由。
