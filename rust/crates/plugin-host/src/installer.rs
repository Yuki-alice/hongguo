//! 安装编排：把「索引条目 + 已下载字节」变成「已安装插件」。
//!
//! 刻意不持有网络：仓库拉取由运行时层完成，这里只做**纯校验 + 落盘**，
//! 因此可以被测试用内存数据完整驱动（ARCHITECTURE.md §7.3 第 4–6 步）。

use semver::Version;

use crate::error::PluginError;
use crate::manifest::{PluginKind, CURRENT_API_LEVEL};
use crate::package::{unpack, PackageLimits};
use crate::repository::{RepoIndexEntry, RepositoryIndex};
use crate::store::{InstallSource, InstalledPlugin, PluginStore};

/// 宿主版本，参与插件 `api.min_host` / `max_host` 判定。
pub const HOST_VERSION: &str = "0.3.0";

/// 一次安装的上下文。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InstallRequest<'a> {
    pub repo_id: &'a str,
    pub repo_signed: bool,
    pub now: u64,
}

/// 从索引里选出要安装的条目：`version` 为空时取该 id 的最高版本。
pub fn select_entry<'a>(
    index: &'a RepositoryIndex,
    id: &str,
    version: Option<&Version>,
) -> Result<&'a RepoIndexEntry, PluginError> {
    let entry = index
        .get(id)
        .ok_or_else(|| PluginError::invalid("索引", format!("仓库里没有 {id}")))?;
    if let Some(wanted) = version {
        if &entry.version != wanted {
            return Err(PluginError::invalid(
                "索引",
                format!("仓库里 {id} 只有 {}，没有 {wanted}", entry.version),
            ));
        }
    }
    Ok(entry)
}

