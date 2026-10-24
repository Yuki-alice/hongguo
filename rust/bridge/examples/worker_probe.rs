//! 临时验证：登记任务后引擎 worker 自动执行、resume 自动恢复。

use guo_engine::pump_downloads;

struct S; struct L;
#[async_trait::async_trait]
impl guo_engine::SourceStore for S {
    async fn get(&self,_:&str)->Result<Option<String>,guo_engine::SourceError>{Ok(None)}
    async fn set(&self,_:&str,_:&str)->Result<(),guo_engine::SourceError>{Ok(())}
}
impl guo_engine::LogSink for L { fn debug(&self,_:&str){} fn warn(&self,_:&str){} }

#[tokio::main]
async fn main() {
    // 1) 起一个本地 HTTP 服务器供下载
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = tokio::spawn(async move {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        loop {
            let Ok((mut socket, _)) = listener.accept().await else { break };
            let mut buf = [0u8; 4096];
            let n = socket.read(&mut buf).await.unwrap_or(0);
            let head = String::from_utf8_lossy(&buf[..n]).to_string();
            if head.contains("HEAD") {
                let _ = socket.write_all(format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n", 64*1024).as_bytes()).await;
                continue;
            }
            let _ = socket.write_all(format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n", 64*1024).as_bytes()).await;
            let _ = socket.write_all(&vec![0x33u8; 64*1024]).await;
        }
    });

    let dir = std::env::temp_dir().join("guo-worker-probe");
    let _ = std::fs::remove_dir_all(&dir);
    guo_engine::api::init_engine();
    let init = guo_engine::api::init_engine_with_directory(
        dir.to_string_lossy().to_string(), String::new(), Vec::new(),
    ).expect("init");
    println!("engine ready, {} sources", init.source_count);
    let engine = guo_engine::require().unwrap();

    // 2) 登记两个任务（不调 run_download！worker 应自动消费）
    for index in 0..2 {
        let target = dir.join(format!("probe-{index}.mp4"));
        guo_engine::api::enqueue_download(guo_engine::api::DownloadRequest {
            id: format!("probe-{index}"),
            url: format!("http://127.0.0.1:{port}/file.mp4"),
            target: target.display().to_string(),
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
        }).expect("enqueue");
    }
    pump_downloads(&engine);

    // 3) 轮询快照，等两个任务完成
    for round in 0..50 {
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        let jobs = engine.scheduler().snapshot();
        let states: Vec<String> = jobs.iter().map(|j| j.state.clone()).collect();
        println!("round {round}: {states:?}");
        if jobs.iter().all(|j| j.state == "completed") { break; }
    }
    let jobs = engine.scheduler().snapshot();
    assert!(jobs.iter().all(|j| j.state == "completed"), "worker 未跑完: {:?}", jobs.iter().map(|j| j.state.clone()).collect::<Vec<_>>());
    println!("auto-run: OK");

    server.abort();
}
