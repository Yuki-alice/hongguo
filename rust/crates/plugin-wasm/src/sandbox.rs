//! 沙箱：运行时配置、导入白名单、宿主能力与资源上限。

use std::time::Duration;

use guo_source_api::{FetchRequest, RequestPriority, SourceEnv, SourceError};
use wasmtime::component::Linker;
use wasmtime::{Store, StoreLimits, StoreLimitsBuilder};

/// 资源上限。默认值来自 ARCHITECTURE.md §7.7。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SandboxLimits {
    /// 单次调用可消耗的指令数（fuel）。
    pub fuel: u64,
    /// 线性内存上限（字节）。
    pub memory_bytes: usize,
    /// 单次 `fetch` 响应体上限（字节）。
    pub response_bytes: u64,
    /// 单次调用墙钟上限；用 epoch 中断实现，不依赖 async 运行时。
    pub wall_clock: Duration,
}

impl Default for SandboxLimits {
    fn default() -> Self {
        Self {
            fuel: 50_000_000,
            memory_bytes: 16 * 1024 * 1024,
            response_bytes: 4 * 1024 * 1024,
            wall_clock: Duration::from_secs(2),
        }
    }
}

/// 宿主提供给插件的宿主能力（对应 WIT 的 `import host`）。
///
/// 所有出网都经过这里：`network` 白名单之外的域名直接拒绝，
/// 而不是交给插件自己判断（§7.7）。
#[derive(Clone)]
pub struct Capabilities {
    pub env: SourceEnv,
    /// 允许访问的主机名；空表示不允许任何网络访问。
    pub network: Vec<String>,
    /// 允许使用的存储命名空间。
    pub storage: Vec<String>,
    pub limits: SandboxLimits,
}

impl Capabilities {
    pub fn new(env: SourceEnv) -> Self {
        Self {
            env,
            network: Vec::new(),
            storage: Vec::new(),
            limits: SandboxLimits::default(),
        }
    }

    pub fn allow_network(mut self, hosts: impl IntoIterator<Item = impl Into<String>>) -> Self {
        self.network = hosts.into_iter().map(Into::into).collect();
        self
    }

    pub fn allow_storage(
        mut self,
        namespaces: impl IntoIterator<Item = impl Into<String>>,
    ) -> Self {
        self.storage = namespaces.into_iter().map(Into::into).collect();
        self
    }

    /// 主机名是否在白名单内。只比较 host 段，忽略端口与大小写。
    pub fn host_allowed(&self, url: &str) -> bool {
        let Some(host) = host_of(url) else {
            return false;
        };
        self.network
            .iter()
            .any(|allowed| allowed.eq_ignore_ascii_case(&host))
    }

    pub fn storage_allowed(&self, namespace: &str) -> bool {
        self.storage.iter().any(|allowed| allowed == namespace)
    }
}

/// 从 URL 里取主机名，解析失败返回 `None`。
pub fn host_of(url: &str) -> Option<String> {
    let rest = url.split_once("://")?.1;
    let authority = rest.split(['/', '?', '#']).next().unwrap_or(rest);
    let host = authority.rsplit('@').next().unwrap_or(authority);
    let host = host.split(':').next().unwrap_or(host);
    if host.is_empty() {
        None
    } else {
        Some(host.to_string())
    }
}

/// 运行时可导入的模块前缀。只允许本插件自己的 host 接口。
pub const ALLOWED_IMPORT_PREFIX: &str = "guo:source/";

/// 组件导入白名单检查：安装期调用，不符合即拒绝安装（§9.1）。
pub fn is_allowed_import(name: &str) -> bool {
    name.starts_with(ALLOWED_IMPORT_PREFIX)
}

/// 运行时配置：固定 Pulley 目标，禁止 JIT，开启 fuel 与 epoch。
pub fn engine_config() -> wasmtime::Config {
    let mut config = wasmtime::Config::new();
    config.wasm_component_model(true);
    // iOS 不允许可执行内存，三端统一走解释器，避免出现两套执行路径。
    config.target("pulley64").expect("pulley64 必须是有效目标");
    config.consume_fuel(true);
    config.epoch_interruption(true);
    config
}

/// 组件引擎，进程内共享。
pub fn engine() -> wasmtime::Engine {
    static INSTANCE: std::sync::OnceLock<wasmtime::Engine> = std::sync::OnceLock::new();
    INSTANCE
        .get_or_init(|| wasmtime::Engine::new(&engine_config()).expect("engine 配置在编译期已校验"))
        .clone()
}

/// 运行时版本，用于诊断面板与包体核对。
pub fn runtime_version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

/// 每次调用使用的 store 数据。
pub struct HostState {
    pub capabilities: Capabilities,
    limits: StoreLimits,
}

impl HostState {
    pub fn new(capabilities: Capabilities) -> Self {
        let limits = StoreLimitsBuilder::new()
            .memory_size(capabilities.limits.memory_bytes)
            .instances(4)
            .build();
        Self {
            capabilities,
            limits,
        }
    }

