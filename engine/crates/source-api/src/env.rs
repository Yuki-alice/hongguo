//! 站源执行环境：宿主注入的能力白名单。
//!
//! 只声明 trait 与持有 `Arc<dyn …>`，具体实现由 `guo-host` 提供。

use std::sync::Arc;

use crate::error::SourceError;
use crate::model::Drama;
use crate::request::{FetchRequest, FetchResponse};

#[async_trait::async_trait]
pub trait Transport: Send + Sync {
    async fn fetch(&self, request: FetchRequest) -> Result<FetchResponse, SourceError>;
}

#[async_trait::async_trait]
pub trait SourceStore: Send + Sync {
    async fn get(&self, key: &str) -> Result<Option<String>, SourceError>;
    async fn set(&self, key: &str, value: &str) -> Result<(), SourceError>;
}

#[async_trait::async_trait]
pub trait ScriptHost: Send + Sync {
    async fn eval(&self, script: &str, input: &str) -> Result<String, SourceError>;
}

pub trait LogSink: Send + Sync {
    fn debug(&self, message: &str);
    fn warn(&self, message: &str);
}

#[derive(Clone)]
pub struct SourceEnv {
    pub source_id: String,
    pub transport: Arc<dyn Transport>,
    pub store: Arc<dyn SourceStore>,
    pub scripts: Option<Arc<dyn ScriptHost>>,
    pub log: Arc<dyn LogSink>,
}

impl SourceEnv {
    pub fn is_same_source(&self, drama: &Drama) -> bool {
        drama.source == self.source_id
    }

    pub async fn text(&self, request: FetchRequest) -> Result<String, SourceError> {
        let response = self.transport.fetch(request).await?;
        response.ensure_success()?;
        Ok(response.text())
    }

    pub async fn json(&self, request: FetchRequest) -> Result<serde_json::Value, SourceError> {
        let body = self.text(request).await?;
        serde_json::from_str(&body)
            .map_err(|err| SourceError::parse("json", format!("{err}: {}", preview(&body))))
    }
}

/// 截取响应前缀用于错误信息，避免把整页 HTML 塞进日志。
pub fn preview(body: &str) -> String {
    let trimmed = body.trim();
    let mut out: String = trimmed.chars().take(80).collect();
    if trimmed.chars().count() > 80 {
        out.push('…');
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::request::Method;

    #[test]
    fn fetch_request_carries_headers() {
        let request =
            FetchRequest::get("https://example.test/a").header("Referer", "https://example.test/");
        assert_eq!(
            request.headers.get("Referer").map(String::as_str),
            Some("https://example.test/")
        );
        assert_eq!(request.method, Method::Get);
    }

    #[test]
    fn non_success_status_becomes_typed_error() {
        let response = FetchResponse::new(404, Vec::new(), "https://example.test/x");
        let err = response.ensure_success().expect_err("must fail");
        assert_eq!(err.http_status(), Some(404));
    }

    #[test]
    fn preview_truncates_long_bodies() {
        let body = "a".repeat(200);
        assert!(preview(&body).chars().count() <= 81);
    }
}
