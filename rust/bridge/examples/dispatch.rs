#[tokio::main]
async fn main() {
    let dir = std::env::temp_dir().join("guo-dispatch");
    guo_engine::api::init_engine_with_directory(
        dir.to_string_lossy().to_string(),
        String::new(),
        Vec::new(),
    )
    .expect("init");

    println!("=== 站源清单 ===");
    for s in guo_engine::api::source_catalog().expect("catalog") {
        println!("  {} | {} | {:?}", s.id, s.name, s.capabilities);
    }

    println!("\n=== 规则源：伍果 目录 ===");
    match guo_engine::api::fetch_catalog(
        "wuguo".into(),
        1,
        "1".into(),
        "dispatch-1".into(),
        "catalog-wuguo".into(),
    )
    .await
    {
        Ok(page) => {
            println!("items: {}", page.items.len());
            for d in page.items.iter().take(3) {
                println!("  {} | {} | {}", d.source_id, d.title, d.category);
            }
        }
        Err(e) => println!("ERROR: {e}"),
    }

    println!("\n=== 代码插件：猫果 目录 ===");
    match guo_engine::api::fetch_catalog(
        "maoguo".into(),
        1,
        "0".into(),
        "dispatch-2".into(),
        "catalog-maoguo".into(),
    )
    .await
    {
        Ok(page) => {
            println!("items: {}", page.items.len());
            for d in page.items.iter().take(3) {
                println!("  {} | {} | eps={}", d.source_id, d.title, d.episodes);
            }
        }
        Err(e) => println!("ERROR: {e}"),
    }

    println!("\n=== 未知站源 ===");
    match guo_engine::api::fetch_catalog(
        "nope".into(),
        1,
        "".into(),
        "dispatch-3".into(),
        "catalog-nope".into(),
    )
    .await
    {
        Ok(_) => println!("unexpected ok"),
        Err(e) => println!("正确报错: {e}"),
    }
}
