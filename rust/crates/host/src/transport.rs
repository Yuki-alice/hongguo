use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;

use guo_source_api::{FetchRequest, FetchResponse, HeaderMap, Method, SourceError, Transport};

pub struct HttpTransport {
    client: reqwest::Client,
    user_agent: String,
}

/// GET 幂等，可安全重试。目标站点的页面接口（字节系尤甚）偶发
/// 「半截响应」：200 + 空 body、chunked 断流、短暂 5xx——重试通常就能
/// 拿到完整页面（curl 实测同一 URL 时好时坏）。
const GET_ATTEMPTS: usize = 3;
/// 第 n 次重试前的退避毫秒数。
const GET_RETRY_BACKOFF_MS: [u64; GET_ATTEMPTS - 1] = [300, 900];
/// 重试轮次的超时上限。首次尝试沿用调用方的超时；既然上一轮已经失败，
/// 再挂一次就应当尽快失败，把时间预算留给下一次尝试。
const RETRY_TIMEOUT_CAP: Duration = Duration::from_secs(8);

impl HttpTransport {
    fn base_builder() -> reqwest::ClientBuilder {
        reqwest::Client::builder()
            .timeout(Duration::from_secs(30))
            .connect_timeout(Duration::from_secs(10))
            .redirect(reqwest::redirect::Policy::limited(10))
    }

    pub fn new(user_agent: impl Into<String>) -> Result<Self, SourceError> {
        let client = Self::base_builder()
            .build()
            .map_err(|err| SourceError::network("client", err))?;
        Ok(Self {
            client,
            user_agent: user_agent.into(),
        })
    }

    /// 测试专用：回环地址绝不能走系统代理，否则本机脚本服务器收不到连接。
    #[cfg(test)]
    fn new_without_proxy(user_agent: impl Into<String>) -> Result<Self, SourceError> {
        let client = Self::base_builder()
            .no_proxy()
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
        let attempts = if request.method == Method::Get {
            GET_ATTEMPTS
        } else {
            1
        };
        // 每轮的超时与随后的退避：首轮沿用调用方超时，重试轮收紧到
        // `RETRY_TIMEOUT_CAP`——上一轮已经失败，再挂一次就该尽快让位。
        let schedule = std::iter::once((request.timeout, None)).chain((0..attempts - 1).map(|i| {
            (
                request.timeout.min(RETRY_TIMEOUT_CAP),
                Some(GET_RETRY_BACKOFF_MS[i]),
            )
        }));
        for (attempt, (timeout, backoff_ms)) in schedule.enumerate() {
            let is_last = attempt + 1 == attempts;
            let result = self.fetch_once(&request, timeout).await;
            let retryable = match &result {
                Ok(response) => is_retryable_response(response),
                Err(err) => is_retryable_error(err),
            };
            match result {
                Ok(response) if !retryable || is_last => return Ok(response),
                Ok(_) => {}
                Err(err) if is_last => return Err(err),
                Err(_) => {}
            }
            if let Some(ms) = backoff_ms {
                tokio::time::sleep(Duration::from_millis(ms)).await;
            }
        }
        // attempts >= 1 且循环内最后一轮必然 return，这里不可达。
        unreachable!("重试循环必然在最后一轮返回")
    }
}

/// 哪些「成功拿到响应」仍然值得再试一次。
fn is_retryable_response(response: &FetchResponse) -> bool {
    // 服务端瞬时故障。
    response.status >= 500
        // 页面被切断的典型形态：HTTP 200 但 body 为空。
        // 下游解析反正会失败，直接在传输层重试一次更便宜。
        || (response.status == 200 && response.body.is_empty())
}

/// 哪些传输错误值得再试一次。超时也走 `Network`（见 `fetch_once` 的映射）。
fn is_retryable_error(err: &SourceError) -> bool {
    matches!(err, SourceError::Network { .. })
}

