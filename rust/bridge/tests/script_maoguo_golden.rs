//! 猫果脚本扩展的金标准夹具测试。
//!
//! 前身是「脚本 vs 编译版」对拍（`source-maoguo` 已删除，脚本包是唯一实现）。
//! 对拍通过后，把两侧一致的结果钉成金标准：签名串、请求头、目录/详情的
//! 关键字段全部逐字锁定。夹具来自真实站点响应，不访问网络。
//!
//! 实网验证在 `maoguo_live.rs`（`#[ignore]`）。

use std::sync::{Arc, Mutex};

use async_trait::async_trait;

use guo_engine::{
    placeholder_env, Capability, FetchRequest, FetchResponse, JsPluginHost, LogSink, ScriptLimits,
    ScriptSource, SourceEnv, SourceError, SourcePlugin, SourceStore, Transport,
};

const SCRIPT: &str = include_str!("../../examples/extensions/maoguo/main.js");

/// 与真实站点响应同构的夹具传输层，并记录每次请求的 URL 供断言。
struct FixtureTransport {
    requests: Mutex<Vec<String>>,
}

impl FixtureTransport {
    fn new() -> Self {
        Self {
            requests: Mutex::new(Vec::new()),
        }
    }

    fn urls(&self) -> Vec<String> {
        self.requests.lock().expect("lock").clone()
    }
}

