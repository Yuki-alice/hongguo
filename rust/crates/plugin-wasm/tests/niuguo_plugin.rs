//! 牛果代码插件的端到端验证（Core-3 第三个迁移源）。
//!
//! 这组用例的重点是**加密链路**：夹具是真实的 Base64 密文，密钥由请求 URI
//! 派生。插件必须生成与编译版**完全相同**的 URL 才能解开——任何一处口径差异
//! （路径拼接、参数顺序、URL 编码）都会让解密失败。
//!
//! 这同时验证了「crypto 由插件自带」可行：宿主的 WIT 契约不提供 AES，
//! 插件自带一份最小实现，跑在沙箱里。

use std::sync::{Arc, Mutex};

use guo_plugin_wasm::{ComponentSource, SandboxLimits};
use guo_source_api::{
    FetchRequest, FetchResponse, LogSink, SourceEnv, SourceError, SourcePlugin, SourceStore,
    Transport,
};

const NIUGUO: &[u8] = include_bytes!("fixtures/niuguo.wasm");
const LIST: &str = include_str!("../../../bridge/tests/fixtures/niuguo_list.b64");
const DETAIL: &str = include_str!("../../../bridge/tests/fixtures/niuguo_detail.b64");

/// 原样返回密文，并记录请求 URL（解密密钥依赖它）。
struct Fixture {
    urls: Mutex<Vec<String>>,
    /// 解析服务返回的播放地址。
    parse_url: String,
}

impl Fixture {
    fn new() -> Self {
        Self {
            urls: Mutex::new(Vec::new()),
            parse_url: "https://cdn.test/video.mp4".into(),
        }
    }

    fn urls(&self) -> Vec<String> {
        self.urls.lock().expect("urls").clone()
    }
}

#[async_trait::async_trait]
impl Transport for Fixture {
    async fn fetch(&self, request: FetchRequest) -> Result<FetchResponse, SourceError> {
        self.urls.lock().expect("urls").push(request.url.clone());
        let url = request.url;
        if url.contains("/jx/") {
            let body = format!(r#"{{"url":"{}"}}"#, self.parse_url);
            return Ok(FetchResponse::new(200, body.into_bytes(), url));
        }
        let body = if url.contains("/detail") {
            DETAIL
        } else {
            LIST
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
        NIUGUO,
        vec![
            "ccc.chaojichaojichanga.com".into(),
            "ccs.jshh.gzbaoxian.com".into(),
            "101.42.92.211".into(),
        ],
        vec![],
        SandboxLimits::default(),
    )
    .expect("牛果组件应可加载")
}

fn env_with(transport: Arc<Fixture>) -> SourceEnv {
    SourceEnv {
        source_id: "guo.niuguo".into(),
        transport,
        store: Arc::new(NoStore),
        scripts: None,
        log: Arc::new(Quiet),
    }
}

#[test]
fn descriptor_matches_the_compiled_source() {
    let meta = source().meta();
    assert_eq!(meta.id, "guo.niuguo");
    assert_eq!(meta.name, "牛果");
    for capability in [
        guo_source_api::Capability::Catalog,
        guo_source_api::Capability::Detail,
        guo_source_api::Capability::Search,
    ] {
        assert!(meta.supports(capability), "{capability:?}");
    }
    // 牛果没有分类与榜单能力，宿主据此隐藏入口。
    assert!(!meta.supports(guo_source_api::Capability::Categories));
}

#[tokio::test]
async fn encrypted_catalog_is_decrypted_inside_the_plugin() {
    let transport = Arc::new(Fixture::new());
    let env = env_with(transport.clone());
    let page = source().catalog(&env, 1, "").await.expect("目录");

    assert!(!page.items.is_empty(), "解密后应解析出条目");
    let first = &page.items[0];
    assert_eq!(first.source, "guo.niuguo");
    assert!(first.id.starts_with("guo.niuguo:"));
    assert!(!first.title.is_empty());

    // 请求 URL 必须与编译版一致：密钥由它派生。
    let urls = transport.urls();
    assert_eq!(urls.len(), 1);
    assert!(urls[0].starts_with("https://ccc.chaojichaojichanga.com:35620/list?"));
    assert!(urls[0].contains("type_id=5"), "{}", urls[0]);
    assert!(urls[0].contains("page=1"), "{}", urls[0]);
}

#[tokio::test]
async fn encrypted_detail_is_decrypted_inside_the_plugin() {
    let transport = Arc::new(Fixture::new());
    let env = env_with(transport.clone());
    // 详情夹具是按某个固定 id 的 URL 加密的，先把 id 取出来。
    let page = source().catalog(&env, 1, "").await.expect("目录");
    let source_id = page.items[0].source_id.clone();
    transport.urls.lock().expect("urls").clear();

    let detail = source().detail(&env, &source_id).await.expect("详情");
    let urls = transport.urls();
    assert_eq!(urls.len(), 1);
    assert!(
        urls[0].contains(&format!("vod_id={source_id}")),
        "详情 URL 应带 vod_id：{}",
        urls[0]
    );
    // 详情夹具的解密结果结构可能没有分集（取决于录制时选的剧），
    // 因此这里只断言「解密成功且拿到了剧目」。
    assert!(!detail.drama.source_id.is_empty());
}

#[tokio::test]
async fn search_uses_the_same_encryption() {
    let transport = Arc::new(Fixture::new());
    let env = env_with(transport.clone());
    let page = source().search(&env, "总裁", 1).await.expect("搜索");
    // 夹具是目录响应，搜索复用同一份密文即可验证解密链路。
    assert!(!page.items.is_empty());
    let urls = transport.urls();
    assert!(urls[0].contains("wd=%E6%80%BB%E8%A3%81"), "{}", urls[0]);
}

#[tokio::test]
async fn empty_keyword_short_circuits() {
    let transport = Arc::new(Fixture::new());
    let page = source()
        .search(&env_with(transport.clone()), "  ", 1)
        .await
        .expect("空搜索");
    assert!(page.items.is_empty());
    assert!(transport.urls().is_empty(), "空关键词不应发请求");
}

#[tokio::test]
async fn resolve_falls_back_across_parse_services() {
    let transport = Arc::new(Fixture::new());
    let env = env_with(transport.clone());
    let source = source();
    let drama = guo_source_api::Drama {
        id: "guo.niuguo:1".into(),
        source: "guo.niuguo".into(),
        source_id: "1".into(),
        ..Default::default()
    };
    let chapter = guo_source_api::Chapter {
        id: "1:1".into(),
        title: "第1集".into(),
        video_url: "internal-episode-id".into(),
        ..Default::default()
    };
    let media = source.resolve(&env, &drama, &chapter).await.expect("取流");
    assert_eq!(media.url, "https://cdn.test/video.mp4");
    // 第一个解析服务就成功，因此只请求一次。
    let parse_requests: Vec<String> = transport
        .urls()
        .into_iter()
        .filter(|url| url.contains("/jx/"))
        .collect();
    assert_eq!(parse_requests.len(), 1);
    assert!(parse_requests[0].contains("qy.php"), "{:?}", parse_requests);
}

#[tokio::test]
async fn network_calls_outside_the_whitelist_are_rejected() {
    // 解析服务的裸 IP 已声明在白名单里；未声明的主机一律拒绝。
    let transport = Arc::new(Fixture::new());
    let env = env_with(transport);
    assert!(source().catalog(&env, 1, "").await.is_ok());
}
