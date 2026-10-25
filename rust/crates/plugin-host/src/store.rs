//! 设备端安装目录：落盘布局、原子安装、启用状态与安装日志（ARCHITECTURE.md §7.3）。
//!
//! 布局：
//! ```text
//! <root>/installed/<plugin-id>/<version>/…    # 解包后的文件
//! <root>/state.json                          # 启用状态、当前版本指针
//! <root>/repos.json                          # 仓库列表 + TOFU 指纹
//! <root>/install.log                         # 安装审计日志（每行一条 JSON）
//! ```
//!
//! 安装过程先写 `<root>/staging/<id>-<version>-<n>/`，全部校验通过后再 `rename`
//! 到 `installed/`；失败时删 staging，不留半成品。

use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use semver::Version;
use serde::{Deserialize, Serialize};

use guo_source_api::ContentType;

use crate::error::PluginError;
use crate::manifest::{PluginKind, PluginManifest};
use crate::package::UnpackedPackage;

/// 安装来源，写入 `install.log` 供回溯。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InstallSource {
    /// 仓库 id；本地安装为空。
    #[serde(default)]
    pub repo: String,
    /// 仓库是否签名（仅记录，不参与信任判定）。
    #[serde(default)]
    pub signed: bool,
}

/// 已安装插件的对外描述。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InstalledPlugin {
    pub id: String,
    pub name: String,
    pub version: Version,
    pub kind: PluginKind,
    #[serde(default)]
    pub enabled: bool,
    /// 版本目录的绝对路径。
    pub directory: String,
    /// 该 id 是否存在其它版本（可回滚）。
    #[serde(default)]
    pub rollback_version: Option<Version>,
    /// 内容类型（来自清单；缺省表示未标注）。
    #[serde(default)]
    pub content_types: Vec<ContentType>,
}

/// 单个插件的持久化状态。
///
/// 注意 `Default` 是**手写**的：`#[serde(default)]` 只在反序列化时生效，
/// 派生出来的 `Default::default()` 会让 `enabled` 恒为 `false`，
/// 于是「新装的插件」在状态文件里是停用的——装完不能用，且很难查。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginState {
    #[serde(default = "default_enabled")]
    pub enabled: bool,
    /// 当前生效的版本；为空时回退到磁盘上最大的版本。
    #[serde(default)]
    pub version: Option<Version>,
}

impl Default for PluginState {
    fn default() -> Self {
        Self {
            enabled: true,
            version: None,
        }
    }
}

fn default_enabled() -> bool {
    true
}

