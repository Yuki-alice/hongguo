//! 进程级引擎：单例装配、会话存储、取消、进度事件与诊断。
//!
//! 桥接层（`guo_engine`）只负责把 Dart 数据结构换成这里的类型，并把
//! `EngineError` 交给 FRB；站点解析仍由 `source-*` crate 与插件承担。
//!
//! 依赖方向：`engine` → `runtime` / `host` / `plugin-*` / `source-api`。
//! 它**不**依赖任何具体站源 crate —— 哪些源编译进二进制由桥接层注入，
//! 这样「主源 + 随包规则 + 插件」的边界只在一个地方定义。

mod bundled;
mod cancel;
mod cover;
mod engine;
mod error;
mod events;
mod gate;
mod migrate;
mod settings;
mod store;

pub use bundled::{
    bundled_root, preinstall, preinstall_or_report, BundledPackage, PreinstallReport, BUNDLED_REPO,
};
pub use cancel::{CancellationRegistry, RequestTicket};
pub use cover::{CoverCache, CoverResult};
pub use engine::{current, initialize, require, BuiltinSources, Engine, EngineConfig};
pub use engine::pump_downloads;
pub use error::{timeout_error, EngineError, EngineErrorKind};
pub use events::{DownloadEvent, EventBus};
pub use gate::RequestGate;
pub use migrate::{import_legacy_index, legacy_index_path, MigrationReport};
pub use settings::{
    ResourceSettings, SettingsStore, CATALOG_CONCURRENCY_RANGE, CATALOG_INTERVAL_MAX_MS,
    DOWNLOAD_CONCURRENCY_RANGE,
};
pub use store::{DiskSourceStore, NamespacedStore};

#[cfg(test)]
pub use engine::open_for_test;
