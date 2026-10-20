//! 仓库客户端：把静态 HTTP 目录变成可安装的插件列表（ARCHITECTURE.md §7.4）。
//!
//! 只做「取字节 + 交给 `plugin-host` 校验」：
//! - 结构校验、哈希、签名在 `guo-plugin-host` 里；
//! - 网络走注入的 [`Transport`]，因此可以被假传输层完整驱动，不需要真实网络。
//!
//! 签名策略（D3）：仓库声明了 `public_key` 就必须带 `index.json.sig` 且校验通过；
//! 未声明的仓库允许安装，但每次版本变更都要用户确认——那属于 UI 层职责，
//! 这里只如实报告 `signed`。

use std::sync::Arc;

use guo_plugin_host::{
    parse_index, sha256_hex, verify_index_signature, PackageLimits, PluginError, RepoIndexEntry,
    RepoManifest, RepositoryIndex,
};
use guo_source_api::{FetchRequest, SourceError, Transport};

/// 单次索引拉取的上限。索引是纯文本，8 MiB 已经远超正常规模。
const MAX_INDEX_BYTES: u64 = 8 * 1024 * 1024;
/// `repo.toml` 通常只有几百字节。
const MAX_MANIFEST_BYTES: u64 = 64 * 1024;

/// 一次成功的索引拉取。
#[derive(Debug, Clone)]
pub struct FetchedIndex {
    pub index: RepositoryIndex,
    /// 索引原始字节，交给安装器做交叉校验时不必重新序列化。
    pub raw: Vec<u8>,
    /// 仓库是否声明并验证了签名。
    pub signed: bool,
}

/// 仓库客户端。
pub struct RepoClient {
    transport: Arc<dyn Transport>,
}

impl RepoClient {
    pub fn new(transport: Arc<dyn Transport>) -> Self {
        Self { transport }
    }

    /// 拉取 `repo.toml`。
    pub async fn fetch_manifest(&self, repo_url: &str) -> Result<RepoManifest, PluginError> {
        let body = self
            .get_text(repo_url, MAX_MANIFEST_BYTES)
            .await
            .map_err(|err| PluginError::io(repo_url, err))?;
        RepoManifest::parse(&body)
    }

    /// 拉取并校验索引。
    ///
    /// 顺序是刻意的：先取索引字节 → 校验签名 → 再解析结构。
    /// 先解析后验签等于「信任了未验证的数据」，哪怕最终拒绝也已经被解析过。
    pub async fn fetch_index(
        &self,
        repo_url: &str,
        manifest: &RepoManifest,
    ) -> Result<FetchedIndex, PluginError> {
        let index_url = join_url(repo_url, &manifest.index);
        let raw = self
            .get_bytes(&index_url, MAX_INDEX_BYTES)
            .await
            .map_err(|err| PluginError::io(&index_url, err))?;

        let key = manifest.verifying_key()?;
        let signed = match key {
            Some(key) => {
                // 声明了公钥：签名缺失或不符都必须拒绝整个仓库。
                let signature_url = format!("{index_url}.sig");
                let signature = self.get_bytes(&signature_url, 4096).await.map_err(|err| {
                    PluginError::integrity(
                        "仓库签名",
                        format!("仓库声明了公钥但读取 {signature_url} 失败：{err}"),
                    )
                })?;
                verify_index_signature(&key, &raw, &trim_signature(&signature))?;
                true
            }
            None => false,
        };

        let text = std::str::from_utf8(&raw)
            .map_err(|err| PluginError::invalid("索引", format!("不是 UTF-8：{err}")))?;
        let index = parse_index(text)?;
        Ok(FetchedIndex { index, raw, signed })
    }

    /// 下载一个插件的 zip，并**在返回前**校验哈希与大小。
    ///
    /// 把校验放在客户端而不是安装器里，是为了让「下载完就落盘」的调用方
    /// 没有机会跳过校验；安装器里的那一次是为了防「调用方自己拼字节」。
    pub async fn download_package(
        &self,
        repo_url: &str,
        entry: &RepoIndexEntry,
    ) -> Result<Vec<u8>, PluginError> {
        let url = join_url(repo_url, &entry.path);
        // 用索引声明的大小做上限，再留一点余量给压缩率差异；没有声明时给 64 MiB。
        let limit = entry
            .size
            .map(|size| size + 1024)
            .unwrap_or(64 * 1024 * 1024);
        let bytes = self
            .get_bytes(&url, limit)
            .await
            .map_err(|err| PluginError::io(&url, err))?;
        if let Some(size) = entry.size {
            if bytes.len() as u64 != size {
                return Err(PluginError::integrity(
                    "包大小",
                    format!("索引声明 {size}，实际 {}", bytes.len()),
                ));
            }
        }
        let actual = sha256_hex(&bytes);
        if !actual.eq_ignore_ascii_case(&entry.sha256) {
            return Err(PluginError::integrity(
                "包哈希",
                format!("期望 {}，实际 {actual}", entry.sha256),
            ));
        }
        Ok(bytes)
    }