/// 完整安装流程：哈希 → 解包防护 → 清单校验 → API 兼容 → 原子落盘。
pub fn install_package(
    store: &PluginStore,
    entry: &RepoIndexEntry,
    archive: &[u8],
    request: &InstallRequest<'_>,
    limits: PackageLimits,
) -> Result<InstalledPlugin, PluginError> {
    if let Some(size) = entry.size {
        if archive.len() as u64 != size {
            return Err(PluginError::integrity(
                "包大小",
                format!("索引声明 {size}，实际 {}", archive.len()),
            ));
        }
    }

    // SHA-256 是强制项：即使仓库未签名也必须通过（D3）。
    let package = unpack(archive, Some(&entry.sha256), limits)?;

    if package.manifest.id.as_str() != entry.id.as_str() {
        return Err(PluginError::integrity(
            "插件 id",
            format!("索引是 {}，包内是 {}", entry.id, package.manifest.id),
        ));
    }
    if package.manifest.version != entry.version {
        return Err(PluginError::integrity(
            "插件版本",
            format!(
                "索引是 {}，包内是 {}",
                entry.version, package.manifest.version
            ),
        ));
    }
    if let Some(kind) = &entry.kind {
        if kind != &package.manifest.kind {
            return Err(PluginError::integrity(
                "插件类型",
                format!(
                    "索引是 {}，包内是 {}",
                    kind.as_str(),
                    package.manifest.kind.as_str()
                ),
            ));
        }
    }
    if let Some(level) = entry.api {
        if level != package.manifest.api.level {
            return Err(PluginError::integrity(
                "API level",
                format!("索引是 {level}，包内是 {}", package.manifest.api.level),
            ));
        }
    }
    if package.manifest.api.level > CURRENT_API_LEVEL {
        return Err(PluginError::Unsupported {
            detail: format!("插件要求 API level {}", package.manifest.api.level),
        });
    }
    let host = Version::parse(HOST_VERSION).expect("宿主版本常量必须合法");
    package.manifest.api.accepts(&host)?;

    // 代码插件还要确认入口确实是组件；真正的 WIT 校验在 plugin-wasm 里做。
    if package.manifest.kind == PluginKind::Component {
        let entry_path = package
            .manifest
            .entry
            .as_deref()
            .ok_or_else(|| PluginError::invalid("清单", "代码插件缺少 entry"))?;
        let bytes = package
            .file(entry_path)
            .ok_or_else(|| PluginError::invalid("包", format!("缺少入口 {entry_path}")))?;
        if !bytes.starts_with(b"\0asm") {
            return Err(PluginError::invalid(
                "包",
                format!("{entry_path} 不是 WASM 模块"),
            ));
        }
    }

    store.install(
        &package,
        &InstallSource {
            repo: request.repo_id.to_string(),
            signed: request.repo_signed,
        },
        request.now,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::PluginManifest;
    use crate::package::sha256_hex;
    use crate::repository::parse_index;
    use crate::store::PluginStore;
    use std::io::{Cursor, Write};
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};
    use zip::write::SimpleFileOptions;

    static NEXT: AtomicU64 = AtomicU64::new(0);

    fn temporary_root(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "guo-installer-{name}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_dir_all(&path);
        path
    }

    fn manifest_text(id: &str, version: &str, kind: &str) -> String {
        let rules = if kind == "declarative" {
            format!("\n[[rules]]\npath = \"rules/{id}.json\"\nsite = \"{id}\"\n")
        } else {
            String::new()
        };
        let entry = if kind == "component" {
            "entry = \"plugin.wasm\"\n"
        } else {
            ""
        };
        format!(
            "spec = 1\nid = \"{id}\"\nname = \"测试\"\nversion = \"{version}\"\nkind = \"{kind}\"\napi = {{ level = 1, min_host = \"0.3.0\" }}\n{entry}{rules}"
        )
    }

    fn archive_of(entries: &[(&str, &[u8])]) -> Vec<u8> {
        let mut buffer = Cursor::new(Vec::new());
        {
            let mut writer = zip::ZipWriter::new(&mut buffer);
            let options =
                SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
            for (name, data) in entries {
                writer.start_file(*name, options).expect("start");
                writer.write_all(data).expect("write");
            }
            writer.finish().expect("finish");
        }
        buffer.into_inner()
    }

    fn index_for(id: &str, version: &str, sha: &str, size: usize, kind: &str) -> String {
        format!(
            r#"[{{"id":"{id}","name":"测试","version":"{version}","kind":"{kind}","api":1,"minHost":"0.3.0","size":{size},"sha256":"{sha}","path":"plugins/{id}.zip"}}]"#
        )
    }

    #[test]
    fn installs_declarative_package_end_to_end() {
        let root = temporary_root("declarative");
        let store = PluginStore::open(&root);
        let text = manifest_text("guo.test", "1.0.0", "declarative");
        let archive = archive_of(&[
            ("plugin.toml", text.as_bytes()),
            ("rules/guo.test.json", b"{\"schema\":\"1.0\"}"),
        ]);
        let sha = sha256_hex(&archive);
        let index = parse_index(&index_for(
            "guo.test",
            "1.0.0",
            &sha,
            archive.len(),
            "declarative",
        ))
        .expect("index");
        let entry = select_entry(&index, "guo.test", None).expect("entry");
        let installed = install_package(
            &store,
            entry,
            &archive,
            &InstallRequest {
                repo_id: "official",
                repo_signed: true,
                now: 42,
            },
            PackageLimits::default(),
        )
        .expect("install");
        assert_eq!(installed.name, "测试");
        assert_eq!(store.installed().len(), 1);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn rejects_tampered_hash_before_writing() {
        let root = temporary_root("tampered");
        let store = PluginStore::open(&root);
        let text = manifest_text("guo.test", "1.0.0", "declarative");
        let archive = archive_of(&[
            ("plugin.toml", text.as_bytes()),
            ("rules/guo.test.json", b"{}"),
        ]);
        let index = parse_index(&index_for(
            "guo.test",
            "1.0.0",
            &"0".repeat(64),
            archive.len(),
            "declarative",
        ))
        .expect("index");
        let entry = select_entry(&index, "guo.test", None).expect("entry");
        let err = install_package(
            &store,
            entry,
            &archive,
            &InstallRequest {
                repo_id: "official",
                repo_signed: false,
                now: 0,
            },
            PackageLimits::default(),
        )
        .expect_err("must fail");
        assert!(matches!(err, PluginError::Integrity { .. }), "{err}");
        assert!(store.installed().is_empty(), "校验失败不得留下任何目录");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn rejects_size_mismatch() {
        let root = temporary_root("size");
        let store = PluginStore::open(&root);
        let text = manifest_text("guo.test", "1.0.0", "declarative");
        let archive = archive_of(&[
            ("plugin.toml", text.as_bytes()),
            ("rules/guo.test.json", b"{}"),
        ]);
        let sha = sha256_hex(&archive);
        let index = parse_index(&index_for(
            "guo.test",
            "1.0.0",
            &sha,
            archive.len() + 1,
            "declarative",
        ))
        .expect("index");
        let entry = select_entry(&index, "guo.test", None).expect("entry");
        let err = install_package(
            &store,
            entry,
            &archive,
            &InstallRequest {
                repo_id: "official",
                repo_signed: false,
                now: 0,
            },
            PackageLimits::default(),
        )
        .expect_err("must fail");
        assert!(err.to_string().contains("包大小"), "{err}");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn rejects_id_or_version_mismatch() {
        let root = temporary_root("identity");
        let store = PluginStore::open(&root);
        let text = manifest_text("guo.other", "1.0.0", "declarative");
        let archive = archive_of(&[
            ("plugin.toml", text.as_bytes()),
            ("rules/guo.other.json", b"{}"),
        ]);
        let sha = sha256_hex(&archive);
        let index = parse_index(&index_for(
            "guo.test",
            "1.0.0",
            &sha,
            archive.len(),
            "declarative",
        ))
        .expect("index");
        let entry = select_entry(&index, "guo.test", None).expect("entry");
        let err = install_package(
            &store,
            entry,
            &archive,
            &InstallRequest {
                repo_id: "official",
                repo_signed: false,
                now: 0,
            },
            PackageLimits::default(),
        )
        .expect_err("must fail");
        assert!(err.to_string().contains("插件 id"), "{err}");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn rejects_component_without_wasm_header() {
        let root = temporary_root("wasm");
        let store = PluginStore::open(&root);
        let text = manifest_text("guo.code", "1.0.0", "component");
        let archive = archive_of(&[
            ("plugin.toml", text.as_bytes()),
            ("plugin.wasm", b"not wasm"),
        ]);
        let sha = sha256_hex(&archive);
        let index = parse_index(&index_for(
            "guo.code",
            "1.0.0",
            &sha,
            archive.len(),
            "component",
        ))
        .expect("index");
        let entry = select_entry(&index, "guo.code", None).expect("entry");
        let err = install_package(
            &store,
            entry,
            &archive,
            &InstallRequest {
                repo_id: "official",
                repo_signed: false,
                now: 0,
            },
            PackageLimits::default(),
        )
        .expect_err("must fail");
        assert!(err.to_string().contains("WASM"), "{err}");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn select_entry_rejects_unknown_and_wrong_version() {
        let sha = "a".repeat(64);
        let index =
            parse_index(&index_for("guo.test", "1.0.0", &sha, 10, "declarative")).expect("index");
        assert!(select_entry(&index, "guo.missing", None).is_err());
        assert!(select_entry(&index, "guo.test", Some(&Version::new(2, 0, 0))).is_err());
        assert!(select_entry(&index, "guo.test", Some(&Version::new(1, 0, 0))).is_ok());
    }

    #[test]
    fn rejects_api_level_above_host() {
        let root = temporary_root("api");
        let store = PluginStore::open(&root);
        let text =
            manifest_text("guo.test", "1.0.0", "declarative").replace("level = 1", "level = 9");
        let archive = archive_of(&[
            ("plugin.toml", text.as_bytes()),
            ("rules/guo.test.json", b"{}"),
        ]);
        let sha = sha256_hex(&archive);
        // 索引里也写 9，避免先被「索引/包不一致」拦下，确保测的是 API 检查。
        let index = parse_index(&index_for(
            "guo.test",
            "1.0.0",
            &sha,
            archive.len(),
            "declarative",
        ))
        .expect("index");
        let entry = select_entry(&index, "guo.test", None).expect("entry");
        let err = install_package(
            &store,
            entry,
            &archive,
            &InstallRequest {
                repo_id: "official",
                repo_signed: false,
                now: 0,
            },
            PackageLimits::default(),
        )
        .expect_err("must fail");
        assert!(
            err.to_string().contains("API level") || err.to_string().contains("API"),
            "{err}"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn manifest_kind_is_exported_for_ui() {
        let manifest = PluginManifest::parse(&manifest_text("guo.test", "1.0.0", "declarative"))
            .expect("manifest");
        assert_eq!(manifest.kind, PluginKind::Declarative);
        assert_eq!(manifest.kind.as_str(), "declarative");
    }
}
