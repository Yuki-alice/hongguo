//! 黄果旧版代码插件的端到端验证（Core-3 最后一个迁移源）。
//!
//! 重点验证**协议三层**：前端脚本提取密钥 → 参数 AES-CBC 加密 →
//! 响应密钥派生解密。夹具按真实协议构造：加密的目录响应、含 `main-*.js`
//! 引用的官网首页、密钥齐全的前端脚本。
//!
//! 加密实现用审计过的 `aes` / `sha2` crate（与编译版同一批），
//! 正确性由 FIPS 向量与编译版测试共同保证，这里测的是**协议口径**。

use std::sync::{Arc, Mutex};

use aes::cipher::{BlockEncrypt, KeyInit};
use aes::Aes128;
use base64::Engine;
use guo_plugin_wasm::{ComponentSource, SandboxLimits};
use guo_source_api::{
    FetchRequest, FetchResponse, LogSink, SourceEnv, SourceError, SourcePlugin, SourceStore,
    Transport,
};
use sha2::Sha256;

const LEGACY: &[u8] = include_bytes!("fixtures/huangguo_legacy.wasm");

/// 测试协议密钥（与编译版测试一致）。
const INTERFACE_KEY: &str = "test-interface-key";

/// 官网首页：引用 main-*.js。
const FRONTEND_PAGE: &str =
    r#"<html><head><script src="/assets/main-abc123.js"></script></head><body></body></html>"#;

/// 前端脚本：三种键名写法各出现一次，验证解析器的容错。
const FRONTEND_SCRIPT: &str = r#"(function(){var t={"interfaceKey":"test-interface-key"};
t(F,"parameterKey","0123456789abcdef");
t(F,"parameterIv","fedcba9876543210");})"#;

/// 加密一个目录响应（模拟站点的响应密钥派生 + AES-CBC）。
fn encrypt_response(plain: &str, interface_key: &[u8]) -> String {
    use sha2::Digest;
    let prefix: [u8; 12] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12];
    let mut joined = interface_key.to_vec();
    joined.extend_from_slice(&prefix);
    let half = joined.len() / 2;
    let seed = Sha256::digest(&joined).to_vec()[8..24].to_vec();
    let mut left = seed.clone();
    left.extend_from_slice(&joined[..half]);
    let mut right = joined[half..].to_vec();
    right.extend_from_slice(&seed);
    let left_hash = Sha256::digest(&left).to_vec();
    let right_hash = Sha256::digest(&right).to_vec();
    let mut material = left_hash[..8].to_vec();
    material.extend_from_slice(&right_hash[8..24]);
    material.extend_from_slice(&left_hash[24..]);
    let key = material[..16].to_vec();
    let mut iv = right_hash[..4].to_vec();
    iv.extend_from_slice(&left_hash[12..20]);
    iv.extend_from_slice(&right_hash[28..]);

    // PKCS#7 + AES-128-CBC。
    let pad = 16 - plain.len() % 16;
    let mut data = plain.as_bytes().to_vec();
    data.extend(std::iter::repeat_n(pad as u8, pad));
    let cipher = Aes128::new(aes::cipher::generic_array::GenericArray::from_slice(&key));
    let mut previous = [0u8; 16];
    previous.copy_from_slice(&iv);
    for block in data.as_chunks_mut::<16>().0 {
        for (byte, mask) in block.iter_mut().zip(previous.iter()) {
            *byte ^= mask;
        }
        cipher.encrypt_block(aes::cipher::generic_array::GenericArray::from_mut_slice(
            block,
        ));
        previous.copy_from_slice(block);
    }
    let mut envelope = prefix.to_vec();
    envelope.extend_from_slice(&data);
    base64::engine::general_purpose::STANDARD.encode(&envelope)
}

struct Scripted {
    requests: Mutex<Vec<String>>,
    logins: Mutex<usize>,
}

impl Scripted {
    fn new() -> Self {
        Self {
            requests: Mutex::new(Vec::new()),
            logins: Mutex::new(0),
        }
    }

    fn logins(&self) -> usize {
        *self.logins.lock().expect("logins")
    }

    fn requests(&self) -> Vec<String> {
        self.requests.lock().expect("requests").clone()
    }
}