#[async_trait]
impl Transport for FixtureTransport {
    async fn fetch(&self, request: FetchRequest) -> Result<FetchResponse, SourceError> {
        self.requests
            .lock()
            .expect("lock")
            .push(request.url.clone());
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
    env_with_transport(Arc::new(FixtureTransport::new()))
}

fn env_with_transport(transport: Arc<dyn Transport>) -> SourceEnv {
    SourceEnv {
        source_id: "maoguo".into(),
        transport,
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
fn script_identity_is_pinned() {
    let meta = script_source().meta();
    assert_eq!(meta.id, "maoguo");
    assert_eq!(meta.name, "猫果");
    assert_eq!(meta.group, "duanju");
    assert!(meta.supports(Capability::Catalog));
    assert!(meta.supports(Capability::Detail));
    assert!(meta.supports(Capability::Search));
}

#[test]
fn signatures_match_the_pinned_goldens() {
    // 签名是「需要代码」的那部分。金标准取自对拍通过时的编译版实现，
    // 脚本改坏签名（RC4 交换顺序、混淆轮次、UTF-8 编码）都会在这里爆。
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
        "24779dff64804dde5bf6bd72d2b0777e",
        "目录签名（tag=0 page=3）"
    );
    assert_eq!(
        value["detail"].as_str().expect("detail"),
        "94a45eec0cb878951f45cc5fee5b32e6",
        "详情签名（playlet_id=21277）"
    );
    assert_eq!(
        value["search"].as_str().expect("search"),
        "f5c487f513101d195773696da9f947b5",
        "搜索签名（含中文 UTF-8）"
    );
    assert_eq!(
        value["tags"].as_str().expect("tags"),
        "9c8abb7acf5f2db77a3fe6fc206a38c1",
        "分类签名"
    );
}

/// 请求头是「签名之外」的另一半：签名算对了但头没带上，站点照样回
/// `44010120 验签失败`（这个坑真实踩过：签名逐字正确、漏了请求头，
/// 表现与「签名算错」一模一样——见 EXTENSION-ECOSYSTEM §3.4）。
#[test]
fn request_headers_match_the_pinned_goldens() {
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

    assert_eq!(
        value["qm-params"].as_str().expect("qm-params"),
        "cLG5Ozo7paHWH2G2pyU1H5w54ln1pqYMtq2-HTZ54q0EpyfLAhRx4qFlgToxN5HjHzk2uz2Tp3U1paHWHTHwgTfwgTHwghHUNIFY4T25AyNx4eKM4eG-pIN-gIgU4e-wNhGxgTfEgz4EpyFwghHLpqk-phNT4eFL4hOwH5w5mqU2m3HWH5HjHzUx4LHWH5HjHzUDpyRjHTZ5gTHwgT0Lgho3FLHjHzJxmqF5A5H5taGD4q2-tqYDtqNx4lx2HTZ5H5w5OyxDBzfQByRlpqw5A5GHH5w5OzRzOzRemaUMcCs2HTZ5gaHjHSN2OEN1BlrQmqF5A5HnNefwgI9wgI9wgI9wH5w5OlJUOzN2uq2-HTZ54q0EpyfLAhRx4qFlgToxN5HjHSNM4Ck14UJe4lJLp3HWHT97AaHjHSNYOLUlpCH5A5Hng5HjHSkLuCNMpqFQmqF5A5H5taGUuq2-HTZ5gI9wgI9wgI9QNlpTNLMwAykTth9wgI9QgI9wgI9wgI9wgI9wH5w5uln5tq2Qpq-5A5H5taGEByHQuq2-HTZ54q0EpyfLAhRx4qFlgToxN5GJ",
        "qm-params 必须逐字节一致（JSON 顺序、Base64、字符映射）"
    );
    assert_eq!(
        value["sign"].as_str().expect("sign"),
        "f81e6e276cca3c328c5b7406fa34e2fc",
        "authorization 签名"
    );
    assert_eq!(value["platform"].as_str(), Some("android"));
    assert_eq!(value["application-id"].as_str(), Some("com.duoduo.read"));
}

#[tokio::test]
async fn catalog_matches_the_pinned_goldens() {
    let script = script_source();

    let page = script
        .catalog(&env(), 1, "0")
        .await
        .expect("script catalog");

    assert_eq!(page.items.len(), 66, "夹具目录条目数");
    assert!(page.has_more);
    for (index, expected) in [
        ("maoguo:21277", "21277", 33, "现实题材", "抚远不远"),
        ("maoguo:24333", "24333", 58, "权谋", "无敌逍遥侯"),
        ("maoguo:23705", "23705", 55, "豪门总裁", "此时不候旧黄昏"),
    ]
    .into_iter()
    .enumerate()
    {
        let item = &page.items[index];
        assert_eq!(item.id, expected.0, "第 {index} 条 id");
        assert_eq!(item.source_id, expected.1, "第 {index} 条 sourceId");
        assert_eq!(item.episodes, expected.2, "第 {index} 条 episodes");
        assert_eq!(item.category, expected.3, "第 {index} 条 category");
        assert_eq!(item.title, expected.4, "第 {index} 条 title");
        assert!(
            item.cover.starts_with("https://cdn.wtzw.com/"),
            "第 {index} 条封面应为站点 CDN：{}",
            item.cover
        );
    }
}

#[tokio::test]
async fn detail_matches_the_pinned_goldens() {
    let script = script_source();

    let detail = script.detail(&env(), "21277").await.expect("script detail");

    assert_eq!(detail.drama.id, "maoguo:21277");
    assert_eq!(detail.chapters.len(), 33, "分集数");
    for (index, expected) in [
        ("21277:1", "第1集"),
        ("21277:2", "第2集"),
        ("21277:3", "第3集"),
    ]
    .into_iter()
    .enumerate()
    {
        let chapter = &detail.chapters[index];
        assert_eq!(chapter.id, expected.0, "第 {index} 集 id");
        assert_eq!(chapter.title, expected.1, "第 {index} 集 title");
        assert!(
            chapter
                .video_url
                .starts_with("https://cdn-vod-playlet.wtzw.com/"),
            "第 {index} 集播放地址应为站点 CDN：{}",
            chapter.video_url
        );
        assert!(
            chapter.video_url.ends_with(".m3u8"),
            "第 {index} 集应为 m3u8"
        );
    }
}

#[tokio::test]
async fn search_matches_the_pinned_goldens() {
    let script = script_source();

    let found = script
        .search(&env(), "都市", 1)
        .await
        .expect("script search");
    assert_eq!(found.items.len(), 66, "夹具搜索条目数");
    assert!(
        found
            .items
            .iter()
            .all(|item| item.id.starts_with("maoguo:")),
        "搜索条目主键必须由宿主补齐"
    );
}

/// 详情请求的 URL 形态（含签名参数）钉死：playlet_id 与 sign 都可从
/// 固定输入确定性推出，改坏 URL 编码或参数顺序会在这里爆。
#[tokio::test]
async fn detail_request_url_matches_the_pinned_golden() {
    let script = script_source();
    let transport = Arc::new(FixtureTransport::new());
    let env = env_with_transport(transport.clone());

    script.detail(&env, "21277").await.expect("script detail");

    let urls = transport.urls();
    let detail_urls: Vec<&String> = urls
        .iter()
        .filter(|url| url.contains("playlet/info"))
        .collect();
    assert_eq!(detail_urls.len(), 1, "详情应恰好发一次 playlet/info 请求");
    let url = detail_urls[0];
    assert!(
        url.starts_with("https://api-read.qmplaylet.com/player/api/v1/playlet/info"),
        "详情域名与路径形态：{url}"
    );
    assert!(
        url.contains("playlet_id=21277"),
        "详情 URL 缺 playlet_id：{url}"
    );
    let sign = url.rsplit("sign=").next().expect("sign");
    assert_eq!(sign, "94a45eec0cb878951f45cc5fee5b32e6", "详情签名串");
}
