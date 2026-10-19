use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;

use crate::env::{FetchRequest, FetchResponse, HeaderMap, Method, Transport};
use crate::SourceError;

pub struct HttpTransport {
    client: reqwest::Client,
    user_agent: String,
}

impl HttpTransport {
    pub fn new(user_agent: impl Into<String>) -> Result<Self, SourceError> {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(30))
            .connect_timeout(Duration::from_secs(10))
            .redirect(reqwest::redirect::Policy::limited(10))
            .build()
            .map_err(|err| SourceError::network("client", err))?;
        Ok(Self {
            client,
            user_agent: user_agent.into(),
        })
    }

    pub fn shared(user_agent: impl Into<String>) -> Result<Arc<Self>, SourceError> {
        Ok(Arc::new(Self::new(user_agent)?))
    }

    /// 进程级共享客户端，保留连接池。
    ///
    /// 每次请求新建 `Client` 会让连接池、TLS 会话缓存和 DNS 缓存全部失效，
    /// 在多站源轮询场景下代价明显。
    pub fn global() -> Result<Arc<Self>, SourceError> {
        static INSTANCE: std::sync::OnceLock<Arc<HttpTransport>> = std::sync::OnceLock::new();
        if let Some(existing) = INSTANCE.get() {
            return Ok(Arc::clone(existing));
        }
        let created = Arc::new(Self::new(DEFAULT_USER_AGENT)?);
        Ok(Arc::clone(INSTANCE.get_or_init(|| created)))
    }
}

#[async_trait]
impl Transport for HttpTransport {
    async fn fetch(&self, request: FetchRequest) -> Result<FetchResponse, SourceError> {
        let overrides_agent = request
            .headers
            .keys()
            .any(|key| key.eq_ignore_ascii_case("user-agent"));
        let mut builder = self
            .client
            .request(
                match request.method {
                    Method::Get => reqwest::Method::GET,
                    Method::Post => reqwest::Method::POST,
                },
                &request.url,
            )
            .timeout(request.timeout);
        // `header()` 是追加语义，默认 UA 与规则里的 UA 同时发出会变成两个值。
        if !overrides_agent {
            builder = builder.header(reqwest::header::USER_AGENT, &self.user_agent);
        }

        for (key, value) in &request.headers {
            builder = builder.header(key.as_str(), value.as_str());
        }
        if let Some(body) = request.body {
            builder = builder.body(body);
        }

        let response = builder.send().await.map_err(|err| {
            if err.is_timeout() {
                SourceError::network(&request.url, "请求超时")
            } else {
                SourceError::network(&request.url, err)
            }
        })?;

        let status = response.status().as_u16();
        let final_url = response.url().to_string();
        let headers = capture_headers(response.headers());
        let body = read_body(response, request.max_bytes, &request.url).await?;
        let truncated = request
            .max_bytes
            .map(|limit| body.len() as u64 >= limit)
            .unwrap_or(false);

        Ok(FetchResponse {
            status,
            body,
            final_url,
            headers,
            truncated,
        })
    }
}

/// 只保留续传与探测需要的响应头，避免把整个头表复制进每条响应。
fn capture_headers(headers: &reqwest::header::HeaderMap) -> HeaderMap {
    const KEEP: [&str; 4] = ["etag", "last-modified", "content-type", "content-length"];
    let mut out = HeaderMap::new();
    for (name, value) in headers {
        let name = name.as_str();
        if !KEEP.iter().any(|keep| name.eq_ignore_ascii_case(keep)) {
            continue;
        }
        if let Ok(text) = value.to_str() {
            out.insert(name.to_string(), text.to_string());
        }
    }
    out
}

/// 读取响应体；`max_bytes` 有值时只读前缀，避免把大文件整个拉进内存。
async fn read_body(
    response: reqwest::Response,
    max_bytes: Option<u64>,
    url: &str,
) -> Result<Vec<u8>, SourceError> {
    let Some(limit) = max_bytes else {
        return Ok(response
            .bytes()
            .await
            .map_err(|err| SourceError::network(url, format!("读取响应失败：{err}")))?
            .to_vec());
    };

    let mut response = response;
    let mut body = Vec::new();
    // `chunk()` 在未启用 `stream` 特性时同样可用，因此不额外引入 futures-util。
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|err| SourceError::network(url, format!("读取响应失败：{err}")))?
    {
        let remaining = limit.saturating_sub(body.len() as u64);
        if remaining == 0 {
            break;
        }
        let take = remaining.min(chunk.len() as u64) as usize;
        body.extend_from_slice(&chunk[..take]);
        if body.len() as u64 >= limit {
            break;
        }
    }
    Ok(body)
}

pub const DEFAULT_USER_AGENT: &str =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transport_builds_with_custom_agent() {
        let transport = HttpTransport::new("test-agent").expect("build");
        assert_eq!(transport.user_agent, "test-agent");
    }

    #[test]
    fn shared_transport_is_reusable() {
        let first = HttpTransport::shared("a").expect("build");
        let second = Arc::clone(&first);
        assert_eq!(Arc::strong_count(&second), 2);
    }
}
