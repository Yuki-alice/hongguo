//! 芽果的离线对拍：夹具是 2026-10-21 的真实接口响应。
//!
//! 芽果的迁移重点：
//! 1. 首次请求先设备登录，令牌在 6 小时内复用；
//! 2. 令牌失效（401）时丢弃并重新登录一次；
//! 3. 分类取 `theater/classes` 的**顶层分组**，`9`（排行榜）走独立接口；
//! 4. 分集自带 MP4 地址，取流不抓页面。

use std::sync::{Arc, Mutex};

use async_trait::async_trait;

use guo_engine::{
    Capability, Chapter, Drama, FetchRequest, FetchResponse, LogSink, Method, SourceEnv,
    SourceError, SourcePlugin, SourceStore, Transport, YaguoSource,
};

const CLASSES: &str = include_str!("fixtures/yaguo_classes.json");
const CATALOG: &str = include_str!("fixtures/yaguo_catalog.json");
const RANKING: &str = include_str!("fixtures/yaguo_ranking.json");
const DETAIL: &str = include_str!("fixtures/yaguo_detail.json");
const SEARCH: &str = include_str!("fixtures/yaguo_search.json");

#[derive(Clone)]
struct RecordedRequest {
    url: String,
    method: Method,
    authorization: String,
    body: String,
}

/// 按路径返回固定响应，并记录每次请求。
///
/// `expire_first` 让前若干次**业务请求**返回 401，用来验证站源会重新登录，
/// 而不是把 401 直接抛给用户。
struct ScriptedTransport {
    requests: Mutex<Vec<RecordedRequest>>,
    issued: Mutex<u64>,
    expire_remaining: Mutex<usize>,
    busy_logins: Mutex<usize>,
}

impl ScriptedTransport {
    fn new(expire_first: usize) -> Self {
        Self {
            requests: Mutex::new(Vec::new()),
            issued: Mutex::new(0),
            expire_remaining: Mutex::new(expire_first),
            busy_logins: Mutex::new(0),
        }
    }

    /// 前 `busy` 次登录返回 `2010007`，模拟同一设备号并发登录被限流。
    fn new_busy(busy: usize) -> Self {
        Self {
            busy_logins: Mutex::new(busy),
            ..Self::new(0)
        }
    }

    fn requests(&self) -> Vec<RecordedRequest> {
        self.requests.lock().expect("requests").clone()
    }

    fn login_count(&self) -> usize {
        self.requests()
            .iter()
            .filter(|request| request.url.ends_with("/user/v1/account/login"))
            .count()
    }
}

#[async_trait]
impl Transport for ScriptedTransport {
    async fn fetch(&self, request: FetchRequest) -> Result<FetchResponse, SourceError> {
        let authorization = request
            .headers
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case("authorization"))
            .map(|(_, value)| value.clone())
            .unwrap_or_default();
        let body = request
            .body
            .as_ref()
            .map(|body| String::from_utf8_lossy(body).into_owned())
            .unwrap_or_default();
        let url = request.url.clone();
        self.requests
            .lock()
            .expect("requests")
            .push(RecordedRequest {
                url: url.clone(),
                method: request.method,
                authorization,
                body,
            });

        if url.ends_with("/user/v1/account/login") {
            let mut busy = self.busy_logins.lock().expect("busy");
            if *busy > 0 {
                *busy -= 1;
                let body =
                    br#"{"code":"2010007","msg":"The system is busy, please try again later"}"#;
                return Ok(FetchResponse::new(200, body.to_vec(), url));
            }
            drop(busy);
            let mut issued = self.issued.lock().expect("issued");
            *issued += 1;
            let body = format!(r#"{{"code":"ok","data":{{"token":"token-{issued}"}}}}"#);
            return Ok(FetchResponse::new(200, body.into_bytes(), url));
        }

        {
            let mut remaining = self.expire_remaining.lock().expect("expire");
            if *remaining > 0 {
                *remaining -= 1;
                let body =
                    br#"{"code":"1040401","data":null,"msg":"token check fail","status":401}"#;
                return Ok(FetchResponse::new(401, body.to_vec(), url));
            }
        }

        let body = if url.contains("/theater/classes") {
            CLASSES
        } else if url.contains("/first_level_ranking/detail") {
            RANKING
        } else if url.contains("/theater/home_page") {
            CATALOG
        } else if url.contains("/v2/theater_parent/detail") {
            DETAIL
        } else if url.ends_with("/v3/search") {
            SEARCH
        } else {
            ""
        };
        Ok(FetchResponse::new(200, body.as_bytes().to_vec(), url))
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
        source_id: "yaguo".into(),
        transport,
        store: Arc::new(NoopStore),
        scripts: None,
        log: Arc::new(NoopLog),
    }
}

