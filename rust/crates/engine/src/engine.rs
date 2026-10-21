//! 进程级引擎单例。
//!
//! 这一层只做装配与状态持有，不做任何站点解析：
//!
//! - 注册表、传输层、会话存储、目录缓存、下载调度器各持一份，进程内复用；
//! - 站源实例因此跨调用存活，芽果令牌、红果设备标识等内存态不再每次重建；
//! - 插件安装 / 卸载只重建注册表，不碰会话、缓存与下载任务。
//!
//! 初始化是幂等的：`Engine::initialize` 可以在测试里多次调用，只有第一次
//! 生效；重复初始化返回 `false`，调用方据此区分「首次装配」与「已就绪」。

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use guo_host::{HttpTransport, QuickJsHost};
use guo_plugin_host::PluginStore;
use guo_plugin_wasm::{ComponentSource, SandboxLimits};
use guo_runtime::{load_installed, CatalogCache, Job, LoadReport, RuleSource, Scheduler};
use guo_source_api::{LogSink, SourceEnv, SourcePlugin, SourceRegistry, SourceStore, Transport};

use crate::cancel::{CancellationRegistry, RequestTicket};
use crate::cover::{CoverCache, CoverResult};
use crate::error::{EngineError, EngineErrorKind};
use crate::events::{DownloadEvent, EventBus};
use crate::store::{DiskSourceStore, NamespacedStore};

/// 随包分发的声明式规则。
const BUILTIN_RULES: &[&str] = &[
    include_str!("../../../rules/wuguo.json"),
    include_str!("../../../rules/huaguo.json"),
    include_str!("../../../rules/fanguo.json"),
    include_str!("../../../rules/guanguo.json"),
    include_str!("../../../rules/xingguo.json"),
    include_str!("../../../rules/heguo.json"),
    include_str!("../../../rules/wangguo.json"),
    include_str!("../../../rules/dsd.json"),
    include_str!("../../../rules/faguo.json"),
];

/// 编译进二进制的代码源装配器。
///
/// 由桥接层注入，避免 `guo-engine` 依赖全部 `source-*` crate；
/// 也保证「哪些源编译进二进制」这一决策只在一处（`bridge/src/sources`）。
pub type BuiltinSources = fn(&mut SourceRegistry);

/// 诊断用的最近错误记录条数上限。
const RECENT_ERRORS: usize = 20;

/// 一次引擎装配的静态配置。
#[derive(Debug, Clone)]
pub struct EngineConfig {
    /// 应用数据目录（缓存、会话、插件都在其下）。
    pub data_directory: PathBuf,
    /// 插件根目录。
    pub plugin_directory: PathBuf,
    /// 下载并发数。
    pub download_concurrency: usize,
    /// 单个请求的默认超时。
    pub request_timeout: Duration,
}

impl EngineConfig {
    /// 以 `data_directory` 为根构造默认配置。
    pub fn new(data_directory: impl Into<PathBuf>) -> Self {
        let data_directory = data_directory.into();
        Self {
            plugin_directory: data_directory.join("plugins"),
            data_directory,
            download_concurrency: 2,
            request_timeout: Duration::from_secs(30),
        }
    }

    pub fn with_plugin_directory(mut self, directory: impl Into<PathBuf>) -> Self {
        self.plugin_directory = directory.into();
        self
    }

    pub fn with_download_concurrency(mut self, concurrency: usize) -> Self {
        self.download_concurrency = concurrency;
        self
    }

    pub fn with_request_timeout(mut self, timeout: Duration) -> Self {
        self.request_timeout = timeout;
        self
    }
}

/// 引擎运行时。
pub struct Engine {
    config: EngineConfig,
    transport: Arc<dyn Transport>,
    store: Arc<DiskSourceStore>,
    cache: CatalogCache,
    covers: CoverCache,
    scheduler: Scheduler,
    cancel: CancellationRegistry,
    events: EventBus,
    registry: Mutex<Arc<SourceRegistry>>,
    load_report: Mutex<LoadReport>,
    recent_errors: Mutex<Vec<EngineError>>,
    request_count: AtomicU64,
    started: AtomicBool,
    started_at: Mutex<Option<Instant>>,
    /// 插件安装 / 卸载后递增；调用方据此判断是否需要重新拉清单。
    registry_revision: AtomicU64,
}

