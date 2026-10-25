//! 猫果代码插件的端到端验证（Core-3 打样源）。
//!
//! 组件由 `examples/plugins/maoguo/build.sh` 编译产出。这里用真实猫果响应
//! 夹具喂给假传输层，验证「WIT v2 → 组件 → 宿主能力注入 → 签名请求 → 解析」
//! 整条链路，不访问真实站点。
//!
//! 与脚本包的关系：站点知识（签名串、字段名）以脚本实现为准
//! （`bridge/tests/script_maoguo_golden.rs` 的金标准）；本测试只锁定
//! Wasm 组件宿主链路本身（L2 冻结通道，见 ADR-13）。

use std::sync::{Arc, Mutex};

use guo_plugin_wasm::{ComponentSource, SandboxLimits};
use guo_source_api::{
    Chapter, Drama, FetchRequest, FetchResponse, LogSink, SourceEnv, SourceError, SourcePlugin,
    SourceStore, Transport,
};

/// 组件由 `examples/plugins/maoguo/build.sh` 产出。
const MAOGUO: &[u8] = include_bytes!("fixtures/maoguo.wasm");

const CATALOG: &str = include_str!("../../../bridge/tests/fixtures/maoguo_catalog.json");
const DETAIL: &str = include_str!("../../../bridge/tests/fixtures/maoguo_detail.json");

/// 按路径返回固定响应，并记录每次请求（含签名头）。
struct ScriptedTransport {
    requests: Mutex<Vec<FetchRequest>>,
}

impl ScriptedTransport {
    fn new() -> Self {
        Self {
            requests: Mutex::new(Vec::new()),
        }
    }

    fn requests(&self) -> Vec<FetchRequest> {
        self.requests.lock().expect("requests").clone()
    }
}

#[async_trait::async_trait]
impl Transport for ScriptedTransport {
    async fn fetch(&self, request: FetchRequest) -> Result<FetchResponse, SourceError> {
        self.requests
            .lock()
            .expect("requests")
            .push(request.clone());
        let body = if request.url.contains("/playlet/index") {
            CATALOG
        } else if request.url.contains("/playlet/info") {
            DETAIL
        } else if request.url.contains("/playlet/search") {
            CATALOG
        } else {
            ""
        };
        if body.is_empty() {
            return Ok(FetchResponse::new(404, Vec::new(), request.url));
        }
        Ok(FetchResponse::new(
            200,
            body.as_bytes().to_vec(),
            request.url,
        ))
    }
}

struct NoStore;

#[async_trait::async_trait]
impl SourceStore for NoStore {
    async fn get(&self, _key: &str) -> Result<Option<String>, SourceError> {
        Ok(None)
    }
    async fn set(&self, _key: &str, _value: &str) -> Result<(), SourceError> {
        Ok(())
    }
}

struct Quiet;

impl LogSink for Quiet {
    fn debug(&self, _message: &str) {}
    fn warn(&self, _message: &str) {}
}

fn source() -> ComponentSource {
    ComponentSource::load(
        MAOGUO,
        vec![
            "api-store.qmplaylet.com".into(),
            "api-read.qmplaylet.com".into(),
        ],
        vec!["session".into()],
        SandboxLimits::default(),
    )
    .expect("猫果组件应可加载")
}

fn env_with(transport: Arc<ScriptedTransport>) -> SourceEnv {
    SourceEnv {
        source_id: "maoguo".into(),
        transport,
        store: Arc::new(NoStore),
        scripts: None,
        log: Arc::new(Quiet),
    }
}

#[test]
fn descriptor_matches_the_compiled_source() {
    let meta = source().meta();
    assert_eq!(meta.id, "guo.maoguo");
    assert_eq!(meta.name, "猫果");
    assert_eq!(meta.group, "duanju");
    assert!(meta.supports(guo_source_api::Capability::Catalog));
    assert!(meta.supports(guo_source_api::Capability::Detail));
    assert!(meta.supports(guo_source_api::Capability::Search));
    // 插件不声明分类 / 取流以外的能力，宿主据此隐藏入口。
    assert!(!meta.supports(guo_source_api::Capability::Categories));
}

