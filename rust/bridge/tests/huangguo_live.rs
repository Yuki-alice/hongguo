//! 黄果三入口（cloudfront / ai / video）的存活探针（默认忽略）。
//!
//! ```sh
//! cargo test -p guo_engine --test huangguo_live -- --ignored --nocapture
//! ```
//!
//! 历史记录互相矛盾（10-24：ai 取流可用、cloudfront 4001、video 403；
//! 10-21：ai / video 超时），迁移立项前必须逐个复测。

use guo_engine::{LogSink, SourceEnv, SourceError, SourcePlugin, SourceStore};
use guo_source_huangguo::{HuangguoAiSource, HuangguoVideoSource, LegacySource};
use std::sync::Arc;

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

fn env(source_id: &str) -> SourceEnv {
    SourceEnv {
        source_id: source_id.into(),
        transport: Arc::new(
            guo_engine::HttpTransport::new(guo_host::DEFAULT_USER_AGENT).expect("transport"),
        ),
        store: Arc::new(NoopStore),
        scripts: None,
        log: Arc::new(NoopLog),
    }
}

async fn probe(source: impl SourcePlugin, name: &str, detail_id: Option<String>) {
    let call_env = env(source.meta().id.as_str());
    match source.catalog(&call_env, 1, "").await {
        Ok(page) => {
            println!(
                "[{name}] 目录 ✅ {} 条{}",
                page.items.len(),
                page.items
                    .first()
                    .map(|item| format!("，首条「{}」({})", item.title, item.source_id))
                    .unwrap_or_default()
            );
            let Some(target) =
                detail_id.or_else(|| page.items.first().map(|item| item.source_id.clone()))
            else {
                println!("[{name}] 详情 ⏭ 空目录，跳过");
                return;
            };
            match source.detail(&call_env, &target).await {
                Ok(detail) => {
                    println!(
                        "[{name}] 详情 ✅ 「{}」{} 集",
                        detail.drama.title,
                        detail.chapters.len()
                    );
                    if let Some(chapter) = detail.chapters.first() {
                        match source.resolve(&call_env, &detail.drama, chapter).await {
                            Ok(media) => println!("[{name}] 取流 ✅ {}", media.url),
                            Err(err) => println!("[{name}] 取流 ❌ {err}"),
                        }
                    }
                }
                Err(err) => println!("[{name}] 详情 ❌ {err}"),
            }
        }
        Err(err) => println!("[{name}] 目录 ❌ {err}"),
    }
    let categories = source.categories(&env(source.meta().id.as_str())).await;
    println!(
        "[{name}] 分类 {}",
        match categories {
            Ok(list) => format!("✅ {} 条", list.len()),
            Err(err) => format!("❌ {err}"),
        }
    );
}

#[tokio::test]
#[ignore = "需要外网，手动执行：cargo test -p guo_engine --test huangguo_live -- --ignored --nocapture"]
async fn probe_all_three_entries() {
    probe(LegacySource::new(), "cloudfront", None).await;
    probe(HuangguoAiSource::new(), "ai", None).await;
    probe(HuangguoVideoSource::new(), "video", None).await;
}
