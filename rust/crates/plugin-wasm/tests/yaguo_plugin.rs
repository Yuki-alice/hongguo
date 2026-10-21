//! 芽果代码插件的端到端验证（Core-3 第二个迁移源）。
//!
//! 这一组用例的重点不是解析，而是**登录态**：
//! 插件把令牌写进宿主存储，因此同一份存储上的第二个实例不会重新登录，
//! 换一份存储才会。这正是「插件化不丢会话」的验收点。

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use guo_plugin_wasm::{ComponentSource, SandboxLimits};
use guo_source_api::{
    FetchRequest, FetchResponse, LogSink, SourceEnv, SourceError, SourcePlugin, SourceStore,
    Transport,
};

const YAGUO: &[u8] = include_bytes!("fixtures/yaguo.wasm");
const CLASSES: &str = include_str!("../../../bridge/tests/fixtures/yaguo_classes.json");
const CATALOG: &str = include_str!("../../../bridge/tests/fixtures/yaguo_catalog.json");
const DETAIL: &str = include_str!("../../../bridge/tests/fixtures/yaguo_detail.json");

/// 记录登录次数，并按路径返回夹具。
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
        if url.ends_with("/user/v1/account/login") {
            let mut logins = self.logins.lock().expect("logins");
            *logins += 1;
            let body = format!(r#"{{"code":"ok","data":{{"token":"token-{logins}"}}}}"#);
            return Ok(FetchResponse::new(200, body.into_bytes(), url));
        }
        let body = if url.contains("/theater/classes") {
            CLASSES
        } else if url.contains("/theater/home_page") {
            CATALOG
        } else if url.contains("/theater_parent/detail") {
            DETAIL
        } else {
            ""
        };
        if body.is_empty() {
            return Ok(FetchResponse::new(404, Vec::new(), url));
        }
        Ok(FetchResponse::new(200, body.as_bytes().to_vec(), url))
    }
}

/// 内存存储，可在多个 `SourceEnv` 之间共享（模拟跨调用的宿主存储）。
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
        YAGUO,
        vec!["app.whjzjx.cn".into(), "u.shytkjgs.com".into()],
        vec!["session".into()],
        SandboxLimits::default(),
    )
    .expect("芽果组件应可加载")
}

fn env_with(transport: Arc<Scripted>, store: SharedStore) -> SourceEnv {
    SourceEnv {
        source_id: "guo.yaguo".into(),
        transport,
        store: Arc::new(store),
        scripts: None,
        log: Arc::new(Quiet),
    }
}

#[test]
fn descriptor_declares_the_same_capabilities_as_compiled() {
    let meta = source().meta();
    assert_eq!(meta.id, "guo.yaguo");
    assert_eq!(meta.name, "芽果");
    for capability in [
        guo_source_api::Capability::Catalog,
        guo_source_api::Capability::Detail,
        guo_source_api::Capability::Search,
        guo_source_api::Capability::Categories,
        guo_source_api::Capability::Resolve,
    ] {
        assert!(meta.supports(capability), "{capability:?}");
    }
}

#[tokio::test]
async fn categories_and_catalog_round_trip() {
    let transport = Arc::new(Scripted::new());
    let env = env_with(transport, SharedStore::default());
    let src = source();

    let categories = src.categories(&env).await.expect("分类");
    assert!(!categories.is_empty());
    assert!(
        categories.iter().any(|item| item.id == "9"),
        "应含排行榜分类"
    );

    let page = src.catalog(&env, 1, "").await.expect("目录");
    assert!(!page.items.is_empty());
    let first = &page.items[0];
    assert_eq!(first.source, "guo.yaguo");
    assert!(first.id.starts_with("guo.yaguo:"));
}

#[tokio::test]
async fn token_is_reused_across_instances_via_host_storage() {
    let transport = Arc::new(Scripted::new());
    let store = SharedStore::default();

    // 第一个实例登录。
    let first = source();
    first
        .catalog(&env_with(transport.clone(), store.clone()), 1, "")
        .await
        .expect("首次目录");
    assert_eq!(transport.logins(), 1, "首次必须登录一次");

    // 第二个实例共享同一份宿主存储：不应再次登录。
    let second = source();
    second
        .catalog(&env_with(transport.clone(), store.clone()), 1, "")
        .await
        .expect("二次目录");
    assert_eq!(
        transport.logins(),
        1,
        "令牌在宿主存储里，第二个实例不应重新登录"
    );

    // 换一份空存储：必须重新登录。
    let third = source();
    third
        .catalog(&env_with(transport.clone(), SharedStore::default()), 1, "")
        .await
        .expect("第三次目录");
    assert_eq!(transport.logins(), 2, "新存储必须重新登录");
}

#[tokio::test]
async fn detail_and_resolve_use_the_stored_token() {
    let transport = Arc::new(Scripted::new());
    let store = SharedStore::default();
    let src = source();
    let env = env_with(transport.clone(), store.clone());

    let page = src.catalog(&env, 1, "").await.expect("目录");
    let source_id = page.items[0].source_id.clone();
    let detail = src.detail(&env, &source_id).await.expect("详情");
    assert!(!detail.chapters.is_empty());
    let chapter = detail.chapters[0].clone();
    assert!(!chapter.video_url.is_empty());

    let media = src
        .resolve(&env, &detail.drama, &chapter)
        .await
        .expect("取流");
    assert_eq!(media.url, chapter.video_url);
    // 芽果分集是直链，不需要 Cookie / Origin。
    assert!(media.cookies.is_empty());

    // 三次业务请求共用一次登录。
    assert_eq!(transport.logins(), 1);
}

#[tokio::test]
async fn empty_keyword_short_circuits_without_network() {
    let transport = Arc::new(Scripted::new());
    let env = env_with(transport.clone(), SharedStore::default());
    let page = source().search(&env, "   ", 1).await.expect("空搜索");
    assert!(page.items.is_empty());
    // 空关键词直接返回，连登录都不该触发。
    assert_eq!(transport.logins(), 0);
    assert!(transport.requests().is_empty());
}