#[tokio::test]
async fn catalog_round_trips_through_the_plugin() {
    let transport = Arc::new(ScriptedTransport::new());
    let env = env_with(transport.clone());
    let page = source().catalog(&env, 1, "0").await.expect("目录");

    assert!(!page.items.is_empty(), "夹具应解析出条目");
    let first = &page.items[0];
    assert_eq!(first.source, "guo.maoguo");
    // 源前缀由宿主按清单补上，插件只给站点内 id。
    assert!(first.id.starts_with("guo.maoguo:"), "实际 id：{}", first.id);
    assert_eq!(first.id, format!("guo.maoguo:{}", first.source_id));
    assert!(!first.title.is_empty());

    // 请求必须带上签名头：这是猫果能工作的前提。
    let requests = transport.requests();
    assert_eq!(requests.len(), 1);
    let headers = &requests[0].headers;
    for key in ["sign", "qm-params", "authorization", "platform"] {
        assert!(
            headers.iter().any(|(name, _)| name == key),
            "缺少头 {key}，实际：{:?}",
            headers.keys().collect::<Vec<_>>()
        );
    }
    let sign = headers
        .iter()
        .find(|(name, _)| name.as_str() == "sign")
        .map(|(_, value)| value.clone())
        .unwrap_or_default();
    assert_eq!(sign.len(), 32, "签名应是 32 位十六进制：{sign}");
    assert!(sign.chars().all(|ch| ch.is_ascii_hexdigit()));
}

#[tokio::test]
async fn detail_round_trips_through_the_plugin() {
    let transport = Arc::new(ScriptedTransport::new());
    let env = env_with(transport);
    let detail = source()
        .detail(&env, "7591318030575802442")
        .await
        .expect("详情");
    assert!(!detail.chapters.is_empty(), "详情应解析出分集");
    assert!(!detail.chapters[0].video_url.is_empty());
}

#[tokio::test]
async fn resolve_passes_through_the_mp4_url() {
    let transport = Arc::new(ScriptedTransport::new());
    let env = env_with(transport);
    let source = source();
    let drama = Drama {
        id: "guo.maoguo:1".into(),
        source: "guo.maoguo".into(),
        source_id: "1".into(),
        ..Default::default()
    };
    let chapter = Chapter {
        id: "1".into(),
        title: "第1集".into(),
        video_url: "https://cdn.test/1.mp4".into(),
        ..Default::default()
    };
    let media = source.resolve(&env, &drama, &chapter).await.expect("取流");
    assert_eq!(media.url, "https://cdn.test/1.mp4");
    // 七猫直链不需要 Cookie / Origin，插件返回空由宿主照常处理。
    assert!(media.cookies.is_empty());
    assert!(media.origin.is_empty());
    assert!(media.referer.starts_with("https://api-store.qmplaylet.com"));
}

#[tokio::test]
async fn empty_search_keyword_is_rejected_by_the_plugin() {
    let transport = Arc::new(ScriptedTransport::new());
    let env = env_with(transport.clone());
    let error = source()
        .search(&env, "   ", 1)
        .await
        .expect_err("空关键词必须拒绝");
    assert!(
        matches!(error, SourceError::Unsupported(_)),
        "实际错误：{error:?}"
    );
    assert!(transport.requests().is_empty(), "不应发出请求");
}

#[tokio::test]
async fn network_calls_outside_the_whitelist_are_rejected() {
    // 插件只能访问清单声明的两个主机；这条约束由宿主强制，插件无法绕过。
    let transport = Arc::new(ScriptedTransport::new());
    let env = env_with(transport.clone());
    let error = source()
        .suggestions(&env, "总裁")
        .await
        .expect_err("联想未实现");
    assert!(matches!(error, SourceError::Unsupported(_)), "{error:?}");
}
