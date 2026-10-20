//! 已安装插件 → `SourcePlugin` 的装配。
//!
//! 这是「插件目录」与「运行时注册表」之间唯一的桥：安装器负责把包落到磁盘，
//! 运行时负责在启动时把这些包重新变成可调用的站源。
//!
//! 加载策略：
//! - 声明式插件：逐条 `[[rules]]` 读 JSON → [`RuleSource`]；
//! - 代码插件：读 `plugin.wasm` → `ComponentSource`，权限来自清单；
//! - 单个插件失败不影响其它插件（记 warning 后跳过），否则一个坏包能让整个应用起不来。

use std::fs;
use std::path::{Path, PathBuf};

use guo_plugin_host::{InstalledPlugin, PluginKind, PluginManifest, PluginStore};
use guo_source_api::{SourcePlugin, SourceRegistry};

use crate::rule_source::RuleSource;

/// 代码插件加载器：把清单与 `plugin.wasm` 路径变成可调用站源。
///
/// 抽成类型别名是因为 `&dyn Fn(&PluginManifest, &Path) -> Result<Box<dyn SourcePlugin>, String>`
/// 直接写在签名里既难读，也会触发 clippy 的 `type_complexity`。
pub type ComponentLoader<'a> =
    &'a dyn Fn(&PluginManifest, &Path) -> Result<Box<dyn SourcePlugin>, String>;

/// 一次装配的结果。失败项保留原因，供诊断页展示。
#[derive(Debug, Default)]
pub struct LoadReport {
    pub loaded: Vec<String>,
    pub failed: Vec<(String, String)>,
}

impl LoadReport {
    pub fn is_empty(&self) -> bool {
        self.loaded.is_empty() && self.failed.is_empty()
    }
}

/// 把已安装且启用的插件注册进 `registry`。
///
/// `load_component` 由调用方注入：它需要 `guo-plugin-wasm`，
/// 而那个 crate 会拖进 wasmtime；把依赖留在桥接层，
/// 可以让 `runtime` 在不需要代码插件的场景（如命令行校验工具）里保持轻量。
pub fn load_installed(
    store: &PluginStore,
    registry: &mut SourceRegistry,
    load_component: ComponentLoader<'_>,
) -> LoadReport {
    let mut report = LoadReport::default();
    for plugin in store.installed() {
        if !plugin.enabled {
            continue;
        }
        match load_one(store, &plugin, load_component) {
            Ok(sources) => {
                for source in sources {
                    registry.register(source);
                }
                report.loaded.push(plugin.id);
            }
            Err(detail) => report.failed.push((plugin.id, detail)),
        }
    }
    report
}

fn load_one(
    store: &PluginStore,
    plugin: &InstalledPlugin,
    load_component: ComponentLoader<'_>,
) -> Result<Vec<std::sync::Arc<dyn SourcePlugin>>, String> {
    let manifest = store
        .manifest_of(&plugin.id, &plugin.version)
        .map_err(|err| err.to_string())?;
    let directory = PathBuf::from(&plugin.directory);
    match manifest.kind {
        PluginKind::Declarative => {
            let mut out = Vec::new();
            for rule in &manifest.rules {
                let path = directory.join(&rule.path);
                let text = fs::read_to_string(&path)
                    .map_err(|err| format!("读取 {} 失败：{err}", path.display()))?;
                let source = RuleSource::from_json(&text).map_err(|err| err.to_string())?;
                out.push(std::sync::Arc::new(source) as std::sync::Arc<dyn SourcePlugin>);
            }
            Ok(out)
        }
        PluginKind::Component => {
            let entry = manifest
                .entry
                .as_deref()
                .ok_or_else(|| "代码插件缺少 entry".to_string())?;
            let path = directory.join(entry);
            let source = load_component(&manifest, &path)?;
            Ok(vec![std::sync::Arc::from(source)])
        }
    }
}

/// 插件目录布局：`<root>` 由桥接层按平台应用数据目录传入。
pub fn plugin_root(support_directory: impl AsRef<Path>) -> PathBuf {
    support_directory.as_ref().join("engine").join("plugins")
}

#[cfg(test)]
mod tests {
    use super::*;
    use guo_plugin_host::sha256_hex;
    use guo_plugin_host::{
        install_package, parse_index, select_entry, InstallRequest, PackageLimits,
    };
    use std::io::{Cursor, Write};
    use std::sync::atomic::{AtomicU64, Ordering};
    use zip::write::SimpleFileOptions;

    static NEXT: AtomicU64 = AtomicU64::new(0);

    fn temporary_root(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "guo-plugins-{name}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = fs::remove_dir_all(&path);
        path
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

    /// 一条最小的合法声明式规则（结构对齐 `rules/wuguo.json`）。
    const RULE: &str = r#"{
      "schema": "1.0",
      "id": "plugin_a",
      "name": "插件 A",
      "base": "https://a.test",
      "kind": "html",
      "categories": [{"id": "1", "name": "全部"}],
      "catalog": {
        "url": "list/{page}",
        "item": "a.card",
        "fields": {"id": "a@href", "title": ".t"}
      },
      "detail": {"episodes": "a.ep"}
    }"#;

