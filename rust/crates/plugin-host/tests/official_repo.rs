//! 官方规则仓库的端到端校验。
//!
//! 直接读取 `pack_rules` 生成的产物（`rust/dist/rules/`），用**同一套安装器**
//! 逐个安装，确保「我们生成的包」一定能被「我们自己装」。
//!
//! 这条测试防的是：打包脚本改了字段名、忘了更新哈希、清单与索引不一致——
//! 这些问题只会在用户装不上时才发现。

use std::collections::BTreeMap;
use std::path::PathBuf;

use guo_plugin_host::{
    install_package, parse_index, parse_repo_from_path, select_entry, InstallRequest,
    PackageLimits, PluginKind, PluginStore,
};

fn repo_root() -> PathBuf {
    // CARGO_MANIFEST_DIR 是 crates/plugin-host，仓库产物在 rust/dist/rules。
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../dist/rules")
        .canonicalize()
        .expect("先运行 cargo run -p guo-plugin-host --bin pack_rules -- dist/rules rules")
}

fn temporary_store(name: &str) -> (PluginStore, PathBuf) {
    let path = std::env::temp_dir().join(format!(
        "guo-official-repo-{name}-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    let _ = std::fs::remove_dir_all(&path);
    (PluginStore::open(&path), path)
}

#[test]
fn repo_manifest_and_index_agree() {
    let root = repo_root();
    let manifest = parse_repo_from_path(&root.join("repo.toml")).expect("repo.toml 应可解析");
    assert_eq!(manifest.id, "official");
    assert!(!manifest.is_signed(), "官方仓库当前未签名（D3 允许）");

    let index_text = std::fs::read_to_string(root.join(&manifest.index)).expect("index.json");
    let index = parse_index(&index_text).expect("index.json 应可解析");
    assert!(index.len() >= 7, "官方仓库应有至少 7 个规则包");
}

#[test]
fn every_indexed_package_installs_and_loads() {
    let root = repo_root();
    let index_text = std::fs::read_to_string(root.join("index.json")).expect("index.json");
    let index = parse_index(&index_text).expect("index");

    let (store, dir) = temporary_store("install-all");
    let mut installed_ids = Vec::new();

    for entry in index.entries() {
        let archive_path = root.join(&entry.path);
        let archive = std::fs::read(&archive_path)
            .unwrap_or_else(|err| panic!("读取 {} 失败：{err}", archive_path.display()));

        assert_eq!(
            archive.len() as u64,
            entry.size.expect("索引必须声明 size"),
            "{} 的大小与索引不符",
            entry.id
        );

        let selected = select_entry(&index, entry.id.as_str(), Some(&entry.version))
            .expect("索引里应能选到该条目");
        let installed = install_package(
            &store,
            selected,
            &archive,
            &InstallRequest {
                repo_id: "official",
                repo_signed: false,
                now: 1,
            },
            PackageLimits::default(),
        )
        .unwrap_or_else(|err| panic!("{} 安装失败：{err}", entry.id));

        assert_eq!(installed.kind, PluginKind::Declarative);
        assert!(installed.enabled, "{} 安装后必须默认启用", entry.id);
        installed_ids.push(entry.id.as_str().to_string());
    }

    let listed: BTreeMap<String, _> = store
        .installed()
        .into_iter()
        .map(|plugin| (plugin.id.clone(), plugin))
        .collect();
    assert_eq!(listed.len(), installed_ids.len());
    for id in &installed_ids {
        assert!(listed.contains_key(id), "{id} 未出现在已安装列表");
    }

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn packaged_rule_content_matches_shipped_rules() {
    // 包里的规则必须与 `rust/rules/*.json` 一致：改规则后忘了重新打包会在这里失败。
    let root = repo_root();
    let index_text = std::fs::read_to_string(root.join("index.json")).expect("index.json");
    let index = parse_index(&index_text).expect("index");

    for entry in index.entries() {
        let archive = std::fs::read(root.join(&entry.path)).expect("读取包");
        let package =
            guo_plugin_host::unpack(&archive, Some(&entry.sha256), PackageLimits::default())
                .expect("解包");
        for declared in package.manifest.declared_paths() {
            let packaged = package.file(declared).expect("包内应有声明文件");
            let site = package
                .manifest
                .rules
                .iter()
                .find(|rule| rule.path == declared)
                .map(|rule| rule.site.clone())
                .expect("应有对应 site");
            let source_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../../rules")
                .join(format!("{site}.json"));
            let source = std::fs::read(&source_path)
                .unwrap_or_else(|err| panic!("读取 {} 失败：{err}", source_path.display()));
            assert_eq!(
                packaged, source,
                "{site} 的包内规则与源文件不一致，需要重新运行 pack_rules"
            );
        }
    }
}
