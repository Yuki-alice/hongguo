//! 剧果的离线对拍：夹具是 2026-10-21 的真实接口响应。
//!
//! 剧果的难点在会话与凭证，因此这里除了字段映射，还专门验证：
//! 1. 首次请求会先申请访客令牌，之后复用；
//! 2. 令牌失效（401）时丢弃并重新申请一次；
//! 3. 取流响应下发的 CDN 签名 Cookie 被原样带进 `Media.cookies`。

use std::sync::{Arc, Mutex};

use async_trait::async_trait;

use guo_engine::{
    Capability, Drama, FetchRequest, FetchResponse, HeaderMap, HuangjuSource, LogSink, SourceEnv,
    SourceError, SourcePlugin, SourceStore, Transport,
};

const LIST: &str = include_str!("fixtures/huangju_list.json");
const DETAIL: &str = include_str!("fixtures/huangju_detail.json");
const PLAY: &str = include_str!("fixtures/huangju_play.json");

/// 记录每次请求的地址，按路径返回固定响应。
///
/// `expire_first` 让前若干次**带令牌的业务请求**返回 401，用来验证站源
/// 会丢弃旧令牌并重新申请，而不是把 401 直接抛给用户。
struct ScriptedTransport {
    urls: Mutex<Vec<String>>,
    issued: Mutex<u64>,
    expire_remaining: Mutex<usize>,
}

impl ScriptedTransport {
    fn new(expire_first: usize) -> Self {
        Self {
            urls: Mutex::new(Vec::new()),
            issued: Mutex::new(0),
            expire_remaining: Mutex::new(expire_first),
        }
    }
}

