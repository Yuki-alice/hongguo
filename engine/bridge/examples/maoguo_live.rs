use guo_engine::HttpTransport;
use guo_engine::MaoguoSource;
use guo_engine::{FetchRequest, SourceEnv};
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
    fn debug(&self, _: &str) {}
    fn warn(&self, m: &str) {
        eprintln!("[warn] {m}");
    }
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
    let url = MaoguoSource::catalog_url("0", 1);
    println!("GET {url}");
    let session = "1750000000000";
    let qm = MaoguoSource::qm_params(session);
    let sign = MaoguoSource::sign_authorization(&qm);
    println!("qm-params: {}...", &qm[..40.min(qm.len())]);
    let body = env
        .text(
            FetchRequest::get(&url)
                .header("Referer", "https://api-store.qmplaylet.com/")
                .header("platform", "android")
                .header("application-id", "com.duoduo.read")
                .header("app-version", "10001")
                .header("channel", "unknown")
                .header("net-env", "5")
                .header("is-white", "")
                .header("reg", "")
                .header("authorization", "")
                .header("qm-params", qm)
                .header("sign", sign)
                .header("Accept", "application/json")
                .header("X-Requested-With", "com.duoduo.read")
                .header("user-agent", "webviewversion/0"),
        )
        .await?;
    println!("body: {} bytes", body.len());
    println!("head: {}", body.chars().take(400).collect::<String>());
    Ok(())
}
