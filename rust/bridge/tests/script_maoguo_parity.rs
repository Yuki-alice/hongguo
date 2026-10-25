//! 脚本型站源试点对拍：猫果 JS 扩展 vs 编译版 Rust 源。
//!
//! 这是 ADR-13 的关键验证。如果两者对同一夹具产出一致结果，
//! `source-maoguo`（编译进二进制的 683 行 Rust）就可以被一个
//! **可远程更新、不用发版**的扩展包取代。
//!
//! 全部走夹具，不访问真实站点。

use std::sync::Arc;

use async_trait::async_trait;

use guo_engine::{
    placeholder_env, FetchRequest, FetchResponse, JsPluginHost, LogSink, MaoguoSource,
    ScriptLimits, ScriptSource, SourceEnv, SourceError, SourcePlugin, SourceStore, Transport,
};

const SCRIPT: &str = include_str!("../../examples/extensions/maoguo/main.js");

/// 与 `maoguo_fixtures.rs` 同款夹具传输层。
struct FixtureTransport;

#[async_trait]
impl Transport for FixtureTransport {
    async fn fetch(&self, request: FetchRequest) -> Result<FetchResponse, SourceError> {
        let body = if request.url.contains("playlet/info") {
            include_str!("fixtures/maoguo_detail.json")
        } else {
            include_str!("fixtures/maoguo_catalog.json")
        };
        Ok(FetchResponse::new(
            200,
            body.as_bytes().to_vec(),
            request.url,
        ))
    }
}

struct NoopStore;
#[async_trait]
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

fn env() -> SourceEnv {
    SourceEnv {
        source_id: "maoguo".into(),
        transport: Arc::new(FixtureTransport),
        store: Arc::new(NoopStore),
        scripts: None,
        log: Arc::new(NoopLog),
    }
}

/// 清单里声明的域名白名单；脚本请求这些主机之外会被宿主拒绝。
fn network() -> Vec<String> {
    vec![
        "api-store.qmplaylet.com".to_string(),
        "api-read.qmplaylet.com".to_string(),
    ]
}

fn script_source() -> ScriptSource {
    ScriptSource::load(
        &placeholder_env(),
        SCRIPT,
        ScriptLimits::default(),
        network(),
    )
    .expect("猫果脚本必须能加载")
}

#[test]
fn script_reports_the_same_identity_as_the_compiled_source() {
    let script = script_source();
    let compiled = MaoguoSource::new();
    assert_eq!(script.meta().id, compiled.meta().id);
    assert_eq!(script.meta().name, compiled.meta().name);
    assert_eq!(script.meta().group, compiled.meta().group);
}

#[test]
fn signatures_match_the_compiled_implementation() {
    // 签名是「需要代码」的那部分——对不上就说明脚本路径承载不了真实站点。
    let out = JsPluginHost::new()
        .invoke_sync(
            &placeholder_env(),
            SCRIPT,
            "signatures",
            r#"{"tagId":"0","page":3,"sourceId":"21277","query":"都市"}"#,
            ScriptLimits::default(),
            &network(),
        )
        .expect("signatures");
    let value: serde_json::Value = serde_json::from_str(&out).expect("json");

    assert_eq!(
        value["catalog"].as_str().expect("catalog"),
        MaoguoSource::sign_catalog("0", 3),
        "目录签名必须与编译版逐字一致"
    );
    assert_eq!(
        value["detail"].as_str().expect("detail"),
        MaoguoSource::sign_detail("21277"),
        "详情签名必须与编译版逐字一致"
    );
    assert_eq!(
        value["search"].as_str().expect("search"),
        MaoguoSource::sign_search("都市"),
        "搜索签名必须与编译版逐字一致（含中文 UTF-8）"
    );
    assert_eq!(
        value["tags"].as_str().expect("tags"),
        MaoguoSource::sign_tags(),
        "分类签名必须与编译版逐字一致"
    );
}

/// 请求头是「签名之外」的另一半：签名算对了但头没带上，站点照样回
/// `44010120 验签失败`。这条用例把两个实现钉在同一串字节上。
#[test]
fn request_headers_match_the_compiled_implementation() {
    let out = JsPluginHost::new()
        .invoke_sync(
            &placeholder_env(),
            SCRIPT,
            "headers",
            r#"{"sessionId":"1750000000000"}"#,
            ScriptLimits::default(),
            &network(),
        )
        .expect("headers");
    let value: serde_json::Value = serde_json::from_str(&out).expect("json");

    let expected = MaoguoSource::qm_params("1750000000000");
    assert_eq!(
        value["qm-params"].as_str().expect("qm-params"),
        expected,
        "qm-params 必须与编译版逐字节一致（JSON 顺序、Base64、字符映射）"
    );
    assert_eq!(
        value["sign"].as_str().expect("sign"),
        MaoguoSource::sign_authorization(&expected),
        "authorization 签名必须与编译版逐字一致"
    );
    assert_eq!(value["platform"].as_str(), Some("android"));
    assert_eq!(value["application-id"].as_str(), Some("com.duoduo.read"));
}

#[tokio::test]
async fn catalog_matches_the_compiled_source() {
    let script = script_source();
    let compiled = MaoguoSource::new();

    let from_script = script
        .catalog(&env(), 1, "0")
        .await
        .expect("script catalog");
    let from_rust = compiled
        .catalog(&env(), 1, "0")
        .await
        .expect("rust catalog");

    assert_eq!(
        from_script.items.len(),
        from_rust.items.len(),
        "条目数必须一致：脚本 {} vs 编译 {}",
        from_script.items.len(),
        from_rust.items.len()
    );
    assert!(!from_script.items.is_empty());
    assert_eq!(from_script.has_more, from_rust.has_more);

    // 逐条比对宿主补齐后的主键、标题、集数、封面、分类。
    for (index, (left, right)) in from_script
        .items
        .iter()
        .zip(from_rust.items.iter())
        .enumerate()
    {
        assert_eq!(left.id, right.id, "第 {index} 条 id");
        assert_eq!(left.source_id, right.source_id, "第 {index} 条 sourceId");
        assert_eq!(left.title, right.title, "第 {index} 条 title");
        assert_eq!(left.cover, right.cover, "第 {index} 条 cover");
        assert_eq!(left.episodes, right.episodes, "第 {index} 条 episodes");
        // `category` 已知差异：编译版的 `tag_names` 只处理数组形式的 `tags`，
        // 站点这个字段是字符串（"现实题材"）时会被丢掉；脚本版两种都收。
        // 脚本是编译版的超集，因此只在编译版有值时要求一致。
        if !right.category.is_empty() {
            assert_eq!(left.category, right.category, "第 {index} 条 category");
        }
    }
}

#[tokio::test]
async fn detail_matches_the_compiled_source() {
    let script = script_source();
    let compiled = MaoguoSource::new();

    let from_script = script.detail(&env(), "21277").await.expect("script detail");
    let from_rust = compiled.detail(&env(), "21277").await.expect("rust detail");

    assert_eq!(from_script.drama.id, from_rust.drama.id);
    assert_eq!(from_script.chapters.len(), from_rust.chapters.len());
    for (index, (left, right)) in from_script
        .chapters
        .iter()
        .zip(from_rust.chapters.iter())
        .enumerate()
    {
        assert_eq!(left.id, right.id, "第 {index} 集 id");
        assert_eq!(left.title, right.title, "第 {index} 集 title");
        assert_eq!(left.video_url, right.video_url, "第 {index} 集 播放地址");
    }
}