impl Engine {
    /// 按配置装配引擎（不注册站源，见 [`Engine::initialize`]）。
    pub fn open(config: EngineConfig) -> Result<Self, EngineError> {
        std::fs::create_dir_all(&config.data_directory).map_err(|err| {
            EngineError::storage(format!(
                "创建数据目录 {} 失败：{err}",
                config.data_directory.display()
            ))
        })?;
        let transport = HttpTransport::global()
            .map(|transport| transport as Arc<dyn Transport>)
            .map_err(|err| EngineError::internal(format!("初始化网络层失败：{err}")))?;
        let store = Arc::new(DiskSourceStore::open(&config.data_directory));
        let cache = CatalogCache::open(&config.data_directory);
        let covers = CoverCache::open(config.data_directory.join("covers"));
        // 下载索引落在数据目录：重启后任务表可恢复（Core-2）。
        let scheduler = Scheduler::open(
            config.download_concurrency,
            config.data_directory.join("downloads").join("index.json"),
        );
        Ok(Self {
            config,
            transport,
            store,
            cache,
            covers,
            scheduler,
            cancel: CancellationRegistry::new(),
            events: EventBus::default(),
            registry: Mutex::new(Arc::new(SourceRegistry::new())),
            load_report: Mutex::new(LoadReport::default()),
            recent_errors: Mutex::new(Vec::new()),
            request_count: AtomicU64::new(0),
            started: AtomicBool::new(false),
            started_at: Mutex::new(None),
            registry_revision: AtomicU64::new(1),
        })
    }

    /// 注册站源并加载插件。重复调用返回 `false` 且不重建注册表。
    pub fn initialize(&self, builtins: BuiltinSources) -> Result<bool, EngineError> {
        if self.started.swap(true, Ordering::SeqCst) {
            return Ok(false);
        }
        self.rebuild_registry(builtins)?;
        if let Ok(mut slot) = self.started_at.lock() {
            *slot = Some(Instant::now());
        }
        Ok(true)
    }

    /// 重新装配注册表。会话、缓存与下载任务不受影响（Core-1 验收项）。
    pub fn rebuild_registry(&self, builtins: BuiltinSources) -> Result<(), EngineError> {
        let mut registry = SourceRegistry::new();
        builtins(&mut registry);
        for text in BUILTIN_RULES {
            match RuleSource::from_json(text) {
                Ok(source) => {
                    registry.register(Arc::new(source));
                }
                Err(err) => {
                    // 随包规则加载失败属于构建期缺陷，必须显式暴露而不是静默跳过。
                    eprintln!("内置规则加载失败：{err}");
                }
            }
        }
        let report = self.load_plugins(&mut registry);
        let mut slot = self
            .registry
            .lock()
            .map_err(|_| EngineError::internal("注册表锁已损坏"))?;
        *slot = Arc::new(registry);
        if let Ok(mut report_slot) = self.load_report.lock() {
            *report_slot = report;
        }
        self.registry_revision.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }

    fn load_plugins(&self, registry: &mut SourceRegistry) -> LoadReport {
        let store = PluginStore::open(&self.config.plugin_directory);
        let report = load_installed(&store, registry, &load_component);
        for (id, detail) in &report.failed {
            eprintln!("插件 {id} 加载失败：{detail}");
        }
        report
    }

    /// 当前注册表快照。调用方持有 `Arc` 期间即使插件被卸载也能安全使用。
    pub fn registry(&self) -> Arc<SourceRegistry> {
        self.registry
            .lock()
            .map(|guard| Arc::clone(&guard))
            .unwrap_or_else(|_| Arc::new(SourceRegistry::new()))
    }

