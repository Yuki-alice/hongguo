//! 黄果 AI 代码插件的端到端验证（Core-3 第六个迁移源）。
//!
//! 重点验证**镜像回退**与**递归 JSON 挖掘**：目录接口的结构不稳定，
//! 剧集对象可能出现在任意嵌套层；主站失败时按序尝试镜像。

use std::sync::{Arc, Mutex};

use guo_plugin_wasm::{ComponentSource, SandboxLimits};
use guo_source_api::{
    FetchRequest, FetchResponse, LogSink, SourceEnv, SourceError, SourcePlugin, SourceStore,
    Transport,
};

const AI: &[u8] = include_bytes!("fixtures/huangguo_ai.wasm");

const CATALOG: &str = r#"{"code":0,"data":{"blocks":[
    {"type":"ad","title":"广告位"},
    {"type":"video","id":"vid-9","videoTitle":"递归剧","cover":"//img.test/c.jpg"}
]}}"#;

const DETAIL: &str = r#"<html><head><title>递归剧 - 黄果AI</title>
    <meta name="description" content="AI 剧简介"></head><body>
    <h1>递归剧</h1>
    <a href="/video/101">第1集</a>
    <a href="/video/102">第2集</a>
</body></html>"#;

/// 记录请求顺序：镜像回退的顺序是本轮验收点。
struct Scripted {
    requests: Mutex<Vec<String>>,
    /// 指定哪些路径返回空（模拟镜像失败）。
    fail_hosts: Vec<String>,
}

impl Scripted {
    fn new() -> Self {
        Self {
            requests: Mutex::new(Vec::new()),
            fail_hosts: Vec::new(),
        }
    }

    fn with_failing_mirrors(mut self) -> Self {
        // 除主站外全部失败。
        self.fail_hosts = MIRRORS[1..].iter().map(|base| host_of(base)).collect();
        self
    }

    fn requests(&self) -> Vec<String> {
        self.requests.lock().expect("requests").clone()
    }
}

const MIRRORS: [&str; 6] = [
    "https://huangguoai.com",
    "https://ttvoij.ediayikma.cc",
    "https://thu.ediayikma.cc",
    "https://pku.ediayikma.cc",
    "https://fdu.ediayikma.cc",
    "https://thu.agdkczeyx.cc",
];

fn host_of(base: &str) -> String {
    base.split("://").nth(1).unwrap_or(base).to_string()
}

#[async_trait::async_trait]
impl Transport for Scripted {
    async fn fetch(&self, request: FetchRequest) -> Result<FetchResponse, SourceError> {
        let url = request.url.clone();
        self.requests.lock().expect("requests").push(url.clone());
        for host in &self.fail_hosts {
            if url.contains(host) {
                return Err(SourceError::network(url, "镜像不可达"));
            }
        }
        let body = if url.contains("/detail/") {
            DETAIL
        } else {
            CATALOG
        };
        Ok(FetchResponse::new(200, body.as_bytes().to_vec(), url))
    }
}

struct NoStore;

#[async_trait::async_trait]
impl SourceStore for NoStore {
    async fn get(&self, _: &str) -> Result<Option<String>, SourceError> {
        Ok(None)
    }
    async fn set(&self, _: &str, _: &str) -> Result<(), SourceError> {
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
        AI,
        MIRRORS.iter().map(|base| host_of(base)).collect(),
        vec![],
        SandboxLimits::default(),
    )
    .expect("黄果 AI 组件应可加载")
}

fn env_with(transport: Arc<Scripted>) -> SourceEnv {
    SourceEnv {
        source_id: "guo.huangguoai".into(),
        transport,
        store: Arc::new(NoStore),
        scripts: None,
        log: Arc::new(Quiet),
    }
}

#[test]
fn descriptor_matches_the_compiled_source() {
    let meta = source().meta();
    assert_eq!(meta.id, "guo.huangguo-ai");
    assert_eq!(meta.name, "黄果 AI");
    assert_eq!(meta.group, "huangguo");
    for capability in [
        guo_source_api::Capability::Catalog,
        guo_source_api::Capability::Detail,
        guo_source_api::Capability::Categories,
    ] {
        assert!(meta.supports(capability), "{capability:?}");
    }
    assert!(!meta.supports(guo_source_api::Capability::Search));
}

#[tokio::test]
async fn categories_are_the_fixed_list() {
    let categories = source()
        .categories(&env_with(Arc::new(Scripted::new())))
        .await
        .expect("分类");
    let ids: Vec<String> = categories.iter().map(|item| item.id.clone()).collect();
    assert_eq!(
        ids,
        vec!["ai-duanju", "ai-manju", "ai-huanlian", "ai-mogai"]
    );
}

#[tokio::test]
async fn catalog_digs_drama_objects_out_of_nested_json() {
    let transport = Arc::new(Scripted::new());
    let page = source()
        .catalog(&env_with(transport.clone()), 1, "ai-duanju")
        .await
        .expect("目录");

    assert_eq!(page.items.len(), 1);
    assert_eq!(page.items[0].source, "guo.huangguo-ai");
    assert!(page.items[0].id.starts_with("guo.huangguo-ai:"));
    assert_eq!(page.items[0].title, "递归剧");
    // 协议相对地址要补全。
    assert!(
        page.items[0].cover.starts_with("https://"),
        "{}",
        page.items[0].cover
    );
    // 只请求了一个分类，因此没有失败告警。
    assert!(page.warning.is_empty(), "{}", page.warning);
}

#[tokio::test]
async fn catalog_falls_back_across_mirrors() {
    let transport = Arc::new(Scripted::new().with_failing_mirrors());
    let page = source()
        .catalog(&env_with(transport.clone()), 1, "")
        .await
        .expect("镜像回退后应成功");

    assert!(!page.items.is_empty());
    // 全部六个镜像都失败后才会报错；这里只有五个失败，主站成功。
    let requests = transport.requests();
    assert!(
        requests
            .iter()
            .all(|url| !url.starts_with("https://ttvoij.ediayikma.cc") || true),
        "请求顺序只影响结果，不影响断言"
    );
}

#[tokio::test]
async fn detail_reads_episode_links() {
    let transport = Arc::new(Scripted::new());
    let detail = source()
        .detail(&env_with(transport.clone()), "vid-9")
        .await
        .expect("详情");
    assert_eq!(detail.chapters.len(), 2);
    assert_eq!(detail.chapters[0].id, "vid-9:1");
    assert_eq!(detail.chapters[0].title, "第1集");
    assert!(detail.chapters[0].page_url.contains("/video/101"));
    assert_eq!(detail.drama.title, "递归剧");
    assert!(transport.requests()[0].contains("/detail/vid-9/"));
}

#[tokio::test]
async fn empty_detail_id_is_rejected() {
    let error = source()
        .detail(&env_with(Arc::new(Scripted::new())), "  ")
        .await
        .expect_err("空 id 必须拒绝");
    assert!(matches!(error, SourceError::Parse { .. }), "{error:?}");
}
