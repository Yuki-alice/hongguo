//! 引擎下载 worker 的行为测试：登记即执行，不调用 `run_download`。
//!
//! 这条用例锁住一个真实回归：桥接层的 `enqueue_download` 已经
//! `pump_downloads`，但 Dart 侧仍在手动 `runDownload`，同一任务会被
//! 两个执行入口重复驱动（从断点续传重入、字节跳变）。
//! 这里只登记、不手动执行，断言 worker 自己把队列跑完。

use std::time::Duration;

use guo_engine::JobState;
use guo_engine_core::pump_downloads;

const BODY: usize = 64 * 1024;

/// 极简 HTTP 服务：HEAD 报长度，GET 返回定长内容。
async fn serve() -> (u16, tokio::task::JoinHandle<()>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind");
    let port = listener.local_addr().expect("addr").port();
    let server = tokio::spawn(async move {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        loop {
            let Ok((mut socket, _)) = listener.accept().await else {
                break;
            };
            let mut buffer = [0u8; 4096];
            let read = socket.read(&mut buffer).await.unwrap_or(0);
            let head = String::from_utf8_lossy(&buffer[..read]).to_string();
            let header = format!("HTTP/1.1 200 OK\r\nContent-Length: {BODY}\r\n\r\n");
            let _ = socket.write_all(header.as_bytes()).await;
            if !head.contains("HEAD") {
                let _ = socket.write_all(&vec![0x33u8; BODY]).await;
            }
        }
    });
    (port, server)
}

#[tokio::test]
async fn registered_jobs_complete_without_manual_run() {
    let (port, server) = serve().await;
    let directory = std::env::temp_dir().join(format!(
        "guo-worker-test-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|value| value.as_nanos())
            .unwrap_or(0)
    ));
    let _ = std::fs::remove_dir_all(&directory);

    guo_engine::api::init_engine();
    let init = guo_engine::api::init_engine_with_directory(
        directory.to_string_lossy().to_string(),
        String::new(),
        Vec::new(),
    )
    .expect("初始化引擎");
    assert!(init.source_count > 0, "应有内置站源");
    let engine = guo_engine::require().expect("引擎单例");

    for index in 0..2 {
        guo_engine::api::enqueue_download(guo_engine::api::DownloadRequest {
            id: format!("probe-{index}"),
            url: format!("http://127.0.0.1:{port}/file.mp4"),
            target: directory
                .join(format!("probe-{index}.mp4"))
                .display()
                .to_string(),
            referer: String::new(),
            title: format!("任务 {index}"),
            drama_id: "probe".into(),
            episode_id: format!("{index}"),
            drama_title: "探测".into(),
            episode_index: index,
            cover_url: String::new(),
            segments: Vec::new(),
            key_uri: String::new(),
            key_iv: String::new(),
        })
        .expect("登记任务");
    }
    // 登记路径已 pump；这里再调一次模拟 resume 补员，必须幂等。
    pump_downloads(&engine);

    let mut states = Vec::new();
    for _ in 0..100 {
        tokio::time::sleep(Duration::from_millis(100)).await;
        let jobs = engine.scheduler().snapshot();
        states = jobs.iter().map(|job| job.state).collect();
        if states.len() == 2 && states.iter().all(|state| *state == JobState::Completed) {
            break;
        }
    }
    assert_eq!(states.len(), 2, "两个任务都应留在索引里");
    assert!(
        states.iter().all(|state| *state == JobState::Completed),
        "worker 未把任务跑完：{states:?}"
    );

    // 不手动 run_download：文件必须由 worker 产出且大小正确。
    for index in 0..2 {
        let path = directory.join(format!("probe-{index}.mp4"));
        assert_eq!(
            std::fs::metadata(&path).expect("下载产物").len() as usize,
            BODY
        );
    }

    server.abort();
    let _ = std::fs::remove_dir_all(&directory);
}
