//! 脚本型站源宿主：把 `main.js` 变成可调用的站源。
//!
//! 设计取舍（对应 ADR-13 / EXTENSION-ECOSYSTEM §2.2）：
//!
//! - **宿主只向 JS 暴露一个函数** `__host_call(kind, payloadJson)`，
//!   `ctx.fetch` / `ctx.store` / `ctx.log` / `ctx.now` 全部由 JS shim 拼出来。
//!   这样 Rust 侧只有一个闭包要管生命周期，新增能力只改 `host_call` 的分支，
//!   不用碰 rquickjs 的函数注册。
//! - **`ctx` 全部同步**。作者写 `const res = ctx.fetch({url})` 就行，
//!   不需要理解 Promise。宿主在阻塞线程里跑脚本，内部的异步请求用
//!   独立的 current-thread runtime 驱动（与 `plugin-wasm` 同款机制）。
//! - **每次调用新建 Runtime**。站点脚本是毫秒级计算，新建开销可忽略；
//!   换来的是实例间零状态泄漏——一个插件看不到另一个插件写过的全局变量。

use std::sync::Arc;
use std::time::{Duration, Instant};

use rquickjs::{Context, Runtime};

use guo_source_api::{FetchRequest, HeaderMap, Method, SourceEnv, SourceError};

use crate::script::PRELUDE;

/// 脚本执行的资源上限。
#[derive(Debug, Clone, Copy)]
pub struct ScriptLimits {
    pub timeout: Duration,
    pub memory_bytes: usize,
}

impl Default for ScriptLimits {
    fn default() -> Self {
        Self {
            timeout: Duration::from_secs(10),
            memory_bytes: 32 * 1024 * 1024,
        }
    }
}

/// 脚本型站源宿主。
#[derive(Debug, Clone, Copy, Default)]
pub struct JsPluginHost {}

impl JsPluginHost {
    pub fn new() -> Self {
        Self {}
    }

    pub fn shared() -> Arc<Self> {
        Arc::new(Self::new())
    }

    /// 执行 `source` 定义脚本，然后调用 `entry(input)`，返回其 JSON 文本。
    ///
    /// 返回的是**字符串**：JS 对象不跨 QuickJS 边界，宿主统一在 JSON 层交换。
    ///
    /// `network` 是清单声明的域名白名单：与 Wasm 沙箱同一策略，
    /// 脚本拿不到白名单之外的主机。
    pub async fn invoke(
        &self,
        env: &SourceEnv,
        source: &str,
        entry: &str,
        input: &str,
        limits: ScriptLimits,
        network: &[String],
    ) -> Result<String, SourceError> {
        let state = HostState::new(env, limits, network);
        let source = source.to_string();
        let entry = entry.to_string();
        let input = input.to_string();
        run_blocking(move || execute(&state, &source, &entry, &input)).await
    }

    /// 同步版本，供装配期使用。
    ///
    /// `load_installed` 跑在 FRB 的同步桥接函数里，那里**没有 tokio 上下文**，
    /// `spawn_blocking` 会直接 panic。所以装配期走这条路，在当前线程执行。
    pub fn invoke_sync(
        &self,
        env: &SourceEnv,
        source: &str,
        entry: &str,
        input: &str,
        limits: ScriptLimits,
        network: &[String],
    ) -> Result<String, SourceError> {
        let state = HostState::new(env, limits, network);
        execute(&state, source, entry, input)
    }
}

/// 传给 JS 侧闭包的最小宿主状态。
struct HostState {
    env: SourceEnv,
    limits: ScriptLimits,
    network: Arc<Vec<String>>,
}

impl HostState {
    fn new(env: &SourceEnv, limits: ScriptLimits, network: &[String]) -> Self {
        Self {
            env: env.clone(),
            limits,
            network: Arc::new(network.to_vec()),
        }
    }
}

/// 取 URL 的主机部分（小写、去端口）。
fn host_of(url: &str) -> Option<&str> {
    let rest = url.split_once("://").map(|(_, rest)| rest).unwrap_or(url);
    let host = rest.split(['/', '?', '#']).next().unwrap_or(rest);
    let host = host.rsplit_once('@').map(|(_, host)| host).unwrap_or(host);
    let host = host.split_once(':').map(|(host, _)| host).unwrap_or(host);
    if host.is_empty() {
        None
    } else {
        Some(host)
    }
}

