//! 请求 / 响应结构。纯数据，不含任何 IO。
//!
//! 放在契约层是为了让规则引擎能在不依赖 `reqwest` 的前提下构造请求
//! （ARCHITECTURE.md §6.3）。

use std::collections::BTreeMap;
use std::time::Duration;

use crate::error::SourceError;

pub type HeaderMap = BTreeMap<String, String>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RequestPriority {
    Catalog,
    Detail,
    Media,
    Preload,
}

#[derive(Debug, Clone)]
pub struct FetchRequest {
    pub url: String,
    pub method: Method,
    pub headers: HeaderMap,
    pub body: Option<Vec<u8>>,
    pub priority: RequestPriority,
    pub timeout: Duration,
    /// 响应体上限。`None` 表示不限。
    ///
    /// 取流探测只需读取前缀判断是否为 HLS，绝不能把整集 MP4 读进内存；
    /// 下载分片时也用这个上限拦住异常大的响应。
    pub max_bytes: Option<u64>,
}

impl FetchRequest {
    pub fn get(url: impl Into<String>) -> Self {
        Self {
            url: url.into(),
            method: Method::Get,
            headers: HeaderMap::new(),
            body: None,
            priority: RequestPriority::Catalog,
            timeout: Duration::from_secs(20),
            max_bytes: None,
        }
    }

    pub fn post(url: impl Into<String>, body: Vec<u8>) -> Self {
        Self {
            body: Some(body),
            method: Method::Post,
            ..Self::get(url)
        }
    }

    pub fn header(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.headers.insert(key.into(), value.into());
        self
    }

    pub fn priority(mut self, priority: RequestPriority) -> Self {
        self.priority = priority;
        self
    }

    /// 覆盖默认超时。网页类请求健康时秒回，给到 20s 默认值只会在
    /// 站点挂起时白等，调用方按需收紧。
    pub fn timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    /// 限制响应体字节数，超出部分丢弃。
    pub fn limit_bytes(mut self, max_bytes: u64) -> Self {
        self.max_bytes = Some(max_bytes);
        self
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Method {
    Get,
    Post,
}

#[derive(Debug, Clone)]
pub struct FetchResponse {
    pub status: u16,
    /// 原始字节。文本响应由调用方按需解码，避免媒体二进制被 UTF-8 破坏。
    pub body: Vec<u8>,
    pub final_url: String,
    /// 仅保留续传与探测需要的一小部分响应头（ETag / Last-Modified / Content-Type / Content-Length）。
    pub headers: HeaderMap,
    /// 是否因 `max_bytes` 被截断。
    pub truncated: bool,
}

impl FetchResponse {
    /// 构造不带响应头的响应，供测试与内部合成响应使用。
    pub fn new(status: u16, body: Vec<u8>, final_url: impl Into<String>) -> Self {
        Self {
            status,
            body,
            final_url: final_url.into(),
            headers: HeaderMap::new(),
            truncated: false,
        }
    }

    /// 按名称读取响应头，大小写不敏感。
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }

    /// 续传校验值：优先 ETag，其次 Last-Modified。
    pub fn validator(&self) -> String {
        self.header("ETag")
            .or_else(|| self.header("Last-Modified"))
            .unwrap_or_default()
            .to_string()
    }

    /// 把响应体按 UTF-8 解码，用于 HTML/JSON。
    pub fn text(&self) -> String {
        String::from_utf8_lossy(&self.body).into_owned()
    }

    pub fn ensure_success(&self) -> Result<(), SourceError> {
        if (200..300).contains(&self.status) {
            Ok(())
        } else {
            Err(SourceError::http(&self.final_url, self.status))
        }
    }
}
