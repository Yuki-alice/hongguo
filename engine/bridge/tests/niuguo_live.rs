//! 牛果的真实网络验证（默认忽略）。
//!
//! 牛果比其他站源多两层外部依赖：AES 密钥绑定实际请求 URI，播放地址还要
//! 再经第三方解析服务。这两点无法用离线夹具证明，因此保留在线用例：
//!
//! ```sh
//! cargo test -p guo_engine --test niuguo_live -- --ignored --nocapture
//! ```
//!
//! **取流一条依赖第三方解析服务**（`ccs.jshh.gzbaoxian.com` /
//! `101.42.92.211:5560`）。2026-10-21 实测两个域名均连接超时，那是服务方
//! 的问题，不是本站源的缺陷；目录与详情只用牛果自己的接口，不受影响。

use std::sync::Arc;

use guo_engine::{
    HttpTransport, LogSink, NiuguoSource, SourceEnv, SourcePlugin, SourceStore, DEFAULT_USER_AGENT,
};

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
        source_id: "niuguo".into(),
        transport: Arc::new(HttpTransport::new(DEFAULT_USER_AGENT).expect("transport")),
        store: Arc::new(NoopStore),
        scripts: None,
        log: Arc::new(NoopLog),
    }
}

#[tokio::test]
#[ignore = "需要外网，手动执行：cargo test --test niuguo_live -- --ignored"]
async fn catalog_live_decrypts_and_returns_items() {
    let source = NiuguoSource::new();
    let page = source.catalog(&env(), 1, "").await.expect("在线目录");
    assert!(!page.items.is_empty(), "在线目录不应为空");
    for item in &page.items {
        assert!(!item.title.trim().is_empty(), "条目缺少标题：{item:?}");
        assert!(!item.source_id.is_empty());
    }
}

#[tokio::test]
#[ignore = "需要外网 + 第三方解析服务在线，手动执行：cargo test --test niuguo_live -- --ignored"]
async fn detail_and_resolve_live_produce_a_media_url() {
    let source = NiuguoSource::new();
    let page = source.catalog(&env(), 1, "").await.expect("在线目录");
    let drama = page.items.first().expect("至少一条").clone();
    let detail = source
        .detail(&env(), &drama.source_id)
        .await
        .expect("在线详情");
    assert!(!detail.chapters.is_empty(), "详情应有分集");

    let chapter = &detail.chapters[0];
    let media = source
        .resolve(&env(), &detail.drama, chapter)
        .await
        .expect("在线取流");
    assert!(
        media.url.starts_with("http"),
        "取到的应是可播地址：{}",
        media.url
    );
}