#[async_trait]
impl Transport for ScriptedTransport {
    async fn fetch(&self, request: FetchRequest) -> Result<FetchResponse, SourceError> {
        self.urls.lock().expect("urls").push(request.url.clone());
        if request.url.ends_with("/auth/guest") {
            let mut issued = self.issued.lock().expect("issued");
            *issued += 1;
            let token = format!("token-{issued}");
            let body = format!(r#"{{"token":"{token}"}}"#);
            return Ok(FetchResponse::new(201, body.into_bytes(), request.url));
        }
        {
            let mut remaining = self.expire_remaining.lock().expect("expire");
            if *remaining > 0 {
                *remaining -= 1;
                return Ok(FetchResponse::new(
                    401,
                    b"{\"message\":\"unauthorized\"}".to_vec(),
                    request.url,
                ));
            }
        }
        let body = if request.url.contains("/play/") {
            PLAY
        } else if request.url.contains("/dramas/") {
            DETAIL
        } else {
            LIST
        };
        let mut response = FetchResponse::new(200, body.as_bytes().to_vec(), request.url.clone());
        if request.url.contains("/play/") {
            // 媒体域走 CDN 签名：真实响应下发三个 Cookie，这里给一个即可。
            let mut headers = HeaderMap::new();
            headers.insert(
                "set-cookie".into(),
                "CloudFront-Policy=eyJ0ZXN0; Domain=.huangju.net; Path=/; Secure".into(),
            );
            response.headers = headers;
        }
        Ok(response)
    }
}

struct NoopStore;
#[async_trait]
impl SourceStore for NoopStore {
    async fn get(&self, _: &str) -> Result<Option<String>, SourceError> {
        Ok(None)
    }
    async fn set(&self, _: &str, _: &str) -> Result<(), SourceError> {
        Ok(())
    }
}

struct NoopLog;
impl LogSink for NoopLog {
    fn debug(&self, _: &str) {}
    fn warn(&self, _: &str) {}
}

fn env(transport: Arc<ScriptedTransport>) -> SourceEnv {
    SourceEnv {
        source_id: "huangju".into(),
        transport,
        store: Arc::new(NoopStore),
        scripts: None,
        log: Arc::new(NoopLog),
    }
}

#[tokio::test]
async fn catalog_maps_real_response_and_requests_guest_token_first() {
    let transport = Arc::new(ScriptedTransport::new(0));
    let source = HuangjuSource::new();
    let page = source
        .catalog(&env(transport.clone()), 1, "")
        .await
        .expect("目录");

    assert_eq!(page.items.len(), 20, "真实目录首页 20 条");
    assert!(page.has_more, "total 1761，首页必然还有下一页");

    // 只断言结构与不变量：站点内容会变，写死剧名会让测试随内容漂移。
    assert!(page.items.iter().all(|item| item.source_id.contains('-')));
    assert!(
        page.items
            .iter()
            .all(|item| item.id == format!("huangju:{}", item.source_id)),
        "主键必须是 huangju:<slug>"
    );
    assert!(page.items.iter().all(|item| !item.title.is_empty()));
    assert!(
        page.items
            .iter()
            .all(|item| item.cover.starts_with("https://video.huangju.net")),
        "封面应保持绝对地址"
    );

    let calls = transport.urls.lock().expect("urls").clone();
    assert!(
        calls[0].ends_with("/auth/guest"),
        "第一次请求必须是申请访客令牌：{calls:?}"
    );
    assert!(
        calls[1].contains("/dramas?sort=hot&page=1"),
        "无分类时走热门排序：{calls:?}"
    );
}

#[tokio::test]
async fn token_is_reused_across_calls() {
    let transport = Arc::new(ScriptedTransport::new(0));
    let source = HuangjuSource::new();
    let shared = transport.clone();
    source
        .catalog(&env(shared.clone()), 1, "")
        .await
        .expect("第一次");
    source
        .catalog(&env(shared.clone()), 2, "")
        .await
        .expect("第二次");

    let auth_calls = transport
        .urls
        .lock()
        .expect("urls")
        .iter()
        .filter(|url| url.ends_with("/auth/guest"))
        .count();
    assert_eq!(auth_calls, 1, "令牌应复用，不应每次重新申请");
}

#[tokio::test]
async fn expired_token_triggers_one_relogin() {
    // 只让第一次业务请求 401：站源的约定是「失效后重新申请一次」。
    let transport = Arc::new(ScriptedTransport::new(1));
    let source = HuangjuSource::new();
    let page = source
        .catalog(&env(transport.clone()), 1, "")
        .await
        .expect("401 后应重新申请令牌并成功");
    assert_eq!(page.items.len(), 20);
}

#[tokio::test]
async fn detail_uses_slug_and_returns_episodes() {
    let transport = Arc::new(ScriptedTransport::new(0));
    let source = HuangjuSource::new();
    let detail = source
        .detail(&env(transport.clone()), "yanyu-473")
        .await
        .expect("详情");

    assert!(!detail.drama.title.is_empty());
    assert!(!detail.chapters.is_empty(), "至少一集");
    let first = &detail.chapters[0];
    assert!(
        first.id.starts_with("yanyu-473:"),
        "分集主键带 slug 前缀：{}",
        first.id
    );
    assert!(
        first.video_url.parse::<u64>().is_ok(),
        "分集要存数字 id 供取流：{}",
        first.video_url
    );
    assert!(
        transport
            .urls
            .lock()
            .expect("urls")
            .iter()
            .any(|url| url.ends_with("/dramas/yanyu-473")),
        "详情必须按 slug 请求"
    );
}

#[tokio::test]
async fn resolve_returns_media_with_cdn_cookie() {
    let transport = Arc::new(ScriptedTransport::new(0));
    let source = HuangjuSource::new();
    let chapter = guo_engine::Chapter {
        id: "yanyu-473:1".into(),
        title: "第1集".into(),
        source: "huangju".into(),
        video_url: "17190".into(),
        ..Default::default()
    };
    let media = source
        .resolve(&env(transport.clone()), &Drama::default(), &chapter)
        .await
        .expect("取流");
    assert!(media.url.starts_with("https://"), "{}", media.url);
    assert!(
        media.cookies.contains("CloudFront-Policy"),
        "媒体域需要签名 Cookie：{}",
        media.cookies
    );
    assert_eq!(media.referer, "https://huangju.net/");
}

#[test]
fn meta_declares_expected_capabilities() {
    let meta = HuangjuSource::new().meta();
    assert_eq!(meta.id, "huangju");
    assert_eq!(meta.name, "剧果");
    for capability in [
        Capability::Catalog,
        Capability::Detail,
        Capability::Search,
        Capability::Categories,
    ] {
        assert!(
            meta.capabilities.contains(&capability),
            "缺少 {capability:?}"
        );
    }
}