fn execute(
    state: &HostState,
    source: &str,
    entry: &str,
    input: &str,
) -> Result<String, SourceError> {
    let runtime = Runtime::new().map_err(|err| script_error("runtime", err))?;
    runtime.set_memory_limit(state.limits.memory_bytes);
    let deadline = Instant::now() + state.limits.timeout;
    // 中断处理器让宿主能掐死死循环脚本，而不是陪它跑到进程退出。
    runtime.set_interrupt_handler(Some(Box::new(move || Instant::now() >= deadline)));

    let context = Context::full(&runtime).map_err(|err| script_error("context", err))?;
    context.with(|ctx| -> Result<String, SourceError> {
        ctx.eval::<(), _>(PRELUDE)
            .map_err(|err| script_error("prelude", err))?;
        ctx.eval::<(), _>(SHIM)
            .map_err(|err| script_error("ctx shim", err))?;

        let host_state = Arc::new(HostCallState {
            env: state.env.clone(),
            network: Arc::clone(&state.network),
        });
        ctx.globals()
            .set(
                "__host_call",
                rquickjs::Function::new(ctx.clone(), move |kind: String, payload: String| {
                    host_call(&host_state, &kind, &payload)
                })
                .map_err(|err| script_error("__host_call", err))?,
            )
            .map_err(|err| script_error("globals", err))?;

        // 先定义，再调用：脚本里可以写具名函数、类和自带 crypto 实现。
        ctx.eval::<(), _>(source.as_bytes())
            .map_err(|err| script_error("脚本", err))?;

        let call = format!("__stringify_result({entry}, {input})");
        let value = ctx
            .eval::<rquickjs::Value, _>(call.as_bytes())
            .map_err(|err| {
                // 脚本抛异常时 rquickjs 只留下 "Exception"；取回宿主侧记录的原因，
                // 否则作者只能看到一句没有信息量的失败。
                let detail = ctx
                    .eval::<String, _>("String(globalThis.__last_host_error || '')")
                    .unwrap_or_default();
                if detail.is_empty() {
                    script_error(entry, err)
                } else {
                    SourceError::Script {
                        source: entry.to_string(),
                        detail,
                    }
                }
            })?;
        value
            .as_string()
            .and_then(|text| text.to_string().ok())
            .ok_or_else(|| SourceError::Script {
                source: entry.to_string(),
                detail: "脚本必须返回可序列化的对象".into(),
            })
    })
}

/// JS 侧看到的 `ctx`：全部由 `__host_call` 拼出来。
const SHIM: &str = r#"
globalThis.__last_host_error = '';
globalThis.__hostCall = function (kind, payload) {
    const raw = __host_call(kind, payload);
    const parsed = JSON.parse(raw || '{}');
    if (parsed && parsed.error) {
        // rquickjs 抛出的异常在 Rust 侧只剩 "Exception"，
        // 因此把原因留在全局，宿主出错时再取回来。
        globalThis.__last_host_error = String(parsed.error);
        throw new Error(parsed.error);
    }
    return parsed || {};
};
globalThis.ctx = {
    fetch: function (request) {
        return __hostCall('fetch', JSON.stringify(request || {})).response || {};
    },
    store: {
        get: function (key) {
            return __hostCall('store_get', JSON.stringify({ key: String(key) })).value;
        },
        set: function (key, value) {
            __hostCall('store_set', JSON.stringify({ key: String(key), value: String(value) }));
            return true;
        },
    },
    log: function (message) {
        __hostCall('log', JSON.stringify({ message: String(message) }));
    },
    now: function () {
        return Number(__hostCall('now', '{}').ms || 0);
    },
};
globalThis.__stringify_result = function (fn, input) {
    if (typeof fn !== 'function') { throw new Error('脚本未导出该函数'); }
    const value = fn(input || {});
    if (value === undefined || value === null) { return '{}'; }
    return JSON.stringify(value);
};
globalThis.__probe_export_map = function () {
    return {
        categories: typeof categories === 'function',
        catalog: typeof catalog === 'function',
        detail: typeof detail === 'function',
        search: typeof search === 'function',
        resolve: typeof resolve === 'function',
        rankingBoards: typeof rankingBoards === 'function',
        ranking: typeof ranking === 'function',
        recommend: typeof recommend === 'function',
        suggestions: typeof suggestions === 'function',
        danmaku: typeof danmaku === 'function',
        seasons: typeof seasons === 'function'
    };
};
"#;