    /// 按 id 取站源。未知源返回 `Unsupported`（ADR-8 的 `UnknownSource` 语义）。
    pub fn source(&self, source_id: &str) -> Result<Arc<dyn SourcePlugin>, EngineError> {
        self.registry().get(source_id).ok_or_else(|| {
            EngineError::new(
                EngineErrorKind::Unsupported,
                format!("未知站源：{source_id}"),
            )
            .with_source(source_id)
        })
    }

    /// 为某个站源构造执行环境。
    ///
    /// 会话存储按 `source_id` 命名空间隔离；脚本宿主共享同一个实例。
    pub fn env(&self, source_id: &str) -> SourceEnv {
        SourceEnv {
            source_id: source_id.to_string(),
            transport: Arc::clone(&self.transport),
            store: Arc::new(NamespacedStore::new(
                Arc::clone(&self.store) as Arc<dyn SourceStore>,
                source_id,
            )) as Arc<dyn SourceStore>,
            scripts: Some(QuickJsHost::shared()),
            log: Arc::new(TracingLog),
        }
    }

    /// 开始一次可取消调用。
    pub fn begin(&self, session: &str, request_id: &str) -> RequestTicket {
        self.request_count.fetch_add(1, Ordering::Relaxed);
        self.cancel.begin(session, request_id)
    }

    /// 取消某个会话的当前请求。
    pub fn cancel(&self, session: &str) -> Option<u64> {
        self.cancel.cancel(session)
    }

    /// 请求结束回收票据。
    pub fn finish(&self, ticket: &RequestTicket) {
        self.cancel.finish(ticket);
    }

    /// 记录一次失败，供诊断页展示。
    pub fn record_error(&self, error: &EngineError) {
        if let Ok(mut slot) = self.recent_errors.lock() {
            slot.push(error.clone());
            if slot.len() > RECENT_ERRORS {
                let overflow = slot.len() - RECENT_ERRORS;
                slot.drain(..overflow);
            }
        }
    }

    pub fn recent_errors(&self) -> Vec<EngineError> {
        self.recent_errors
            .lock()
            .map(|slot| slot.clone())
            .unwrap_or_default()
    }

    pub fn config(&self) -> &EngineConfig {
        &self.config
    }

    pub fn transport(&self) -> Arc<dyn Transport> {
        Arc::clone(&self.transport)
    }

    pub fn store(&self) -> &DiskSourceStore {
        &self.store
    }

    pub fn cache(&self) -> &CatalogCache {
        &self.cache
    }

    pub fn covers(&self) -> &CoverCache {
        &self.covers
    }

    /// 取封面：命中缓存直接返回，否则下载后落盘。
    pub async fn cover(
        &self,
        source_id: &str,
        url: &str,
        referer: &str,
        force: bool,
    ) -> Result<CoverResult, crate::EngineError> {
        let env = self.env(source_id);
        self.covers
            .fetch(&env, url, referer, force)
            .await
            .map_err(|err| crate::EngineError::from_source(&err, source_id, ""))
    }

    pub fn scheduler(&self) -> &Scheduler {
        &self.scheduler
    }

    pub fn events(&self) -> &EventBus {
        &self.events
    }

    pub fn cancel_registry(&self) -> &CancellationRegistry {
        &self.cancel
    }

    pub fn load_report(&self) -> LoadReport {
        self.load_report
            .lock()
            .map(|report| LoadReport {
                loaded: report.loaded.clone(),
                failed: report.failed.clone(),
            })
            .unwrap_or_default()
    }

    pub fn registry_revision(&self) -> u64 {
        self.registry_revision.load(Ordering::SeqCst)
    }

    pub fn request_count(&self) -> u64 {
        self.request_count.load(Ordering::Relaxed)
    }

    pub fn uptime(&self) -> Duration {
        self.started_at
            .lock()
            .ok()
            .and_then(|slot| *slot)
            .map(|start| start.elapsed())
            .unwrap_or_default()
    }