    /// 构造 store 并设置 fuel / epoch 预算。
    pub fn store(capabilities: Capabilities) -> Store<HostState> {
        let limits = capabilities.limits;
        let mut store = Store::new(&engine(), HostState::new(capabilities));
        store.limiter(|state| &mut state.limits);
        store
            .set_fuel(limits.fuel)
            .expect("engine 已开启 consume_fuel");
        // 每次调用给 1 个 tick；由后台计时器推进 epoch 触发中断。
        store.set_epoch_deadline(1);
        store
    }
}

/// 把 `SourceError` 转成 WIT 的错误变体。
pub fn to_wit_error(err: &SourceError) -> crate::bindings::guo::source::types::Error {
    use crate::bindings::guo::source::types::Error;
    match err {
        SourceError::Unsupported(what) => Error::Unsupported((*what).to_string()),
        SourceError::Network { detail, .. } => Error::Network(detail.clone()),
        SourceError::Http { status, .. } => Error::Http(*status),
        SourceError::Blocked { .. } => Error::Blocked(err.to_string()),
        SourceError::Script { .. } => Error::SessionFailed(err.to_string()),
        SourceError::Parse { .. } | SourceError::Rule { .. } => {
            Error::ParseChanged(err.to_string())
        }
        SourceError::EmptyRequest(_) | SourceError::NoResult => Error::Empty,
    }
}

/// 把 WIT 错误变体转回 `SourceError`，供统一错误处理复用。
pub fn from_wit_error(err: crate::bindings::guo::source::types::Error) -> SourceError {
    use crate::bindings::guo::source::types::Error;
    match err {
        // `Unsupported` 必须映射成 `Unsupported`：UI 靠它区分「不该显示入口」
        // 与「解析失败要重试」。映射成 `Rule` 会让「不支持联想」变成红色报错。
        Error::Unsupported(detail) => {
            // WIT 的 detail 是动态字符串，而 `SourceError::Unsupported`
            // 只收 `&'static str`；泄漏极小的字符串换取正确语义。
            SourceError::Unsupported(Box::leak(detail.into_boxed_str()))
        }
        Error::Network(detail) => SourceError::network("plugin", detail),
        Error::Http(status) => SourceError::http("plugin", status),
        // 风控是「稍后重试」，不是解析失败。
        Error::Blocked(detail) => blocked_from_plugin(&detail),
        Error::SessionFailed(detail) => SourceError::Script {
            source: "plugin".into(),
            detail,
        },
        Error::ParseChanged(detail) => SourceError::parse("plugin", detail),
        Error::Empty => SourceError::NoResult,
    }
}

/// 插件报的风控错误转成带冷却时间的 `Blocked`。
///
/// 冷却时长由宿主决定（默认 60 秒），插件只能描述现象，
/// 避免插件通过错误文案影响宿主的退避策略。
fn blocked_from_plugin(detail: &str) -> SourceError {
    // `Blocked` 只带截止时间，说明写进日志供诊断。
    eprintln!("[plugin] 站点限制：{detail}");
    SourceError::blocked_for(std::time::Duration::from_secs(60))
}

/// 用共享的当前线程运行时执行异步调用。
///
/// wasmtime 的宿主函数必须同步（启用 `async` 会引入 fiber 协程栈，iOS 编译不过），
/// 所以这里 `block_on`；调用方须保证不在 tokio 工作线程里（bridge 用 `spawn_blocking`）。
pub fn block_on<F, T>(future: F) -> Result<T, SourceError>
where
    F: std::future::Future<Output = Result<T, SourceError>>,
{
    static RUNTIME: std::sync::OnceLock<Option<tokio::runtime::Runtime>> =
        std::sync::OnceLock::new();
    let runtime = RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .ok()
    });
    match runtime {
        Some(runtime) => runtime.block_on(future),
        None => Err(SourceError::Script {
            source: "plugin".into(),
            detail: "无法创建插件宿主运行时".into(),
        }),
    }
}

/// 同步执行一次取数。插件宿主函数是同步的，因此在这里 `block_on`。
pub fn run_blocking(
    env: SourceEnv,
    request: FetchRequest,
) -> Result<guo_source_api::FetchResponse, SourceError> {
    block_on(async move { env.transport.fetch(request).await })
}

/// 构造插件请求。插件只能决定方法、地址、头与请求体，其余由宿主决定。
pub fn build_request(
    method: &str,
    url: &str,
    headers: Vec<(String, String)>,
    body: Option<Vec<u8>>,
) -> FetchRequest {
    let is_post = method.eq_ignore_ascii_case("post");
    let mut request = match (is_post, body) {
        (true, Some(body)) => FetchRequest::post(url, body),
        _ => FetchRequest::get(url),
    };
    request.priority = RequestPriority::Catalog;
    for (key, value) in headers {
        if is_forbidden_header(&key) {
            continue;
        }
        request.headers.insert(key, value);
    }
    request
}

