use guo_engine::HttpTransport;
use guo_engine::{FetchRequest, SourceEnv};
use guo_engine::{RuleDocument, RuleExecutor};
use std::sync::Arc;

struct NoopStore;
#[async_trait::async_trait]
impl guo_engine::SourceStore for NoopStore {
    async fn get(&self, _: &str) -> Result<Option<String>, guo_engine::SourceError> {
        Ok(None)
    }
    async fn set(&self, _: &str, _: &str) -> Result<(), guo_engine::SourceError> {
        Ok(())
    }
}
struct NoopLog;
impl guo_engine::LogSink for NoopLog {
    fn debug(&self, m: &str) {
        eprintln!("[debug] {m}");
    }
    fn warn(&self, m: &str) {
        eprintln!("[warn] {m}");
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let rule = RuleDocument::from_json(include_str!("../../rules/wuguo.json"))?;
    let transport = HttpTransport::shared(guo_engine::DEFAULT_USER_AGENT)?;
    let env = SourceEnv {
        source_id: rule.id.clone(),
        transport,
        store: Arc::new(NoopStore),
        scripts: None,
        log: Arc::new(NoopLog),
    };
    let catalog = rule.catalog.as_ref().expect("catalog");
    let path = rule.expand(&catalog.url, 1, "1", "");
    let url = format!("{}/{}", rule.base.trim_end_matches('/'), path);
    println!("GET {url}");

    let body = env
        .text(FetchRequest::get(&url).header("Referer", format!("{}/", rule.base)))
        .await?;
    println!("body: {} bytes", body.len());

    let page = RuleExecutor::new(&rule).parse_catalog(&body, 1)?;
    println!("parsed: {} items", page.items.len());
    for d in page.items.iter().take(3) {
        println!("  {} | {}", d.source_id, d.title);
    }
    Ok(())
}
