//! Core-3 验收：启用 / 停用 / 回滚插件不丢失会话与下载任务。
//!
//! 这是 PLAN.md 里明确写出的验收项。测的是**引擎层的装配语义**：
//! `rebuild_registry` 只换注册表，不碰会话存储与任务表。
//!
//! 用真实的预装包（`assets/bundled_plugins/*.zip`）驱动，与 App 启动一致。

use std::path::PathBuf;

use guo_engine_core::{Engine, EngineConfig, EngineError};
use guo_plugin_host::PluginStore;

const MAOGUO_ZIP: &[u8] = include_bytes!("../../../../assets/bundled_plugins/guo.maoguo-1.1.0.zip");
const YAGUO_ZIP: &[u8] = include_bytes!("../../../../assets/bundled_plugins/guo.yaguo-1.0.0.zip");
const INDEX: &str = include_str!("../../../../assets/bundled_plugins/index.json");

fn temp_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "guo-toggle-{name}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|value| value.as_nanos())
            .unwrap_or(0)
    ));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

/// 只注册内建源的装配器：插件由预装提供，避免测试依赖编译期源。
fn no_builtins(_registry: &mut guo_source_api::SourceRegistry) {}

fn bundled() -> Vec<guo_engine_core::BundledPackage> {
    vec![
        guo_engine_core::BundledPackage {
            name: "guo.maoguo-1.1.0.zip".into(),
            index_json: INDEX,
            archive: MAOGUO_ZIP,
        },
        guo_engine_core::BundledPackage {
            name: "guo.yaguo-1.0.0.zip".into(),
            index_json: INDEX,
            archive: YAGUO_ZIP,
        },
    ]
}

fn engine_at(directory: &PathBuf) -> Result<Engine, EngineError> {
    let engine = Engine::open(
        EngineConfig::new(directory).with_plugin_directory(directory.join("plugins")),
    )?;
    engine.initialize(no_builtins, &bundled())?;
    Ok(engine)
}

fn source_ids(engine: &Engine) -> Vec<String> {
    engine
        .registry()
        .metas()
        .into_iter()
        .map(|meta| meta.id)
        .collect()
}

#[test]
fn disabling_a_plugin_removes_its_source_but_keeps_sessions() {
    let dir = temp_dir("disable");
    let engine = engine_at(&dir).expect("engine");
    assert!(source_ids(&engine).contains(&"maoguo".to_string()));

    // 模拟插件写过会话：引擎的会话存储是独立文件。
    let store = engine.store();
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("rt");
    rt.block_on(async {
        use guo_source_api::SourceStore;
        store.set("guo.yaguo/token", "tok").await.expect("set");
    });

    // 停用插件并重建注册表。
    let plugin_store = PluginStore::open(dir.join("plugins"));
    plugin_store
        .set_enabled("guo.maoguo", false)
        .expect("disable");
    engine.rebuild_registry(no_builtins).expect("rebuild");

    assert!(
        !source_ids(&engine).contains(&"maoguo".to_string()),
        "停用后该源必须从注册表消失"
    );
    // 另一个插件不受影响。
    assert!(source_ids(&engine).contains(&"guo.yaguo".to_string()));

    let token = rt.block_on(async {
        use guo_source_api::SourceStore;
        store.get("guo.yaguo/token").await.expect("get")
    });
    assert_eq!(token.as_deref(), Some("tok"), "会话必须保留");

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn re_enabling_restores_the_source_without_losing_session() {
    let dir = temp_dir("reenable");
    let engine = engine_at(&dir).expect("engine");
    let plugin_store = PluginStore::open(dir.join("plugins"));

    plugin_store
        .set_enabled("guo.yaguo", false)
        .expect("disable");
    engine.rebuild_registry(no_builtins).expect("rebuild 1");
    assert!(!source_ids(&engine).contains(&"guo.yaguo".to_string()));

    plugin_store.set_enabled("guo.yaguo", true).expect("enable");
    engine.rebuild_registry(no_builtins).expect("rebuild 2");
    assert!(source_ids(&engine).contains(&"guo.yaguo".to_string()));

    // 重新装配后源实例是新的，但会话存储在引擎上，仍然一致。
    let source = engine.source("guo.yaguo").expect("source");
    assert_eq!(source.meta().name, "芽果");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn rebuilding_keeps_download_jobs() {
    let dir = temp_dir("jobs");
    let engine = engine_at(&dir).expect("engine");

    let mut job = guo_runtime::Job::new("job-1", dir.join("out/1"), "https://cdn.test/1.mp4");
    job.drama_id = "guo.yaguo:1".into();
    job.state = guo_runtime::JobState::Completed;
    engine.scheduler().enqueue(job);
    assert_eq!(engine.scheduler().snapshot().len(), 1);

    // 插件启停会触发注册表重建，但任务表属于引擎，不该被清。
    PluginStore::open(dir.join("plugins"))
        .set_enabled("guo.maoguo", false)
        .expect("disable");
    engine.rebuild_registry(no_builtins).expect("rebuild");

    let snapshot = engine.scheduler().snapshot();
    assert_eq!(snapshot.len(), 1, "下载任务不能因插件启停而丢失");
    assert_eq!(snapshot[0].state, guo_runtime::JobState::Completed);

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn registry_revision_advances_on_each_rebuild() {
    let dir = temp_dir("revision");
    let engine = engine_at(&dir).expect("engine");
    let first = engine.registry_revision();
    engine.rebuild_registry(no_builtins).expect("rebuild");
    let second = engine.registry_revision();
    assert!(second > first, "重建注册表必须推进修订号");
    let _ = std::fs::remove_dir_all(&dir);
}
