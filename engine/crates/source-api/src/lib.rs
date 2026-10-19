//! 站源插件契约。
//!
//! 这个 crate 只放**数据与类型**：数据模型、能力位、错误类型。
//! 它刻意不依赖 `tokio` / `reqwest` / `wasmtime`，以便被插件、规则引擎与宿主
//! 三方同时引用而不引入运行时耦合（见 ARCHITECTURE.md §6.3）。

mod error;
mod model;

pub use error::SourceError;
pub use model::{Category, Chapter, Detail, Drama, Media, Page};