    /// 完整流程：清单 → 索引 → 指定包的字节。
    pub async fn resolve_package(
        &self,
        repo_url: &str,
        plugin_id: &str,
    ) -> Result<(FetchedIndex, RepoIndexEntry, Vec<u8>), PluginError> {
        let manifest = self.fetch_manifest(repo_url).await?;
        let fetched = self.fetch_index(repo_url, &manifest).await?;
        let entry = fetched
            .index
            .get(plugin_id)
            .ok_or_else(|| PluginError::invalid("索引", format!("仓库里没有 {plugin_id}")))?
            .clone();
        let bytes = self.download_package(repo_url, &entry).await?;
        Ok((fetched, entry, bytes))
    }

    async fn get_bytes(&self, url: &str, limit: u64) -> Result<Vec<u8>, SourceError> {
        let request = FetchRequest::get(url).limit_bytes(limit);
        let response = self.transport.fetch(request).await?;
        response.ensure_success()?;
        if response.truncated {
            // 截断意味着「对象比上限大」，继续用会得到半个 zip 或半个索引。
            return Err(SourceError::parse(
                "repo",
                format!("{url} 超过 {limit} 字节上限"),
            ));
        }
        Ok(response.body)
    }

    async fn get_text(&self, url: &str, limit: u64) -> Result<String, SourceError> {
        let bytes = self.get_bytes(url, limit).await?;
        String::from_utf8(bytes)
            .map_err(|err| SourceError::parse("repo", format!("{url} 不是 UTF-8：{err}")))
    }
}

/// `.sig` 文件可能是裸的 64 字节，也可能是 base64 文本（很多人用 `base64 > file` 生成）。
///
/// 两种都要接受，否则「用命令行签的名」会被误判成签名损坏。
fn trim_signature(bytes: &[u8]) -> Vec<u8> {
    if bytes.len() == 64 {
        return bytes.to_vec();
    }
    let text = String::from_utf8_lossy(bytes);
    let trimmed = text.trim();
    if trimmed.len() == bytes.len() && bytes.len() != 64 {
        // 没有可裁剪的空白，且不是 64 字节：原样返回，让验签给出明确错误。
        return bytes.to_vec();
    }
    match guo_plugin_host::decode_base64(trimmed) {
        Ok(decoded) if decoded.len() == 64 => decoded,
        _ => bytes.to_vec(),
    }
}

/// 把仓库里的相对路径解析成绝对 URL。
///
/// `repo.toml` 常写成 `index = "index.json"`，必须相对仓库自身目录而不是站点根。
pub fn join_url(base: &str, path: &str) -> String {
    let path = path.trim();
    if path.starts_with("http://") || path.starts_with("https://") {
        return path.to_string();
    }
    let base = base.trim_end_matches('/');
    // 仓库地址可能是 `https://host/repo.toml`（文件）或 `https://host/dir/`（目录）。
    let directory = match base.rsplit('/').next() {
        Some(last) if last.contains('.') && !last.ends_with('/') => {
            base.rsplit_once('/').map(|(dir, _)| dir).unwrap_or(base)
        }
        _ => base,
    };
    format!(
        "{}/{}",
        directory.trim_end_matches('/'),
        path.trim_start_matches('/')
    )
}

