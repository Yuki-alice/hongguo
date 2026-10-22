//! 星本地引擎（Flutter 桥接层）。
//!
//! 对外只暴露两类入口：
//! - [`api`]：`flutter_rust_bridge` 生成的 Dart 绑定调用点；
//! - 站源契约（`SourcePlugin`）、数据模型（`Drama` 等）与错误（`SourceError`）的重导出，
//!   供集成测试与示例直接使用。
//!
//! 真正的实现分布在 `crates/` 下；引擎状态（注册表 / 会话 / 缓存 / 调度）
//! 由 `guo-engine` 的进程级单例持有（ARCHITECTURE.md §6.5、§10）。

pub mod api;

mod sources;

/// `flutter_rust_bridge` 生成的代码以 `crate::env::*` 引入站源契约类型。
/// 拆 crate 后这些类型住在 `guo-source-api`，这里保留一个窄别名，
/// 避免每次重新生成都要手工改生成物（`frb_generated.rs` 里只保留 `ioDirectory` 一处手改）。
#[allow(unused_imports)]
mod env {
    pub use guo_source_api::*;
}

mod frb_generated; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */

pub use sources::register_builtin_sources;

// 引擎运行时：单例、错误、取消、会话存储、进度事件
pub use guo_engine_core::{
    current, initialize, require, CancellationRegistry, DiskSourceStore, DownloadEvent, Engine,
    EngineConfig, EngineError, EngineErrorKind, EventBus, NamespacedStore, RequestTicket,
};

// 契约层：类型与 trait
pub use guo_source_api::{
    md5_hash, md5_hex, Capability, Category, Chapter, Detail, Drama, FetchRequest, FetchResponse,
    HeaderMap, LogSink, Media, Method, Page, RequestPriority, ScriptHost, SourceEnv, SourceError,
    SourceMeta, SourcePlugin, SourceRegistry, SourceStore, Transport, CURRENT_API_LEVEL,
};

// 宿主能力实现
pub use guo_host::{HttpTransport, QuickJsHost, DEFAULT_USER_AGENT};

// 声明式规则
pub use guo_rule_engine::{
    JsonRuleExecutor, RuleDocument, RuleExecutor, RuleFields, RuleKind, SelectorList, TemplateCtx,
};

// HLS / 媒体
pub use guo_media::{extract_media_url, parse_playlist, Playlist};

// 运行时装配
pub use guo_runtime::{
    catalog_key, commit, discard, download_file, download_hls, merge, playlist_signature,
    replace_first_page, CatalogCache, CatalogDisk, CatalogState, DownloadOutcome, FileState,
    HlsKey, Job, JobState, RuleSource, Scheduler,
};

// 内置代码源
pub use guo_source_hongguo::HongguoSource;
pub use guo_source_huangju::HuangjuSource;
pub use guo_source_maoguo::MaoguoSource;
pub use guo_source_niuguo::NiuguoSource;
pub use guo_source_yaguo::YaguoSource;

/// 测试与示例用的独立注册表（不触碰单例）。
///
/// 与 `Engine` 的装配逻辑保持一致，避免夹具与实际运行时漂移。
pub fn builtin_registry() -> SourceRegistry {
    api::debug_registry()
}
