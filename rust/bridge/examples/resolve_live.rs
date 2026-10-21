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
    for id in ["wuguo", "huaguo", "maoguo"] {
        let Some(source) = registry.get(id) else {
            continue;
        };
        println!("=== {id} ===");
        let env = engine_env(id.to_string());
        let category = match id {
            "wuguo" => "1",
            "huaguo" => "27",
            _ => "0",
        };
        match source.catalog(&env, 1, category).await {
            Ok(page) if !page.items.is_empty() => {
                let drama = &page.items[0];
                match source.detail(&env, &drama.source_id).await {
                    Ok(detail) if !detail.chapters.is_empty() => {
                        let chapter = &detail.chapters[0];
                        println!(
                            "  drama: {} | chapters={}",
                            drama.title,
                            detail.chapters.len()
                        );
                        match source.resolve(&env, drama, chapter).await {
                            Ok(media) => {
                                let short: String = media.url.chars().take(70).collect();
                                println!("  media: {short}");
                                println!(
                                    "  playlist segments: {:?}",
                                    media.playlist.as_ref().map(|p| p.len())
                                );
                            }
                            Err(e) => println!("  resolve error: {e}"),
                        }
                    }
                    Ok(_) => println!("  no chapters"),
                    Err(e) => println!("  detail error: {e}"),
                }
            }
            Ok(_) => println!("  empty catalog"),
            Err(e) => println!("  catalog error: {e}"),
        }
    }
}