/// `__host_call` 的 Rust 实现：一种能力一个分支，统一 JSON 出入。
fn host_call(state: &HostCallState, kind: &str, payload: &str) -> String {
    let result = match kind {
        "fetch" => call_fetch(state, payload),
        "store_get" => call_store_get(state, payload),
        "store_set" => call_store_set(state, payload),
        "log" => call_log(state, payload),
        "now" => Ok(serde_json::json!({ "ms": now_ms() }).to_string()),
        other => Err(format!("脚本调用了不存在的能力：{other}")),
    };
    match result {
        Ok(text) => text,
        Err(detail) => serde_json::json!({ "error": detail }).to_string(),
    }
}

struct HostCallState {
    env: SourceEnv,
    network: Arc<Vec<String>>,
}

fn call_fetch(state: &HostCallState, payload: &str) -> Result<String, String> {
    #[derive(serde::Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Input {
        url: String,
        #[serde(default)]
        method: Option<String>,
        #[serde(default)]
        headers: std::collections::BTreeMap<String, String>,
        #[serde(default)]
        body: Option<String>,
    }
    let input: Input =
        serde_json::from_str(payload).map_err(|err| format!("fetch 参数无效：{err}"))?;
    if input.url.trim().is_empty() {
        return Err("fetch 缺少 url".into());
    }
    // 白名单是硬约束：脚本请求站外域名一律拒绝，而不是「先发再说」。
    let host = host_of(&input.url).unwrap_or_default();
    let allowed = state
        .network
        .iter()
        .any(|entry| entry.eq_ignore_ascii_case(host));
    if !allowed {
        return Err(format!(
            "脚本请求了未声明的域名：{}（清单只声明了 {:?}）",
            input.url,
            state.network.as_slice()
        ));
    }
    let method = match input.method.as_deref().map(str::to_lowercase).as_deref() {
        Some("post") => Method::Post,
        _ => Method::Get,
    };
    let mut request = match (method, input.body) {
        (Method::Post, Some(body)) => FetchRequest::post(&input.url, body.into_bytes()),
        _ => FetchRequest::get(&input.url),
    };
    for (key, value) in input.headers {
        request = request.header(key, value);
    }
    // 脚本是同步的，宿主在这里驱动异步请求（与 plugin-wasm 同款）。
    // 两层 Result：外层是宿主运行时不可用，内层是请求本身失败。
    let response = block_on(async { state.env.transport.fetch(request).await })
        .map_err(|err| err.to_string())?
        .map_err(|err| err.to_string())?;
    let headers: HeaderMap = response
        .headers
        .iter()
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect();
    Ok(serde_json::json!({
        "response": {
            "status": response.status,
            "body": String::from_utf8_lossy(&response.body),
            "headers": headers,
            "finalUrl": response.final_url,
        }
    })
    .to_string())
}

fn call_store_get(state: &HostCallState, payload: &str) -> Result<String, String> {
    let input: serde_json::Value =
        serde_json::from_str(payload).map_err(|err| format!("store.get 参数无效：{err}"))?;
    let key = input
        .get("key")
        .and_then(|value| value.as_str())
        .unwrap_or_default();
    let value = block_on(async { state.env.store.get(key).await })
        .map_err(|err| err.to_string())?
        .map_err(|err| err.to_string())?;
    Ok(serde_json::json!({ "value": value }).to_string())
}

