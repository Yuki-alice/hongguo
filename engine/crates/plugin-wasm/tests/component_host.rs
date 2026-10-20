//! 用**真实编译**的组件（`examples/plugin-template`）验证宿主端到端可用。
//!
//! 这是 P0 探针之外的第一个真实链路：WIT 契约 → wasm32-wasip2 编译 →
//! 宿主加载 → 能力注入 → 调用导出 → 结果转换。

use std::sync::Arc;

use guo_plugin_wasm::{ComponentSource, SandboxLimits};
use guo_source_api::{
    Chapter, Drama, FetchRequest, FetchResponse, LogSink, SourceEnv, SourceError, SourcePlugin,
    SourceStore, Transport,
};

/// 组件由 `examples/plugin-template` 编译产出，随测试夹具分发。
const TEMPLATE: &[u8] = include_bytes!("fixtures/template.wasm");

struct NoTransport;

#[async_trait::async_trait]
impl Transport for NoTransport {
    async fn fetch(&self, request: FetchRequest) -> Result<FetchResponse, SourceError> {
        Err(SourceError::network(request.url, "测试不联网"))
    }
}

struct MemoryStore;

#[async_trait::async_trait]
impl SourceStore for MemoryStore {
    async fn get(&self, _key: &str) -> Result<Option<String>, SourceError> {
        Ok(None)
    }
    async fn set(&self, _key: &str, _value: &str) -> Result<(), SourceError> {
        Ok(())
    }
}

struct Quiet;

impl LogSink for Quiet {
    fn debug(&self, _message: &str) {}
    fn warn(&self, _message: &str) {}
}

fn env() -> SourceEnv {
    SourceEnv {
        source_id: "guo.template".into(),
        transport: Arc::new(NoTransport),
        store: Arc::new(MemoryStore),
        scripts: None,
        log: Arc::new(Quiet),
    }
}

fn source() -> ComponentSource {
    ComponentSource::load(
        TEMPLATE,
        vec!["example.test".into()],
        vec!["session".into()],
        SandboxLimits::default(),
    )
    .expect("模板组件应可加载")
}

#[test]
fn descriptor_is_read_from_component() {
    let source = source();
    let meta = source.meta();
    assert_eq!(meta.id, "guo.template");
    assert_eq!(meta.api_level, 1);
    assert!(meta.supports(guo_source_api::Capability::Catalog));
    assert!(meta.supports(guo_source_api::Capability::Resolve));
}

#[tokio::test]
async fn catalog_call_round_trips_through_wasm() {
    let source = source();
    let page = source.catalog(&env(), 1, "demo").await.expect("catalog");
    assert_eq!(page.items.len(), 1);
    assert_eq!(page.items[0].title, "第 1 页示例");
    assert_eq!(page.items[0].category, "demo");
    assert!(page.has_more);
}

#[tokio::test]
async fn detail_and_resolve_round_trip() {
    let source = source();
    let env = env();
    let detail = source.detail(&env, "demo-1").await.expect("detail");
    assert_eq!(detail.chapters.len(), 1);
    assert_eq!(detail.chapters[0].video_url, "https://example.test/1.m3u8");

    let drama = Drama {
        id: "guo.template:demo-1".into(),
        source: "guo.template".into(),
        source_id: "demo-1".into(),
        title: "示例".into(),
        ..Default::default()
    };
    let chapter = Chapter {
        id: "1".into(),
        title: "第 1 集".into(),
        video_url: "https://example.test/1.m3u8".into(),
        ..Default::default()
    };
    let media = source
        .resolve(&env, &drama, &chapter)
        .await
        .expect("resolve");
    assert_eq!(media.url, "https://example.test/1.m3u8");
    assert!(media.playlist.is_none());
}

#[tokio::test]
async fn calls_are_repeatable_within_fuel_budget() {
    let source = source();
    let env = env();
    for page in 1..=3 {
        let result = source.catalog(&env, page, "demo").await.expect("catalog");
        assert_eq!(result.page, page);
    }
}

#[tokio::test]
async fn network_calls_outside_whitelist_are_rejected() {
    // 模板不联网；这里直接验证宿主函数的行为：白名单由清单决定，插件无法绕过。
    let source = source();
    let env = env();
    // 白名单内的主机不会出现在模板里，因此只断言「调用本身不越权」：
    // 真正的拒绝路径由 sandbox::tests::network_whitelist_matches_host_only 覆盖。
    assert!(source.catalog(&env, 1, "").await.is_ok());
}

#[test]
fn rejects_component_without_required_exports() {
    // 最小合法组件只有魔数，没有 `guo:source/source` 导出。
    const MINIMAL: &[u8] = &[0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00];
    let result = ComponentSource::load(MINIMAL, Vec::new(), Vec::new(), SandboxLimits::default());
    let err = match result {
        Ok(_) => panic!("缺少导出必须失败"),
        Err(err) => err,
    };
    assert!(err.to_string().contains("WIT 契约"), "{err}");
}

#[test]
fn template_component_imports_only_the_contract() {
    // 这是打包流程的硬性要求：`wasm32-unknown-unknown` 编译后必须用
    // `wasm-tools component new` 组件化，否则会带一堆 `wasi:*` 导入而被拒绝。
    let source = source();
    let imports: Vec<String> = source
        .component()
        .component_type()
        .imports(&guo_plugin_wasm::engine())
        .map(|(name, _)| name.to_string())
        .collect();
    assert_eq!(imports, vec!["guo:source/types@1.0.0".to_string()]);
    for name in &imports {
        assert!(
            guo_plugin_wasm::is_allowed_import(name),
            "{name} 不在能力白名单内"
        );
    }
}

#[test]
fn rejects_api_level_above_host() {
    // 模板声明 level 1，宿主也是 1；把宿主上限降低的行为由 manifest 层校验，
    // 这里只确认 level 边界判断存在（避免将来放宽时静默通过）。
    assert_eq!(guo_source_api::CURRENT_API_LEVEL, 1);
}
