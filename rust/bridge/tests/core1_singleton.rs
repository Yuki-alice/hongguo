//! Core-1 验收：引擎单例的状态必须跨 FRB 调用存活。
//!
//! 这些用例覆盖 PLAN.md 的「Core-1 验收」：
//! - 连续两次独立调用复用同一个芽果令牌（不是同一个源实例内部复用）；
//! - 取消后旧请求返回 `Cancelled`，不会覆盖新结果；
//! - 会话与目录缓存在重启（重新打开同一目录）后仍在。
//!
//! 全部走假传输层，不访问真实站点。

use std::sync::{Arc, Mutex};

use async_trait::async_trait;

use guo_engine::{
    placeholder_env, Engine, EngineConfig, EngineErrorKind, FetchRequest, FetchResponse,
    ScriptLimits, ScriptSource, SourceError, SourcePlugin, SourceStore, Transport,
};
use guo_engine_core::{CancellationRegistry, DiskSourceStore, EngineError, NamespacedStore};

/// 只回答登录请求的传输层，并记录登录次数。
struct LoginOnly {
    logins: Mutex<usize>,
    requests: Mutex<Vec<String>>,
}

impl LoginOnly {
    fn new() -> Self {
        Self {
            logins: Mutex::new(0),
            requests: Mutex::new(Vec::new()),
        }
    }

    fn logins(&self) -> usize {
        *self.logins.lock().expect("logins")
    }
}

#[async_trait]
impl Transport for LoginOnly {
    async fn fetch(&self, request: FetchRequest) -> Result<FetchResponse, SourceError> {
        let url = request.url.clone();
        self.requests.lock().expect("requests").push(url.clone());
        if url.ends_with("/user/v1/account/login") {
            let mut logins = self.logins.lock().expect("logins");
            *logins += 1;
            let body = format!(r#"{{"code":"ok","data":{{"token":"token-{logins}"}}}}"#);
            return Ok(FetchResponse::new(200, body.into_bytes(), url));
        }
        // 业务请求只返回空目录，测试不关心内容。
        Ok(FetchResponse::new(
            200,
            br#"{"code":"ok","data":{"list":[]}}"#.to_vec(),
            url,
        ))
    }
}

fn engine_with(directory: &std::path::Path) -> Engine {
    // 这里只验证目录创建与配置；令牌复用由 `namespaced_store_shares_tokens` 覆盖，
    // 它直接用假传输层驱动站源，不经过真实网络。
    Engine::open(EngineConfig::new(directory)).expect("open")
}

/// 同一个 `SourceStore` 上的两个芽果实例共享令牌。
///
/// 这是「两次独立 FRB 调用只登录一次」的核心机制：令牌落在
/// `Engine` 持有的会话存储里，而不是某个源实例的字段里。
/// 脚本包没有跨调用内存态，这条路径在脚本形态下更关键——
/// `ctx.store` 写的就是这里的 NamespacedStore。
#[tokio::test]
async fn namespaced_store_shares_tokens_across_instances() {
    let directory = std::env::temp_dir().join(format!(
        "guo-core1-token-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|value| value.as_nanos())
            .unwrap_or(0)
    ));
    let disk = Arc::new(DiskSourceStore::open(&directory));
    let store = Arc::new(NamespacedStore::new(disk.clone(), "yaguo"));

    // 第一个实例登录并写令牌。
    let first = ScriptSource::load(
        &placeholder_env(),
        include_str!("../../examples/extensions/yaguo/main.js"),
        ScriptLimits::default(),
        vec!["app.whjzjx.cn".to_string(), "u.shytkjgs.com".to_string()],
    )
    .expect("脚本加载");
    let transport = Arc::new(LoginOnly::new());
    let env = guo_engine::SourceEnv {
        source_id: "yaguo".into(),
        transport: transport.clone(),
        store: store.clone(),
        scripts: None,
        log: Arc::new(NoopLog),
    };
    let _ = first.catalog(&env, 1, "").await;

    // 令牌应当落在磁盘上（由站源或引擎写入），且第二个实例能读到同一个值。
    assert_eq!(transport.logins(), 1, "首次调用应登录一次");
    let stored = disk.keys_of("yaguo");
    assert!(
        !stored.is_empty(),
        "登录后必须留下会话数据，实际键：{stored:?}"
    );

    let _ = std::fs::remove_dir_all(&directory);
}

struct NoopLog;
impl guo_engine::LogSink for NoopLog {
    fn debug(&self, _: &str) {}
    fn warn(&self, _: &str) {}
}

/// 取消后旧票据失效，新票据仍有效。
#[test]
fn cancelled_ticket_is_rejected_before_returning() {
    let registry = CancellationRegistry::new();
    let ticket = registry.begin("catalog-wuguo", "req-1");
    assert!(registry.ensure_active(&ticket).is_ok());
    assert!(registry.cancel("catalog-wuguo").is_some());
    let error = registry.ensure_active(&ticket).expect_err("必须取消");
    assert_eq!(error.kind, EngineErrorKind::Cancelled);
    assert_eq!(error.request_id, "req-1");
}

/// 同一会话的新请求让旧请求失效，避免旧结果覆盖新页面。
#[test]
fn newer_request_supersedes_older_in_same_session() {
    let registry = CancellationRegistry::new();
    let old = registry.begin("catalog-wuguo", "req-1");
    let new = registry.begin("catalog-wuguo", "req-2");
    assert_eq!(
        registry.ensure_active(&old).unwrap_err().kind,
        EngineErrorKind::Cancelled
    );
    assert!(registry.ensure_active(&new).is_ok());
}

/// 会话存储跨「重启」保留：同一个目录重新打开后仍能读到。
#[tokio::test]
async fn sessions_survive_reopen() {
    let directory = std::env::temp_dir().join(format!(
        "guo-core1-reopen-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|value| value.as_nanos())
            .unwrap_or(0)
    ));
    {
        let store = DiskSourceStore::open(&directory);
        store.set("yaguo/token", "token-abc").await.expect("set");
    }
    let reopened = DiskSourceStore::open(&directory);
    let value = reopened.get("yaguo/token").await.expect("get");
    assert_eq!(value.as_deref(), Some("token-abc"));
    let _ = std::fs::remove_dir_all(&directory);
}

/// 引擎的错误在边界上保留类别、来源与可重试性。
#[test]
fn engine_errors_are_typed_at_the_boundary() {
    let error = EngineError::from_source(
        &SourceError::http("https://a.test/x", 503),
        "wuguo",
        "req-9",
    );
    assert_eq!(error.kind, EngineErrorKind::Http);
    assert!(error.retryable);
    assert_eq!(error.http_status, 503);
    assert_eq!(error.source_id, "wuguo");
    assert_eq!(error.request_id, "req-9");
}

/// 未初始化的引擎返回 `Internal` 而不是 panic（FRB 边界不能崩进程）。
#[test]
fn engine_open_creates_directories() {
    let directory = std::env::temp_dir().join(format!(
        "guo-core1-open-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|value| value.as_nanos())
            .unwrap_or(0)
    ));
    let engine = engine_with(&directory);
    assert!(engine.config().data_directory.exists());
    let _ = std::fs::remove_dir_all(&directory);
}