#[tokio::test]
async fn catalog_logs_in_first_and_maps_wrapped_items() {
    let transport = Arc::new(ScriptedTransport::new(0));
    let source = YaguoSource::new();
    let page = source
        .catalog(&env(transport.clone()), 1, "")
        .await
        .expect("目录");

    assert_eq!(page.items.len(), 3, "夹具保留 3 条目录");
    assert!(page.has_more, "total 300、首页 3 条，必然还有下一页");
    assert_eq!(page.items[0].title, "女神的近身高手");
    assert_eq!(page.items[0].id, "yaguo:51");
    assert_eq!(page.items[0].episodes, 100);
    assert!(
        page.items
            .iter()
            .all(|item| item.id == format!("yaguo:{}", item.source_id)),
        "主键必须是 yaguo:<id>"
    );
    assert!(
        page.items
            .iter()
            .all(|item| item.cover.starts_with("https://qiniu.rongjuwh.cn")),
        "封面应保持绝对地址"
    );

    let calls = transport.requests();
    assert!(
        calls[0].url.ends_with("/user/v1/account/login"),
        "第一次请求必须是设备登录：{calls:?}",
        calls = calls.iter().map(|call| &call.url).collect::<Vec<_>>()
    );
    assert!(
        calls[1].url.contains("/cloud/v2/theater/home_page"),
        "登录后请求目录：{}",
        calls[1].url
    );
    assert_eq!(calls[1].authorization, "token-1", "业务请求要带设备令牌");
    assert_eq!(calls[1].method, Method::Get);
}

#[tokio::test]
async fn token_is_reused_across_calls() {
    let transport = Arc::new(ScriptedTransport::new(0));
    let source = YaguoSource::new();
    source
        .catalog(&env(transport.clone()), 1, "")
        .await
        .expect("第一次目录");
    source
        .catalog(&env(transport.clone()), 2, "")
        .await
        .expect("第二次目录");

    assert_eq!(transport.login_count(), 1, "令牌应复用，不应每次重新登录");
}

#[tokio::test]
async fn busy_login_is_retried() {
    let transport = Arc::new(ScriptedTransport::new_busy(2));
    let source = YaguoSource::new();
    let page = source
        .catalog(&env(transport.clone()), 1, "")
        .await
        .expect("繁忙重试后应登录成功");
    assert_eq!(page.items.len(), 3);
    assert_eq!(transport.login_count(), 3, "繁忙两次后第三次登录成功");
}

#[tokio::test]
async fn expired_token_triggers_one_relogin() {
    let transport = Arc::new(ScriptedTransport::new(1));
    let source = YaguoSource::new();
    let page = source
        .catalog(&env(transport.clone()), 1, "")
        .await
        .expect("401 后应重新登录并成功");
    assert_eq!(page.items.len(), 3);
    assert_eq!(transport.login_count(), 2, "一次失败后只重登一次");

    let catalog_calls: Vec<_> = transport
        .requests()
        .into_iter()
        .filter(|request| request.url.contains("/theater/home_page"))
        .collect();
    assert_eq!(catalog_calls.len(), 2);
    assert_eq!(catalog_calls[0].authorization, "token-1");
    assert_eq!(catalog_calls[1].authorization, "token-2");
}

#[tokio::test]
async fn categories_read_top_level_groups() {
    let transport = Arc::new(ScriptedTransport::new(0));
    let source = YaguoSource::new();
    let categories = source
        .categories(&env(transport.clone()))
        .await
        .expect("分类");

    // Go 版在这里把 `data` 当成数组，实际响应是 `data.list`，导致分类永远读不到、
    // 只能退回写死的两项。Rust 版按真实结构读取，得到站点完整的五个分组。
    assert_eq!(
        categories
            .iter()
            .map(|category| (category.id.as_str(), category.name.as_str()))
            .collect::<Vec<_>>(),
        vec![
            ("1", "剧场"),
            ("3", "新剧"),
            ("9", "排行榜"),
            ("2", "热播剧"),
            ("7", "星选好剧"),
        ]
    );
}

