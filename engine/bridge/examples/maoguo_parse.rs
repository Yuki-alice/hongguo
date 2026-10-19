use guo_engine::HttpTransport;
use guo_engine::MaoguoSource;
use guo_engine::SourceError;
use guo_engine::SourcePlugin;
use guo_engine::{LogSink, SourceEnv, SourceStore};
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

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let env = SourceEnv {
        source_id: "maoguo".into(),
        transport: HttpTransport::shared(guo_engine::DEFAULT_USER_AGENT)?,
        store: Arc::new(NoopStore),
        scripts: None,
        log: Arc::new(NoopLog),
    };
    let source = MaoguoSource::new();
    let page = source.catalog(&env, 1, "0").await?;
    println!("catalog items: {}", page.items.len());
    for d in page.items.iter().take(5) {
        println!("  {} | {} | eps={}", d.source_id, d.title, d.episodes);
    }
    if let Some(first) = page.items.first() {
        let detail = source.detail(&env, &first.source_id).await?;
        println!(
            "\ndetail: {} | chapters={}",
            detail.drama.title,
            detail.chapters.len()
        );
        if let Some(ch) = detail.chapters.first() {
            println!(
                "  ep1: {} | {}",
                ch.title,
                ch.video_url.chars().take(60).collect::<String>()
            );
        }
    }
    Ok(())
}