fn call_store_set(state: &HostCallState, payload: &str) -> Result<String, String> {
    let input: serde_json::Value =
        serde_json::from_str(payload).map_err(|err| format!("store.set 参数无效：{err}"))?;
    let key = input
        .get("key")
        .and_then(|value| value.as_str())
        .unwrap_or_default();
    let value = input
        .get("value")
        .map(|value| value.as_str().unwrap_or_default())
        .unwrap_or_default();
    block_on(async { state.env.store.set(key, value).await })
        .map_err(|err| err.to_string())?
        .map_err(|err| err.to_string())?;
    Ok(serde_json::json!({ "ok": true }).to_string())
}

fn call_log(state: &HostCallState, payload: &str) -> Result<String, String> {
    let input: serde_json::Value =
        serde_json::from_str(payload).map_err(|err| format!("log 参数无效：{err}"))?;
    if let Some(message) = input.get("message").and_then(|value| value.as_str()) {
        state.env.log.debug(message);
    }
    Ok(serde_json::json!({ "ok": true }).to_string())
}

/// 脚本宿主函数必须同步，因此在这里驱动异步请求。
///
/// 用独立的 current-thread runtime 而不是外层 handle：脚本运行在阻塞线程池里，
/// 复用外层 handle 会把请求排进同一个 reactor，反而更容易互相拖慢。
pub fn block_on<F, T>(future: F) -> Result<T, SourceError>
where
    F: std::future::Future<Output = T>,
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
        Some(runtime) => Ok(runtime.block_on(future)),
        None => Err(SourceError::Script {
            source: "engine".into(),
            detail: "无法创建脚本宿主运行时".into(),
        }),
    }
}

async fn run_blocking<T, F>(f: F) -> Result<T, SourceError>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T, SourceError> + Send + 'static,
{
    // 没有 tokio 上下文时（FRB 同步桥接函数）直接在当前线程跑，
    // 否则 `spawn_blocking` 会 panic。
    if tokio::runtime::Handle::try_current().is_err() {
        return f();
    }
    tokio::task::spawn_blocking(f)
        .await
        .map_err(|err| SourceError::Script {
            source: "engine".into(),
            detail: format!("任务调度失败：{err}"),
        })?
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|value| value.as_millis() as u64)
        .unwrap_or(0)
}

