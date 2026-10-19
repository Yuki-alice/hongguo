//! 真果鉴本地引擎。
//!
//! 对外只暴露两类入口：
//! - [`api`]：`flutter_rust_bridge` 生成的 Dart 绑定调用点；
//! - 站源契约（[`SourcePlugin`]）、数据模型（[`Drama`] 等）与错误（[`SourceError`]）。
//!
//! 内部实现模块保持私有，在根级做定向重导出，避免「扁平的 lib.rs + 通配重导出」反模式。

pub mod api;

/// P0 体积探针：仅用于测量链接 wasmtime 后的产物大小。
mod cache;
mod crypto;
mod download;
mod env;
mod media;
mod rule;
mod scheduler;
mod script;
mod source;
mod sources;
mod transport;

pub use cache::{catalog_key, merge, replace_first_page, CatalogCache, CatalogDisk, CatalogState};
pub use download::{
    commit, discard, download_file, download_hls, playlist_signature, DownloadOutcome, FileState,
    HlsKey,
};
pub use env::{
    FetchRequest, FetchResponse, LogSink, Method, RequestPriority, ScriptHost, SourceEnv,
    SourceStore, Transport,
};
pub use guo_source_api::SourceError;
pub use guo_source_api::{Category, Chapter, Detail, Drama, Media, Page};
pub use media::{extract_media_url, parse_playlist, Playlist};
pub use rule::{RuleDocument, RuleExecutor, TemplateCtx};
pub use scheduler::{Job, JobState, Scheduler};
pub use script::QuickJsHost;
pub use source::{Capability, SourceMeta, SourcePlugin, SourceRegistry, CURRENT_API_LEVEL};
pub use sources::{builtin_registry, MaoguoSource, RuleSource};
pub use transport::{HttpTransport, DEFAULT_USER_AGENT};

mod frb_generated; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */
