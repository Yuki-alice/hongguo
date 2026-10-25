//! 芽果的真实网络验证（默认忽略）。
//!
//! ```sh
//! cargo test -p guo_engine --test yaguo_live -- --ignored --nocapture
//! ```
//!
//! 离线夹具（`yaguo_fixtures.rs`）证明脚本行为没变，证明不了「站点还认
//! 这套请求」；登录令牌、401 刷新这类会话行为必须真网验证。
//! 历史教训见 maoguo_live.rs：结论进文档前先跑它。

use std::sync::Arc;

use guo_engine::{
    placeholder_env, HttpTransport, LogSink, ScriptLimits, ScriptSource, SourceEnv, SourcePlugin,
    SourceStore,
};
use guo_host::DEFAULT_USER_AGENT;

const SCRIPT: &str = include_str!("../../examples/extensions/yaguo/main.js");

/// 清单 `[permissions] network`：业务域 + 登录域。
fn network() -> Vec<String> {
    vec!["app.whjzjx.cn".to_string(), "u.shytkjgs.com".to_string()]
}

fn script_source() -> ScriptSource {
    ScriptSource::load(
        &placeholder_env(),
        SCRIPT,
        ScriptLimits::default(),
        network(),
    )
    .expect("芽果脚本必须能加载")
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
        source_id: "yaguo".into(),
        transport: Arc::new(HttpTransport::new(DEFAULT_USER_AGENT).expect("transport")),
        store: Arc::new(NoopStore),
        scripts: None,
        log: Arc::new(NoopLog),
    }
}

#[tokio::test]
#[ignore = "需要外网，手动执行：cargo test --test yaguo_live -- --ignored"]
async fn categories_live_return_top_level_groups() {
    let categories = script_source().categories(&env()).await.expect("在线分类");
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
    let source = script_source();
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
    let page = script_source()
        .search(&env(), "豪门", 1)
        .await
        .expect("在线搜索");
    assert!(!page.items.is_empty(), "搜索「豪门」应有结果");
}