    /// 登记下载任务并广播初始事件。
    pub fn enqueue_download(&self, job: Job) -> u64 {
        let revision = self.scheduler.enqueue(job.clone());
        self.broadcast_job(&job.id);
        revision
    }

    /// 把某个任务的最新状态推给订阅者。
    pub fn broadcast_job(&self, id: &str) {
        if let Some(job) = self.scheduler.get(id) {
            self.events.publish(DownloadEvent::from(&job));
        }
    }

    /// 广播全部任务（批量控制后调用）。
    pub fn broadcast_all(&self) {
        for job in self.scheduler.snapshot() {
            self.events.publish(DownloadEvent::from(&job));
        }
    }

    /// 清理某个站源的会话数据。
    pub fn clear_source_session(&self, source_id: &str) -> Result<usize, EngineError> {
        self.store
            .clear_source(source_id)
            .map_err(|err| EngineError::from_source(&err, source_id, ""))
    }
}

/// 代码插件加载器。
fn load_component(
    manifest: &guo_plugin_host::PluginManifest,
    entry: &Path,
) -> Result<Box<dyn SourcePlugin>, String> {
    let bytes =
        std::fs::read(entry).map_err(|err| format!("读取 {} 失败：{err}", entry.display()))?;
    let limits = manifest
        .permissions
        .script
        .map(|script| SandboxLimits {
            fuel: script.memory_kb.saturating_mul(1_000_000),
            memory_bytes: (script.memory_kb as usize) * 1024,
            ..SandboxLimits::default()
        })
        .unwrap_or_default();
    let source = ComponentSource::load(
        &bytes,
        manifest.permissions.network.clone(),
        manifest.permissions.storage.clone(),
        limits,
    )
    .map_err(|err| err.to_string())?;
    Ok(Box::new(source))
}

/// 站源日志出口。站源目前只区分 debug / warn，这里统一走 stderr。
struct TracingLog;

impl LogSink for TracingLog {
    fn debug(&self, message: &str) {
        if cfg!(debug_assertions) {
            eprintln!("[source] {message}");
        }
    }

    fn warn(&self, message: &str) {
        eprintln!("[source] {message}");
    }
}

/// 进程级单例槽位。
static INSTANCE: OnceLock<Arc<Engine>> = OnceLock::new();

/// 当前引擎；未初始化时返回 `None`。
pub fn current() -> Option<Arc<Engine>> {
    INSTANCE.get().cloned()
}

/// 初始化单例。重复调用返回已有实例并报告 `false`。
pub fn initialize(
    config: EngineConfig,
    builtins: BuiltinSources,
) -> Result<(Arc<Engine>, bool), EngineError> {
    if let Some(existing) = INSTANCE.get() {
        return Ok((Arc::clone(existing), false));
    }
    let engine = Arc::new(Engine::open(config)?);
    let fresh = engine.initialize(builtins)?;
    // 竞态：另一个线程可能已经抢先写入；此时丢弃自己的实例，保持单例唯一。
    match INSTANCE.set(Arc::clone(&engine)) {
        Ok(()) => Ok((engine, fresh)),
        Err(_) => Ok((Arc::clone(INSTANCE.get().expect("单例已写入")), false)),
    }
}

/// 取单例；未初始化时返回 `Internal` 而不是 panic。
pub fn require() -> Result<Arc<Engine>, EngineError> {
    INSTANCE.get().cloned().ok_or_else(|| {
        EngineError::new(
            EngineErrorKind::Internal,
            "引擎尚未初始化，请先调用 init_engine_with_directory",
        )
    })
}

/// 仅测试用：清空单例槽位。
///
/// `OnceLock` 没有 `clear`，因此这里用 `#[cfg(test)]` 的独立槽位替代，
/// 让同一进程内的多个用例可以各自初始化（例如不同临时目录）。
#[cfg(test)]
mod test_support {
    use super::*;

