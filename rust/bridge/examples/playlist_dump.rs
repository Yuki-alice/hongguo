use guo_engine::builtin_registry;

#[tokio::main]
async fn main() {
    let registry = builtin_registry();
    let source = registry.get("maoguo").expect("maoguo");
    let env = guo_engine::api::debug_env("maoguo".into()).expect("env");
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
