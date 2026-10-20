//! 内置站源装配。
//!
//! 三部分按优先级注册：
//! 1. **主源**（红果）：随包分发，不走插件体系（ARCHITECTURE.md §5）；
//! 2. **随包规则**：迁移期保留，P1 后逐步搬进官方仓库包；
//! 3. **已安装插件**：声明式读 JSON、代码插件走 WASM 宿主。
//!
//! 插件装配失败不会影响前两部分——否则一个坏包能让主源也起不来。

use std::path::Path;
use std::sync::{Arc, Mutex, OnceLock};

use guo_plugin_host::PluginStore;
use guo_plugin_wasm::{ComponentSource, SandboxLimits};
use guo_runtime::{load_installed, LoadReport, RuleSource};
use guo_source_api::{SourcePlugin, SourceRegistry};
use guo_source_hongguo::HongguoSource;
use guo_source_maoguo::MaoguoSource;

/// 插件根目录。由 Dart 侧在启动时通过 `set_plugin_directory` 指定。
static PLUGIN_DIRECTORY: OnceLock<std::path::PathBuf> = OnceLock::new();

/// 上一次装配的插件加载结果，供诊断接口读取。
static LAST_REPORT: OnceLock<Mutex<LoadReport>> = OnceLock::new();

fn report_slot() -> &'static Mutex<LoadReport> {
    LAST_REPORT.get_or_init(|| Mutex::new(LoadReport::default()))
}

/// 指定插件根目录；重复设置返回 `false`。
pub fn set_plugin_directory(directory: impl Into<std::path::PathBuf>) -> bool {
    PLUGIN_DIRECTORY.set(directory.into()).is_ok()
}

pub fn plugin_directory() -> Option<&'static Path> {
    PLUGIN_DIRECTORY.get().map(|path| path.as_path())
}

/// 注册所有内置站源 + 已安装插件。新增随包站源只需在这里加一行。
pub fn builtin_registry() -> SourceRegistry {
    let mut registry = SourceRegistry::new();
    // 主源固定注册：它随包分发，不走插件体系（ARCHITECTURE.md §5）。
    registry.register(Arc::new(HongguoSource::new()));
    registry.register(Arc::new(MaoguoSource::new()));
    for text in BUILTIN_RULES {
        match RuleSource::from_json(text) {
            Ok(source) => {
                registry.register(Arc::new(source));
            }
            Err(err) => {
                // 规则随包分发，加载失败属于构建期缺陷，必须显式暴露。
                eprintln!("内置规则加载失败：{err}");
            }
        }
    }
    load_plugins(&mut registry);
    registry
}

/// 把已安装插件注册进来，并把结果留给诊断接口。
fn load_plugins(registry: &mut SourceRegistry) {
    let Some(root) = plugin_directory() else {
        return;
    };
    let store = PluginStore::open(root);
    let report = load_installed(&store, registry, &load_component);
    for (id, detail) in &report.failed {
        eprintln!("插件 {id} 加载失败：{detail}");
    }
    if let Ok(mut slot) = report_slot().lock() {
        *slot = report;
    }
}

/// 代码插件加载器：把 `plugin.wasm` 变成 `ComponentSource`。
///
/// 权限来自清单（`permissions.network` / `permissions.storage`），
/// 插件无法自行扩大。
fn load_component(
    manifest: &guo_plugin_host::PluginManifest,
    entry: &Path,
) -> Result<Box<dyn SourcePlugin>, String> {
    let bytes =
        std::fs::read(entry).map_err(|err| format!("读取 {} 失败：{err}", entry.display()))?;
    let limits = manifest
        .permissions
        .script
        .map(|script| SandboxLimits {
            fuel: script.memory_kb.saturating_mul(1_000_000),
            memory_bytes: (script.memory_kb as usize) * 1024,
            ..SandboxLimits::default()
        })
        .unwrap_or_default();
    let source = ComponentSource::load(
        &bytes,
        manifest.permissions.network.clone(),
        manifest.permissions.storage.clone(),
        limits,
    )
    .map_err(|err| err.to_string())?;
    Ok(Box::new(source))
}

/// 上一次插件装配的结果，供 `plugin_load_report` 使用。
pub fn last_load_report() -> (Vec<String>, Vec<(String, String)>) {
    match report_slot().lock() {
        Ok(report) => (report.loaded.clone(), report.failed.clone()),
        Err(_) => (Vec::new(), Vec::new()),
    }
}

/// 随包分发的声明式规则。
const BUILTIN_RULES: &[&str] = &[
    include_str!("../../../rules/wuguo.json"),
    include_str!("../../../rules/huaguo.json"),
    include_str!("../../../rules/fanguo.json"),
    include_str!("../../../rules/guanguo.json"),
    include_str!("../../../rules/xingguo.json"),
    include_str!("../../../rules/heguo.json"),
    include_str!("../../../rules/wangguo.json"),
    include_str!("../../../rules/diguo.json"),
    include_str!("../../../rules/faguo.json"),
];
