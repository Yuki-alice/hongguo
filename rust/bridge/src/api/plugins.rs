//! 插件安装与仓库管理入口。
//!
//! 两条路径都保留：
//! - [`install_plugin`]：调用方自己下载字节后传入（便于离线测试与「从文件安装」）；
//! - [`install_from_repo`]：完整网络流程，仓库客户端拉清单 → 索引 → 包，再交给安装器。
//!
//! 无论走哪条，校验都在同一处（`guo-plugin-host`），不存在「网络路径少校验一次」。

use guo_plugin_host::{
    install_package, parse_index, select_entry, PackageLimits, PluginError, PluginStore,
    RepoManifest, RepositoryIndex,
};
use guo_runtime::{precheck_entry, RepoClient};

use super::{PluginSummary, RepoSummary};

/// 返回插件根目录；未初始化时返回错误而不是 panic。
///
/// 目录状态只保存在 `sources::builtin` 一处：那里既要装 `PluginStore`，
/// 也要在 `builtin_registry()` 里加载插件。两处各存一份会得到
/// 「设置成功但插件不生效」这种极难排查的行为。
fn store() -> Result<PluginStore, String> {
    let root =
        crate::sources::plugin_directory().ok_or_else(|| "插件目录尚未初始化".to_string())?;
    Ok(PluginStore::open(root))
}

/// 指定插件根目录。必须在任何插件调用前设置一次。
pub fn set_plugin_directory(directory: String) -> bool {
    crate::sources::set_plugin_directory(directory)
}

/// 进程级共享的 HTTP 传输层。
///
/// 每次调用新建 client 会让连接池、TLS 会话缓存与 DNS 缓存全部失效；
/// 插件仓库的访问频率不高，但也没有理由为每次请求重建。
fn host_transport() -> Result<std::sync::Arc<dyn guo_source_api::Transport>, String> {
    guo_host::HttpTransport::global()
        .map(|transport| transport as std::sync::Arc<dyn guo_source_api::Transport>)
        .map_err(|err| err.to_string())
}

fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|value| value.as_secs())
        .unwrap_or(0)
}

/// 校验 `repo.toml`，返回规范化后的摘要。
pub fn parse_repository(text: String) -> Result<RepoSummary, String> {
    let manifest = RepoManifest::parse(&text).map_err(|err| err.to_string())?;
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
pub fn parse_repository_index(text: String) -> Result<Vec<PluginSummary>, String> {
    let index = parse_index(&text).map_err(|err| err.to_string())?;
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
) -> Result<PluginSummary, String> {
    let index: RepositoryIndex = parse_index(&index_json).map_err(|err| err.to_string())?;
    let wanted = semver_like(&version);
    let entry = select_entry(&index, &plugin_id, wanted.as_ref()).map_err(|err| err.to_string())?;
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
    .map_err(plugin_error_hint)?;
    Ok(PluginSummary {
        id: installed.id,
        name: installed.name,
        version: installed.version.to_string(),
        kind: installed.kind.as_str().to_string(),
        installed: true,
        enabled: installed.enabled,
        signed: repo_signed,
    })
}

fn semver_like(text: &str) -> Option<semver::Version> {
    if text.trim().is_empty() {
        return None;
    }
    semver::Version::parse(text.trim()).ok()
}

/// 已安装插件清单。
pub fn installed_plugins() -> Vec<PluginSummary> {
    let Ok(store) = store() else {
        return Vec::new();
    };
    store
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
        })
        .collect()
}

/// 卸载插件。返回是否真的移除了内容。
pub fn uninstall_plugin(plugin_id: String) -> Result<bool, String> {
    store()?
        .uninstall(&plugin_id)
        .map_err(|err: PluginError| err.to_string())
}

/// 启用 / 停用插件。
pub fn set_plugin_enabled(plugin_id: String, enabled: bool) -> Result<(), String> {
    store()?
        .set_enabled(&plugin_id, enabled)
        .map_err(|err| err.to_string())
}

/// 回滚到指定版本。
pub fn rollback_plugin(plugin_id: String, version: String) -> Result<(), String> {
    let parsed = semver_like(&version).ok_or_else(|| format!("版本号非法：{version}"))?;
    store()?
        .set_active_version(&plugin_id, &parsed)
        .map_err(|err| err.to_string())
}

/// 记录仓库并返回指纹是否变化（变化时 UI 必须提示并拒绝自动更新）。
pub fn remember_repository(
    repo_id: String,
    url: String,
    public_key: String,
) -> Result<bool, String> {
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
        .map_err(|err| err.to_string())
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
pub fn plugin_load_report() -> PluginLoadReport {
    let (loaded, failed) = crate::sources::last_load_report();
    PluginLoadReport {
        loaded,
        failed: failed
            .into_iter()
            .map(|(id, detail)| FailedPlugin { id, detail })
            .collect(),
    }
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
/// 传输层用宿主全局实例（连接池复用）；之所以不接受 Dart 传入，
/// 是因为 `Arc<dyn Transport>` 既不是 `Clone` 也不是可序列化类型，
/// 跨 FFI 传递只会把「谁能构造网络层」这件事从引擎手里漏出去。
/// 网络层的可测试性由 `guo-runtime` 的假传输层测试保证。
pub async fn install_from_repo(
    repo_url: String,
    plugin_id: String,
    repo_id: String,
    repo_signed: bool,
) -> Result<PluginSummary, String> {
    let store = store()?;
    let client = RepoClient::new(host_transport()?);

    let manifest = client
        .fetch_manifest(&repo_url)
        .await
        .map_err(plugin_error_hint)?;
    // 仓库自己声明的 id 优先于调用方传入的，避免「装的包和记账的仓库对不上」。
    let repo_id = if manifest.id.is_empty() {
        repo_id
    } else {
        manifest.id.clone()
    };
    let fetched = client
        .fetch_index(&repo_url, &manifest)
        .await
        .map_err(plugin_error_hint)?;
    let entry = fetched
        .index
        .get(&plugin_id)
        .ok_or_else(|| format!("仓库里没有 {plugin_id}"))?
        .clone();
    precheck_entry(&entry, PackageLimits::default()).map_err(plugin_error_hint)?;

    let archive = client
        .download_package(&repo_url, &entry)
        .await
        .map_err(plugin_error_hint)?;

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
    .map_err(plugin_error_hint)?;

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
    })
}

/// 只查询仓库有哪些可安装插件（不下载包）。
pub async fn list_repo_plugins(repo_url: String) -> Result<Vec<PluginSummary>, String> {
    let client = RepoClient::new(host_transport()?);
    let manifest = client
        .fetch_manifest(&repo_url)
        .await
        .map_err(plugin_error_hint)?;
    let fetched = client
        .fetch_index(&repo_url, &manifest)
        .await
        .map_err(plugin_error_hint)?;
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
        })
        .collect())
}