/// 禁止插件设置的头：这些由宿主统一管理（§9.1）。
fn is_forbidden_header(name: &str) -> bool {
    const FORBIDDEN: [&str; 6] = [
        "host",
        "content-length",
        "connection",
        "accept-encoding",
        "transfer-encoding",
        "cookie",
    ];
    FORBIDDEN.iter().any(|item| item.eq_ignore_ascii_case(name))
}

/// 把宿主能力注册进 linker。
pub fn add_host_to_linker(linker: &mut Linker<HostState>) -> Result<(), wasmtime::Error> {
    use wasmtime::component::HasSelf;
    crate::bindings::Plugin::add_to_linker::<HostState, HasSelf<HostState>>(linker, |state| state)
}

#[cfg(test)]
mod tests {
    use super::*;
    use guo_source_api::{LogSink, Method, SourceStore};
    use std::sync::Arc;

    struct NoopStore;
    #[async_trait::async_trait]
    impl SourceStore for NoopStore {
        async fn get(&self, _key: &str) -> Result<Option<String>, SourceError> {
            Ok(None)
        }
        async fn set(&self, _key: &str, _value: &str) -> Result<(), SourceError> {
            Ok(())
        }
    }

    struct NoopLog;
    impl LogSink for NoopLog {
        fn debug(&self, _message: &str) {}
        fn warn(&self, _message: &str) {}
    }

    fn env() -> SourceEnv {
        SourceEnv {
            source_id: "plugin".into(),
            transport: Arc::new(NoopTransport),
            store: Arc::new(NoopStore),
            scripts: None,
            log: Arc::new(NoopLog),
        }
    }

    struct NoopTransport;
    #[async_trait::async_trait]
    impl guo_source_api::Transport for NoopTransport {
        async fn fetch(
            &self,
            _request: FetchRequest,
        ) -> Result<guo_source_api::FetchResponse, SourceError> {
            Err(SourceError::network("test", "no network"))
        }
    }

    #[test]
    fn allows_only_plugin_host_imports() {
        assert!(is_allowed_import("guo:source/host@1.0.0"));
        assert!(is_allowed_import("guo:source/types@1.0.0"));
        for forbidden in [
            "wasi:http/incoming-handler@0.2.0",
            "wasi:filesystem/types@0.2.0",
            "wasi:sockets/tcp@0.2.0",
            "wasi:cli/run@0.2.0",
            "wasi:clocks/monotonic-clock@0.2.0",
        ] {
            assert!(!is_allowed_import(forbidden), "{forbidden} 必须被拒绝");
        }
    }

    #[test]
    fn network_whitelist_matches_host_only() {
        let caps = Capabilities::new(env()).allow_network(["api.example.test"]);
        assert!(caps.host_allowed("https://api.example.test/catalog?page=1"));
        assert!(caps.host_allowed("https://API.example.test:8443/x"));
        assert!(!caps.host_allowed("https://evil.example.test/x"));
        assert!(!caps.host_allowed("https://api.example.test.evil.com/x"));
        assert!(!caps.host_allowed("not a url"));
    }

    #[test]
    fn host_is_extracted_from_urls() {
        assert_eq!(host_of("https://a.test/x").as_deref(), Some("a.test"));
        assert_eq!(
            host_of("https://user:pw@a.test:443/x").as_deref(),
            Some("a.test")
        );
        assert_eq!(host_of("no-scheme"), None);
    }

    #[test]
    fn storage_namespaces_are_explicit() {
        let caps = Capabilities::new(env()).allow_storage(["session"]);
        assert!(caps.storage_allowed("session"));
        assert!(!caps.storage_allowed("cache"));
    }

    #[test]
    fn forbidden_headers_are_dropped() {
        let request = build_request(
            "GET",
            "https://a.test/x",
            vec![
                ("Host".into(), "evil.test".into()),
                ("Cookie".into(), "sid=1".into()),
                ("Referer".into(), "https://a.test/".into()),
            ],
            None,
        );
        assert!(!request.headers.contains_key("Host"));
        assert!(!request.headers.contains_key("Cookie"));
        assert_eq!(
            request.headers.get("Referer").map(String::as_str),
            Some("https://a.test/")
        );
    }

    #[test]
    fn post_with_body_keeps_method_and_payload() {
        let request = build_request("post", "https://a.test/x", Vec::new(), Some(b"{}".to_vec()));
        assert_eq!(request.method, Method::Post);
        assert_eq!(request.body.as_deref(), Some(&b"{}"[..]));
    }

    #[test]
    fn source_errors_round_trip_through_wit() {
        for original in [
            SourceError::network("https://a.test/x", "timeout"),
            SourceError::http("https://a.test/x", 403),
            SourceError::parse("catalog", "structure changed"),
            SourceError::NoResult,
        ] {
            let wit = to_wit_error(&original);
            let back = from_wit_error(wit);
            assert_eq!(back.is_retryable(), original.is_retryable());
        }
    }

    #[test]
    fn sandbox_limits_are_bounded_by_default() {
        let limits = SandboxLimits::default();
        assert!(limits.fuel > 0);
        assert!(limits.memory_bytes >= 4 * 1024 * 1024);
        assert!(limits.wall_clock.as_secs() >= 1);
    }
}
