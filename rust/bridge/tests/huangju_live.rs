//! 剧果的真实网络验证（默认忽略）。
//!
//! ```sh
//! cargo test -p guo_engine --test huangju_live -- --ignored --nocapture
//! ```
//!
//! **取流一条依赖媒体域可达**：`video.huangju.net` 是独立 CDN，
//! 2026-10-21 在本机网络下无法连接（`huangju.net` 与 `api.huangju.net`
//! 均正常）。因此该用例验证到「拿到带签名 Cookie 的 m3u8 地址」为止，
//! 不追拉分片。

use std::sync::Arc;

use guo_engine::{
    placeholder_env, HttpTransport, LogSink, ScriptLimits, ScriptSource, SourceEnv, SourcePlugin,
    SourceStore,
};
use guo_host::DEFAULT_USER_AGENT;

const SCRIPT: &str = include_str!("../../examples/extensions/huangju/main.js");

/// 清单 `[permissions] network`。
fn network() -> Vec<String> {
    vec!["api.huangju.net".to_string()]
}

fn script_source() -> ScriptSource {
    ScriptSource::load(
        &placeholder_env(),
        SCRIPT,
        ScriptLimits::default(),
        network(),
    )
    .expect("剧果脚本必须能加载")
}

struct NoopStore;
#[async_trait::async_trait]
impl SourceStore for NoopStore {
    async fn get(&self, _: &str) -> Result<Option<String>, guo_engine::SourceError> {
        Ok(None)
    }
    async fn set(&self, _: &str, _: &str) -> Result<(), guo_engine::SourceError> {
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
        source_id: "huangju".into(),
        transport: Arc::new(HttpTransport::new(DEFAULT_USER_AGENT).expect("transport")),
        store: Arc::new(NoopStore),
        scripts: None,
        log: Arc::new(NoopLog),
    }
}

#[tokio::test]
#[ignore = "需要外网，手动执行：cargo test --test huangju_live -- --ignored"]
async fn catalog_live_returns_items_with_slug_ids() {
    let page = script_source()
        .catalog(&env(), 1, "")
        .await
        .expect("在线目录");
    assert!(!page.items.is_empty(), "在线目录不应为空");
    for item in &page.items {
        assert!(!item.title.trim().is_empty(), "条目缺少标题：{item:?}");
        assert!(
            !item.source_id.is_empty() && item.source_id != item.title,
            "主键应是 slug：{item:?}"
        );
    }
}

#[tokio::test]
#[ignore = "需要外网，手动执行：cargo test --test huangju_live -- --ignored"]
async fn detail_and_resolve_live_yield_signed_media_url() {
    let source = script_source();
    // 列表里会出现已下架的条目（详情返回 404），逐个尝试直到拿到可用的一条。
    let page = source.catalog(&env(), 1, "").await.expect("在线目录");
    let mut detail = None;
    for drama in page.items.iter().take(6) {
        if let Ok(found) = source.detail(&env(), &drama.source_id).await {
            if !found.chapters.is_empty() {
                detail = Some(found);
                break;
            }
        }
    }
    let detail = detail.expect("前 6 条里应有可用的详情");
    assert!(!detail.chapters.is_empty(), "详情应有分集");

    let media = source
        .resolve(&env(), &detail.drama, &detail.chapters[0])
        .await
        .expect("在线取流");
    assert!(media.url.starts_with("https://"), "{}", media.url);
    assert!(
        media.cookies.contains("CloudFront-Policy"),
        "媒体域需要签名 Cookie，实际：{}",
        media.cookies
    );
}
