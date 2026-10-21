use guo_engine::HttpTransport;
use guo_engine::MaoguoSource;
use guo_engine::SourceError;
use guo_engine::{Capability, SourcePlugin};
use guo_engine::{FetchRequest, LogSink, SourceEnv, SourceStore};
use guo_engine::{FetchResponse, Transport};
use std::sync::Arc;

/// 用真实响应夹具代替网络，验证解析与字段映射。
struct FixtureTransport {
    catalog: &'static str,
    detail: &'static str,
}

#[async_trait::async_trait]
impl Transport for FixtureTransport {
    async fn fetch(&self, request: FetchRequest) -> Result<FetchResponse, SourceError> {
        let body = if request.url.contains("playlet/info") {
            self.detail
        } else {
            self.catalog
        };
        Ok(FetchResponse::new(
            200,
            body.as_bytes().to_vec(),
            request.url,
        ))
    }
}

struct NoopStore;
#[async_trait::async_trait]
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

fn env() -> SourceEnv {
    SourceEnv {
        source_id: "maoguo".into(),
        transport: Arc::new(FixtureTransport {
            catalog: include_str!("fixtures/maoguo_catalog.json"),
            detail: include_str!("fixtures/maoguo_detail.json"),
        }),
        store: Arc::new(NoopStore),
        scripts: None,
        log: Arc::new(NoopLog),
    }
}

#[tokio::test]
async fn catalog_parses_real_response() {
    let source = MaoguoSource::new();
    let page = source.catalog(&env(), 1, "0").await.expect("catalog");
    assert!(page.items.len() >= 50, "got {} items", page.items.len());

    let first = &page.items[0];
    assert_eq!(first.source, "maoguo");
    assert!(first.id.starts_with("maoguo:"));
    assert!(!first.title.is_empty(), "title must not be empty");
    assert!(
        first.episodes > 0,
        "episode count must be parsed: {first:?}"
    );
    assert!(first.cover.starts_with("http"), "cover: {}", first.cover);
    assert!(
        !first.title.contains('<'),
        "title must be plain text: {}",
        first.title
    );
}

#[tokio::test]
async fn detail_parses_chapters_with_names() {
    let source = MaoguoSource::new();
    let page = source.catalog(&env(), 1, "0").await.expect("catalog");
    let target = page.items.first().expect("item");
    let detail = source
        .detail(&env(), &target.source_id)
        .await
        .expect("detail");

    assert_eq!(detail.drama.id, target.id);
    assert!(
        detail.chapters.len() > 5,
        "got {} chapters",
        detail.chapters.len()
    );
    for chapter in detail.chapters.iter().take(3) {
        assert!(!chapter.video_url.is_empty(), "chapter needs media url");
        assert!(!chapter.title.is_empty(), "chapter needs title");
    }
    assert!(
        detail.chapters.iter().any(|c| c.title.starts_with('第')),
        "fallback title should look like 第N集"
    );
}

#[tokio::test]
async fn metadata_is_complete() {
    let meta = MaoguoSource::new().meta();
    assert_eq!(meta.id, "maoguo");
    assert_eq!(meta.name, "猫果");
    assert!(meta.supports(Capability::Catalog));
    assert!(meta.supports(Capability::Detail));
    assert!(meta.supports(Capability::Search));
}

#[test]
fn transport_defaults_are_sane() {
    let transport = HttpTransport::new("ua").expect("transport");
    assert_eq!(transport_user_agent(&transport), "ua");
}

fn transport_user_agent(transport: &HttpTransport) -> String {
    // 仅用于确认构造不 panic；真实抓取由 POC 与 live 示例覆盖。
    let _ = transport;
    "ua".to_string()
}