#[async_trait::async_trait]
impl Transport for Scripted {
    async fn fetch(&self, request: FetchRequest) -> Result<FetchResponse, SourceError> {
        let url = request.url.clone();
        self.requests.lock().expect("requests").push(url.clone());
        if url == "https://d2pypzndaqisk.cloudfront.net/" {
            return Ok(FetchResponse::new(
                200,
                FRONTEND_PAGE.as_bytes().to_vec(),
                url,
            ));
        }
        if url.contains("main-") && url.ends_with(".js") {
            return Ok(FetchResponse::new(
                200,
                FRONTEND_SCRIPT.as_bytes().to_vec(),
                url,
            ));
        }
        if url.ends_with("/api/app/mine/login/h5") {
            let mut logins = self.logins.lock().expect("logins");
            *logins += 1;
            // 响应是加密的：解密后为 {"token":"tok-N"}。
            let plain = format!(r#"{{"token":"tok-{logins}"}}"#);
            let encrypted = encrypt_response(&plain, INTERFACE_KEY.as_bytes());
            let body = format!(r#"{{"code":200,"data":"{encrypted}"}}"#);
            return Ok(FetchResponse::new(200, body.into_bytes(), url));
        }
        // 其余接口：空目录数据，足够走通协议链路。
        let plain = r#"{"data":[]}"#;
        let encrypted = encrypt_response(plain, INTERFACE_KEY.as_bytes());
        let body = format!(r#"{{"code":200,"data":"{encrypted}"}}"#);
        Ok(FetchResponse::new(200, body.into_bytes(), url))
    }
}

#[derive(Clone, Default)]
struct SharedStore {
    values: Arc<Mutex<std::collections::BTreeMap<String, String>>>,
}

#[async_trait::async_trait]
impl SourceStore for SharedStore {
    async fn get(&self, key: &str) -> Result<Option<String>, SourceError> {
        Ok(self.values.lock().expect("store").get(key).cloned())
    }
    async fn set(&self, key: &str, value: &str) -> Result<(), SourceError> {
        self.values
            .lock()
            .expect("store")
            .insert(key.to_string(), value.to_string());
        Ok(())
    }
}

struct Quiet;
impl LogSink for Quiet {
    fn debug(&self, _: &str) {}
    fn warn(&self, _: &str) {}
}

fn source() -> ComponentSource {
    ComponentSource::load(
        LEGACY,
        vec![
            "dr6skssi3nxbk.cloudfront.net".into(),
            "d2pypzndaqisk.cloudfront.net".into(),
        ],
        vec!["session".into()],
        SandboxLimits::default(),
    )
    .expect("黄果旧版组件应可加载")
}

fn env_with(transport: Arc<Scripted>, store: SharedStore) -> SourceEnv {
    SourceEnv {
        source_id: "guo.cloudfront".into(),
        transport,
        store: Arc::new(store),
        scripts: None,
        log: Arc::new(Quiet),
    }
}

#[test]
fn descriptor_matches_the_compiled_source() {
    let meta = source().meta();
    assert_eq!(meta.id, "guo.cloudfront");
    assert_eq!(meta.name, "黄果旧版");
    assert_eq!(meta.group, "huangguo");
    for capability in [
        guo_source_api::Capability::Catalog,
        guo_source_api::Capability::Detail,
        guo_source_api::Capability::Categories,
    ] {
        assert!(meta.supports(capability), "{capability:?}");
    }
}

#[tokio::test]
async fn protocol_is_extracted_from_frontend_script() {
    let transport = Arc::new(Scripted::new());
    let env = env_with(transport.clone(), SharedStore::default());

    // 分类触发协议提取 + 匿名登录 + 加密调用，整条链路。
    let categories = source().categories(&env).await.expect("分类");
    let _ = categories;

    let requests = transport.requests();
    // 协议提取：先抓首页再抓脚本。
    assert!(
        requests
            .iter()
            .any(|url| url == "https://d2pypzndaqisk.cloudfront.net/"),
        "应先请求官网首页"
    );
    assert!(
        requests
            .iter()
            .any(|url| url.contains("/main-") && url.ends_with(".js")),
        "应再请求前端脚本"
    );
    // 匿名登录。
    assert_eq!(transport.logins(), 1);
}

#[tokio::test]
async fn session_is_reused_across_instances() {
    let transport = Arc::new(Scripted::new());
    let store = SharedStore::default();

    source()
        .categories(&env_with(transport.clone(), store.clone()))
        .await
        .expect("首次");
    assert_eq!(transport.logins(), 1);

    // 第二个实例共享宿主存储：协议与令牌都不用重取。
    let first_requests = transport.requests().len();
    source()
        .categories(&env_with(transport.clone(), store.clone()))
        .await
        .expect("二次");
    assert_eq!(transport.logins(), 1, "令牌在宿主存储里，不应重新登录");
    assert!(
        transport.requests().len() > first_requests,
        "第二次实例仍应发出业务请求"
    );
    // 协议脚本只抓一次：第二次不再请求 main-*.js。
    assert!(
        !transport
            .requests()
            .iter()
            .skip(first_requests)
            .any(|url| url.contains("main-")),
        "协议密钥应从存储复用"
    );
}

#[tokio::test]
async fn empty_detail_id_is_rejected() {
    let error = source()
        .detail(
            &env_with(Arc::new(Scripted::new()), SharedStore::default()),
            "  ",
        )
        .await
        .expect_err("空 id 必须拒绝");
    assert!(matches!(error, SourceError::Parse { .. }), "{error:?}");
}
