//! 引擎错误：Dart 与 Rust 之间唯一的失败契约。
//!
//! 取代 `Result<_, String>`：`kind` 决定 UI 的分级处理（重试 / 冷却 / 换源 / 隐藏），
//! `retryable` 与 `http_status` 让退避策略不必解析文案，`request_id` 让调用方能
//! 把错误与自己发出的请求对上号（ADR-8）。

use std::fmt;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use guo_source_api::SourceError;

/// 失败类别。新增类别时同步更新 Dart 侧 `EngineFailureKind` 的映射。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EngineErrorKind {
    /// 站源或引擎不支持该能力。UI 应隐藏入口，而不是提示重试。
    Unsupported,
    /// 传输层失败（DNS / TLS / 连接中断）。
    Network,
    /// 超时。
    Timeout,
    /// 站点返回了非 2xx。
    Http,
    /// 页面结构变化导致解析失败。
    ParseChanged,
    /// 登录 / 令牌 / Cookie 失效。
    Session,
    /// 站点限流或风控。
    Blocked,
    /// 调用方主动取消。
    Cancelled,
    /// 磁盘读写失败。
    Storage,
    /// 插件加载或执行失败。
    Plugin,
    /// 引擎内部缺陷。
    Internal,
}

impl EngineErrorKind {
    /// 稳定的字符串标识。Dart 侧按它分派，不要依赖 `Debug` 输出。
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Unsupported => "unsupported",
            Self::Network => "network",
            Self::Timeout => "timeout",
            Self::Http => "http",
            Self::ParseChanged => "parse_changed",
            Self::Session => "session",
            Self::Blocked => "blocked",
            Self::Cancelled => "cancelled",
            Self::Storage => "storage",
            Self::Plugin => "plugin",
            Self::Internal => "internal",
        }
    }
}

/// 引擎错误。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EngineError {
    pub kind: EngineErrorKind,
    /// 面向用户的中文说明。UI 可以直接展示，也可以按 `kind` 自行措辞。
    pub message: String,
    /// 出错站源；与站源无关时为空。
    pub source_id: String,
    /// 调用方传入的请求标识；未携带时为空。
    pub request_id: String,
    /// 是否值得原样重试。
    pub retryable: bool,
    /// HTTP 状态码；非 HTTP 错误为 0。
    pub http_status: u16,
    /// 风控解除时间（Unix 毫秒）；仅 `Blocked` 有意义，否则为 0。
    pub retry_at_ms: u64,
}

impl EngineError {
    pub fn new(kind: EngineErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
            source_id: String::new(),
            request_id: String::new(),
            retryable: matches!(
                kind,
                EngineErrorKind::Network | EngineErrorKind::Timeout | EngineErrorKind::Http
            ),
            http_status: 0,
            retry_at_ms: 0,
        }
    }

    pub fn unsupported(capability: impl Into<String>) -> Self {
        Self::new(
            EngineErrorKind::Unsupported,
            format!("不支持的操作：{}", capability.into()),
        )
    }

    pub fn cancelled(request_id: impl Into<String>) -> Self {
        Self::new(EngineErrorKind::Cancelled, "请求已取消").with_request_id(request_id)
    }

    pub fn internal(detail: impl fmt::Display) -> Self {
        Self::new(EngineErrorKind::Internal, detail.to_string())
    }

    pub fn storage(detail: impl fmt::Display) -> Self {
        Self::new(EngineErrorKind::Storage, detail.to_string())
    }

    pub fn with_source(mut self, source_id: impl Into<String>) -> Self {
        self.source_id = source_id.into();
        self
    }

    pub fn with_request_id(mut self, request_id: impl Into<String>) -> Self {
        self.request_id = request_id.into();
        self
    }

    pub fn with_status(mut self, status: u16) -> Self {
        self.http_status = status;
        self
    }

    /// 把站源层的错误映射为引擎错误。
    ///
    /// 映射保持「可重试性」不变：站源认为可重试的，引擎也认为可重试。
    pub fn from_source(error: &SourceError, source_id: &str, request_id: &str) -> Self {
        let kind = match error {
            SourceError::Unsupported(_) => EngineErrorKind::Unsupported,
            SourceError::EmptyRequest(_) => EngineErrorKind::Internal,
            SourceError::Network { .. } => EngineErrorKind::Network,
            SourceError::Http { .. } => EngineErrorKind::Http,
            SourceError::Parse { .. } => EngineErrorKind::ParseChanged,
            SourceError::NoResult => EngineErrorKind::ParseChanged,
            SourceError::Blocked { .. } => EngineErrorKind::Blocked,
            SourceError::Rule { .. } => EngineErrorKind::ParseChanged,
            SourceError::Script { .. } => EngineErrorKind::Plugin,
        };
        let retry_at_ms = match error {
            SourceError::Blocked { until } => unix_millis(*until),
            _ => 0,
        };
        Self {
            kind,
            message: error.to_string(),
            source_id: source_id.to_string(),
            request_id: request_id.to_string(),
            retryable: error.is_retryable(),
            http_status: error.http_status().unwrap_or(0),
            retry_at_ms,
        }
    }
}

fn unix_millis(time: SystemTime) -> u64 {
    time.duration_since(UNIX_EPOCH)
        .map(|value| value.as_millis() as u64)
        .unwrap_or(0)
}

impl fmt::Display for EngineError {
    fn fmt(&self, out: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(out, "{}", self.message)
    }
}

impl std::error::Error for EngineError {}

impl From<SourceError> for EngineError {
    fn from(error: SourceError) -> Self {
        Self::from_source(&error, "", "")
    }
}

impl From<&SourceError> for EngineError {
    fn from(error: &SourceError) -> Self {
        Self::from_source(error, "", "")
    }
}

impl From<EngineError> for String {
    fn from(error: EngineError) -> Self {
        error.message
    }
}

/// 把超时转成 `Timeout`，其它传输错误保持原类别。
pub fn timeout_error(request_id: &str, after: Duration) -> EngineError {
    EngineError::new(
        EngineErrorKind::Timeout,
        format!("请求超过 {} 秒未完成", after.as_secs()),
    )
    .with_request_id(request_id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kinds_have_stable_wire_names() {
        assert_eq!(EngineErrorKind::ParseChanged.as_str(), "parse_changed");
        assert_eq!(EngineErrorKind::Unsupported.as_str(), "unsupported");
    }

    #[test]
    fn source_errors_keep_retryability_and_status() {
        let retryable =
            EngineError::from_source(&SourceError::http("https://a.test", 503), "wuguo", "req-1");
        assert_eq!(retryable.kind, EngineErrorKind::Http);
        assert_eq!(retryable.http_status, 503);
        assert!(retryable.retryable);
        assert_eq!(retryable.source_id, "wuguo");
        assert_eq!(retryable.request_id, "req-1");

        let fatal =
            EngineError::from_source(&SourceError::http("https://a.test", 404), "wuguo", "");
        assert!(!fatal.retryable);
    }

    #[test]
    fn unsupported_is_never_retryable() {
        let error = EngineError::unsupported("弹幕");
        assert_eq!(error.kind, EngineErrorKind::Unsupported);
        assert!(!error.retryable);
        assert!(error.message.contains("弹幕"));
    }

    #[test]
    fn blocked_carries_retry_at() {
        let error = EngineError::from_source(
            &SourceError::blocked_for(Duration::from_secs(60)),
            "faguo",
            "",
        );
        assert_eq!(error.kind, EngineErrorKind::Blocked);
        assert!(error.retry_at_ms > 0);
        assert!(!error.retryable);
    }
}
