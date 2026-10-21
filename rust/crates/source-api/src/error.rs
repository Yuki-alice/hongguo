use std::fmt;
use std::time::{Duration, SystemTime};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SourceError {
    Unsupported(&'static str),
    EmptyRequest(&'static str),
    Network { url: String, detail: String },
    Http { url: String, status: u16 },
    Parse { field: &'static str, detail: String },
    NoResult,
    Blocked { until: SystemTime },
    Rule { rule_id: String, detail: String },
    Script { source: String, detail: String },
}

impl SourceError {
    pub fn network(url: impl Into<String>, detail: impl fmt::Display) -> Self {
        Self::Network {
            url: url.into(),
            detail: detail.to_string(),
        }
    }

    pub fn http(url: impl Into<String>, status: u16) -> Self {
        Self::Http {
            url: url.into(),
            status,
        }
    }

    pub fn parse(field: &'static str, detail: impl fmt::Display) -> Self {
        Self::Parse {
            field,
            detail: detail.to_string(),
        }
    }

    pub fn blocked_for(duration: Duration) -> Self {
        Self::Blocked {
            until: SystemTime::now() + duration,
        }
    }

    pub fn is_retryable(&self) -> bool {
        match self {
            Self::Network { .. } => true,
            Self::Http { status, .. } => *status >= 500,
            _ => false,
        }
    }

    pub fn http_status(&self) -> Option<u16> {
        match self {
            Self::Http { status, .. } => Some(*status),
            _ => None,
        }
    }
}

impl fmt::Display for SourceError {
    fn fmt(&self, out: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unsupported(what) => write!(out, "不支持的操作：{what}"),
            Self::EmptyRequest(what) => write!(out, "请求缺少必要参数：{what}"),
            Self::Network { url, detail } => write!(out, "网络请求失败（{url}）：{detail}"),
            Self::Http { url, status } => write!(out, "站源返回 HTTP {status}（{url}）"),
            Self::Parse { field, detail } => write!(out, "解析失败（{field}）：{detail}"),
            Self::NoResult => write!(out, "站源没有返回有效内容"),
            Self::Blocked { until } => {
                let secs = until
                    .duration_since(SystemTime::now())
                    .map(|d| d.as_secs())
                    .unwrap_or(0);
                write!(out, "站源暂时拦截，请 {secs} 秒后重试")
            }
            Self::Rule { rule_id, detail } => write!(out, "规则 {rule_id} 执行失败：{detail}"),
            Self::Script { source, detail } => write!(out, "脚本 {source} 执行失败：{detail}"),
        }
    }
}

impl std::error::Error for SourceError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn http_errors_expose_status_for_matching() {
        let err = SourceError::http("https://example.test/x", 404);
        assert_eq!(err.http_status(), Some(404));
        assert!(!err.is_retryable());
    }

    #[test]
    fn server_errors_are_retryable() {
        assert!(SourceError::http("https://example.test/x", 503).is_retryable());
        assert!(SourceError::network("https://example.test/x", "timeout").is_retryable());
    }

    #[test]
    fn blocked_errors_render_remaining_seconds() {
        let err = SourceError::blocked_for(Duration::from_secs(90));
        let text = err.to_string();
        assert!(text.contains("拦截"), "{text}");
    }
}