    fn install_declarative(store: &PluginStore, id: &str, version: &str, rules: &[(&str, &str)]) {
        // `[[rules]]` 的 site 是规则里的站点 id（不是文件内容）。
        let rule_entries: String = rules
            .iter()
            .map(|(path, text)| {
                let site = text
                    .split("\"id\": \"")
                    .nth(1)
                    .and_then(|rest| rest.split('"').next())
                    .unwrap_or("unknown");
                format!("\n[[rules]]\npath = \"{path}\"\nsite = \"{site}\"\n")
            })
            .collect();
        let manifest = format!(
            "spec = 1\nid = \"{id}\"\nname = \"插件\"\nversion = \"{version}\"\nkind = \"declarative\"\napi = {{ level = 1, min_host = \"0.3.0\" }}\n{rule_entries}"
        );
        let mut entries: Vec<(String, Vec<u8>)> =
            vec![("plugin.toml".into(), manifest.into_bytes())];
        for (path, text) in rules {
            entries.push((path.to_string(), text.as_bytes().to_vec()));
        }
        let refs: Vec<(&str, &[u8])> = entries
            .iter()
            .map(|(name, data)| (name.as_str(), data.as_slice()))
            .collect();
        let archive = archive_of(&refs);
        let sha = sha256_hex(&archive);
        let index_json = format!(
            r#"[{{"id":"{id}","name":"插件","version":"{version}","kind":"declarative","api":1,"minHost":"0.3.0","size":{},"sha256":"{sha}","path":"plugins/{id}.zip"}}]"#,
            archive.len()
        );
        let index = parse_index(&index_json).expect("index");
        let entry = select_entry(&index, id, None).expect("entry");
        install_package(
            store,
            entry,
            &archive,
            &InstallRequest {
                repo_id: "official",
                repo_signed: false,
                now: 1,
            },
            PackageLimits::default(),
        )
        .expect("install");
    }

    fn no_components(
        _manifest: &PluginManifest,
        _path: &Path,
    ) -> Result<Box<dyn SourcePlugin>, String> {
        Err("测试里不加载代码插件".to_string())
    }

    #[test]
    fn loads_declarative_plugins_into_registry() {
        let root = temporary_root("declarative");
        let store = PluginStore::open(&root);
        install_declarative(&store, "guo.plugina", "1.0.0", &[("rules/a.json", RULE)]);

        let mut registry = SourceRegistry::new();
        let report = load_installed(&store, &mut registry, &no_components);
        assert_eq!(
            report.loaded,
            vec!["guo.plugina"],
            "失败：{:?}",
            report.failed
        );
        assert!(report.failed.is_empty());
        assert!(registry.get("plugin_a").is_some());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn disabled_plugins_are_skipped() {
        let root = temporary_root("disabled");
        let store = PluginStore::open(&root);
        install_declarative(&store, "guo.plugina", "1.0.0", &[("rules/a.json", RULE)]);
        store.set_enabled("guo.plugina", false).expect("disable");

        let mut registry = SourceRegistry::new();
        let report = load_installed(&store, &mut registry, &no_components);
        assert!(report.loaded.is_empty());
        assert!(registry.is_empty());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn broken_rule_is_reported_not_fatal() {
        let root = temporary_root("broken");
        let store = PluginStore::open(&root);
        // 清单合法但规则 JSON 损坏：加载期必须报错，且不注册任何源。
        install_declarative(
            &store,
            "guo.broken",
            "1.0.0",
            &[("rules/x.json", "{not json")],
        );

        let mut registry = SourceRegistry::new();
        let report = load_installed(&store, &mut registry, &no_components);
        assert!(report.loaded.is_empty());
        assert_eq!(report.failed.len(), 1);
        assert_eq!(report.failed[0].0, "guo.broken");
        assert!(registry.is_empty());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn one_broken_plugin_does_not_block_others() {
        let root = temporary_root("mixed");
        let store = PluginStore::open(&root);
        install_declarative(&store, "guo.broken", "1.0.0", &[("rules/x.json", "{}")]);
        install_declarative(&store, "guo.good", "1.0.0", &[("rules/a.json", RULE)]);

        let mut registry = SourceRegistry::new();
        let report = load_installed(&store, &mut registry, &no_components);
        assert_eq!(report.loaded, vec!["guo.good"]);
        assert_eq!(report.failed.len(), 1);
        assert!(registry.get("plugin_a").is_some());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn component_plugins_delegate_to_the_injected_loader() {
        let root = temporary_root("component");
        let store = PluginStore::open(&root);
        let manifest = "spec = 1\nid = \"guo.code\"\nname = \"代码\"\nversion = \"1.0.0\"\nkind = \"component\"\nentry = \"plugin.wasm\"\napi = { level = 1, min_host = \"0.3.0\" }\n";
        // `\0asm` 头，足够通过安装器的初步检查。
        let archive = archive_of(&[
            ("plugin.toml", manifest.as_bytes()),
            ("plugin.wasm", b"\0asm"),
        ]);
        let sha = sha256_hex(&archive);
        let index_json = format!(
            r#"[{{"id":"guo.code","name":"代码","version":"1.0.0","kind":"component","api":1,"minHost":"0.3.0","size":{},"sha256":"{sha}","path":"plugins/guo.code.zip"}}]"#,
            archive.len()
        );
        let index = parse_index(&index_json).expect("index");
        let entry = select_entry(&index, "guo.code", None).expect("entry");
        install_package(
            &store,
            entry,
            &archive,
            &InstallRequest {
                repo_id: "official",
                repo_signed: false,
                now: 1,
            },
            PackageLimits::default(),
        )
        .expect("install");

        let mut registry = SourceRegistry::new();
        let report = load_installed(&store, &mut registry, &|_manifest, path| {
            assert!(path.ends_with("plugin.wasm"), "{}", path.display());
            Err("模拟编译失败".to_string())
        });
        assert!(report.loaded.is_empty());
        assert_eq!(report.failed.len(), 1);
        assert!(report.failed[0].1.contains("模拟编译失败"));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn plugin_root_is_under_engine_directory() {
        assert_eq!(
            plugin_root("/data/app"),
            PathBuf::from("/data/app/engine/plugins")
        );
    }
}
