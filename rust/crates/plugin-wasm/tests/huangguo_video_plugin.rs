//! 黄果视频代码插件的端到端验证（Core-3 第五个迁移源）。
//!
//! 重点验证 **ADR-12 的提取原语**：插件不内嵌 HTML 解析器，
//! 全部解析走宿主的 `html_select`（CSS 选择器）。这组用例同时覆盖
//! 编译版既有的语义：卡片分类、无编号分集丢弃、单集页回退。

use std::sync::Arc;

use guo_plugin_wasm::{ComponentSource, SandboxLimits};
use guo_source_api::{
    Chapter, Drama, FetchRequest, FetchResponse, LogSink, SourceEnv, SourceError, SourcePlugin,
    SourceStore, Transport,
};

const VIDEO: &[u8] = include_bytes!("fixtures/huangguo_video.wasm");

const CATALOG: &str = r#"<html><body>
    <article class="video-card">
        <a href="/series/abc" title="剧集甲"><img data-src="/c/a.jpg"></a>
    </article>
    <article class="video-card">
        <a href="/video/xyz" title="单集乙"><img src="https://img.test/b.jpg"></a>
    </article>
    <article class="other"><a href="/series/skip">不应命中</a></article>
</body></html>"#;

const SERIES_DETAIL: &str = r#"<html><head><title>剧集甲 - 黄果视频</title>
    <meta name="description" content="剧集甲简介"></head><body>
    <h1>剧集甲</h1>
    <img property="og:image" content="https://img.test/cover.jpg">
    <article class="video-card"><a href="/video/1" title="第1集"><video data-hls="https://cdn.test/1.m3u8"></video></a></article>
    <article class="video-card"><a href="/video/2" title="第2集"><video data-hls="https://cdn.test/2.m3u8"></video></a></article>
    <article class="video-card"><a href="/video/rec">推荐位</a></article>
</body></html>"#;

struct Fixture {
    /// 按 `/series/` 与 `/videos` 分流。
    urls: std::sync::Mutex<Vec<String>>,
}

impl Fixture {
    fn urls(&self) -> Vec<String> {
        self.urls.lock().expect("urls").clone()
    }
}

#[async_trait::async_trait]
impl Transport for Fixture {
    async fn fetch(&self, request: FetchRequest) -> Result<FetchResponse, SourceError> {
        self.urls.lock().expect("urls").push(request.url.clone());
        let body = if request.url.contains("/series/") || request.url.contains("/video/") {
            SERIES_DETAIL
        } else {
            CATALOG
        };
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
        VIDEO,
        vec!["huangguo.video".into()],
        vec![],
        SandboxLimits::default(),
    )
    .expect("黄果视频组件应可加载")
}

fn env_with(transport: Arc<Fixture>) -> SourceEnv {
    SourceEnv {
        source_id: "guo.huangguo-video".into(),
        transport,
        store: Arc::new(NoStore),
        scripts: None,
        log: Arc::new(Quiet),
    }
}

#[test]
fn descriptor_matches_the_compiled_source() {
    let meta = source().meta();
    assert_eq!(meta.id, "guo.huangguo-video");
    assert_eq!(meta.name, "黄果视频");
    assert_eq!(meta.group, "huangguo");
    assert!(meta.supports(guo_source_api::Capability::Catalog));
    assert!(meta.supports(guo_source_api::Capability::Detail));
    // 编译版不声明搜索与分类，插件保持一致。
    assert!(!meta.supports(guo_source_api::Capability::Search));
    assert!(!meta.supports(guo_source_api::Capability::Categories));
}

#[tokio::test]
async fn catalog_parses_cards_through_host_extraction() {
    let transport = Arc::new(Fixture {
        urls: std::sync::Mutex::new(Vec::new()),
    });
    let env = env_with(transport.clone());
    let page = source().catalog(&env, 1, "").await.expect("目录");

    // `article.other` 不带 video-card，必须被排除。
    assert_eq!(page.items.len(), 2, "{:?}", page.items);
    assert_eq!(page.items[0].source, "guo.huangguo-video");
    assert!(page.items[0].id.starts_with("guo.huangguo-video:"));
    assert_eq!(page.items[0].category, "series");
    assert_eq!(page.items[1].category, "video");
    // 封面走宿主的属性读取并补全域名。
    assert!(
        page.items[0].cover.starts_with("https://"),
        "{}",
        page.items[0].cover
    );
    assert!(transport.urls()[0].contains("/videos?page=1"));
}

#[tokio::test]
async fn detail_reads_episodes_and_drops_unnumbered() {
    let transport = Arc::new(Fixture {
        urls: std::sync::Mutex::new(Vec::new()),
    });
    let env = env_with(transport.clone());
    let detail = source().detail(&env, "abc").await.expect("详情");

    // 有编号时丢弃无编号的推荐位，与编译版语义一致。
    assert_eq!(detail.chapters.len(), 2, "{:?}", detail.chapters);
    assert_eq!(detail.chapters[0].id, "1:1");
    assert_eq!(detail.chapters[0].video_url, "https://cdn.test/1.m3u8");
    assert!(detail.chapters[0].page_url.contains("/video/1"));
    assert_eq!(detail.drama.title, "剧集甲");
    // 请求的路径是 series/abc（自动归入 series）。
    assert!(transport.urls()[0].contains("/series/abc"));
}

#[tokio::test]
async fn resolve_passes_through_the_hls_url() {
    let transport = Arc::new(Fixture {
        urls: std::sync::Mutex::new(Vec::new()),
    });
    let env = env_with(transport);
    let drama = Drama {
        id: "guo.huangguo-video:abc".into(),
        source: "guo.huangguo-video".into(),
        source_id: "abc".into(),
        ..Default::default()
    };
    let chapter = Chapter {
        id: "abc:1".into(),
        title: "第1集".into(),
        video_url: "https://cdn.test/1.m3u8".into(),
        ..Default::default()
    };
    let media = source()
        .resolve(&env, &drama, &chapter)
        .await
        .expect("取流");
    assert_eq!(media.url, "https://cdn.test/1.m3u8");
    assert_eq!(media.referer, "https://huangguo.video/");
}

#[tokio::test]
async fn empty_detail_id_is_rejected() {
    let env = env_with(Arc::new(Fixture {
        urls: std::sync::Mutex::new(Vec::new()),
    }));
    let error = source()
        .detail(&env, "  ")
        .await
        .expect_err("空 id 必须拒绝");
    assert!(matches!(error, SourceError::Parse { .. }), "{error:?}");
}
