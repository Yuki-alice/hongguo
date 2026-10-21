//! 牛果的离线对拍：夹具是 2026-10-21 的真实加密响应。
//!
//! 与其他站源不同，这里测的是完整链路：`FixtureTransport` 原样返回 Base64
//! 密文，站源自己按「实际请求 URI」派生密钥、解密、再解析。任何一处口径
//! 不一致（URI 取路径还是全地址、Base64 变体、填充处理）都会让这条测试失败，
//! 而这正是线上最容易静默出错的地方。

use std::sync::Arc;

use async_trait::async_trait;

use guo_engine::{
    Capability, FetchRequest, FetchResponse, LogSink, NiuguoSource, SourceEnv, SourceError,
    SourcePlugin, SourceStore, Transport,
};

const LIST: &str = include_str!("fixtures/niuguo_list.b64");
const DETAIL: &str = include_str!("fixtures/niuguo_detail.b64");

/// 按请求路径返回对应的加密响应；不联网、不校验参数。
struct FixtureTransport;

#[async_trait]
impl Transport for FixtureTransport {
    async fn fetch(&self, request: FetchRequest) -> Result<FetchResponse, SourceError> {
        let body = if request.url.contains("/detail") {
            DETAIL
        } else {
            LIST
        };
        Ok(FetchResponse::new(
            200,
            body.as_bytes().to_vec(),
            request.url,
        ))
    }
}

/// 只应答第三方解析服务：第一个域名失败，验证回退顺序。
struct ParseTransport {
    attempts: Arc<std::sync::Mutex<Vec<String>>>,
}

#[async_trait]
impl Transport for ParseTransport {
    async fn fetch(&self, request: FetchRequest) -> Result<FetchResponse, SourceError> {
        self.attempts
            .lock()
            .expect("attempts")
            .push(request.url.clone());
        if request.url.contains("gzbaoxian") {
            return Err(SourceError::Network {
                url: request.url,
                detail: "连接超时".into(),
            });
        }
        let body = r#"{"code":200,"url":"https://play.example.com/hls/index.m3u8"}"#;
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
        source_id: "niuguo".into(),
        transport: Arc::new(FixtureTransport),
        store: Arc::new(NoopStore),
        scripts: None,
        log: Arc::new(NoopLog),
    }
}

#[tokio::test]
async fn catalog_decrypts_real_response() {
    let source = NiuguoSource::new();
    let page = source.catalog(&env(), 1, "").await.expect("目录应解密成功");
    assert_eq!(page.items.len(), 12, "真实目录返回 12 条");

    let first = &page.items[0];
    assert_eq!(first.source, "niuguo");
    assert!(first.id.starts_with("niuguo:"));
    assert!(!first.title.is_empty(), "标题不能为空");
    assert!(
        first.cover.starts_with("http"),
        "封面应是绝对地址：{}",
        first.cover
    );
    assert!(
        page.items.iter().all(|item| !item.source_id.is_empty()),
        "每条都要有主键"
    );
}

#[tokio::test]
async fn detail_decrypts_and_yields_all_episodes() {
    let source = NiuguoSource::new();
    let detail = source
        .detail(&env(), "582428")
        .await
        .expect("详情应解密成功");
    assert_eq!(detail.drama.title, "认下混混老爹，我一路青云");
    assert_eq!(
        detail.chapters.len(),
        75,
        "详情声明 75 集，实际 {}",
        detail.chapters.len()
    );

    let first = &detail.chapters[0];
    assert_eq!(first.title, "第01集");
    assert!(
        !first.video_url.is_empty(),
        "分集要带上内部分集 ID，取流时还要用它"
    );
    assert_eq!(first.id, "582428:1", "分集按 1 起编号");
}

#[tokio::test]
async fn resolve_falls_back_to_the_second_parse_service() {
    let attempts = Arc::new(std::sync::Mutex::new(Vec::new()));
    let source = NiuguoSource::new();
    let chapter = guo_engine::Chapter {
        id: "582428:1".into(),
        title: "第01集".into(),
        source: "niuguo".into(),
        video_url: "7696746275915451454".into(),
        ..Default::default()
    };
    let env = SourceEnv {
        source_id: "niuguo".into(),
        transport: Arc::new(ParseTransport {
            attempts: attempts.clone(),
        }),
        store: Arc::new(NoopStore),
        scripts: None,
        log: Arc::new(NoopLog),
    };
    let media = source
        .resolve(&env, &guo_engine::Drama::default(), &chapter)
        .await
        .expect("取流应回退成功");
    assert_eq!(media.url, "https://play.example.com/hls/index.m3u8");

    let tried = attempts.lock().expect("attempts").clone();
    assert_eq!(tried.len(), 3, "第一个域名两次尝试后换域名：{tried:?}");
    assert!(tried[0].contains("gzbaoxian"), "先试主域名");
    assert!(tried[2].contains("101.42.92.211"), "回退到备用域名");
    assert!(
        tried[0].ends_with("url=7696746275915451454"),
        "分集 ID 要原样带上：{}",
        tried[0]
    );
}

#[tokio::test]
async fn resolve_rejects_empty_chapter_id() {
    let source = NiuguoSource::new();
    let chapter = guo_engine::Chapter {
        id: "582428:1".into(),
        source: "niuguo".into(),
        ..Default::default()
    };
    let error = source
        .resolve(&env(), &guo_engine::Drama::default(), &chapter)
        .await
        .expect_err("缺少解析 ID 应报错");
    assert!(
        format!("{error:?}").contains("解析 ID"),
        "错误文案要指向真正的原因：{error:?}"
    );
}

#[test]
fn meta_declares_expected_capabilities() {
    let meta = NiuguoSource::new().meta();
    assert_eq!(meta.id, "niuguo");
    assert_eq!(meta.name, "牛果");
    for capability in [Capability::Catalog, Capability::Detail, Capability::Search] {
        assert!(
            meta.capabilities.contains(&capability),
            "缺少能力位 {capability:?}"
        );
    }
}
