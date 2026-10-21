//! 剧果代码插件的端到端验证（Core-3 第四个迁移源）。
//!
//! 重点验证 **WIT v2 的播放凭证透传**：取流响应下发 CDN 签名 Cookie，
//! 插件把它填进 `Media.cookies`，宿主必须原样带到播放计划里。
//! 这是「剧果的签名 Cookie 能到达播放器」这条验收的技术前提。
//!
//! 另外验证访客令牌：`POST /auth/guest` 用 UUID v4 设备号换令牌，
//! 令牌存宿主存储，跨实例复用。

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use guo_plugin_wasm::{ComponentSource, SandboxLimits};
use guo_source_api::{
    Chapter, Drama, FetchRequest, FetchResponse, LogSink, SourceEnv, SourceError, SourcePlugin,
    SourceStore, Transport,
};

const HUANGJU: &[u8] = include_bytes!("fixtures/huangju.wasm");

const CATALOG: &str = r#"{"items":[
    {"slug":"yanyu-1","title":"剧果样本","description":"简介","coverUrl":"https://img.test/c.jpg","totalEpisodes":2,"status":"completed"}
],"pageSize":20,"total":1}"#;

const DETAIL: &str = r#"{"slug":"yanyu-1","title":"剧果样本","totalEpisodes":2,"status":"ongoing","episodes":[
    {"id":1001,"epNo":1,"title":"第1集"},
    {"id":1002,"epNo":2,"title":"第2集"}
]}"#;

/// 登录与取流都会下发 Set-Cookie，用来验证凭证透传。
struct Scripted {
    logins: Mutex<usize>,
    requests: Mutex<Vec<String>>,
}

impl Scripted {
    fn new() -> Self {
        Self {
            logins: Mutex::new(0),
            requests: Mutex::new(Vec::new()),
        }
    }

    fn logins(&self) -> usize {
        *self.logins.lock().expect("logins")
    }

    fn requests(&self) -> Vec<String> {
        self.requests.lock().expect("requests").clone()
    }
}