impl HttpTransport {
    async fn fetch_once(
        &self,
        request: &FetchRequest,
        timeout: Duration,
    ) -> Result<FetchResponse, SourceError> {
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
            .timeout(timeout);
        // `header()` 是追加语义，默认 UA 与规则里的 UA 同时发出会变成两个值。
        if !overrides_agent {
            builder = builder.header(reqwest::header::USER_AGENT, &self.user_agent);
        }

        for (key, value) in &request.headers {
            builder = builder.header(key.as_str(), value.as_str());
        }
        if let Some(body) = &request.body {
            builder = builder.body(body.clone());
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

/// 只保留续传、探测与播放凭证需要的响应头，避免把整个头表复制进每条响应。
///
/// `set-cookie` 必须保留：剧果等站点的媒体域走 CDN 签名，播放列表与分片
/// 只有在带上这次响应下发的 Cookie 时才可访问。同名头可能有多个值
/// （每个 Cookie 一条），因此单独累加而不是覆盖。
fn capture_headers(headers: &reqwest::header::HeaderMap) -> HeaderMap {
    const KEEP: [&str; 5] = [
        "etag",
        "last-modified",
        "content-type",
        "content-length",
        "set-cookie",
    ];
    let mut out = HeaderMap::new();
    for (name, value) in headers {
        let name = name.as_str();
        if !KEEP.iter().any(|keep| name.eq_ignore_ascii_case(keep)) {
            continue;
        }
        let Ok(text) = value.to_str() else {
            continue;
        };
        let key = name.to_ascii_lowercase();
        match out.get_mut(&key) {
            Some(existing) => {
                existing.push('\n');
                existing.push_str(text);
            }
            None => {
                out.insert(key, text.to_string());
            }
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
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::atomic::{AtomicUsize, Ordering};

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

    /// 起一个按脚本逐连接应答的本机 HTTP 服务。每条响应都带
    /// `Connection: close`，reqwest 每次尝试都会开新连接，
    /// 因此连接序号 = 重试轮次。
    fn scripted_server(
        script: Vec<Vec<u8>>,
    ) -> (String, Arc<AtomicUsize>, std::thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = listener.local_addr().expect("addr");
        let hits = Arc::new(AtomicUsize::new(0));
        let counter = Arc::clone(&hits);
        let handle = std::thread::spawn(move || {
            for response in script {
                let Ok((mut stream, _)) = listener.accept() else {
                    break;
                };
                counter.fetch_add(1, Ordering::SeqCst);
                // 把请求头（及可能的 body）读完，避免客户端发送阶段被 RST。
                let mut buf = Vec::new();
                let mut chunk = [0u8; 4096];
                loop {
                    match stream.read(&mut chunk) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => {
                            buf.extend_from_slice(&chunk[..n]);
                            let header_end = buf
                                .windows(4)
                                .position(|w| w == b"\r\n\r\n")
                                .map(|pos| pos + 4);
                            if let Some(end) = header_end {
                                let length = buf[..end]
                                    .split(|b| *b == b'\n')
                                    .find_map(|line| {
                                        let text = String::from_utf8_lossy(line);
                                        let (name, value) = text.split_once(':')?;
                                        name.trim()
                                            .eq_ignore_ascii_case("content-length")
                                            .then(|| value.trim().parse::<usize>().ok())?
                                    })
                                    .unwrap_or(0);
                                if buf.len() >= end + length {
                                    break;
                                }
                            }
                        }
                    }
                }
                let _ = stream.write_all(&response);
                let _ = stream.flush();
            }
        });
        (format!("http://{addr}/probe"), hits, handle)
    }

    fn http_response(status_line: &str, body: &[u8]) -> Vec<u8> {
        let mut out = format!(
            "{status_line}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        )
        .into_bytes();
        out.extend_from_slice(body);
        out
    }

    async fn get(transport: &HttpTransport, url: &str) -> Result<FetchResponse, SourceError> {
        transport
            .fetch(FetchRequest {
                timeout: Duration::from_secs(5),
                ..FetchRequest::get(url)
            })
            .await
    }

    #[tokio::test]
    async fn get_retries_through_transient_5xx() {
        let (url, hits, server) = scripted_server(vec![
            http_response("HTTP/1.1 500 Upstream Error", b""),
            http_response("HTTP/1.1 200 OK", b"recovered"),
        ]);
        let transport = HttpTransport::new_without_proxy("test").expect("build");
        let response = get(&transport, &url).await.expect("must recover");
        assert_eq!(response.status, 200);
        assert_eq!(response.body, b"recovered");
        assert_eq!(hits.load(Ordering::SeqCst), 2, "恰好重试了一次");
        server.join().expect("server");
    }

    #[tokio::test]
    async fn get_retries_on_empty_ok_body() {
        let (url, hits, server) = scripted_server(vec![
            http_response("HTTP/1.1 200 OK", b""),
            http_response("HTTP/1.1 200 OK", b"real body"),
        ]);
        let transport = HttpTransport::new_without_proxy("test").expect("build");
        let response = get(&transport, &url).await.expect("must recover");
        assert_eq!(response.body, b"real body");
        assert_eq!(hits.load(Ordering::SeqCst), 2);
        server.join().expect("server");
    }

    #[tokio::test]
    async fn get_gives_up_after_three_attempts() {
        let (url, hits, server) = scripted_server(vec![
            http_response("HTTP/1.1 500 a", b""),
            http_response("HTTP/1.1 500 b", b""),
            http_response("HTTP/1.1 500 c", b""),
        ]);
        let transport = HttpTransport::new_without_proxy("test").expect("build");
        let response = get(&transport, &url).await.expect("response");
        assert_eq!(response.status, 500, "重试耗尽后返回最后一次响应");
        assert_eq!(hits.load(Ordering::SeqCst), 3, "共尝试三次");
        server.join().expect("server");
    }

    #[tokio::test]
    async fn post_is_never_retried() {
        let (url, hits, server) = scripted_server(vec![http_response("HTTP/1.1 500 no", b"")]);
        let transport = HttpTransport::new_without_proxy("test").expect("build");
        let response = transport
            .fetch(FetchRequest::post(url, b"{}".to_vec()))
            .await
            .expect("response");
        assert_eq!(response.status, 500);
        assert_eq!(hits.load(Ordering::SeqCst), 1, "POST 非幂等，失败即返回");
        server.join().expect("server");
    }

    #[tokio::test]
    async fn success_is_not_retried() {
        let (url, hits, server) = scripted_server(vec![http_response("HTTP/1.1 200 OK", b"fine")]);
        let transport = HttpTransport::new_without_proxy("test").expect("build");
        let response = get(&transport, &url).await.expect("response");
        assert_eq!(response.body, b"fine");
        assert_eq!(hits.load(Ordering::SeqCst), 1, "成功响应不应多打一次");
        server.join().expect("server");
    }
}
