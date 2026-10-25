//! 插件安装与仓库管理入口。
//!
//! 两条路径都保留：
//! - [`install_plugin`]：调用方自己下载字节后传入（便于离线测试与「从文件安装」）；
//! - [`install_from_repo`]：完整网络流程，仓库客户端拉清单 → 索引 → 包，再交给安装器。
//!
//! 无论走哪条，校验都在同一处（`guo-plugin-host`），不存在「网络路径少校验一次」。
//!
//! 插件目录来自引擎单例（`Engine::config().plugin_directory`），不再单独维护一份：
//! 两处各存一份会得到「设置成功但插件不生效」这种极难排查的行为。
//! 安装 / 卸载 / 启停之后由 Dart 侧调用 `reload_sources` 重建注册表，
//! 会话与下载任务不受影响（Core-1 验收项）。

use guo_engine_core::{EngineError, EngineErrorKind};

use crate::api::error::EngineFailure;
use guo_plugin_host::{
    install_package, parse_index, select_entry, PackageLimits, PluginError, PluginStore,
    RepoManifest, RepositoryIndex,
};
use guo_runtime::{precheck_entry, RepoClient};

use super::{PluginSummary, RepoSummary};

/// 插件错误统一映射为 `EngineError::Plugin`，并保留可读提示。
fn plugin_error(error: PluginError) -> EngineFailure {
    let hint = match &error {
        PluginError::Integrity { .. } => "（包可能被替换或下载不完整）",
        PluginError::Unsupported { .. } => "（请升级应用）",
        PluginError::Unsafe { .. } => "（出于安全考虑已拒绝安装）",
        _ => "",
    };
    EngineFailure::from(EngineError::new(
        EngineErrorKind::Plugin,
        format!("{error}{hint}"),
    ))
}

fn engine() -> Result<std::sync::Arc<guo_engine_core::Engine>, EngineFailure> {
    guo_engine_core::require().map_err(EngineFailure::from)
}

fn store() -> Result<PluginStore, EngineFailure> {
    let engine = engine()?;
    Ok(PluginStore::open(&engine.config().plugin_directory))
}

fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|value| value.as_secs())
        .unwrap_or(0)
}

/// 校验 `repo.toml`，返回规范化后的摘要。
pub fn parse_repository(text: String) -> Result<RepoSummary, EngineFailure> {
    let manifest = RepoManifest::parse(&text).map_err(|err| {
        EngineFailure::from(EngineError::new(EngineErrorKind::Plugin, err.to_string()))
    })?;
    let signed = manifest.is_signed();
    Ok(RepoSummary {
        id: manifest.id,
        name: manifest.name,
        index: manifest.index,
        signed,
        fingerprint: manifest.public_key.unwrap_or_default(),
    })
}

/// 校验 `index.json` 并返回可安装条目。
pub fn parse_repository_index(text: String) -> Result<Vec<PluginSummary>, EngineFailure> {
    let index = parse_index(&text).map_err(|err| {
        EngineFailure::from(EngineError::new(EngineErrorKind::Plugin, err.to_string()))
    })?;
    Ok(index
        .entries()
        .map(|entry| PluginSummary {
            id: entry.id.as_str().to_string(),
            name: entry.name.clone(),
            version: entry.version.to_string(),
            kind: entry
                .kind
                .as_ref()
                .map(|kind| kind.as_str().to_string())
                .unwrap_or_else(|| "declarative".to_string()),
            installed: false,
            enabled: false,
            signed: false,
            content_types: content_types_of(&entry.content_types),
        })
        .collect())
}

