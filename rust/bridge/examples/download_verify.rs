use guo_engine::builtin_registry;

#[tokio::main]
async fn main() {
    let dir = std::env::temp_dir().join("guo-download-verify");
    guo_engine::api::init_engine_with_directory(
        dir.to_string_lossy().to_string(),
        String::new(),
        Vec::new(),
    )
    .expect("init");

    let registry = builtin_registry();
    let Some(source) = registry.get("maoguo") else {
        return;
    };
    let env = guo_engine::require().expect("engine").env("maoguo");

    let page = source.catalog(&env, 1, "0").await.expect("catalog");
    let drama = &page.items[0];
    let detail = source.detail(&env, &drama.source_id).await.expect("detail");
    let chapter = &detail.chapters[0];
    let media = source.resolve(&env, drama, chapter).await.expect("resolve");
    println!("media: {}", media.url.chars().take(60).collect::<String>());

    let target = std::env::temp_dir().join("guo-dl-verify/ep1");
    let _ = std::fs::remove_dir_all(target.parent().unwrap());
    std::fs::create_dir_all(target.parent().unwrap()).expect("dir");

    let segments = media.playlist.clone().unwrap_or_default();
    println!("  segments: {}", segments.len());
    println!("  encrypted: {}", !media.key_uri.is_empty());
    let outcome = if segments.is_empty() {
        guo_engine::download_file(&env, &media.url, &media.referer, &target, |r, t| {
            print!("\r  progress {r}/{t}");
        })
        .await
        .expect("download")
    } else {
        let key_bytes = if media.key_uri.is_empty() {
            None
        } else {
            let resp = env
                .transport
                .fetch(guo_engine::FetchRequest::get(&media.key_uri))
                .await
                .expect("key");
            println!("  key: status={} len={}", resp.status, resp.body.len());
            Some(resp.body)
        };
        let material = key_bytes.as_ref().map(|bytes| guo_engine::HlsKey {
            bytes,
            iv_hex: if media.key_iv.is_empty() {
                None
            } else {
                Some(media.key_iv.as_str())
            },
        });
        guo_engine::download_hls(
            &env,
            &segments,
            &media.referer,
            &target,
            material,
            |r, t| {
                print!("\r  segment {r}/{t}");
            },
        )
        .await
        .expect("hls download")
    };
    println!();

    match outcome {
        guo_engine::DownloadOutcome::Completed(bytes) => {
            let part = target.with_extension("part");
            let size = std::fs::metadata(&part).map(|m| m.len()).unwrap_or(0);
            let head = std::fs::read(&part)
                .map(|b| b[..8.min(b.len())].to_vec())
                .unwrap_or_default();
            println!("  completed: {bytes} bytes, file={size}");
            println!("  magic: {:02x?}", head);
            // HLS 分片拼接后是 MPEG-TS（0x47 同步字节），不是 MP4。
            let is_ts = head.first() == Some(&0x47);
            let is_mp4 = head.len() >= 8 && &head[4..8] == b"ftyp";
            println!(
                "  container: {}",
                if is_ts {
                    "MPEG-TS"
                } else if is_mp4 {
                    "MP4"
                } else {
                    "unknown"
                }
            );
        }
        guo_engine::DownloadOutcome::Restart => println!("  restart required"),
        guo_engine::DownloadOutcome::Paused => println!("  paused"),
    }
}
