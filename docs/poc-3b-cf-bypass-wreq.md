# POC-3 补充：黄果视频的真实 CF 拦截与 wreq 验证

日期：2026-10-18
结论：**Rust 侧有可用的 TLS 指纹方案**

## 实测矩阵

| 目标 | 普通 HTTP（curl） | wreq Chrome131 | wreq Safari17 |
| --- | --- | --- | --- |
| `ptt.red/p/66/c/67` | ✅ 200 | — | — |
| `huangguoai.com` | ✅ 200（145 KB） | — | — |
| `huangguo.video` | ❌ **403 `Attention Required!`** | ✅ **200（129 KB）** | ✅ 200（129 KB） |

## 关键结论

1. **皮果不需要指纹**：README 的「Cloudflare 拦截」是路径错误导致的误判，见 `poc-3-tls-fingerprint.md`。
2. **黄果视频确实需要指纹**：403 是真正的 CF 拦截，换 UA 无效。
3. **`wreq` 能过**：Chrome131 / Safari17 两种指纹均返回 200。

## 风险

`wreq` 当前版本是 **`6.0.0-rc.31`**，不是稳定版；`rquest` 已标记 deprecated。
这是 Rust 方案唯一的生态风险点，需要：

- 锁定具体版本，避免自动升级；
- 在 `Cargo.lock` 中固定；
- 准备降级路径：若 `wreq` 失效，黄果视频改用 WebView 取 `cf_clearance`，或暂时停用该源。

## 依赖体积

`wreq` + `btls` + `tokio-btls` 引入了 BoringSSL 绑定，构建时间约 85 秒（冷启动）。
需在 POC 后续关注最终二进制体积增量。

## 对方案的意义

Rust 路线在「TLS 指纹」这一唯一硬需求上有可用方案（虽为 rc 版本），
因此不再构成选用 Go 的决定性理由。
