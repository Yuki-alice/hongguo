//! 断点续传的端到端测试：用假传输层模拟服务器行为。

use async_trait::async_trait;
use guo_engine::{
    download_file, DownloadOutcome, FetchRequest, FetchResponse, FileState, LogSink, SourceEnv,
    SourceError, SourceStore, Transport,
};
use std::sync::{Arc, Mutex};

#[derive(Default)]
struct Scripted {
    /// 服务器持有的完整内容。
    body: Vec<u8>,
    /// 最近一次收到的 Range 头。
    last_range: Arc<Mutex<Option<String>>>,
    /// 忽略 Range，总是返回 200。
    ignore_range: bool,
    /// 返回 416 模拟数据变化。
    reject_range: bool,
    /// 服务器当前 ETag；为空则不下发。
    etag: Option<&'static str>,
    /// 记录收到的 If-Range。
    last_if_range: Arc<Mutex<Option<String>>>,
}

#[async_trait]
impl Transport for Scripted {
    async fn fetch(&self, request: FetchRequest) -> Result<FetchResponse, SourceError> {
        let range = request.headers.get("Range").cloned();
        *self.last_range.lock().expect("lock") = range.clone();
        if self.reject_range && range.is_some() {
            return Ok(FetchResponse::new(416, Vec::new(), request.url));
        }
        let start = match (range.as_deref(), self.ignore_range) {
            (Some(value), false) => value
                .trim_start_matches("bytes=")
                .trim_end_matches('-')
                .parse::<usize>()
                .unwrap_or(0),
            _ => 0,
        };
        let slice = &self.body[start.min(self.body.len())..];
        let status = if start > 0 && !self.ignore_range {
            206
        } else {
            200
        };
        let mut response = FetchResponse::new(status, slice.to_vec(), request.url);
        if let Some(etag) = self.etag {
            response.headers.insert("ETag".into(), etag.to_string());
        }
        *self.last_if_range.lock().expect("lock") = request.headers.get("If-Range").cloned();
        Ok(response)
    }
}

struct NoopStore;
#[async_trait]
impl SourceStore for NoopStore {
    async fn get(&self, _: &str) -> Result<Option<String>, SourceError> {
        Ok(None)
    }
    async fn set(&self, _: &str, _: &str) -> Result<(), SourceError> {
        Ok(())
    }
}

struct NoopLog;
impl LogSink for NoopLog {
    fn debug(&self, _: &str) {}
    fn warn(&self, _: &str) {}
}

fn env(transport: Arc<Scripted>) -> SourceEnv {
    SourceEnv {
        source_id: "fixture".into(),
        transport,
        store: Arc::new(NoopStore {}),
        scripts: None,
        log: Arc::new(NoopLog {}),
    }
}

