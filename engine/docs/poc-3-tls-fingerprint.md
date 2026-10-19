# POC-3：TLS 指纹 / WebView 需求验证

日期：2026-10-18
结论：**不需要 TLS 指纹，也不需要 WebView**

## 背景

主项目 README 声称：

> 皮果（全站源版）| 网页目录与详情；`ptt.red` 由 Cloudflare 校验拦截，当前 HTTP 方式无法通过

Go 核心为此引入了 `tls-client`（utls 指纹），并在 `duanjuProviderCatalog` 中给皮果标记 `Browser: true`。
这是「必须保留 Go」的唯一实质性论据。

## 实测结果

| 测试 | 结果 |
| --- | --- |
| `curl https://ptt.red/` | HTTP 200，51 KB，141 链接，123 段中文 |
| 更换 UA（curl / iPhone Safari） | 均 200，无差异 |
| `/p/66/c/67`（Go 代码中的真实目录路径） | **HTTP 200，52 KB，146 链接，147 段中文** |
| `/q/韩剧?page=1`（搜索） | HTTP 200，28 KB |
| `/p/66/c/67?year=&page=2`（分页） | HTTP 200，52 KB |

页面中的 `challenge-platform` 字符串只是 Cloudflare 注入的常规脚本引用，不是拦截页。

## 真实原因

`ptt.red` 是 Vue 动态渲染站，首页 HTML 不含剧集列表。正确入口是分类路径 `/p/66/c/{category}`，
现有 Go 代码已经知道这个路径（`provider_duanju_maccms.go:288`），但 README 把「路径没找对」
误记成了「Cloudflare 拦截」。

## 对方案的意义

- **`tls-client` / `wreq` 不再是必需依赖**，`reqwest` 即可覆盖皮果。
- 主项目为「唯一需要指纹的源」保留整套 Go 网络栈，前提不成立。
- 黄果视频 / 黄果 AI 是否也需要指纹，需单独验证；但在「12 个新增短剧站源」范围内，
  结论明确：**没有指纹需求**。

## 待补验

- 黄果视频 `huangguo.video`、黄果 AI `huangguoai.com` 的实际拦截情况（这两个不在 12 源范围内）。
