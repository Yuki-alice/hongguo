//! FRB 边界的失败契约。
//!
//! `guo_engine_core::EngineError` 住在另一个 crate，FRB 会把外部类型当作不透明句柄，
//! Dart 侧就读不到字段。这里显式定义一个扁平 DTO：字段全部是可序列化的基本类型，
//! Dart 侧因此得到普通数据类，可以按 `kind` 分派重试 / 冷却 / 换源。
//!
//! 这也让线协议与内部表示解耦：内部错误结构变化不会悄悄改变 Dart 侧的类型。

use guo_engine_core::EngineError;

/// 失败类别（与 `guo_engine_core::EngineErrorKind::as_str` 一一对应）。
pub mod kind {
    pub const UNSUPPORTED: &str = "unsupported";
    pub const NETWORK: &str = "network";
    pub const TIMEOUT: &str = "timeout";
    pub const HTTP: &str = "http";
    pub const PARSE_CHANGED: &str = "parse_changed";
    pub const SESSION: &str = "session";
    pub const BLOCKED: &str = "blocked";
    pub const CANCELLED: &str = "cancelled";
    pub const STORAGE: &str = "storage";
    pub const PLUGIN: &str = "plugin";
    pub const INTERNAL: &str = "internal";
}

/// Dart 可见的引擎错误。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EngineFailure {
    /// `unsupported` / `network` / `timeout` / `http` / `parse_changed` /
    /// `session` / `blocked` / `cancelled` / `storage` / `plugin` / `internal`。
    pub kind: String,
    pub message: String,
    pub source_id: String,
    pub request_id: String,
    pub retryable: bool,
    /// HTTP 状态码；非 HTTP 错误为 0。
    pub http_status: u32,
    /// 风控解除时间（Unix 毫秒）；仅 `blocked` 有意义。
    pub retry_at_ms: u64,
}

impl std::fmt::Display for EngineFailure {
    fn fmt(&self, out: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(out, "{}", self.message)
    }
}

impl From<EngineError> for EngineFailure {
    fn from(error: EngineError) -> Self {
        Self {
            kind: error.kind.as_str().to_string(),
            message: error.message,
            source_id: error.source_id,
            request_id: error.request_id,
            retryable: error.retryable,
            http_status: error.http_status as u32,
            retry_at_ms: error.retry_at_ms,
        }
    }
}

/// 把内部错误转成边界 DTO。所有 FRB 函数统一走这里。
///
/// 只供 Rust 侧调用；Dart 通过各 API 的返回类型拿到 `EngineFailure`，
/// 不需要直接构造它。
#[flutter_rust_bridge::frb(ignore)]
pub fn failure(error: EngineError) -> EngineFailure {
    EngineFailure::from(error)
}

#[cfg(test)]
mod tests {
    use super::*;
    use guo_engine_core::{EngineError, EngineErrorKind};

    #[test]
    fn kinds_are_stable_strings() {
        let failure = EngineFailure::from(EngineError::unsupported("弹幕"));
        assert_eq!(failure.kind, kind::UNSUPPORTED);
        assert!(!failure.retryable);
        assert_eq!(failure.http_status, 0);
    }

    #[test]
    fn request_id_and_status_survive_the_boundary() {
        let error = EngineError::new(EngineErrorKind::Http, "boom")
            .with_source("wuguo")
            .with_request_id("req-7")
            .with_status(503);
        let failure = EngineFailure::from(error);
        assert_eq!(failure.source_id, "wuguo");
        assert_eq!(failure.request_id, "req-7");
        assert_eq!(failure.http_status, 503);
        assert!(failure.retryable);
    }
}