#[tokio::test]
async fn ranking_category_uses_the_ranking_endpoint() {
    let transport = Arc::new(ScriptedTransport::new(0));
    let source = YaguoSource::new();
    let page = source
        .catalog(&env(transport.clone()), 1, "9")
        .await
        .expect("榜单");

    assert_eq!(page.items.len(), 3);
    assert!(!page.has_more, "榜单接口不分页");
    assert_eq!(page.items[0].id, "yaguo:4200");
    assert_eq!(page.items[0].title, "花开时节动京城");
    assert!(
        transport
            .requests()
            .iter()
            .any(|request| request.url.contains("/first_level_ranking/detail?id=1")),
        "分类 9 必须请求榜单接口"
    );
}

#[tokio::test]
async fn detail_maps_episodes_with_direct_media_urls() {
    let transport = Arc::new(ScriptedTransport::new(0));
    let source = YaguoSource::new();
    let detail = source
        .detail(&env(transport.clone()), "51")
        .await
        .expect("详情");

    assert_eq!(detail.drama.id, "yaguo:51");
    assert_eq!(detail.drama.title, "女神的近身高手");
    assert_eq!(detail.drama.release_status, "finished");
    assert_eq!(detail.drama.episodes, 3, "分集数应与返回的章节一致");
    assert_eq!(detail.chapters.len(), 3);

    let first = &detail.chapters[0];
    assert_eq!(first.id, "51:1");
    assert_eq!(first.title, "女神的近身高手1");
    assert!(
        first.video_url.starts_with("http://qcapp.xingya.com.cn"),
        "分集地址应是可直接播放的 MP4：{}",
        first.video_url
    );
    assert_eq!(first.referer, "https://app.whjzjx.cn/");
}

#[tokio::test]
async fn search_posts_the_query_and_reads_search_data() {
    let transport = Arc::new(ScriptedTransport::new(0));
    let source = YaguoSource::new();
    let page = source
        .search(&env(transport.clone()), "豪门", 1)
        .await
        .expect("搜索");

    assert_eq!(page.items.len(), 3);
    assert_eq!(page.items[0].id, "yaguo:2207");
    assert_eq!(page.items[0].title, "开局离婚，她竟是豪门继承人");

    let call = transport
        .requests()
        .into_iter()
        .find(|request| request.url.ends_with("/v3/search"))
        .expect("应请求搜索接口");
    assert_eq!(call.method, Method::Post);
    assert!(
        call.body.contains(r#""text":"豪门""#),
        "搜索词要放在 JSON 请求体里：{}",
        call.body
    );
    assert!(!call.authorization.is_empty(), "搜索同样需要设备令牌");
}

#[tokio::test]
async fn blank_search_does_not_hit_the_network() {
    let transport = Arc::new(ScriptedTransport::new(0));
    let source = YaguoSource::new();
    let page = source
        .search(&env(transport.clone()), "   ", 1)
        .await
        .expect("空搜索");
    assert!(page.items.is_empty());
    assert!(transport.requests().is_empty());
}

#[tokio::test]
async fn resolve_passes_through_the_direct_media_url() {
    let transport = Arc::new(ScriptedTransport::new(0));
    let source = YaguoSource::new();
    let chapter = Chapter {
        id: "51:1".into(),
        title: "第1集".into(),
        source: "yaguo".into(),
        video_url: "http://qcapp.xingya.com.cn/ep1.mp4?sign=abc".into(),
        ..Default::default()
    };
    let media = source
        .resolve(&env(transport.clone()), &Drama::default(), &chapter)
        .await
        .expect("取流");
    assert_eq!(media.url, "http://qcapp.xingya.com.cn/ep1.mp4?sign=abc");
    assert_eq!(media.referer, "https://app.whjzjx.cn/");
    assert!(media.playlist.is_none());
    assert!(transport.requests().is_empty(), "直链取流不应发起网络请求");

    let empty = Chapter {
        id: "51:1".into(),
        source: "yaguo".into(),
        ..Default::default()
    };
    let error = source
        .resolve(&env(transport), &Drama::default(), &empty)
        .await
        .expect_err("缺少地址应报错");
    assert!(error.to_string().contains("播放地址"), "{error}");
}

#[test]
fn meta_declares_expected_capabilities() {
    let meta = YaguoSource::new().meta();
    assert_eq!(meta.id, "yaguo");
    assert_eq!(meta.name, "芽果");
    for capability in [
        Capability::Catalog,
        Capability::Detail,
        Capability::Search,
        Capability::Categories,
        Capability::Resolve,
    ] {
        assert!(
            meta.capabilities.contains(&capability),
            "缺少能力位 {capability:?}"
        );
    }
}