/// 安装一个已下载的包。`index_json` 用于交叉校验 id / 版本 / 哈希。
pub fn install_plugin(
    index_json: String,
    plugin_id: String,
    version: String,
    repo_id: String,
    repo_signed: bool,
    archive: Vec<u8>,
) -> Result<PluginSummary, EngineFailure> {
    let index: RepositoryIndex = parse_index(&index_json).map_err(|err| {
        EngineFailure::from(EngineError::new(EngineErrorKind::Plugin, err.to_string()))
    })?;
    let wanted = semver_like(&version);
    let entry = select_entry(&index, &plugin_id, wanted.as_ref()).map_err(plugin_error)?;
    let store = store()?;
    let installed = install_package(
        &store,
        entry,
        &archive,
        &guo_plugin_host::InstallRequest {
            repo_id: &repo_id,
            repo_signed,
            now: now_secs(),
        },
        PackageLimits::default(),
    )
    .map_err(plugin_error)?;
    Ok(PluginSummary {
        id: installed.id,
        name: installed.name,
        version: installed.version.to_string(),
        kind: installed.kind.as_str().to_string(),
        installed: true,
        enabled: installed.enabled,
        signed: repo_signed,
        content_types: content_types_of(&installed.content_types),
    })
}

/// 内容类型 → 稳定字符串，供 Dart 侧做筛选与本地化。
fn content_types_of(kinds: &[guo_source_api::ContentType]) -> Vec<String> {
    kinds.iter().map(|kind| kind.as_str().to_string()).collect()
}

fn semver_like(text: &str) -> Option<semver::Version> {
    if text.trim().is_empty() {
        return None;
    }
    semver::Version::parse(text.trim()).ok()
}

/// 已安装插件清单。
pub fn installed_plugins() -> Result<Vec<PluginSummary>, EngineFailure> {
    let store = store()?;
    Ok(store
        .installed()
        .into_iter()
        .map(|plugin| PluginSummary {
            id: plugin.id,
            name: plugin.name,
            version: plugin.version.to_string(),
            kind: plugin.kind.as_str().to_string(),
            installed: true,
            enabled: plugin.enabled,
            signed: false,
            content_types: content_types_of(&plugin.content_types),
        })
        .collect())
}

/// 卸载插件。返回是否真的移除了内容。
pub fn uninstall_plugin(plugin_id: String) -> Result<bool, EngineFailure> {
    store()?.uninstall(&plugin_id).map_err(|err| {
        EngineFailure::from(EngineError::new(EngineErrorKind::Plugin, err.to_string()))
    })
}

/// 启用 / 停用插件。
pub fn set_plugin_enabled(plugin_id: String, enabled: bool) -> Result<(), EngineFailure> {
    store()?.set_enabled(&plugin_id, enabled).map_err(|err| {
        EngineFailure::from(EngineError::new(EngineErrorKind::Plugin, err.to_string()))
    })
}

/// 回滚到指定版本。
pub fn rollback_plugin(plugin_id: String, version: String) -> Result<(), EngineFailure> {
    let parsed = semver_like(&version).ok_or_else(|| {
        EngineError::new(EngineErrorKind::Plugin, format!("版本号非法：{version}"))
    })?;
    store()?
        .set_active_version(&plugin_id, &parsed)
        .map_err(|err| {
            EngineFailure::from(EngineError::new(EngineErrorKind::Plugin, err.to_string()))
        })
}

/// 记录仓库并返回指纹是否变化（变化时 UI 必须提示并拒绝自动更新）。
pub fn remember_repository(
    repo_id: String,
    url: String,
    public_key: String,
) -> Result<bool, EngineFailure> {
    store()?
        .remember_repo(
            &repo_id,
            guo_plugin_host::RepoRecord {
                url,
                signed: !public_key.is_empty(),
                fingerprint: public_key,
                last_fetch: now_secs(),
            },
        )
        .map_err(|err| {
            EngineFailure::from(EngineError::new(EngineErrorKind::Plugin, err.to_string()))
        })
}

/// 给安全类错误补上人话解释，避免 UI 只显示「校验失败」。
///
/// `PluginError` 不是 FRB 类型，标 `ignore` 让生成器跳过；它只在 Rust 侧内部使用。
#[flutter_rust_bridge::frb(ignore)]
pub fn plugin_error_hint(err: PluginError) -> String {
    match err {
        PluginError::Integrity { .. } => format!("{err}（包可能被替换或下载不完整）"),
        PluginError::Unsupported { .. } => format!("{err}（请升级应用）"),
        PluginError::Unsafe { .. } => format!("{err}（出于安全考虑已拒绝安装）"),
        _ => err.to_string(),
    }
}