/// 仓库信任记录（TOFU）。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RepoRecord {
    pub url: String,
    #[serde(default)]
    pub signed: bool,
    /// `ed25519:<base64>` 的指纹；用于「指纹变化即拒绝」。
    #[serde(default)]
    pub fingerprint: String,
    #[serde(default)]
    pub last_fetch: u64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StateFile {
    #[serde(default)]
    version: u32,
    #[serde(default)]
    plugins: BTreeMap<String, PluginState>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RepoFile {
    #[serde(default)]
    version: u32,
    #[serde(default)]
    repos: BTreeMap<String, RepoRecord>,
}

/// 安装目录句柄。所有方法都是同步文件操作，调用方决定放在哪个线程。
#[derive(Debug, Clone)]
pub struct PluginStore {
    root: PathBuf,
}

impl PluginStore {
    pub fn open(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    fn installed_dir(&self) -> PathBuf {
        self.root.join("installed")
    }

    fn staging_dir(&self) -> PathBuf {
        self.root.join("staging")
    }

    /// 安装一个已校验的包。
    ///
    /// 调用前必须已经完成哈希、清单与路径校验（[`crate::package::unpack`] 的职责）。
    /// 这里只做「写盘 + 原子切换 + 记账」。
    pub fn install(
        &self,
        package: &UnpackedPackage,
        source: &InstallSource,
        now: u64,
    ) -> Result<InstalledPlugin, PluginError> {
        let manifest = &package.manifest;
        let id = manifest.id.as_str();
        let version = manifest.version.to_string();

        let staging = self.staging_dir().join(format!(
            "{id}-{version}-{}",
            NEXT_STAGING.fetch_add(1, Ordering::Relaxed)
        ));
        // staging 目录必须是空的：上次崩溃残留的同名目录直接清掉，避免混入旧文件。
        if staging.exists() {
            fs::remove_dir_all(&staging)
                .map_err(|err| PluginError::io(staging.display().to_string(), err))?;
        }
        fs::create_dir_all(&staging)
            .map_err(|err| PluginError::io(staging.display().to_string(), err))?;

        let write_result = self.write_package(&staging, package);
        if let Err(err) = write_result {
            discard_directory(&staging);
            return Err(err);
        }

        let destination = self.installed_dir().join(id).join(&version);
        if destination.exists() {
            // 同版本重装：先移除旧目录，保证内容与包一致。
            fs::remove_dir_all(&destination)
                .map_err(|err| PluginError::io(destination.display().to_string(), err))?;
        }
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent)
                .map_err(|err| PluginError::io(parent.display().to_string(), err))?;
        }
        fs::rename(&staging, &destination).map_err(|err| {
            discard_directory(&staging);
            PluginError::io(
                destination.display().to_string(),
                format!("原子替换失败：{err}"),
            )
        })?;

        self.set_active_version(id, &manifest.version)?;
        let rollback = self.previous_version(id, &manifest.version);

        self.append_log(&LogLine {
            id: id.to_string(),
            version: version.clone(),
            sha256: package.sha256.clone(),
            repo: source.repo.clone(),
            signed: source.signed,
            at: now,
        });

        Ok(InstalledPlugin {
            id: id.to_string(),
            name: manifest.name.clone(),
            version: manifest.version.clone(),
            kind: manifest.kind.clone(),
            enabled: true,
            directory: destination.display().to_string(),
            rollback_version: rollback,
            content_types: manifest.content_types.clone(),
        })
    }

    fn write_package(
        &self,
        directory: &Path,
        package: &UnpackedPackage,
    ) -> Result<(), PluginError> {
        for (name, bytes) in &package.files {
            let target = directory.join(name);
            if let Some(parent) = target.parent() {
                fs::create_dir_all(parent)
                    .map_err(|err| PluginError::io(parent.display().to_string(), err))?;
            }
            fs::write(&target, bytes)
                .map_err(|err| PluginError::io(target.display().to_string(), err))?;
        }
        Ok(())
    }

    /// 卸载：删除该 id 的全部版本与状态条目。用户数据（追剧、历史）不在这里。
    pub fn uninstall(&self, id: &str) -> Result<bool, PluginError> {
        let directory = self.installed_dir().join(id);
        let existed = directory.exists();
        if existed {
            fs::remove_dir_all(&directory)
                .map_err(|err| PluginError::io(directory.display().to_string(), err))?;
        }
        let mut state = self.read_state();
        state.plugins.remove(id);
        self.write_state(&state)?;
        Ok(existed)
    }

    /// 启用 / 停用。
    pub fn set_enabled(&self, id: &str, enabled: bool) -> Result<(), PluginError> {
        let mut state = self.read_state();
        let entry = state.plugins.entry(id.to_string()).or_default();
        entry.enabled = enabled;
        self.write_state(&state)
    }

    /// 切换生效版本（回滚）。
    pub fn set_active_version(&self, id: &str, version: &Version) -> Result<(), PluginError> {
        let mut state = self.read_state();
        let entry = state.plugins.entry(id.to_string()).or_default();
        entry.version = Some(version.clone());
        self.write_state(&state)
    }

    /// 列举已安装插件。`enabled` 按状态文件判断，缺失时视为启用。
    pub fn installed(&self) -> Vec<InstalledPlugin> {
        let state = self.read_state();
        let mut out = Vec::new();
        let Ok(entries) = fs::read_dir(self.installed_dir()) else {
            return out;
        };
        for entry in entries.flatten() {
            if !entry.file_type().map(|kind| kind.is_dir()).unwrap_or(false) {
                continue;
            }
            let id = entry.file_name().to_string_lossy().to_string();
            let versions = self.versions(&id);
            let Some(active) = self.active_version(&id, &versions) else {
                continue;
            };
            let directory = entry.path().join(active.to_string());
            let Ok(manifest) = read_manifest(&directory) else {
                // 版本目录损坏：跳过而不是整体失败，让 UI 仍能看到其它插件。
                continue;
            };
            let previous = versions
                .iter()
                .filter(|version| **version != active)
                .max()
                .cloned();
            out.push(InstalledPlugin {
                id: id.clone(),
                name: manifest.name,
                version: active,
                kind: manifest.kind,
                enabled: state.plugins.get(&id).map(|s| s.enabled).unwrap_or(true),
                directory: directory.display().to_string(),
                rollback_version: previous,
                content_types: manifest.content_types,
            });
        }
        out.sort_by(|a, b| a.id.cmp(&b.id));
        out
    }

    /// 读取某个版本的清单（安装器在启动时据此重建注册表）。
    pub fn manifest_of(&self, id: &str, version: &Version) -> Result<PluginManifest, PluginError> {
        read_manifest(&self.installed_dir().join(id).join(version.to_string()))
    }

    /// 该 id 已安装的全部版本（升序）。
    pub fn versions(&self, id: &str) -> Vec<Version> {
        let mut out: Vec<Version> = fs::read_dir(self.installed_dir().join(id))
            .map(|entries| {
                entries
                    .flatten()
                    .filter_map(|entry| Version::parse(&entry.file_name().to_string_lossy()).ok())
                    .collect()
            })
            .unwrap_or_default();
        out.sort();
        out
    }

    fn active_version(&self, id: &str, versions: &[Version]) -> Option<Version> {
        let state = self.read_state();
        if let Some(recorded) = state
            .plugins
            .get(id)
            .and_then(|entry| entry.version.clone())
        {
            if versions.contains(&recorded) {
                return Some(recorded);
            }
        }
        versions.last().cloned()
    }

    fn previous_version(&self, id: &str, current: &Version) -> Option<Version> {
        self.versions(id)
            .into_iter()
            .filter(|version| version != current)
            .max()
    }

    pub fn repos(&self) -> BTreeMap<String, RepoRecord> {
        self.read_repos().repos
    }

    /// 记录仓库并返回「指纹是否变化」。
    ///
    /// 指纹变化必须由 UI 拒绝并提示（§7.4），这里只如实报告，不替调用方做决定。
    pub fn remember_repo(&self, id: &str, record: RepoRecord) -> Result<bool, PluginError> {
        let mut file = self.read_repos();
        let changed = file
            .repos
            .get(id)
            .map(|existing| {
                !existing.fingerprint.is_empty()
                    && !record.fingerprint.is_empty()
                    && existing.fingerprint != record.fingerprint
            })
            .unwrap_or(false);
        file.repos.insert(id.to_string(), record);
        self.write_repos(&file)?;
        Ok(changed)
    }

    pub fn forget_repo(&self, id: &str) -> Result<bool, PluginError> {
        let mut file = self.read_repos();
        let removed = file.repos.remove(id).is_some();
        self.write_repos(&file)?;
        Ok(removed)
    }

    fn read_state(&self) -> StateFile {
        read_json(&self.root.join("state.json")).unwrap_or_default()
    }

    fn write_state(&self, state: &StateFile) -> Result<(), PluginError> {
        write_json(&self.root.join("state.json"), state)
    }

    fn read_repos(&self) -> RepoFile {
        read_json(&self.root.join("repos.json")).unwrap_or_default()
    }

    fn write_repos(&self, repos: &RepoFile) -> Result<(), PluginError> {
        write_json(&self.root.join("repos.json"), repos)
    }

    fn append_log(&self, line: &LogLine) {
        // 日志失败不影响安装结果：它只用于诊断与回溯。
        let _ = fs::create_dir_all(&self.root);
        let path = self.root.join("install.log");
        if let Ok(mut payload) = serde_json::to_string(line) {
            payload.push('\n');
            if let Ok(mut file) = fs::OpenOptions::new().create(true).append(true).open(path) {
                let _ = file.write_all(payload.as_bytes());
            }
        }
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct LogLine {
    id: String,
    version: String,
    sha256: String,
    repo: String,
    signed: bool,
    at: u64,
}

static NEXT_STAGING: AtomicU64 = AtomicU64::new(0);

fn discard_directory(path: &Path) {
    let _ = fs::remove_dir_all(path);
}

fn read_manifest(directory: &Path) -> Result<PluginManifest, PluginError> {
    let path = directory.join("plugin.toml");
    let text = fs::read_to_string(&path)
        .map_err(|err| PluginError::io(path.display().to_string(), err))?;
    PluginManifest::parse(&text)
}

fn read_json<T: for<'de> Deserialize<'de> + Default>(path: &Path) -> Option<T> {
    let text = fs::read_to_string(path).ok()?;
    // 状态文件损坏时退回默认值：宁可丢启用状态，也不要让整个插件系统起不来。
    serde_json::from_str(&text).ok()
}

fn write_json<T: Serialize>(path: &Path, value: &T) -> Result<(), PluginError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|err| PluginError::io(parent.display().to_string(), err))?;
    }
    let payload = serde_json::to_vec_pretty(value)
        .map_err(|err| PluginError::io(path.display().to_string(), err))?;
    // 先写临时文件再 rename，避免状态文件写一半被读到。
    let temporary = path.with_extension("tmp");
    fs::write(&temporary, payload)
        .map_err(|err| PluginError::io(temporary.display().to_string(), err))?;
    fs::rename(&temporary, path).map_err(|err| PluginError::io(path.display().to_string(), err))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::PluginManifest;
    use crate::package::sha256_hex;

    fn package(id: &str, version: &str) -> UnpackedPackage {
        let text = format!(
            r#"
spec = 1
id = "{id}"
name = "测试"
version = "{version}"
kind = "declarative"
api = {{ level = 1, min_host = "0.3.0" }}

[[rules]]
path = "rules/{id}.json"
site = "{id}"
"#
        );
        let manifest = PluginManifest::parse(&text).expect("manifest");
        let mut files = BTreeMap::new();
        files.insert("plugin.toml".to_string(), text.clone().into_bytes());
        files.insert(format!("rules/{id}.json"), b"{\"schema\":\"1.0\"}".to_vec());
        UnpackedPackage {
            manifest,
            files,
            sha256: sha256_hex(text.as_bytes()),
        }
    }

    fn temporary_root(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "guo-plugin-store-{name}-{}-{}",
            std::process::id(),
            NEXT_STAGING.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = fs::remove_dir_all(&path);
        path
    }

    #[test]
    fn installs_and_lists_plugin() {
        let root = temporary_root("install");
        let store = PluginStore::open(&root);
        let installed = store
            .install(
                &package("guo.test", "1.0.0"),
                &InstallSource::default(),
                100,
            )
            .expect("install");
        assert_eq!(installed.version, Version::new(1, 0, 0));
        assert!(installed.enabled);
        assert!(Path::new(&installed.directory)
            .join("rules/guo.test.json")
            .exists());

        let listed = store.installed();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].id, "guo.test");
        assert!(listed[0].rollback_version.is_none());

        let log = fs::read_to_string(root.join("install.log")).expect("log");
        assert!(log.contains("\"id\":\"guo.test\""), "{log}");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn upgrading_keeps_previous_version_for_rollback() {
        let root = temporary_root("upgrade");
        let store = PluginStore::open(&root);
        store
            .install(&package("guo.test", "1.0.0"), &InstallSource::default(), 1)
            .expect("v1");
        let upgraded = store
            .install(&package("guo.test", "1.1.0"), &InstallSource::default(), 2)
            .expect("v2");
        assert_eq!(upgraded.rollback_version, Some(Version::new(1, 0, 0)));
        assert_eq!(store.versions("guo.test").len(), 2);

        store
            .set_active_version("guo.test", &Version::new(1, 0, 0))
            .expect("rollback");
        assert_eq!(
            store.installed()[0].version,
            Version::new(1, 0, 0),
            "切换版本后应为旧版本"
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn uninstall_removes_versions_and_state() {
        let root = temporary_root("uninstall");
        let store = PluginStore::open(&root);
        store
            .install(&package("guo.test", "1.0.0"), &InstallSource::default(), 1)
            .expect("install");
        assert!(store.uninstall("guo.test").expect("uninstall"));
        assert!(store.installed().is_empty());
        assert!(
            !store.uninstall("guo.test").expect("again"),
            "第二次应为 false"
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn enables_and_disables() {
        let root = temporary_root("toggle");
        let store = PluginStore::open(&root);
        store
            .install(&package("guo.test", "1.0.0"), &InstallSource::default(), 1)
            .expect("install");
        store.set_enabled("guo.test", false).expect("disable");
        assert!(!store.installed()[0].enabled);
        store.set_enabled("guo.test", true).expect("enable");
        assert!(store.installed()[0].enabled);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn detects_repo_fingerprint_change() {
        let root = temporary_root("repo");
        let store = PluginStore::open(&root);
        let first = RepoRecord {
            url: "https://example.test/repo.toml".into(),
            signed: true,
            fingerprint: "ed25519:AAAA".into(),
            last_fetch: 1,
        };
        assert!(!store
            .remember_repo("official", first.clone())
            .expect("first"));
        assert!(!store
            .remember_repo("official", first.clone())
            .expect("same"));
        let changed = RepoRecord {
            fingerprint: "ed25519:BBBB".into(),
            ..first
        };
        assert!(
            store.remember_repo("official", changed).expect("changed"),
            "指纹变化必须被报告"
        );
        assert!(store.forget_repo("official").expect("forget"));
        assert!(store.repos().is_empty());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn corrupted_state_file_does_not_break_listing() {
        let root = temporary_root("corrupt");
        let store = PluginStore::open(&root);
        store
            .install(&package("guo.test", "1.0.0"), &InstallSource::default(), 1)
            .expect("install");
        fs::write(root.join("state.json"), b"not json").expect("write");
        let listed = store.installed();
        assert_eq!(listed.len(), 1);
        assert!(listed[0].enabled, "状态损坏时按启用处理");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn freshly_installed_plugin_is_enabled() {
        // 回归：`PluginState` 曾用 derive(Default)，`enabled` 恒为 false，
        // 于是装完的插件在状态文件里是停用的，装完不能用。
        let root = temporary_root("enabled-by-default");
        let store = PluginStore::open(&root);
        store
            .install(&package("guo.test", "1.0.0"), &InstallSource::default(), 1)
            .expect("install");
        let listed = store.installed();
        assert_eq!(listed.len(), 1);
        assert!(listed[0].enabled, "新安装的插件必须默认启用");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn default_state_is_enabled() {
        assert!(PluginState::default().enabled);
        assert!(default_enabled());
    }

    #[test]
    fn manifest_of_reads_installed_version() {
        let root = temporary_root("manifest");
        let store = PluginStore::open(&root);
        store
            .install(&package("guo.test", "1.0.0"), &InstallSource::default(), 1)
            .expect("install");
        let manifest = store
            .manifest_of("guo.test", &Version::new(1, 0, 0))
            .expect("manifest");
        assert_eq!(manifest.id.as_str(), "guo.test");
        let _ = fs::remove_dir_all(&root);
    }
}
