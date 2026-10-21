//! 仓库协议：`repo.toml` + `index.json` + 可选 Ed25519 签名（ARCHITECTURE.md §7.4）。
//!
//! D3 已定：签名不强制。逐包 SHA-256 无论如何都强制，那由 [`crate::package`] 负责。

use std::collections::BTreeMap;

use base64::Engine as _;
use ed25519_dalek::{Signature, VerifyingKey};
use semver::Version;
use serde::Deserialize;

use crate::error::PluginError;
use crate::manifest::{PluginId, PluginKind};

/// 当前支持的仓库格式版本。
pub const REPO_SPEC: u32 = 1;

/// `repo.toml`。
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct RepoManifest {
    pub spec: u32,
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub homepage: Option<String>,
    /// 索引路径，相对仓库根或绝对 URL。
    pub index: String,
    /// `ed25519:<base64>`；声明后索引必须带有效签名。
    #[serde(default)]
    pub public_key: Option<String>,
    #[serde(default)]
    pub issued_at: Option<String>,
}

impl RepoManifest {
    pub fn parse(text: &str) -> Result<Self, PluginError> {
        let manifest: Self = toml::from_str(text)
            .map_err(|err| PluginError::invalid("仓库清单", format!("{err}")))?;
        if manifest.spec != REPO_SPEC {
            return Err(PluginError::Unsupported {
                detail: format!(
                    "仓库格式 spec {} 不受支持（当前 {REPO_SPEC}）",
                    manifest.spec
                ),
            });
        }
        if manifest.id.trim().is_empty() || manifest.name.trim().is_empty() {
            return Err(PluginError::invalid("仓库清单", "id 与 name 不能为空"));
        }
        if manifest.index.trim().is_empty() {
            return Err(PluginError::invalid("仓库清单", "缺少 index"));
        }
        if manifest.public_key.is_some() {
            // 提前解析，避免「加了仓库到安装时才发现公钥写错」。
            parse_public_key(manifest.public_key.as_deref().unwrap_or_default())?;
        }
        Ok(manifest)
    }

    /// 解析 `ed25519:<base64>` 形式的公钥。
    pub fn verifying_key(&self) -> Result<Option<VerifyingKey>, PluginError> {
        match self.public_key.as_deref() {
            None => Ok(None),
            Some(text) => parse_public_key(text).map(Some),
        }
    }

    pub fn is_signed(&self) -> bool {
        self.public_key.is_some()
    }
}

/// 解码标准 base64（带 padding）。
///
/// 暴露出来是为了让仓库客户端统一处理 `.sig` 的两种形态（裸 64 字节 / base64 文本），
/// 避免每个调用方各写一份 base64 依赖。
pub fn decode_base64(text: &str) -> Result<Vec<u8>, PluginError> {
    base64::engine::general_purpose::STANDARD
        .decode(text.trim())
        .map_err(|err| PluginError::invalid("base64", format!("解码失败：{err}")))
}

fn parse_public_key(text: &str) -> Result<VerifyingKey, PluginError> {
    let body = text
        .strip_prefix("ed25519:")
        .ok_or_else(|| PluginError::invalid("仓库公钥", "必须以 ed25519: 开头"))?;
    // 保留「公钥」这个上下文：只报 base64 解码失败，用户不知道该改哪个字段。
    let bytes =
        decode_base64(body).map_err(|err| PluginError::invalid("仓库公钥", format!("{err}")))?;
    let array: [u8; 32] = bytes.as_slice().try_into().map_err(|_| {
        PluginError::invalid(
            "仓库公钥",
            format!("长度应为 32 字节，实际 {}", bytes.len()),
        )
    })?;
    VerifyingKey::from_bytes(&array)
        .map_err(|err| PluginError::invalid("仓库公钥", format!("不是有效公钥：{err}")))
}

/// `index.json` 的单项。字段名与 Kazumi 保持同构，另加 `sha256` 与 `kind`。
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RepoIndexEntry {
    pub id: PluginId,
    pub name: String,
    pub version: Version,
    #[serde(default)]
    pub kind: Option<PluginKind>,
    #[serde(default)]
    pub api: Option<u32>,
    #[serde(default, alias = "minHost")]
    pub min_host: Option<Version>,
    #[serde(default)]
    pub author: Option<String>,
    #[serde(default, alias = "lastUpdate", alias = "updatedAt")]
    pub updated_at: Option<String>,
    #[serde(default)]
    pub size: Option<u64>,
    pub sha256: String,
    pub path: String,
    #[serde(default)]
    pub changelog: Option<String>,
}

