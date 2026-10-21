//! 官方插件预装。
//!
//! 官方插件随应用资源分发，首次启动安装到插件仓库；之后按仓库更新。
//!
//! 关键语义：
//! - **只装不覆盖**：仓库里已有同 id 且版本 >= 随包版本时跳过。否则用户手动
//!   升级后，每次启动都会被随包旧版本覆盖回去。
//! - **失败不拦启动**：单个包损坏只记录，其余照装。
//! - **幂等**：重复调用不会重复安装，也不会改变已启用的插件状态。
//!
//! 预装源用 `repo_id = "bundled"` 记账，与从网络仓库装的包区分开，
//! 便于诊断页回答「这个插件是从哪来的」。

use std::path::Path;

use semver::Version;

use guo_plugin_host::{install_package, parse_index, select_entry, PluginError, PluginStore};

use crate::EngineError;

/// 预装来源标识。
pub const BUNDLED_REPO: &str = "bundled";

/// 一个随包插件包。
pub struct BundledPackage {
    /// 文件名，仅用于日志。
    pub name: String,
    /// 官方索引 JSON（只含这一个条目时也能用）。
    pub index_json: &'static str,
    /// zip 字节。
    pub archive: &'static [u8],
}

/// 预装结果。
#[derive(Debug, Default, PartialEq, Eq)]
pub struct PreinstallReport {
    /// 实际安装的插件 id。
    pub installed: Vec<String>,
    /// 因已有同版本或更新版本而跳过。
    pub skipped: Vec<String>,
    /// 安装失败的原因。
    pub failed: Vec<(String, String)>,
}

impl PreinstallReport {
    pub fn is_empty(&self) -> bool {
        self.installed.is_empty() && self.skipped.is_empty() && self.failed.is_empty()
    }
}

/// 把随包插件装进 `store`。
///
/// `now` 由调用方给出（Unix 秒），便于测试固定时间戳。
pub fn preinstall(store: &PluginStore, packages: &[BundledPackage], now: u64) -> PreinstallReport {
    let mut report = PreinstallReport::default();
    let installed = store.installed();

    for package in packages {
        let index = match parse_index(package.index_json) {
            Ok(index) => index,
            Err(error) => {
                report
                    .failed
                    .push((package.name.clone(), error.to_string()));
                continue;
            }
        };
        let Some(entry) = index.entries().next() else {
            report
                .failed
                .push((package.name.clone(), "索引为空".to_string()));
            continue;
        };
        let plugin_id = entry.id.as_str().to_string();

        // 已有更高或相同版本：跳过。用户手动升级过就不能被随包版本覆盖。
        if let Some(existing) = installed.iter().find(|plugin| plugin.id == plugin_id) {
            if existing.version >= entry.version {
                report.skipped.push(plugin_id);
                continue;
            }
        }

        // 选中同版本条目：`select_entry` 在版本为空时取最高版本，
        // 这里显式给版本，避免随包索引里混入其它条目时选错。
        let wanted: Version = entry.version.clone();
        let Some(entry) = select_entry(&index, &plugin_id, Some(&wanted)).ok() else {
            report
                .failed
                .push((plugin_id, "索引里找不到目标版本".to_string()));
            continue;
        };
        match install_package(
            store,
            entry,
            package.archive,
            &guo_plugin_host::InstallRequest {
                repo_id: BUNDLED_REPO,
                // 随包资源本身通过应用签名与商店分发生效，不再叠加插件签名。
                repo_signed: false,
                now,
            },
            guo_plugin_host::PackageLimits::default(),
        ) {
            Ok(_) => report.installed.push(plugin_id),
            Err(error) => report.failed.push((plugin_id, describe(&error))),
        }
    }
    report
}

/// 预装数据的根目录（随包资源解压后的位置）。
pub fn bundled_root(asset_directory: impl AsRef<Path>) -> std::path::PathBuf {
    asset_directory.as_ref().to_path_buf()
}

fn describe(error: &PluginError) -> String {
    match error {
        PluginError::Integrity { .. } => format!("{error}（包可能被替换或不完整）"),
        PluginError::Unsupported { .. } => format!("{error}（请升级应用）"),
        PluginError::Unsafe { .. } => format!("{error}（出于安全考虑已拒绝）"),
        _ => error.to_string(),
    }
}

/// 预装并返回引擎错误包装（供桥接层直接调用）。
pub fn preinstall_or_report(
    store: &PluginStore,
    packages: &[BundledPackage],
    now: u64,
) -> Result<PreinstallReport, EngineError> {
    Ok(preinstall(store, packages, now))
}

#[cfg(test)]
mod tests {
    use std::io::{Cursor, Write};
    use std::path::PathBuf;

    use zip::write::SimpleFileOptions;

    use super::*;

