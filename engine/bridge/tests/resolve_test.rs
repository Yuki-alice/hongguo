//! 取流链路的离线测试：用假传输层模拟播放页与 HLS。

use async_trait::async_trait;
use guo_engine::{
    builtin_registry, FetchRequest, FetchResponse, RuleSource, SourceEnv, SourceError,
    SourcePlugin, SourceStore, Transport,
};
use std::sync::Arc;

struct StaticTransport {
    playlist_body: &'static str,
    page_body: &'static str,
}

#[async_trait]
impl Transport for StaticTransport {
    async fn fetch(&self, request: FetchRequest) -> Result<FetchResponse, SourceError> {
        let (body, status) = if request.url.contains(".m3u8") {
            (self.playlist_body, 200)
        } else {
            (self.page_body, 200)
        };
        let mut bytes = body.as_bytes().to_vec();
        let mut truncated = false;
        if let Some(limit) = request.max_bytes {
            if (bytes.len() as u64) > limit {
                bytes.truncate(limit as usize);
                truncated = true;
            }
        }
        let mut response = FetchResponse::new(status, bytes, request.url);
        response.truncated = truncated;
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
impl guo_engine::LogSink for NoopLog {
    fn debug(&self, _: &str) {}
    fn warn(&self, _: &str) {}
}

const RULE: &str = r#"{
    "schema": "1.0",
    "id": "fixture",
    "name": "夹具",
    "base": "https://site.test",
    "catalog": { "url": "list/{page}.html", "item": "a.x" },
    "detail": { "url": "play/{id}.html", "episodes": "a[href*='/ep/']" }
}"#;

fn env(playlist: &'static str, page: &'static str) -> SourceEnv {
    SourceEnv {
        source_id: "fixture".into(),
        transport: Arc::new(StaticTransport {
            playlist_body: playlist,
            page_body: page,
        }),
        store: Arc::new(NoopStore {}),
        scripts: None,
        log: Arc::new(NoopLog {}),
    }
}

fn drama() -> guo_engine::Drama {
    guo_engine::Drama {
        id: "fixture:1".into(),
        source: "fixture".into(),
        source_id: "1".into(),
        title: "样本".into(),
        ..Default::default()
    }
}

fn chapter(video_url: &str, page_url: &str) -> guo_engine::Chapter {
    guo_engine::Chapter {
        id: "fixture:1:1".into(),
        title: "第1集".into(),
        source: "fixture".into(),
        video_url: video_url.into(),
        page_url: page_url.into(),
        ..Default::default()
    }
}

#[tokio::test]
async fn direct_mp4_returns_immediately() {
    let source = RuleSource::from_json(RULE).expect("rule");
    let media = source
        .resolve(
            &env("#EXTM3U", ""),
            &drama(),
            &chapter("https://cdn.test/a.mp4", ""),
        )
        .await
        .expect("resolve");
    assert_eq!(media.url, "https://cdn.test/a.mp4");
    assert!(media.playlist.is_none());
}

#[tokio::test]
async fn hls_returns_segment_list() {
    let playlist = "#EXTM3U\n#EXTINF:10,\nseg0.ts\n#EXTINF:10,\nseg1.ts\n";
    let source = RuleSource::from_json(RULE).expect("rule");
    let media = source
        .resolve(
            &env(playlist, ""),
            &drama(),
            &chapter("https://cdn.test/hls/index.m3u8", ""),
        )
        .await
        .expect("resolve");
    let segments = media.playlist.expect("segments");
    assert_eq!(segments.len(), 2);
    assert_eq!(segments[0], "https://cdn.test/hls/seg0.ts");
}

#[tokio::test]
async fn invalid_playlist_is_reported() {
    let source = RuleSource::from_json(RULE).expect("rule");
    let err = source
        .resolve(
            &env("<html>登录后可见</html>", ""),
            &drama(),
            &chapter("https://cdn.test/hls/index.m3u8", ""),
        )
        .await
        .expect_err("must fail");
    assert!(err.to_string().contains("M3U8"), "{err}");
}

#[tokio::test]
async fn page_url_is_scraped_for_media() {
    let page = r#"<script>var player_aaaa={"url":"https:\/\/cdn.test\/x\/index.m3u8"}</script>"#;
    let playlist = "#EXTM3U\n#EXTINF:5,\nseg.ts\n";
    let source = RuleSource::from_json(RULE).expect("rule");
    let media = source
        .resolve(
            &env(playlist, page),
            &drama(),
            &chapter("", "https://site.test/play/1.html"),
        )
        .await
        .expect("resolve");
    assert_eq!(media.url, "https://cdn.test/x/index.m3u8");
    assert_eq!(media.playlist.expect("segments").len(), 1);
}

#[tokio::test]
async fn page_without_media_reports_error() {
    let source = RuleSource::from_json(RULE).expect("rule");
    let err = source
        .resolve(
            &env("", "<html>无视频</html>"),
            &drama(),
            &chapter("", "https://site.test/play/1.html"),
        )
        .await
        .expect_err("must fail");
    assert!(err.to_string().contains("媒体地址"), "{err}");
}

#[test]
fn registry_exposes_resolve_capability_only_when_rule_declares_it() {
    let with_resolve = RuleSource::from_json(
        r#"{"schema":"1.0","id":"a","name":"A","base":"https://a.test",
            "catalog":{"url":"x","item":"a"},
            "detail":{"episodes":"a"},
            "resolve":{"playerVar":"player_aaaa"}}"#,
    )
    .expect("rule");
    assert!(with_resolve
        .meta()
        .supports(guo_engine::Capability::Resolve));

    let registry = builtin_registry();
    for meta in registry.metas() {
        assert!(meta.api_level >= 1);
    }
}
