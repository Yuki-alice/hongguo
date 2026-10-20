//! zip 容器解包：路径穿越、条目数、体积与哈希校验（ARCHITECTURE.md §7.3 第 4 步）。
//!
//! 解包只做「读进内存 + 校验」，写入磁盘由调用方在确认全部检查通过后进行，
//! 避免出现「一半文件已经落地、签名才发现不对」的中间态。

use std::collections::BTreeMap;
use std::io::{Cursor, Read};

use sha2::{Digest, Sha256};

use crate::error::PluginError;
use crate::manifest::PluginManifest;

/// 解包上限。数值取自架构文档 §7.7「响应炸弹」一行。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PackageLimits {
    /// 单个文件上限。
    pub max_file_bytes: u64,
    /// 解压总量上限。
    pub max_total_bytes: u64,
    /// 条目数上限。
    pub max_entries: usize,
}

impl Default for PackageLimits {
    fn default() -> Self {
        Self {
            max_file_bytes: 8 * 1024 * 1024,
            max_total_bytes: 32 * 1024 * 1024,
            max_entries: 512,
        }
    }
}

/// 解包结果：包内文件按相对路径索引，外加解析好的清单。
#[derive(Debug, Clone)]
pub struct UnpackedPackage {
    pub manifest: PluginManifest,
    pub files: BTreeMap<String, Vec<u8>>,
    pub sha256: String,
}

impl UnpackedPackage {
    pub fn file(&self, path: &str) -> Option<&[u8]> {
        self.files.get(path).map(Vec::as_slice)
    }
}

