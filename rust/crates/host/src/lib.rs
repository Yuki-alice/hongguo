//! 宿主能力实现。
//!
//! `guo-source-api` 只声明 trait；这里给出设备端可用的实现：
//! - [`transport`]：`reqwest` 传输层（连接池、超时、流式截断）；
//! - [`script`]：QuickJS 沙箱，供签名脚本使用；
//! - [`js_host`]：脚本型站源宿主，把 `main.js` 变成可调用的站源。
//!
//! 限流、冷却、Cookie 与落盘存储按 ARCHITECTURE.md §10.2 在 P1 补入。

mod js_host;
mod script;
mod transport;

pub use js_host::{JsPluginHost, ScriptLimits};
pub use script::QuickJsHost;
pub use transport::{HttpTransport, DEFAULT_USER_AGENT};
