//! 缓存读写验证：跑一次真实目录，再读缓存。
//!
//! 需要引擎单例，因此先初始化到临时目录。
//! `cargo run -p guo_engine --example cache_verify`

use std::time::Instant;

#[tokio::main]
async fn main() {
    let dir = std::env::temp_dir().join("guo-cache-verify");
    let _ = std::fs::remove_dir_all(&dir);
    println!("cache dir: {}", dir.display());
    guo_engine::api::init_engine_with_directory(
        dir.to_string_lossy().to_string(),
        String::new(),
        Vec::new(),
    )
    .expect("init");

    println!("\n=== 首次读取（应联网）===");
    let start = Instant::now();
    let first = guo_engine::api::fetch_catalog(
        "wuguo".into(),
        1,
        "1".into(),
        "cache-verify-1".into(),
        "catalog-wuguo".into(),
    )
    .await
    .expect("first");
    println!(
        "  items={} elapsed={:?}",
        first.items.len(),
        start.elapsed()
    );

    println!("\n=== 缓存读取 ===");
    let start = Instant::now();
    let cached = guo_engine::api::cached_catalog("wuguo".into(), "1".into()).expect("cached");
    println!(
        "  items={} page={} hasMore={} elapsed={:?}",
        cached.items.len(),
        cached.page,
        cached.has_more,
        start.elapsed()
    );
    println!(
        "  fresh={}",
        guo_engine::api::catalog_is_fresh("wuguo".into(), "1".into()).expect("fresh")
    );

    println!("\n=== 磁盘文件 ===");
    let path = dir.join("catalogs.json");
    if let Ok(info) = std::fs::metadata(&path) {
        println!("  {} bytes", info.len());
    }

    println!("\n=== 分类键汇总到基础源 ===");
    let base = guo_engine::api::cached_catalog("wuguo".into(), String::new()).expect("base");
    println!("  base items={}", base.items.len());
}
