use guo_engine::builtin_registry;

fn engine_env(source: String) -> guo_engine::SourceEnv {
    guo_engine::require().expect("engine").env(&source)
}

#[tokio::main]
async fn main() {
    let dir = std::env::temp_dir().join("guo-example");
    guo_engine::api::init_engine_with_directory(dir.to_string_lossy().to_string(), String::new())
        .expect("init");
    let registry = builtin_registry();
    let source = registry.get("maoguo").expect("maoguo");
    let env = engine_env("maoguo".into());
    let page = source.catalog(&env, 1, "0").await.expect("catalog");
    let drama = &page.items[0];
    let detail = source.detail(&env, &drama.source_id).await.expect("detail");
    let chapter = &detail.chapters[0];

    // 取原始播放列表文本
    let resp = env
        .transport
        .fetch(guo_engine::FetchRequest::get(&chapter.video_url))
        .await
        .expect("playlist");
    let text = String::from_utf8_lossy(&resp.body);
    println!("=== playlist head ===");
    for line in text.lines().take(12) {
        println!("{line}");
    }
}