fn script_error(source: &str, err: impl std::fmt::Debug) -> SourceError {
    SourceError::Script {
        source: source.to_string(),
        detail: format!("{err:?}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use guo_source_api::{FetchResponse, LogSink, SourceStore, Transport};
    use std::sync::Mutex;

    struct FakeTransport {
        body: String,
    }

    #[async_trait::async_trait]
    impl Transport for FakeTransport {
        async fn fetch(&self, request: FetchRequest) -> Result<FetchResponse, SourceError> {
            Ok(FetchResponse::new(
                200,
                self.body.as_bytes().to_vec(),
                &request.url,
            ))
        }
    }

    #[derive(Default)]
    struct MemStore {
        values: Mutex<std::collections::BTreeMap<String, String>>,
    }

    #[async_trait::async_trait]
    impl SourceStore for MemStore {
        async fn get(&self, key: &str) -> Result<Option<String>, SourceError> {
            Ok(self
                .values
                .lock()
                .map_err(|_| SourceError::parse("store", "锁损坏"))?
                .get(key)
                .cloned())
        }
        async fn set(&self, key: &str, value: &str) -> Result<(), SourceError> {
            self.values
                .lock()
                .map_err(|_| SourceError::parse("store", "锁损坏"))?
                .insert(key.to_string(), value.to_string());
            Ok(())
        }
    }

    struct NoLog;
    impl LogSink for NoLog {
        fn debug(&self, _message: &str) {}
        fn warn(&self, _message: &str) {}
    }

    fn env(body: &str, store: Arc<MemStore>) -> SourceEnv {
        SourceEnv {
            source_id: "script".into(),
            transport: Arc::new(FakeTransport { body: body.into() }),
            store,
            scripts: None,
            log: Arc::new(NoLog),
        }
    }

    fn limits() -> ScriptLimits {
        ScriptLimits {
            timeout: Duration::from_secs(5),
            memory_bytes: 16 * 1024 * 1024,
        }
    }

    #[tokio::test]
    async fn script_can_call_host_fetch_and_store() {
        let store = Arc::new(MemStore::default());
        let env = env(
            r#"{"list":[{"id":"1","title":"剧名"}]}"#,
            Arc::clone(&store),
        );
        let source = r#"
            function catalog(input) {
                const res = ctx.fetch({ url: 'https://x.test/list?page=' + input.page });
                const data = JSON.parse(res.body);
                ctx.store.set('lastPage', String(input.page));
                return {
                    items: (data.list || []).map(function (row) {
                        return { id: row.id, title: row.title };
                    }),
                    hasMore: false,
                };
            }
        "#;
        let out = JsPluginHost::new()
            .invoke(
                &env,
                source,
                "catalog",
                r#"{"page":2}"#,
                limits(),
                &["x.test".to_string()],
            )
            .await
            .expect("invoke");
        let parsed: serde_json::Value = serde_json::from_str(&out).expect("json");
        assert_eq!(parsed["items"][0]["title"], "剧名");
        // 脚本写过的会话必须真的落进宿主存储（命名空间前缀由引擎的
        // NamespacedStore 加，这里直接用裸 store）。
        assert_eq!(
            store.get("lastPage").await.expect("get").as_deref(),
            Some("2")
        );
    }

    #[tokio::test]
    async fn script_can_bundle_its_own_crypto() {
        let store = Arc::new(MemStore::default());
        let env = env("{}", Arc::clone(&store));
        // 宿主只提供 md5 兜底；真实插件会自带 crypto-js，这里验证「自带函数可用」。
        let source = r#"
            function sign(input) {
                const base = input.url + '|' + input.salt;
                return { signature: crypto.md5(base), length: base.length };
            }
        "#;
        let out = JsPluginHost::new()
            .invoke(
                &env,
                source,
                "sign",
                r#"{"url":"/a","salt":"s"}"#,
                limits(),
                &[],
            )
            .await
            .expect("invoke");
        let parsed: serde_json::Value = serde_json::from_str(&out).expect("json");
        let signature = parsed["signature"].as_str().expect("signature");
        assert_eq!(signature.len(), 32, "md5 应为 32 位十六进制：{signature}");
        assert_eq!(parsed["length"], 4);
    }

    #[tokio::test]
    async fn fetch_outside_the_declared_hosts_is_refused() {
        let store = Arc::new(MemStore::default());
        let env = env("{}", Arc::clone(&store));
        let source = "function catalog(){ return ctx.fetch({ url: 'https://evil.test/a' }); }";
        // 白名单里只有 x.test，脚本请求 evil.test 必须在宿主侧就被拒绝。
        let err = JsPluginHost::new()
            .invoke(
                &env,
                source,
                "catalog",
                "{}",
                limits(),
                &["x.test".to_string()],
            )
            .await
            .expect_err("must fail");
        assert!(err.to_string().contains("未声明的域名"), "{err}");

        // 清单没声明任何主机时同样拒绝，避免「忘写配置 = 全放行」。
        let err = JsPluginHost::new()
            .invoke(&env, source, "catalog", "{}", limits(), &[])
            .await
            .expect_err("must fail");
        assert!(err.to_string().contains("未声明的域名"), "{err}");
    }

    #[tokio::test]
    async fn missing_export_reports_a_locatable_error() {
        let store = Arc::new(MemStore::default());
        let env = env("{}", Arc::clone(&store));
        let err = JsPluginHost::new()
            .invoke(&env, "function a() {}", "catalog", "{}", limits(), &[])
            .await
            .expect_err("must fail");
        assert!(
            err.to_string().contains("catalog"),
            "错误信息必须指出是哪个导出：{err}"
        );
    }

    #[tokio::test]
    async fn infinite_loop_is_interrupted_by_the_deadline() {
        let store = Arc::new(MemStore::default());
        let env = env("{}", Arc::clone(&store));
        let source = "function spin() { while (true) {} }";
        let err = JsPluginHost::new()
            .invoke(
                &env,
                source,
                "spin",
                "{}",
                ScriptLimits {
                    timeout: Duration::from_millis(200),
                    memory_bytes: 8 * 1024 * 1024,
                },
                &[],
            )
            .await
            .expect_err("must fail");
        assert!(err.to_string().contains("spin"), "{err}");
    }
}
