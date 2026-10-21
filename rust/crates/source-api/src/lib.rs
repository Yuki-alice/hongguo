//! 站源插件契约。
//!
//! 这个 crate 只放**数据与契约**：数据模型、能力位、错误类型、请求/响应结构、
//! `SourcePlugin` trait，以及一个纯计算的 MD5 原语（规则模板与站源签名共用）。
//! 它刻意不依赖 `tokio` / `reqwest` / `wasmtime`，以便被插件、规则引擎与宿主
//! 三方同时引用而不引入运行时耦合（见 ARCHITECTURE.md §6.3）。

mod env;
mod error;
mod md5;
mod model;
mod plugin;
mod request;
mod sha256;

pub use env::{preview, LogSink, ScriptHost, SourceEnv, SourceStore, Transport};
pub use error::SourceError;
pub use md5::{md5_hash, md5_hex};
pub use model::{
    Category, Chapter, Danmaku, DanmakuPage, Detail, Drama, Media, Page, RankingBoard, RankingItem,
    RankingPage, RecommendCursor, RecommendPage, SeriesSeason, Suggestion,
};
pub use plugin::{Capability, SourceMeta, SourcePlugin, SourceRegistry, CURRENT_API_LEVEL};
pub use request::{FetchRequest, FetchResponse, HeaderMap, Method, RequestPriority};
pub use sha256::{sha256_bytes, sha256_hex};
