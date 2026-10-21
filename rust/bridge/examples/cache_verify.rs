use std::time::Instant;

#[tokio::main]
async fn main() {
    let dir = std::env::temp_dir().join("guo-cache-verify");
    let _ = std::fs::remove_dir_all(&dir);
    println!("cache dir: {}", dir.display());
    guo_engine::api::set_cache_directory(dir.to_string_lossy().to_string());

    println!("\n=== 首次读取（应联网）===");
    let start = Instant::now();
    let first = guo_engine::api::fetch_catalog("wuguo".into(), 1, "1".into())
        .await
        .expect("first");
    println!(
        "  items={} elapsed={:?}",
        first.items.len(),
        start.elapsed()
    );

    println!("\n=== 缓存读取 ===");
    let start = Instant::now();
    let cached = guo_engine::api::cached_catalog("wuguo".into(), "1".into());
    println!(
        "  items={} page={} hasMore={} elapsed={:?}",
        cached.items.len(),
        cached.page,
        cached.has_more,
        start.elapsed()
    );
    println!(
        "  fresh={}",
        guo_engine::api::catalog_is_fresh("wuguo".into(), "1".into())
    );

    println!("\n=== 磁盘文件 ===");
    let path = dir.join("catalogs.json");
    if let Ok(info) = std::fs::metadata(&path) {
        println!("  {} bytes", info.len());
    }

    println!("\n=== 分类键汇总到基础源 ===");
    let base = guo_engine::api::cached_catalog("wuguo".into(), String::new());
    println!("  base items={}", base.items.len());
}