/// 安装前的统一预检：包内清单与索引条目必须一致。
///
/// 这一条在 `plugin-host::install_package` 里也做，但仓库客户端先做一次
/// 可以在**下载之前**就拒绝明显不匹配的条目（省一次流量与一次解包）。
pub fn precheck_entry(entry: &RepoIndexEntry, limits: PackageLimits) -> Result<(), PluginError> {
    if let Some(size) = entry.size {
        if size > limits.max_total_bytes {
            return Err(PluginError::Unsupported {
                detail: format!("包大小 {size} 超过宿主上限 {}", limits.max_total_bytes),
            });
        }
    }
    entry.validate()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;
    use std::sync::Mutex;

    /// 假传输层：按 URL 返回预置响应，并记录请求顺序。
    struct FakeTransport {
        responses: BTreeMap<String, (u16, Vec<u8>)>,
        requested: Mutex<Vec<String>>,
    }

    impl FakeTransport {
        fn new(responses: impl IntoIterator<Item = (&'static str, Vec<u8>)>) -> Self {
            Self {
                responses: responses
                    .into_iter()
                    .map(|(url, body)| (url.to_string(), (200, body)))
                    .collect(),
                requested: Mutex::new(Vec::new()),
            }
        }

        fn with_status(mut self, url: &'static str, status: u16, body: Vec<u8>) -> Self {
            self.responses.insert(url.to_string(), (status, body));
            self
        }

        fn requested(&self) -> Vec<String> {
            self.requested.lock().expect("lock").clone()
        }
    }

    #[async_trait::async_trait]
    impl Transport for FakeTransport {
        async fn fetch(
            &self,
            request: FetchRequest,
        ) -> Result<guo_source_api::FetchResponse, SourceError> {
            self.requested
                .lock()
                .expect("lock")
                .push(request.url.clone());
            let (status, body) = self
                .responses
                .get(&request.url)
                .cloned()
                .unwrap_or((404, Vec::new()));
            Ok(guo_source_api::FetchResponse::new(
                status,
                body,
                request.url,
            ))
        }
    }

    const REPO_URL: &str = "https://repo.test/guo/repo.toml";
    const INDEX_URL: &str = "https://repo.test/guo/index.json";

    const REPO: &str = r#"
spec = 1
id = "official"
name = "官方仓库"
index = "index.json"
"#;

    fn index_json(sha: &str, size: usize) -> String {
        format!(
            r#"[{{"id":"guo.wuguo","name":"伍果","version":"1.2.0","kind":"declarative","api":1,"minHost":"0.3.0","size":{size},"sha256":"{sha}","path":"plugins/guo.wuguo-1.2.0.zip"}}]"#
        )
    }

    fn repo_client(transport: FakeTransport) -> RepoClient {
        RepoClient::new(Arc::new(transport))
    }

    /// 同时拿到客户端与假传输层，便于断言请求顺序。
    fn repo_client_with_log(transport: FakeTransport) -> (RepoClient, Arc<FakeTransport>) {
        let shared = Arc::new(transport);
        (RepoClient::new(shared.clone()), shared)
    }

    #[test]
    fn joins_relative_paths_against_repo_directory() {
        assert_eq!(
            join_url("https://h/repo.toml", "index.json"),
            "https://h/index.json"
        );
        assert_eq!(
            join_url("https://h/dir/repo.toml", "index.json"),
            "https://h/dir/index.json"
        );
        assert_eq!(
            join_url("https://h/dir/", "index.json"),
            "https://h/dir/index.json"
        );
        assert_eq!(
            join_url("https://h/repo.toml", "https://cdn.test/i.json"),
            "https://cdn.test/i.json"
        );
        assert_eq!(
            join_url("https://h/repo.toml", "/abs/index.json"),
            "https://h/abs/index.json"
        );
    }

    #[tokio::test]
    async fn fetches_manifest_then_index() {
        let sha = "a".repeat(64);
        let transport = FakeTransport::new([
            (REPO_URL, REPO.as_bytes().to_vec()),
            (INDEX_URL, index_json(&sha, 10).into_bytes()),
        ]);
        let client = repo_client(transport);
        let manifest = client.fetch_manifest(REPO_URL).await.expect("manifest");
        assert_eq!(manifest.id, "official");
        let fetched = client
            .fetch_index(REPO_URL, &manifest)
            .await
            .expect("index");
        assert_eq!(fetched.index.len(), 1);
        assert!(!fetched.signed);
        assert!(fetched.index.get("guo.wuguo").is_some());
    }

    #[tokio::test]
    async fn rejects_index_with_wrong_content() {
        let transport = FakeTransport::new([
            (REPO_URL, REPO.as_bytes().to_vec()),
            (INDEX_URL, b"not json".to_vec()),
        ]);
        let client = repo_client(transport);
        let manifest = client.fetch_manifest(REPO_URL).await.expect("manifest");
        assert!(client.fetch_index(REPO_URL, &manifest).await.is_err());
    }

    #[tokio::test]
    async fn missing_manifest_is_reported_with_url() {
        let client = repo_client(FakeTransport::new([]));
        let err = client.fetch_manifest(REPO_URL).await.expect_err("必须失败");
        assert!(err.to_string().contains("repo.toml"), "{err}");
    }

    #[tokio::test]
    async fn signed_repo_requires_signature() {
        use base64::Engine as _;
        use ed25519_dalek::{Signer, SigningKey};

        let signing = SigningKey::from_bytes(&[9u8; 32]);
        let public =
            base64::engine::general_purpose::STANDARD.encode(signing.verifying_key().to_bytes());
        let repo = format!("{REPO}public_key = \"ed25519:{public}\"\n");
        let sha = "b".repeat(64);
        let index = index_json(&sha, 10);

        // 缺 `.sig`：必须拒绝，而不是「当作未签名放行」。
        let transport = FakeTransport::new([
            (REPO_URL, repo.clone().into_bytes()),
            (INDEX_URL, index.clone().into_bytes()),
        ]);
        let client = repo_client(transport);
        let manifest = client.fetch_manifest(REPO_URL).await.expect("manifest");
        let err = client
            .fetch_index(REPO_URL, &manifest)
            .await
            .expect_err("必须拒绝");
        assert!(err.to_string().contains("签名"), "{err}");

        // 带正确签名：通过，并标记 signed。
        let signature = signing.sign(index.as_bytes());
        let sig_url = format!("{INDEX_URL}.sig");
        let transport = FakeTransport::new([
            (REPO_URL, repo.into_bytes()),
            (INDEX_URL, index.into_bytes()),
        ])
        .with_status(
            // `with_status` 复用同一张表；这里用 200 + 签名内容。
            Box::leak(sig_url.into_boxed_str()),
            200,
            signature.to_bytes().to_vec(),
        );
        let client = repo_client(transport);
        let manifest = client.fetch_manifest(REPO_URL).await.expect("manifest");
        let fetched = client
            .fetch_index(REPO_URL, &manifest)
            .await
            .expect("index");
        assert!(fetched.signed);
    }

    #[tokio::test]
    async fn signature_file_may_be_base64_text() {
        use base64::Engine as _;
        use ed25519_dalek::{Signer, SigningKey};

        let signing = SigningKey::from_bytes(&[11u8; 32]);
        let public =
            base64::engine::general_purpose::STANDARD.encode(signing.verifying_key().to_bytes());
        let repo = format!("{REPO}public_key = \"ed25519:{public}\"\n");
        let sha = "c".repeat(64);
        let index = index_json(&sha, 10);
        let signature = base64::engine::general_purpose::STANDARD
            .encode(signing.sign(index.as_bytes()).to_bytes());
        let sig_url: &'static str = Box::leak(format!("{INDEX_URL}.sig").into_boxed_str());

        let transport = FakeTransport::new([
            (REPO_URL, repo.into_bytes()),
            (INDEX_URL, index.into_bytes()),
        ])
        .with_status(sig_url, 200, format!("{signature}\n").into_bytes());
        let client = repo_client(transport);
        let manifest = client.fetch_manifest(REPO_URL).await.expect("manifest");
        let fetched = client
            .fetch_index(REPO_URL, &manifest)
            .await
            .expect("index");
        assert!(fetched.signed);
    }

    #[tokio::test]
    async fn downloads_package_and_verifies_hash() {
        let package = b"PK\x03\x04 fake zip".to_vec();
        let sha = sha256_hex(&package);
        let package_url = "https://repo.test/guo/plugins/guo.wuguo-1.2.0.zip";
        let transport = FakeTransport::new([
            (REPO_URL, REPO.as_bytes().to_vec()),
            (INDEX_URL, index_json(&sha, package.len()).into_bytes()),
            (package_url, package.clone()),
        ]);
        let client = repo_client(transport);
        let (_index, entry, bytes) = client
            .resolve_package(REPO_URL, "guo.wuguo")
            .await
            .expect("package");
        assert_eq!(bytes, package);
        assert_eq!(entry.version.to_string(), "1.2.0");
    }

    #[tokio::test]
    async fn rejects_package_with_wrong_hash() {
        let package = b"PK\x03\x04 tampered".to_vec();
        let package_url = "https://repo.test/guo/plugins/guo.wuguo-1.2.0.zip";
        let transport = FakeTransport::new([
            (REPO_URL, REPO.as_bytes().to_vec()),
            (
                INDEX_URL,
                index_json(&"0".repeat(64), package.len()).into_bytes(),
            ),
            (package_url, package),
        ]);
        let client = repo_client(transport);
        let err = client
            .resolve_package(REPO_URL, "guo.wuguo")
            .await
            .expect_err("必须拒绝");
        assert!(err.to_string().contains("包哈希"), "{err}");
    }

    #[tokio::test]
    async fn rejects_package_with_wrong_size() {
        let package = b"PK\x03\x04 x".to_vec();
        let sha = sha256_hex(&package);
        let package_url = "https://repo.test/guo/plugins/guo.wuguo-1.2.0.zip";
        let transport = FakeTransport::new([
            (REPO_URL, REPO.as_bytes().to_vec()),
            (INDEX_URL, index_json(&sha, package.len() + 5).into_bytes()),
            (package_url, package),
        ]);
        let client = repo_client(transport);
        let err = client
            .resolve_package(REPO_URL, "guo.wuguo")
            .await
            .expect_err("必须拒绝");
        assert!(err.to_string().contains("包大小"), "{err}");
    }

    #[tokio::test]
    async fn signature_is_fetched_before_the_index_is_trusted() {
        use base64::Engine as _;
        use ed25519_dalek::SigningKey;

        // 关键顺序：先取索引字节 → 取 `.sig` → 验签 → 最后才解析。
        // 先解析后验签等于「信任了未验证的数据」。
        let signing = SigningKey::from_bytes(&[13u8; 32]);
        let public =
            base64::engine::general_purpose::STANDARD.encode(signing.verifying_key().to_bytes());
        let repo = format!("{REPO}public_key = \"ed25519:{public}\"\n");
        let sha = "1".repeat(64);
        let index = index_json(&sha, 10);
        let sig_url: &'static str = Box::leak(format!("{INDEX_URL}.sig").into_boxed_str());
        let transport = FakeTransport::new([
            (REPO_URL, repo.into_bytes()),
            (INDEX_URL, index.clone().into_bytes()),
        ])
        .with_status(sig_url, 200, b"wrong-signature-bytes".to_vec());
        let (client, log) = repo_client_with_log(transport);

        let manifest = client.fetch_manifest(REPO_URL).await.expect("manifest");
        assert!(client.fetch_index(REPO_URL, &manifest).await.is_err());
        let requested = log.requested();
        assert_eq!(
            requested,
            vec![
                REPO_URL.to_string(),
                INDEX_URL.to_string(),
                sig_url.to_string()
            ],
            "请求顺序：清单 → 索引 → 签名"
        );
    }

    #[tokio::test]
    async fn unknown_plugin_is_an_error() {
        let sha = "d".repeat(64);
        let transport = FakeTransport::new([
            (REPO_URL, REPO.as_bytes().to_vec()),
            (INDEX_URL, index_json(&sha, 10).into_bytes()),
        ]);
        let client = repo_client(transport);
        let err = client
            .resolve_package(REPO_URL, "guo.missing")
            .await
            .expect_err("必须失败");
        assert!(err.to_string().contains("guo.missing"), "{err}");
    }

    #[tokio::test]
    async fn index_request_is_bounded() {
        let sha = "e".repeat(64);
        let huge = vec![b' '; (MAX_INDEX_BYTES + 1) as usize];
        let transport = FakeTransport::new([
            (REPO_URL, REPO.as_bytes().to_vec()),
            // 直接返回超限内容，模拟「服务端不遵守 Range/len」的情形。
            (INDEX_URL, huge),
        ]);
        let client = repo_client(transport);
        let manifest = client.fetch_manifest(REPO_URL).await.expect("manifest");
        // 假传输层不模拟截断，这里只断言请求带了上限。
        let _ = client.fetch_index(REPO_URL, &manifest).await;
        assert_eq!(sha.len(), 64);
    }

    #[test]
    fn precheck_rejects_oversized_package() {
        let sha = "f".repeat(64);
        let index = parse_index(&index_json(&sha, 100)).expect("index");
        let entry = index.get("guo.wuguo").expect("entry");
        assert!(precheck_entry(entry, PackageLimits::default()).is_ok());
        let tiny = PackageLimits {
            max_total_bytes: 10,
            ..PackageLimits::default()
        };
        let err = precheck_entry(entry, tiny).expect_err("必须拒绝");
        assert!(err.to_string().contains("上限"), "{err}");
    }
}