fn temp_target(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("guo-dl-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("dir");
    dir.join("media")
}

#[tokio::test]
async fn downloads_from_scratch() {
    let target = temp_target("fresh");
    let transport = Arc::new(Scripted {
        body: b"0123456789".to_vec(),
        ..Default::default()
    });
    let outcome = download_file(
        &env(transport.clone()),
        "https://cdn.test/a.mp4",
        "https://site.test/",
        &target,
        |_, _| {},
    )
    .await
    .expect("download");

    assert_eq!(outcome, DownloadOutcome::Completed(10));
    let part = target.with_extension("part");
    assert_eq!(std::fs::read(&part).expect("read"), b"0123456789");
    assert!(transport.last_range.lock().expect("lock").is_none());
}

#[tokio::test]
async fn resumes_from_partial_file() {
    let target = temp_target("resume");
    let part = target.with_extension("part");
    std::fs::write(&part, b"01234").expect("seed");

    let transport = Arc::new(Scripted {
        body: b"0123456789".to_vec(),
        ..Default::default()
    });
    let outcome = download_file(
        &env(transport.clone()),
        "https://cdn.test/a.mp4",
        "https://site.test/",
        &target,
        |_, _| {},
    )
    .await
    .expect("download");

    assert_eq!(outcome, DownloadOutcome::Completed(10));
    assert_eq!(std::fs::read(&part).expect("read"), b"0123456789");
    assert_eq!(
        transport.last_range.lock().expect("lock").as_deref(),
        Some("bytes=5-")
    );
}

#[tokio::test]
async fn restart_when_server_rejects_range() {
    let target = temp_target("restart");
    let part = target.with_extension("part");
    std::fs::write(&part, b"stale").expect("seed");

    let transport = Arc::new(Scripted {
        body: b"0123456789".to_vec(),
        reject_range: true,
        ..Default::default()
    });
    let outcome = download_file(
        &env(transport),
        "https://cdn.test/a.mp4",
        "https://site.test/",
        &target,
        |_, _| {},
    )
    .await
    .expect("download");

    assert_eq!(outcome, DownloadOutcome::Restart);
}

#[tokio::test]
async fn restarts_when_server_ignores_range() {
    let target = temp_target("ignore");
    let part = target.with_extension("part");
    std::fs::write(&part, b"stale").expect("seed");

    let transport = Arc::new(Scripted {
        body: b"0123456789".to_vec(),
        ignore_range: true,
        ..Default::default()
    });
    let outcome = download_file(
        &env(transport),
        "https://cdn.test/a.mp4",
        "https://site.test/",
        &target,
        |_, _| {},
    )
    .await
    .expect("download");

    // 服务器忽略 Range 时必须整段重写，否则文件会被污染。
    assert_eq!(outcome, DownloadOutcome::Completed(10));
    assert_eq!(std::fs::read(&part).expect("read"), b"0123456789");
}

#[tokio::test]
async fn captures_response_validator_for_future_range_requests() {
    let target = temp_target("validator");
    let transport = Arc::new(Scripted {
        body: b"abcdef".to_vec(),
        etag: Some("\"v1\""),
        ..Default::default()
    });
    download_file(
        &env(transport.clone()),
        "https://cdn.test/a.mp4",
        "https://site.test/",
        &target,
        |_, _| {},
    )
    .await
    .expect("download");

    let raw = std::fs::read(target.with_extension("json")).expect("meta");
    let state: FileState = serde_json::from_slice(&raw).expect("decode");
    assert_eq!(
        state.validator, "\"v1\"",
        "必须记录 ETag 供下次 If-Range 使用"
    );

    // 第二次请求应该带上 If-Range。
    download_file(
        &env(transport.clone()),
        "https://cdn.test/a.mp4",
        "https://site.test/",
        &target,
        |_, _| {},
    )
    .await
    .expect("resume");
    assert_eq!(
        transport.last_if_range.lock().expect("lock").as_deref(),
        Some("\"v1\"")
    );
}

#[tokio::test]
async fn writes_metadata_for_future_resume() {
    let target = temp_target("meta");
    let transport = Arc::new(Scripted {
        body: b"abcdef".to_vec(),
        ..Default::default()
    });
    download_file(
        &env(transport),
        "https://cdn.test/a.mp4",
        "https://site.test/",
        &target,
        |_, _| {},
    )
    .await
    .expect("download");

    let meta = target.with_extension("json");
    let raw = std::fs::read(&meta).expect("meta exists");
    let state: FileState = serde_json::from_slice(&raw).expect("decode");
    assert_eq!(state.url, "https://cdn.test/a.mp4");
    assert_eq!(state.total, 6);
}

#[tokio::test]
async fn rejects_invalid_address() {
    let target = temp_target("invalid");
    let err = download_file(
        &env(Arc::new(Scripted::default())),
        "file:///etc/passwd",
        "",
        &target,
        |_, _| {},
    )
    .await
    .expect_err("must fail");
    assert!(err.to_string().contains("无效"), "{err}");
}

#[tokio::test]
async fn reports_progress() {
    let target = temp_target("progress");
    let seen = Arc::new(Mutex::new(Vec::new()));
    let recorder = Arc::clone(&seen);
    let transport = Arc::new(Scripted {
        body: b"0123456789".to_vec(),
        ..Default::default()
    });
    download_file(
        &env(transport),
        "https://cdn.test/a.mp4",
        "https://site.test/",
        &target,
        move |received, total| {
            recorder.lock().expect("lock").push((received, total));
        },
    )
    .await
    .expect("download");

    let records = seen.lock().expect("lock");
    assert_eq!(records.len(), 1);
    assert_eq!(records[0], (10, 10));
}

#[tokio::test]
async fn scheduler_limits_concurrency() {
    use guo_engine::{Job, Scheduler};
    use std::sync::atomic::{AtomicUsize, Ordering};

    // 记录同时进行中的请求数。
    struct Counting {
        active: Arc<AtomicUsize>,
        peak: Arc<AtomicUsize>,
    }

    #[async_trait]
    impl Transport for Counting {
        async fn fetch(&self, request: FetchRequest) -> Result<FetchResponse, SourceError> {
            let current = self.active.fetch_add(1, Ordering::SeqCst) + 1;
            self.peak.fetch_max(current, Ordering::SeqCst);
            tokio::time::sleep(std::time::Duration::from_millis(60)).await;
            self.active.fetch_sub(1, Ordering::SeqCst);
            Ok(FetchResponse::new(200, b"0123456789".to_vec(), request.url))
        }
    }

    let active = Arc::new(AtomicUsize::new(0));
    let peak = Arc::new(AtomicUsize::new(0));
    let transport = Arc::new(Counting {
        active: Arc::clone(&active),
        peak: Arc::clone(&peak),
    });
    let env = SourceEnv {
        source_id: "fixture".into(),
        transport,
        store: Arc::new(NoopStore {}),
        scripts: None,
        log: Arc::new(NoopLog {}),
    };

    let dir = std::env::temp_dir().join(format!("guo-dl-conc-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("dir");

    let scheduler = Arc::new(Scheduler::new(2));
    for index in 0..6 {
        scheduler.enqueue(Job::new(
            format!("job{index}"),
            dir.join(format!("f{index}")),
            format!("https://cdn.test/{index}.mp4"),
        ));
    }

    let mut handles = Vec::new();
    for index in 0..6 {
        let scheduler = Arc::clone(&scheduler);
        let env = env.clone();
        handles.push(tokio::spawn(async move {
            scheduler.run(&env, &format!("job{index}")).await
        }));
    }
    for handle in handles {
        handle.await.expect("join").expect("download");
    }

    let observed = peak.load(Ordering::SeqCst);
    assert!(observed <= 2, "并发超过上限：{observed}");
    let (_, _, completed, failed) = scheduler.counts();
    assert_eq!((completed, failed), (6, 0));
}

#[tokio::test]
async fn scheduler_marks_failure_and_keeps_state() {
    use guo_engine::{Job, Scheduler};

    struct Failing;

    #[async_trait]
    impl Transport for Failing {
        async fn fetch(&self, request: FetchRequest) -> Result<FetchResponse, SourceError> {
            Ok(FetchResponse::new(404, Vec::new(), request.url))
        }
    }

    let env = SourceEnv {
        source_id: "fixture".into(),
        transport: Arc::new(Failing),
        store: Arc::new(NoopStore {}),
        scripts: None,
        log: Arc::new(NoopLog {}),
    };
    let dir = std::env::temp_dir().join(format!("guo-dl-fail-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("dir");

    let scheduler = Scheduler::new(1);
    scheduler.enqueue(Job::new("bad", dir.join("x"), "https://cdn.test/x.mp4"));
    let err = scheduler.run(&env, "bad").await.expect_err("must fail");
    assert!(err.to_string().contains("404"), "{err}");

    let job = scheduler.get("bad").expect("job");
    assert_eq!(job.state, guo_engine::JobState::Failed);
    assert!(job.error.contains("404"));
}

/// HLS 分片断点续传：已完成的字节在重跑时不应重复下载。
#[tokio::test]
async fn hls_resumes_from_recorded_segment() {
    use guo_engine::download_hls;

    #[derive(Default)]
    struct Segments {
        hits: Arc<Mutex<Vec<String>>>,
    }

    #[async_trait]
    impl Transport for Segments {
        async fn fetch(&self, request: FetchRequest) -> Result<FetchResponse, SourceError> {
            self.hits.lock().expect("lock").push(request.url.clone());
            let name = request.url.rsplit('/').next().unwrap_or("?").to_string();
            Ok(FetchResponse::new(200, name.into_bytes(), request.url))
        }
    }

    let dir = std::env::temp_dir().join(format!("guo-dl-hls-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("dir");
    let target = dir.join("episode");

    let transport = Arc::new(Segments::default());
    let transport_dyn: Arc<dyn Transport> = transport.clone();
    let env = SourceEnv {
        source_id: "fixture".into(),
        transport: transport_dyn,
        store: Arc::new(NoopStore {}),
        scripts: None,
        log: Arc::new(NoopLog {}),
    };
    let segments = vec![
        "https://cdn.test/seg0.ts".to_string(),
        "https://cdn.test/seg1.ts".to_string(),
        "https://cdn.test/seg2.ts".to_string(),
    ];

    // 第一轮：只下第一个分片就中断（模拟进程被杀）。
    {
        let part = target.with_extension("part");
        std::fs::write(&part, b"seg0.ts").expect("seed part");
        let meta = FileState {
            url: guo_engine::playlist_signature(&segments),
            validator: String::new(),
            total: 3,
            completed_segments: 1,
        };
        std::fs::write(
            target.with_extension("json"),
            serde_json::to_vec(&meta).expect("encode"),
        )
        .expect("seed meta");
    }
    let outcome = download_hls(
        &env,
        &segments,
        "https://site.test/",
        &target,
        None,
        |_, _| {},
    )
    .await
    .expect("resume");
    match outcome {
        DownloadOutcome::Completed(bytes) => assert!(bytes > 0),
        other => panic!("unexpected outcome: {other:?}"),
    }

    let hits = transport.hits.lock().expect("lock").clone();
    assert!(
        !hits.iter().any(|url| url.ends_with("seg0.ts")),
        "已完成的分片不应重复下载：{hits:?}"
    );
    assert!(hits.iter().any(|url| url.ends_with("seg1.ts")), "{hits:?}");
    assert!(hits.iter().any(|url| url.ends_with("seg2.ts")), "{hits:?}");
}

/// 播放列表变化时不得续传旧字节。
#[tokio::test]
async fn hls_restarts_when_playlist_changes() {
    use guo_engine::download_hls;

    struct Fixed;

    #[async_trait]
    impl Transport for Fixed {
        async fn fetch(&self, request: FetchRequest) -> Result<FetchResponse, SourceError> {
            Ok(FetchResponse::new(200, b"new".to_vec(), request.url))
        }
    }

    let dir = std::env::temp_dir().join(format!("guo-dl-hls-change-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("dir");
    let target = dir.join("episode");

    // 旧播放列表留下的 .part 与元数据。
    std::fs::write(target.with_extension("part"), b"stale-bytes").expect("seed");
    let stale = FileState {
        url: "different-signature".into(),
        validator: String::new(),
        total: 1,
        completed_segments: 1,
    };
    std::fs::write(
        target.with_extension("json"),
        serde_json::to_vec(&stale).expect("encode"),
    )
    .expect("seed meta");

    let env = SourceEnv {
        source_id: "fixture".into(),
        transport: Arc::new(Fixed),
        store: Arc::new(NoopStore {}),
        scripts: None,
        log: Arc::new(NoopLog {}),
    };
    let segments = vec!["https://cdn.test/only.ts".to_string()];
    download_hls(
        &env,
        &segments,
        "https://site.test/",
        &target,
        None,
        |_, _| {},
    )
    .await
    .expect("download");

    let bytes = std::fs::read(target.with_extension("part")).expect("part");
    assert_eq!(bytes, b"new", "列表变化后必须丢弃旧字节");
}