impl RepoIndexEntry {
    pub fn validate(&self) -> Result<(), PluginError> {
        if self.sha256.len() != 64 || !self.sha256.chars().all(|c| c.is_ascii_hexdigit()) {
            return Err(PluginError::invalid(
                "索引",
                format!("{} 的 sha256 不是 64 位十六进制", self.id),
            ));
        }
        if self.path.trim().is_empty() || self.path.starts_with('/') || self.path.contains("..") {
            return Err(PluginError::unsafe_entry(format!(
                "{} 的 path 必须是仓库内相对路径：{}",
                self.id, self.path
            )));
        }
        if self.name.trim().is_empty() {
            return Err(PluginError::invalid(
                "索引",
                format!("{} 缺少 name", self.id),
            ));
        }
        Ok(())
    }
}

/// 从文件读取并解析 `repo.toml`。
///
/// 单独提供是为了让构建脚本与测试不必各自拼「读文件 + 解析」这两步，
/// 也避免把 `std::fs` 依赖渗进 [`RepoManifest::parse`] 这样的纯函数。
pub fn parse_repo_from_path(path: &std::path::Path) -> Result<RepoManifest, PluginError> {
    let text = std::fs::read_to_string(path)
        .map_err(|err| PluginError::io(path.display().to_string(), err))?;
    RepoManifest::parse(&text)
}

/// 解析后的索引：去重并保留「每个 id 的最新版本」。
#[derive(Debug, Clone, Default)]
pub struct RepositoryIndex {
    entries: BTreeMap<String, RepoIndexEntry>,
}

impl RepositoryIndex {
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn get(&self, id: &str) -> Option<&RepoIndexEntry> {
        self.entries.get(id)
    }

    pub fn entries(&self) -> impl Iterator<Item = &RepoIndexEntry> {
        self.entries.values()
    }
}

/// 解析 `index.json`。同一 id 出现多次时保留版本号最高的一条。
pub fn parse_index(text: &str) -> Result<RepositoryIndex, PluginError> {
    let list: Vec<RepoIndexEntry> =
        serde_json::from_str(text).map_err(|err| PluginError::invalid("索引", format!("{err}")))?;
    let mut entries: BTreeMap<String, RepoIndexEntry> = BTreeMap::new();
    for entry in list {
        entry.validate()?;
        let key = entry.id.as_str().to_string();
        match entries.get(&key) {
            Some(existing) if existing.version >= entry.version => {}
            _ => {
                entries.insert(key, entry);
            }
        }
    }
    Ok(RepositoryIndex { entries })
}

/// 校验 `index.json.sig`（对索引**原始字节**的签名）。
pub fn verify_index_signature(
    key: &VerifyingKey,
    index: &[u8],
    signature: &[u8],
) -> Result<(), PluginError> {
    let signature = Signature::from_slice(signature)
        .map_err(|err| PluginError::integrity("仓库签名", format!("格式非法：{err}")))?;
    key.verify_strict(index, &signature)
        .map_err(|err| PluginError::integrity("仓库签名", format!("校验失败：{err}")))
}

/// 仓库信任状态的对外展示取值，供 UI 标注。
pub fn trust_label(signed: bool, trusted: bool) -> &'static str {
    match (signed, trusted) {
        (true, true) => "已签名",
        (true, false) => "签名已变更",
        (false, _) => "未签名",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};

    const REPO: &str = r#"