/// 插件装配结果：已加载与失败的 id。失败项带原因，供诊断页展示。
pub fn plugin_load_report() -> Result<PluginLoadReport, EngineFailure> {
    let report = engine()?.load_report();
    Ok(PluginLoadReport {
        loaded: report.loaded,
        failed: report
            .failed
            .into_iter()
            .map(|(id, detail)| FailedPlugin { id, detail })
            .collect(),
    })
}

/// 单个插件加载失败的原因。
pub struct FailedPlugin {
    pub id: String,
    pub detail: String,
}

/// 插件装配结果。
pub struct PluginLoadReport {
    pub loaded: Vec<String>,
    pub failed: Vec<FailedPlugin>,
}

/// 从仓库完整安装：拉 `repo.toml` → `index.json`（含可选验签）→ 包 → 落盘。
///
/// 传输层用引擎的全局实例（连接池复用）；之所以不接受 Dart 传入，
/// 是因为 `Arc<dyn Transport>` 既不是 `Clone` 也不是可序列化类型，
/// 跨 FFI 传递只会把「谁能构造网络层」这件事从引擎手里漏出去。
pub async fn install_from_repo(
    repo_url: String,
    plugin_id: String,
    repo_id: String,
    repo_signed: bool,
) -> Result<PluginSummary, EngineFailure> {
    let store = store()?;
    let client = RepoClient::new(engine()?.transport());

    let manifest = client
        .fetch_manifest(&repo_url)
        .await
        .map_err(plugin_error)?;
    // 仓库自己声明的 id 优先于调用方传入的，避免「装的包和记账的仓库对不上」。
    let repo_id = if manifest.id.is_empty() {
        repo_id
    } else {
        manifest.id.clone()
    };
    let fetched = client
        .fetch_index(&repo_url, &manifest)
        .await
        .map_err(plugin_error)?;
    let entry = fetched
        .index
        .get(&plugin_id)
        .ok_or_else(|| {
            EngineError::new(EngineErrorKind::Plugin, format!("仓库里没有 {plugin_id}"))
        })?
        .clone();
    precheck_entry(&entry, PackageLimits::default()).map_err(plugin_error)?;

    let archive = client
        .download_package(&repo_url, &entry)
        .await
        .map_err(plugin_error)?;

    let installed = install_package(
        &store,
        &entry,
        &archive,
        &guo_plugin_host::InstallRequest {
            repo_id: &repo_id,
            repo_signed: repo_signed || fetched.signed,
            now: now_secs(),
        },
        PackageLimits::default(),
    )
    .map_err(plugin_error)?;

    // 记录仓库信任状态：指纹变化由 UI 决定是否提示，这里只如实上报。
    let fingerprint = manifest.public_key.clone().unwrap_or_default();
    let _ = store.remember_repo(
        &repo_id,
        guo_plugin_host::RepoRecord {
            url: repo_url,
            signed: fetched.signed,
            fingerprint,
            last_fetch: now_secs(),
        },
    );

    Ok(PluginSummary {
        id: installed.id,
        name: installed.name,
        version: installed.version.to_string(),
        kind: installed.kind.as_str().to_string(),
        installed: true,
        enabled: installed.enabled,
        signed: fetched.signed,
        content_types: content_types_of(&installed.content_types),
    })
}

/// 只查询仓库有哪些可安装插件（不下载包）。
pub async fn list_repo_plugins(repo_url: String) -> Result<Vec<PluginSummary>, EngineFailure> {
    let client = RepoClient::new(engine()?.transport());
    let manifest = client
        .fetch_manifest(&repo_url)
        .await
        .map_err(plugin_error)?;
    let fetched = client
        .fetch_index(&repo_url, &manifest)
        .await
        .map_err(plugin_error)?;
    Ok(fetched
        .index
        .entries()
        .map(|entry| PluginSummary {
            id: entry.id.as_str().to_string(),
            name: entry.name.clone(),
            version: entry.version.to_string(),
            kind: entry
                .kind
                .as_ref()
                .map(|kind| kind.as_str().to_string())
                .unwrap_or_else(|| "declarative".to_string()),
            installed: false,
            enabled: false,
            signed: fetched.signed,
            content_types: content_types_of(&entry.content_types),
        })
        .collect())
}