    fn temp_root(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "guo-preinstall-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|value| value.as_nanos())
                .unwrap_or(0)
        ));
        let _ = std::fs::remove_dir_all(&path);
        path
    }

    /// 构造一个声明式插件包与其索引。
    fn package(id: &str, version: &str) -> (Vec<u8>, String) {
        let manifest = format!(
            "spec = 1\nid = \"{id}\"\nname = \"插件\"\nversion = \"{version}\"\nkind = \"declarative\"\napi = {{ level = 1, min_host = \"0.3.0\" }}\n\n[[rules]]\npath = \"rules/a.json\"\nsite = \"site_{id}\"\n"
        );
        let rule = format!(
            r#"{{"schema":"1.0","id":"site_{id}","name":"站点","base":"https://a.test","kind":"html","catalog":{{"url":"list/{{page}}","item":"a","fields":{{"id":"a@href","title":".t"}}}}}}"#
        );
        let mut buffer = Cursor::new(Vec::new());
        {
            let mut writer = zip::ZipWriter::new(&mut buffer);
            let options =
                SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
            for (name, body) in [
                ("plugin.toml", manifest.as_bytes().to_vec()),
                ("rules/a.json", rule.into_bytes()),
            ] {
                writer.start_file(name, options).expect("start");
                writer.write_all(&body).expect("write");
            }
            writer.finish().expect("finish");
        }
        let archive = buffer.into_inner();
        let sha = guo_plugin_host::sha256_hex(&archive);
        let index = format!(
            r#"[{{"id":"{id}","name":"插件","version":"{version}","kind":"declarative","api":1,"minHost":"0.3.0","size":{},"sha256":"{sha}","path":"plugins/{id}.zip"}}]"#,
            archive.len()
        );
        (archive, index)
    }

    #[test]
    fn installs_bundled_packages() {
        let root = temp_root("install");
        let store = PluginStore::open(&root);
        let (archive, index) = package("guo.bundled", "1.0.0");
        let report = preinstall(
            &store,
            &[BundledPackage {
                name: "bundled.zip".into(),
                index_json: Box::leak(index.into_boxed_str()),
                archive: Box::leak(archive.into_boxed_slice()),
            }],
            1,
        );
        assert_eq!(report.installed, vec!["guo.bundled"]);
        assert!(report.failed.is_empty());
        assert!(store
            .installed()
            .iter()
            .any(|plugin| plugin.id == "guo.bundled"));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn skips_when_installed_version_is_same_or_newer() {
        let root = temp_root("skip");
        let store = PluginStore::open(&root);
        let (archive, index) = package("guo.bundled", "1.0.0");
        let packages = [BundledPackage {
            name: "bundled.zip".into(),
            index_json: Box::leak(index.into_boxed_str()),
            archive: Box::leak(archive.into_boxed_slice()),
        }];
        assert_eq!(
            preinstall(&store, &packages, 1).installed,
            vec!["guo.bundled"]
        );
        // 第二次启动不应重复安装。
        let again = preinstall(&store, &packages, 2);
        assert!(again.installed.is_empty());
        assert_eq!(again.skipped, vec!["guo.bundled"]);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn upgrades_when_bundled_version_is_newer() {
        let root = temp_root("upgrade");
        let store = PluginStore::open(&root);
        let (old_archive, old_index) = package("guo.bundled", "1.0.0");
        preinstall(
            &store,
            &[BundledPackage {
                name: "old".into(),
                index_json: Box::leak(old_index.into_boxed_str()),
                archive: Box::leak(old_archive.into_boxed_slice()),
            }],
            1,
        );
        let (new_archive, new_index) = package("guo.bundled", "2.0.0");
        let report = preinstall(
            &store,
            &[BundledPackage {
                name: "new".into(),
                index_json: Box::leak(new_index.into_boxed_str()),
                archive: Box::leak(new_archive.into_boxed_slice()),
            }],
            2,
        );
        assert_eq!(report.installed, vec!["guo.bundled"]);
        let active = store
            .installed()
            .into_iter()
            .find(|plugin| plugin.id == "guo.bundled")
            .expect("installed");
        assert_eq!(active.version.to_string(), "2.0.0");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn broken_package_does_not_block_others() {
        let root = temp_root("broken");
        let store = PluginStore::open(&root);
        let (good_archive, good_index) = package("guo.good", "1.0.0");
        let garbage = b"not a zip".to_vec();
        let fake_index = r#"[{"id":"guo.broken","name":"坏包","version":"1.0.0","kind":"declarative","api":1,"minHost":"0.3.0","size":9,"sha256":"0000000000000000000000000000000000000000000000000000000000000000","path":"plugins/broken.zip"}]"#;
        let report = preinstall(
            &store,
            &[
                BundledPackage {
                    name: "broken.zip".into(),
                    index_json: fake_index,
                    archive: Box::leak(garbage.into_boxed_slice()),
                },
                BundledPackage {
                    name: "good.zip".into(),
                    index_json: Box::leak(good_index.into_boxed_str()),
                    archive: Box::leak(good_archive.into_boxed_slice()),
                },
            ],
            1,
        );
        assert_eq!(report.installed, vec!["guo.good"]);
        assert_eq!(report.failed.len(), 1);
        assert_eq!(report.failed[0].0, "guo.broken");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn invalid_index_is_reported_not_fatal() {
        let root = temp_root("badindex");
        let store = PluginStore::open(&root);
        let report = preinstall(
            &store,
            &[BundledPackage {
                name: "bad".into(),
                index_json: "{not json",
                archive: b"",
            }],
            1,
        );
        assert!(report.installed.is_empty());
        assert_eq!(report.failed.len(), 1);
        let _ = std::fs::remove_dir_all(&root);
    }
}