    /// 测试用引擎：不占用全局单例，避免用例之间互相污染。
    pub fn open_for_test(name: &str, builtins: BuiltinSources) -> (Arc<Engine>, PathBuf) {
        let directory = std::env::temp_dir().join(format!(
            "guo-engine-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|value| value.as_nanos())
                .unwrap_or(0)
        ));
        let config = EngineConfig::new(&directory);
        let engine = Arc::new(Engine::open(config).expect("open engine"));
        engine.initialize(builtins).expect("initialize");
        (engine, directory)
    }
}

#[cfg(test)]
pub use test_support::open_for_test;

#[cfg(test)]
mod tests {
    use super::*;
    use guo_source_api::{Capability, SourceMeta, CURRENT_API_LEVEL};

    struct Stub {
        meta: SourceMeta,
    }

    #[async_trait::async_trait]
    impl SourcePlugin for Stub {
        fn meta(&self) -> SourceMeta {
            self.meta.clone()
        }
    }

    fn stub_sources(registry: &mut SourceRegistry) {
        registry.register(Arc::new(Stub {
            meta: SourceMeta {
                id: "stub".into(),
                name: "桩源".into(),
                group: "test".into(),
                api_level: CURRENT_API_LEVEL,
                capabilities: vec![Capability::Catalog],
            },
        }));
    }

    #[test]
    fn initialize_is_idempotent() {
        let (engine, dir) = open_for_test("idempotent", stub_sources);
        assert!(
            !engine.initialize(stub_sources).expect("second"),
            "重复初始化应返回 false"
        );
        assert!(engine.source("stub").is_ok());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn registry_includes_builtin_rules_and_dsd_identity() {
        let (engine, dir) = open_for_test("rules", stub_sources);
        let metas = engine.registry().metas();
        assert!(
            metas.iter().any(|meta| meta.id == "dsd"),
            "帝果必须以 dsd 注册"
        );
        assert!(
            !metas.iter().any(|meta| meta.id == "diguo"),
            "不得再出现 diguo"
        );
        assert!(metas.iter().any(|meta| meta.id == "wuguo"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn unknown_source_is_unsupported_not_panic() {
        let (engine, dir) = open_for_test("unknown", stub_sources);
        let error = match engine.source("nope") {
            Ok(_) => panic!("未知站源必须失败"),
            Err(error) => error,
        };
        assert_eq!(error.kind, EngineErrorKind::Unsupported);
        assert!(error.message.contains("nope"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn rebuild_keeps_session_store() {
        let (engine, dir) = open_for_test("rebuild", stub_sources);
        let store = engine.store();
        // 直接写一个会话键，模拟站源登录后落盘。
        futures_lite_block_on(store.set("stub/token", "abc")).expect("set");
        engine.rebuild_registry(stub_sources).expect("rebuild");
        let value = futures_lite_block_on(store.get("stub/token")).expect("get");
        assert_eq!(value.as_deref(), Some("abc"), "重建注册表不能清会话");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// 测试里需要一个最小 executor：`DiskSourceStore` 的 `set` / `get` 是 async，
    /// 但实现内部是同步锁，用单线程运行时阻塞等待即可。
    fn futures_lite_block_on<T>(future: impl std::future::Future<Output = T>) -> T {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("runtime")
            .block_on(future)
    }

    #[test]
    fn diagnostics_count_requests_and_errors() {
        let (engine, dir) = open_for_test("diag", stub_sources);
        engine.begin("catalog", "r1");
        engine.begin("catalog", "r2");
        assert_eq!(engine.request_count(), 2);
        let error = EngineError::unsupported("弹幕").with_source("stub");
        engine.record_error(&error);
        assert_eq!(engine.recent_errors().len(), 1);
        assert!(engine.registry_revision() >= 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn recent_errors_are_capped() {
        let (engine, dir) = open_for_test("errors", stub_sources);
        for index in 0..(RECENT_ERRORS + 5) {
            engine.record_error(&EngineError::internal(format!("e{index}")));
        }
        assert_eq!(engine.recent_errors().len(), RECENT_ERRORS);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