/// 计算 SHA-256 的十六进制小写表示。
pub fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    let digest = hasher.finalize();
    let mut out = String::with_capacity(digest.len() * 2);
    for byte in digest {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

/// 解包并校验。`expected_sha256` 为 `None` 时只计算不比对（用于本地开发包）。
pub fn unpack(
    archive: &[u8],
    expected_sha256: Option<&str>,
    limits: PackageLimits,
) -> Result<UnpackedPackage, PluginError> {
    let sha256 = sha256_hex(archive);
    if let Some(expected) = expected_sha256 {
        if !expected.eq_ignore_ascii_case(&sha256) {
            return Err(PluginError::integrity(
                "包哈希",
                format!("期望 {expected}，实际 {sha256}"),
            ));
        }
    }

    let mut zip = zip::ZipArchive::new(Cursor::new(archive))
        .map_err(|err| PluginError::invalid("包", format!("不是合法的 zip：{err}")))?;
    if zip.len() > limits.max_entries {
        return Err(PluginError::unsafe_entry(format!(
            "条目数 {} 超过上限 {}",
            zip.len(),
            limits.max_entries
        )));
    }

    let mut files = BTreeMap::new();
    let mut total = 0u64;
    for index in 0..zip.len() {
        let mut entry = zip
            .by_index(index)
            .map_err(|err| PluginError::invalid("包", format!("第 {index} 项读取失败：{err}")))?;
        let name = entry
            .name()
            .map_err(|err| PluginError::invalid("包", format!("第 {index} 项文件名非法：{err}")))?
            .to_string();
        if entry.is_dir() {
            continue;
        }
        check_entry_path(&name)?;
        let declared = entry.size();
        if declared > limits.max_file_bytes {
            return Err(PluginError::unsafe_entry(format!(
                "{name} 声明大小 {declared} 超过单文件上限 {}",
                limits.max_file_bytes
            )));
        }
        let mut buffer = Vec::with_capacity(declared as usize);
        // 读的时候再卡一次：zip 头里的 size 可以被伪造。
        entry
            .by_ref()
            .take(limits.max_file_bytes + 1)
            .read_to_end(&mut buffer)
            .map_err(|err| PluginError::io(&name, err))?;
        if buffer.len() as u64 > limits.max_file_bytes {
            return Err(PluginError::unsafe_entry(format!(
                "{name} 实际大小超过单文件上限 {}",
                limits.max_file_bytes
            )));
        }
        total += buffer.len() as u64;
        if total > limits.max_total_bytes {
            return Err(PluginError::unsafe_entry(format!(
                "解压总量超过上限 {}",
                limits.max_total_bytes
            )));
        }
        if files.insert(name.clone(), buffer).is_some() {
            return Err(PluginError::unsafe_entry(format!("重复条目：{name}")));
        }
    }

    let manifest_bytes = files
        .get("plugin.toml")
        .ok_or_else(|| PluginError::invalid("包", "缺少 plugin.toml"))?;
    let manifest_text = std::str::from_utf8(manifest_bytes)
        .map_err(|err| PluginError::invalid("清单", format!("不是 UTF-8：{err}")))?;
    let manifest = PluginManifest::parse(manifest_text)?;

    for path in manifest.declared_paths() {
        if !files.contains_key(path) {
            return Err(PluginError::invalid(
                "包",
                format!("清单声明的 {path} 不在包内"),
            ));
        }
    }

    Ok(UnpackedPackage {
        manifest,
        files,
        sha256,
    })
}

/// 拒绝绝对路径、上跳、盘符与反斜杠。
fn check_entry_path(name: &str) -> Result<(), PluginError> {
    let bad = name.is_empty()
        || name.starts_with('/')
        || name.contains("..")
        || name.contains('\\')
        || name.contains(':');
    if bad {
        return Err(PluginError::unsafe_entry(format!("非法条目路径：{name}")));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use zip::write::SimpleFileOptions;

    fn build(entries: &[(&str, &[u8])]) -> Vec<u8> {
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

    const MANIFEST: &str = r#"
spec = 1
id = "guo.fanguo"
name = "饭果"
version = "1.0.0"
kind = "declarative"
api = { level = 1, min_host = "0.3.0" }

[[rules]]
path = "rules/fanguo.json"
site = "fanguo"
"#;

    #[test]
    fn unpacks_valid_package() {
        let archive = build(&[
            ("plugin.toml", MANIFEST.as_bytes()),
            ("rules/fanguo.json", b"{\"schema\":\"1.0\"}"),
        ]);
        let sha = sha256_hex(&archive);
        let package = unpack(&archive, Some(&sha), PackageLimits::default()).expect("unpack");
        assert_eq!(package.manifest.id.as_str(), "guo.fanguo");
        assert_eq!(
            package.file("rules/fanguo.json"),
            Some(&b"{\"schema\":\"1.0\"}"[..])
        );
        assert_eq!(package.sha256, sha);
    }

    #[test]
    fn rejects_hash_mismatch() {
        let archive = build(&[("plugin.toml", MANIFEST.as_bytes())]);
        let err = unpack(&archive, Some(&"0".repeat(64)), PackageLimits::default())
            .expect_err("must fail");
        assert!(matches!(err, PluginError::Integrity { .. }), "{err}");
    }

    #[test]
    fn rejects_path_traversal_entries() {
        let archive = build(&[("plugin.toml", MANIFEST.as_bytes()), ("../evil.json", b"x")]);
        let err = unpack(&archive, None, PackageLimits::default()).expect_err("must fail");
        assert!(err.to_string().contains(".."), "{err}");
    }

    #[test]
    fn rejects_missing_declared_rule() {
        let archive = build(&[("plugin.toml", MANIFEST.as_bytes())]);
        let err = unpack(&archive, None, PackageLimits::default()).expect_err("must fail");
        assert!(err.to_string().contains("rules/fanguo.json"), "{err}");
    }

    #[test]
    fn rejects_missing_manifest() {
        let archive = build(&[("rules/fanguo.json", b"{}")]);
        let err = unpack(&archive, None, PackageLimits::default()).expect_err("must fail");
        assert!(err.to_string().contains("plugin.toml"), "{err}");
    }

    #[test]
    fn rejects_oversized_file() {
        let big = vec![0u8; 2048];
        let archive = build(&[
            ("plugin.toml", MANIFEST.as_bytes()),
            ("rules/fanguo.json", &big),
        ]);
        let limits = PackageLimits {
            max_file_bytes: 1024,
            ..PackageLimits::default()
        };
        let err = unpack(&archive, None, limits).expect_err("must fail");
        assert!(matches!(err, PluginError::Unsafe { .. }), "{err}");
    }

    #[test]
    fn rejects_too_many_entries() {
        let mut entries: Vec<(String, Vec<u8>)> =
            vec![("plugin.toml".into(), MANIFEST.as_bytes().to_vec())];
        for index in 0..8 {
            entries.push((format!("assets/{index}.txt"), b"x".to_vec()));
        }
        let refs: Vec<(&str, &[u8])> = entries
            .iter()
            .map(|(name, data)| (name.as_str(), data.as_slice()))
            .collect();
        let archive = build(&refs);
        let limits = PackageLimits {
            max_entries: 4,
            ..PackageLimits::default()
        };
        let err = unpack(&archive, None, limits).expect_err("must fail");
        assert!(err.to_string().contains("条目数"), "{err}");
    }

    #[test]
    fn sha256_matches_reference_vectors() {
        assert_eq!(
            sha256_hex(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }
}
