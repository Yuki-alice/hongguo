//! 芽果的真实网络验证（默认忽略）。
//!
//! ```sh
//! cargo test -p guo_engine --test yaguo_live -- --ignored --nocapture
//! ```

use std::sync::Arc;

use guo_engine::{HttpTransport, LogSink, SourceEnv, SourcePlugin, SourceStore, YaguoSource};

const USER_AGENT: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

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
        source_id: "yaguo".into(),
        transport: Arc::new(HttpTransport::new(USER_AGENT).expect("transport")),
        store: Arc::new(NoopStore),
        scripts: None,
        log: Arc::new(NoopLog),
    }
}

#[tokio::test]
#[ignore = "需要外网，手动执行：cargo test --test yaguo_live -- --ignored"]
async fn categories_live_return_top_level_groups() {
    let source = YaguoSource::new();
    let categories = source.categories(&env()).await.expect("在线分类");
    assert!(
        categories.iter().any(|category| category.name == "剧场"),
        "分类里应有剧场：{categories:?}"
    );
    assert!(
        categories.iter().any(|category| category.id == "9"),
        "分类里应有排行榜：{categories:?}"
    );
}

#[tokio::test]
#[ignore = "需要外网，手动执行：cargo test --test yaguo_live -- --ignored"]
async fn catalog_detail_and_resolve_live_yield_playable_url() {
    let source = YaguoSource::new();
    let env = env();
    let page = source.catalog(&env, 1, "").await.expect("在线目录");
    assert!(!page.items.is_empty(), "在线目录不应为空");
    let drama = page
        .items
        .iter()
        .find(|item| !item.title.trim().is_empty())
        .expect("目录应有可用条目");

    let detail = source
        .detail(&env, &drama.source_id)
        .await
        .expect("在线详情");
    assert!(!detail.chapters.is_empty(), "详情应有分集");

    let media = source
        .resolve(&env, &detail.drama, &detail.chapters[0])
        .await
        .expect("在线取流");
    assert!(
        media.url.starts_with("http://") || media.url.starts_with("https://"),
        "取流应返回可播放地址：{}",
        media.url
    );
}

#[tokio::test]
#[ignore = "需要外网，手动执行：cargo test --test yaguo_live -- --ignored"]
async fn search_live_finds_results() {
    let source = YaguoSource::new();
    let page = source.search(&env(), "豪门", 1).await.expect("在线搜索");
    assert!(!page.items.is_empty(), "搜索「豪门」应有结果");
}