spec = 1
id = "official"
name = "真果鉴官方规则仓库"
description = "官方维护的短剧站源规则"
index = "index.json"
issued_at = "2026-10-19T00:00:00Z"
"#;

    fn index_json(sha: &str) -> String {
        format!(
            r#"[
  {{
    "id": "guo.wuguo",
    "name": "伍果",
    "version": "1.2.0",
    "kind": "declarative",
    "api": 1,
    "minHost": "0.3.0",
    "author": "official",
    "updatedAt": "2026-10-18T12:00:00Z",
    "size": 4096,
    "sha256": "{sha}",
    "path": "plugins/guo.wuguo/guo.wuguo-1.2.0.zip"
  }}
]"#
        )
    }

    #[test]
    fn parses_unsigned_repo() {
        let repo = RepoManifest::parse(REPO).expect("repo");
        assert!(!repo.is_signed());
        assert!(repo.verifying_key().expect("key").is_none());
    }

    #[test]
    fn rejects_repo_with_bad_spec() {
        let text = REPO.replace("spec = 1", "spec = 2");
        assert!(RepoManifest::parse(&text).is_err());
    }

    #[test]
    fn rejects_repo_with_broken_public_key() {
        let text = format!("{REPO}\npublic_key = \"ed25519:not-base64!\"\n");
        let err = RepoManifest::parse(&text).expect_err("must fail");
        assert!(err.to_string().contains("公钥"), "{err}");
    }

    #[test]
    fn parses_index_and_maps_kazumi_field_names() {
        let index = parse_index(&index_json(&"a".repeat(64))).expect("index");
        assert_eq!(index.len(), 1);
        let entry = index.get("guo.wuguo").expect("entry");
        assert_eq!(entry.version, Version::new(1, 2, 0));
        assert_eq!(entry.min_host, Some(Version::new(0, 3, 0)));
        assert_eq!(entry.updated_at.as_deref(), Some("2026-10-18T12:00:00Z"));
        assert_eq!(entry.kind, Some(PluginKind::Declarative));
    }

    #[test]
    fn keeps_highest_version_per_id() {
        let sha = "b".repeat(64);
        let text = format!(
            "[{},{},{}]",
            entry_json("guo.wuguo", "1.0.0", &sha),
            entry_json("guo.wuguo", "1.3.0", &sha),
            entry_json("guo.wuguo", "1.1.0", &sha)
        );
        let index = parse_index(&text).expect("index");
        assert_eq!(index.len(), 1);
        assert_eq!(
            index.get("guo.wuguo").expect("entry").version,
            Version::new(1, 3, 0)
        );
    }

    fn entry_json(id: &str, version: &str, sha: &str) -> String {
        format!(
            r#"{{"id":"{id}","name":"x","version":"{version}","sha256":"{sha}","path":"plugins/{id}.zip"}}"#
        )
    }

    #[test]
    fn rejects_index_entry_with_short_hash() {
        let err = parse_index(&index_json("abc")).expect_err("must fail");
        assert!(err.to_string().contains("sha256"), "{err}");
    }

    #[test]
    fn rejects_index_entry_with_traversal_path() {
        let text = index_json(&"a".repeat(64))
            .replace("plugins/guo.wuguo/guo.wuguo-1.2.0.zip", "../outside.zip");
        let err = parse_index(&text).expect_err("must fail");
        assert!(matches!(err, PluginError::Unsafe { .. }), "{err}");
    }

    #[test]
    fn verifies_ed25519_index_signature() {
        let signing = SigningKey::from_bytes(&[7u8; 32]);
        let verifying = signing.verifying_key();
        let index = index_json(&"c".repeat(64));
        let signature = signing.sign(index.as_bytes());
        verify_index_signature(&verifying, index.as_bytes(), &signature.to_bytes()).expect("ok");

        let tampered = index.replace("伍果", "伪果");
        let err = verify_index_signature(&verifying, tampered.as_bytes(), &signature.to_bytes())
            .expect_err("must fail");
        assert!(matches!(err, PluginError::Integrity { .. }), "{err}");
    }

    #[test]
    fn base64_helper_rejects_garbage() {
        assert_eq!(decode_base64("").expect("空串合法"), Vec::<u8>::new());
        assert_eq!(decode_base64("YWJj").expect("abc"), b"abc".to_vec());
        // 仓库客户端用它解析 `.sig`：非法内容必须报错而不是返回半截字节。
        assert!(decode_base64("not base64!").is_err());
    }

    #[test]
    fn trust_labels_cover_three_states() {
        assert_eq!(trust_label(true, true), "已签名");
        assert_eq!(trust_label(true, false), "签名已变更");
        assert_eq!(trust_label(false, false), "未签名");
    }
}