#[async_trait::async_trait]
impl Transport for Scripted {
    async fn fetch(&self, request: FetchRequest) -> Result<FetchResponse, SourceError> {
        let url = request.url.clone();
        self.requests.lock().expect("requests").push(url.clone());

        if url.ends_with("/auth/guest") {
            let mut logins = self.logins.lock().expect("logins");
            *logins += 1;
            let body = format!(r#"{{"token":"guest-{logins}"}}"#);
            return Ok(FetchResponse::new(200, body.into_bytes(), url));
        }
        if url.contains("/play/") {
            let mut response = FetchResponse::new(
                200,
                br#"{"url":"https://cdn.huangju.test/v.m3u8"}"#.to_vec(),
                url,
            );
            // 真实站点在取流响应里下发 CDN 签名 Cookie。
            response.headers.insert(
                "set-cookie".to_string(),
                "CloudFront-Policy=eyJ; Path=/; HttpOnly\nCloudFront-Signature=sig; Path=/"
                    .to_string(),
            );
            return Ok(response);
        }
        let body = if url.contains("/dramas/") {
            DETAIL
        } else {
            CATALOG
        };
        Ok(FetchResponse::new(200, body.as_bytes().to_vec(), url))
    }
}

#[derive(Clone, Default)]
struct SharedStore {
    values: Arc<Mutex<BTreeMap<String, String>>>,
}

#[async_trait::async_trait]
impl SourceStore for SharedStore {
    async fn get(&self, key: &str) -> Result<Option<String>, SourceError> {
        Ok(self.values.lock().expect("store").get(key).cloned())
    }
    async fn set(&self, key: &str, value: &str) -> Result<(), SourceError> {
        self.values
            .lock()
            .expect("store")
            .insert(key.to_string(), value.to_string());
        Ok(())
    }
}

struct Quiet;
impl LogSink for Quiet {
    fn debug(&self, _: &str) {}
    fn warn(&self, _: &str) {}
}

fn source() -> ComponentSource {
    ComponentSource::load(
        HUANGJU,
        vec!["api.huangju.net".into()],
        vec!["session".into()],
        SandboxLimits::default(),
    )
    .expect("剧果组件应可加载")
}

fn env_with(transport: Arc<Scripted>, store: SharedStore) -> SourceEnv {
    SourceEnv {
        source_id: "guo.huangju".into(),
        transport,
        store: Arc::new(store),
        scripts: None,
        log: Arc::new(Quiet),
    }
}

#[test]
fn descriptor_matches_the_compiled_source() {
    let meta = source().meta();
    assert_eq!(meta.id, "guo.huangju");
    assert_eq!(meta.name, "剧果");
    for capability in [
        guo_source_api::Capability::Catalog,
        guo_source_api::Capability::Detail,
        guo_source_api::Capability::Search,
        guo_source_api::Capability::Resolve,
    ] {
        assert!(meta.supports(capability), "{capability:?}");
    }
}

#[tokio::test]
async fn catalog_and_detail_round_trip() {
    let transport = Arc::new(Scripted::new());
    let env = env_with(transport, SharedStore::default());
    let src = source();

    let page = src.catalog(&env, 1, "").await.expect("目录");
    assert_eq!(page.items.len(), 1);
    assert_eq!(page.items[0].source, "guo.huangju");
    assert!(page.items[0].id.starts_with("guo.huangju:"));
    assert_eq!(page.items[0].release_status, "finished");

    let detail = src.detail(&env, "yanyu-1").await.expect("详情");
    assert_eq!(detail.chapters.len(), 2);
    // 分集按集号排序，id 形如 `<source>:<number>`。
    assert_eq!(detail.chapters[0].id, "yanyu-1:1");
    assert_eq!(detail.chapters[1].id, "yanyu-1:2");
    assert_eq!(detail.chapters[0].video_url, "1001");
}

#[tokio::test]
async fn resolve_returns_cdn_signed_cookies() {
    let transport = Arc::new(Scripted::new());
    let env = env_with(transport.clone(), SharedStore::default());
    let src = source();
    let drama = Drama {
        id: "guo.huangju:yanyu-1".into(),
        source: "guo.huangju".into(),
        source_id: "yanyu-1".into(),
        ..Default::default()
    };
    let chapter = Chapter {
        id: "yanyu-1:1".into(),
        title: "第1集".into(),
        video_url: "1001".into(),
        ..Default::default()
    };
    let media = src.resolve(&env, &drama, &chapter).await.expect("取流");

    assert_eq!(media.url, "https://cdn.huangju.test/v.m3u8");
    // 核心验收：CDN 签名 Cookie 必须穿过 WIT v2 到达宿主。
    assert!(
        media.cookies.contains("CloudFront-Policy=eyJ"),
        "实际 Cookie：{}",
        media.cookies
    );
    assert!(media.cookies.contains("CloudFront-Signature=sig"));
    // 属性（Path / HttpOnly）不应混进 Cookie 值。
    assert!(!media.cookies.contains("HttpOnly"), "{}", media.cookies);
    assert_eq!(media.origin, "https://huangju.net");
}

#[tokio::test]
async fn guest_token_is_reused_across_instances() {
    let transport = Arc::new(Scripted::new());
    let store = SharedStore::default();

    source()
        .catalog(&env_with(transport.clone(), store.clone()), 1, "")
        .await
        .expect("首次目录");
    assert_eq!(transport.logins(), 1, "首次必须登录一次");

    source()
        .catalog(&env_with(transport.clone(), store.clone()), 1, "")
        .await
        .expect("二次目录");
    assert_eq!(
        transport.logins(),
        1,
        "令牌在宿主存储里，第二个实例不应重新登录"
    );

    // 换一份空存储必须重新登录。
    source()
        .catalog(&env_with(transport.clone(), SharedStore::default()), 1, "")
        .await
        .expect("三次目录");
    assert_eq!(transport.logins(), 2);
}

#[tokio::test]
async fn device_id_is_stable_and_uuid_shaped() {
    let transport = Arc::new(Scripted::new());
    let store = SharedStore::default();

    // 触发两次登录路径（清空令牌后重新登录），设备号应保持一致。
    source()
        .catalog(&env_with(transport.clone(), store.clone()), 1, "")
        .await
        .expect("首次");
    let device = store
        .values
        .lock()
        .expect("store")
        // 宿主给插件的存储键统一加 `plugin/<namespace>/` 前缀。
        .get("plugin/session/device-id")
        .cloned();
    let device = device.expect("设备号应落盘");
    assert_eq!(device.len(), 36);
    assert_eq!(&device[14..15], "4", "版本位必须是 4：{device}");
    assert!(device.chars().all(|ch| ch == '-' || ch.is_ascii_hexdigit()));
}

#[tokio::test]
async fn empty_keyword_short_circuits() {
    let transport = Arc::new(Scripted::new());
    let page = source()
        .search(
            &env_with(transport.clone(), SharedStore::default()),
            "  ",
            1,
        )
        .await
        .expect("空搜索");
    assert!(page.items.is_empty());
    assert_eq!(transport.logins(), 0, "空关键词不应触发登录");
    assert!(transport.requests().is_empty());
}
