//! 临时验证：Rust 侧弹幕全链路（评论签名 + 新解析）。

use std::sync::Arc;
use guo_engine::{HongguoSource, SourceEnv};
use guo_source_api::{Chapter, SourcePlugin};

struct S; struct L;
#[async_trait::async_trait]
impl guo_engine::SourceStore for S {
    async fn get(&self,_:&str)->Result<Option<String>,guo_engine::SourceError>{Ok(None)}
    async fn set(&self,_:&str,_:&str)->Result<(),guo_engine::SourceError>{Ok(())}
}
impl guo_engine::LogSink for L { fn debug(&self,_:&str){} fn warn(&self,_:&str){} }

#[tokio::main]
async fn main() {
    let env = SourceEnv {
        source_id:"hongguo".into(),
        transport: guo_engine::HttpTransport::shared(guo_engine::DEFAULT_USER_AGENT).unwrap(),
        store: Arc::new(S), scripts: None, log: Arc::new(L),
    };
    let s = HongguoSource::new();
    let catalog = s.catalog(&env, 1, "").await.expect("catalog");
    let drama = &catalog.items[0];
    let detail = s.detail(&env, &drama.source_id).await.expect("detail");
    // 真实链路里分集的 video_url 由详情解析填好（hongguo-cenc://<vid>），
    // source 是 series_id。直接用详情返回的分集。
    let chapter_full = &detail.chapters[0];
    println!("chapter id={} video_url={} source={}", chapter_full.id, chapter_full.video_url, chapter_full.source);
    for start in [0i64, 30000, 60000] {
        match s.danmaku(&env, &chapter_full, start).await {
            Ok(page) => println!("start={start:>6}: {} items, window [{start}, {}), first={:?}",
                page.items.len(), page.end_ms,
                page.items.first().map(|i| (i.time_ms, i.text.chars().take(12).collect::<String>()))),
            Err(e) => println!("start={start:>6}: FAIL {e}"),
        }
    }
}
