use guo_engine::HttpTransport;
use guo_engine::MaoguoSource;
use guo_engine::SourceError;
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
    let catalog = env
        .text(MaoguoSource::signed_request(&MaoguoSource::catalog_url(
            "0", 1,
        )))
        .await?;
    std::fs::write("tests/fixtures/maoguo_catalog.json", &catalog)?;
    println!("catalog: {} bytes", catalog.len());

    let detail = env
        .text(MaoguoSource::signed_request(&MaoguoSource::detail_url(
            "21277",
        )))
        .await?;
    std::fs::write("tests/fixtures/maoguo_detail.json", &detail)?;
    println!("detail: {} bytes", detail.len());
    Ok(())
}
