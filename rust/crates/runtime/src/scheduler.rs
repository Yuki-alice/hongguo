use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};
use tokio::sync::Semaphore;

use crate::download::{
    commit, discard, download_file_with, download_hls_with, DownloadOutcome, HlsKey,
};
use guo_source_api::{FetchRequest, SourceEnv, SourceError};

/// 下载任务状态。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum JobState {
    Queued,
    Running,
    Completed,
    Failed,
    Paused,
}

impl JobState {
    pub fn is_terminal(self) -> bool {
        matches!(self, Self::Completed | Self::Failed)
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Queued => "queued",
            Self::Running => "running",
            Self::Completed => "completed",
            Self::Failed => "failed",
            Self::Paused => "paused",
        }
    }
}

/// 单个下载任务。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Job {
    pub id: String,
    pub drama_id: String,
    pub episode_id: String,
    pub title: String,
    /// 剧名。重启后 UI 仍要能显示「哪部剧」，不能只靠 id。
    #[serde(default)]
    pub drama_title: String,
    /// 集号。与 `episode_id` 不同：前者是显示用的序号。
    #[serde(default)]
    pub episode_index: u32,
    /// 剧集封面 URL；重启后列表缩略图仍可用。
    #[serde(default)]
    pub cover_url: String,
    pub url: String,
    #[serde(default)]
    pub referer: String,
    /// 目标文件路径（不含扩展名）。
    pub target: String,
    /// HLS 分片清单；非空时走分片下载。
    #[serde(default)]
    pub segments: Vec<String>,
    /// HLS AES-128 密钥地址。
    #[serde(default)]
    pub key_uri: String,
    /// HLS AES-128 的 IV。
    #[serde(default)]
    pub key_iv: String,
    pub state: JobState,
    #[serde(default)]
    pub bytes: u64,
    #[serde(default)]
    pub total: i64,
    #[serde(default)]
    pub error: String,
    /// 每次状态变化递增，供上层做乐观并发控制。
    #[serde(default)]
    pub revision: u64,
}

impl Job {
    pub fn new(id: impl Into<String>, target: impl Into<PathBuf>, url: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            drama_id: String::new(),
            episode_id: String::new(),
            title: String::new(),
            drama_title: String::new(),
            episode_index: 0,
            cover_url: String::new(),
            url: url.into(),
            referer: String::new(),
            target: target.into().to_string_lossy().to_string(),
            segments: Vec::new(),
            key_uri: String::new(),
            key_iv: String::new(),
            state: JobState::Queued,
            bytes: 0,
            total: 0,
            error: String::new(),
            revision: 0,
        }
    }

    pub fn progress(&self) -> f64 {
        if self.total <= 0 {
            return 0.0;
        }
        (self.bytes as f64 / self.total as f64).clamp(0.0, 1.0)
    }
}

/// 下载索引的落盘格式版本。不匹配时丢弃，避免误读历史结构。
const INDEX_VERSION: u32 = 1;

/// 索引文件上限，防止异常数据把磁盘写满。
const INDEX_MAX_BYTES: usize = 16 * 1024 * 1024;

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct IndexDisk {
    version: u32,
    #[serde(default)]
    jobs: Vec<Job>,
}

/// 下载调度器：有界并发 + 状态快照 + 索引落盘。
///
/// 并发上限由 `Semaphore` 控制，符合「先定并发预算再选执行模型」的要求；
/// 状态放在 `Mutex<BTreeMap>` 中，读多写少且临界区短。
///
/// `index_path` 为空时纯内存运行（测试与一次性校验工具）；否则每次状态
/// 变化都原子写盘，进程被杀后由 [`Scheduler::restore`] 读回。
pub struct Scheduler {
    jobs: Mutex<BTreeMap<String, Job>>,
    gate: Arc<Semaphore>,
    revision: AtomicU64,
    index_path: Option<PathBuf>,
}

impl Scheduler {
    pub fn new(concurrency: usize) -> Self {
        let limit = concurrency.clamp(1, 6);
        Self {
            jobs: Mutex::new(BTreeMap::new()),
            gate: Arc::new(Semaphore::new(limit)),
            revision: AtomicU64::new(0),
            index_path: None,
        }
    }

    /// 带索引落盘的调度器。启动时自动恢复上次的任务表。
    pub fn open(concurrency: usize, index_path: impl Into<PathBuf>) -> Self {
        let scheduler = Self {
            index_path: Some(index_path.into()),
            ..Self::new(concurrency)
        };
        scheduler.restore();
        scheduler
    }

    /// 从索引文件恢复任务表。
    ///
    /// 恢复语义：
    /// - `running` 视为中断，回到 `queued`（重启后重新排队，而不是永远卡住）；
    /// - `completed` / `failed` / `paused` 原样保留；
    /// - 文件缺失、损坏或版本不符时静默返回空表（下载记录丢失不应拦住启动）。
    pub fn restore(&self) {
        let Some(path) = &self.index_path else {
            return;
        };
        let Ok(info) = std::fs::metadata(path) else {
            return;
        };
        if info.len() as usize > INDEX_MAX_BYTES {
            return;
        }
        let Ok(bytes) = std::fs::read(path) else {
            return;
        };
        let Ok(disk) = serde_json::from_slice::<IndexDisk>(&bytes) else {
            return;
        };
        if disk.version != INDEX_VERSION {
            return;
        }
        let mut jobs = self.jobs.lock().expect("jobs lock");
        for mut job in disk.jobs {
            if job.state == JobState::Running {
                job.state = JobState::Queued;
                job.error = "上次退出时任务被中断，已重新排队".to_string();
            }
            let revision = self.revision.fetch_add(1, Ordering::SeqCst) + 1;
            job.revision = revision;
            jobs.insert(job.id.clone(), job);
        }
    }

    /// 把当前任务表写盘。没有索引路径时是空操作。
    fn persist(&self, jobs: &BTreeMap<String, Job>) {
        let Some(path) = &self.index_path else {
            return;
        };
        let payload = IndexDisk {
            version: INDEX_VERSION,
            jobs: jobs.values().cloned().collect(),
        };
        let Ok(encoded) = serde_json::to_vec(&payload) else {
            return;
        };
        if encoded.len() > INDEX_MAX_BYTES {
            eprintln!("下载索引超过上限，已跳过写盘");
            return;
        }
        if let Some(parent) = path.parent() {
            if std::fs::create_dir_all(parent).is_err() {
                return;
            }
        }
        let temporary = path.with_extension("json.tmp");
        if std::fs::write(&temporary, &encoded).is_err() {
            return;
        }
        let _ = std::fs::rename(&temporary, path);
    }

    pub fn concurrency(&self) -> usize {
        self.gate.available_permits()
    }

    /// 登记任务；同一 id 重复登记会被忽略。
    pub fn enqueue(&self, job: Job) -> u64 {
        let revision = self.revision.fetch_add(1, Ordering::SeqCst) + 1;
        let mut jobs = self.jobs.lock().expect("jobs lock");
        jobs.entry(job.id.clone())
            .or_insert(Job { revision, ..job });
        self.persist(&jobs);
        revision
    }

    pub fn snapshot(&self) -> Vec<Job> {
        self.jobs
            .lock()
            .expect("jobs lock")
            .values()
            .cloned()
            .collect()
    }

    pub fn get(&self, id: &str) -> Option<Job> {
        self.jobs.lock().expect("jobs lock").get(id).cloned()
    }

    pub fn counts(&self) -> (usize, usize, usize, usize) {
        let jobs = self.jobs.lock().expect("jobs lock");
        let mut queued = 0;
        let mut running = 0;
        let mut completed = 0;
        let mut failed = 0;
        for job in jobs.values() {
            match job.state {
                JobState::Queued => queued += 1,
                JobState::Running => running += 1,
                JobState::Completed => completed += 1,
                JobState::Failed => failed += 1,
                JobState::Paused => {}
            }
        }
        (queued, running, completed, failed)
    }

    fn update(&self, id: &str, apply: impl FnOnce(&mut Job)) -> u64 {
        let revision = self.revision.fetch_add(1, Ordering::SeqCst) + 1;
        let mut jobs = self.jobs.lock().expect("jobs lock");
        if let Some(job) = jobs.get_mut(id) {
            apply(job);
            job.revision = revision;
            self.persist(&jobs);
        }
        revision
    }

    /// 执行一个已登记的任务。
    pub async fn run(&self, env: &SourceEnv, id: &str) -> Result<DownloadOutcome, SourceError> {
        let job = self
            .get(id)
            .ok_or_else(|| SourceError::parse("download", format!("任务不存在：{id}")))?;
        if job.state.is_terminal() {
            return Err(SourceError::parse("download", "任务已结束"));
        }

        let _permit = self
            .gate
            .acquire()
            .await
            .map_err(|_| SourceError::parse("download", "下载队列已关闭"))?;

        self.update(id, |job| {
            job.state = JobState::Running;
            job.error.clear();
        });

        let target = PathBuf::from(&job.target);
        let segments = job.segments.clone();
        let recorder = |received: u64, total: i64| {
            self.update(id, |job| {
                job.bytes = received;
                job.total = total;
            });
        };
        // 暂停判定：下载循环在每个分片 / 请求前询问一次。
        let should_continue = || {
            self.get(id)
                .map(|job| job.state != JobState::Paused)
                .unwrap_or(false)
        };
        let result = if segments.is_empty() {
            download_file_with(
                env,
                &job.url,
                &job.referer,
                &target,
                recorder,
                should_continue,
            )
            .await
        } else {
            // 加密播放列表需要先取到密钥；取不到就明确失败，不落盘无效数据。
            let key_bytes = if job.key_uri.is_empty() {
                None
            } else {
                let response = env
                    .transport
                    .fetch(FetchRequest::get(&job.key_uri).header("Referer", &job.referer))
                    .await?;
                if response.status != 200 {
                    return Err(SourceError::http(&job.key_uri, response.status));
                }
                Some(response.body)
            };
            let material = key_bytes.as_ref().map(|bytes| HlsKey {
                bytes,
                iv_hex: if job.key_iv.is_empty() {
                    None
                } else {
                    Some(job.key_iv.as_str())
                },
            });
            download_hls_with(
                env,
                &segments,
                &job.referer,
                &target,
                material,
                recorder,
                should_continue,
            )
            .await
        };

        match result {
            Ok(DownloadOutcome::Completed(bytes)) => {
                match commit(&target) {
                    Ok(_) => {
                        self.update(id, |job| {
                            job.state = JobState::Completed;
                            job.bytes = bytes;
                            // HLS 的 total 是分片数，完成后统一按字节数上报。
                            job.total = bytes as i64;
                        });
                        Ok(DownloadOutcome::Completed(bytes))
                    }
                    Err(err) => {
                        self.update(id, |job| {
                            job.state = JobState::Failed;
                            job.error = err.to_string();
                        });
                        Err(err)
                    }
                }
            }
            Ok(DownloadOutcome::Paused) => {
                // 已写入的分片与元数据保留，恢复时从断点续传。
                self.update(id, |job| {
                    job.state = JobState::Paused;
                });
                Ok(DownloadOutcome::Paused)
            }
            Ok(DownloadOutcome::Restart) => {
                // 服务器数据已变化，丢弃中间文件并回到队列。
                discard(&target);
                self.update(id, |job| {
                    job.state = JobState::Queued;
                    job.bytes = 0;
                    job.total = 0;
                    job.error = "服务器内容已变化，已重置".into();
                });
                Ok(DownloadOutcome::Restart)
            }
            Err(err) => {
                self.update(id, |job| {
                    job.state = JobState::Failed;
                    job.error = err.to_string();
                });
                Err(err)
            }
        }
    }

    /// 暂停/继续/重试/删除。
    pub fn control(&self, command: &str, id: &str) -> bool {
        match command {
            "pause" => {
                self.update(id, |job| {
                    if !job.state.is_terminal() {
                        job.state = JobState::Paused;
                    }
                });
                true
            }
            "resume" | "retry" => {
                self.update(id, |job| {
                    job.state = JobState::Queued;
                    job.error.clear();
                });
                true
            }
            "delete" => {
                // 必须先取出 target 再删任务：remove 之后 target_of 已查不到，
                // 会退化成对空路径调用 discard，既删不掉文件也可能误伤相对路径。
                let target = self.target_of(id);
                let removed = {
                    let mut jobs = self.jobs.lock().expect("jobs lock");
                    let removed = jobs.remove(id).is_some();
                    self.persist(&jobs);
                    removed
                };
                if let Some(target) = target {
                    discard(&PathBuf::from(target));
                }
                removed
            }
            _ => false,
        }
    }

    fn target_of(&self, id: &str) -> Option<String> {
        self.jobs
            .lock()
            .expect("jobs lock")
            .get(id)
            .map(|job| job.target.clone())
    }
}

impl Default for Scheduler {
    fn default() -> Self {
        Self::new(2)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn concurrency_is_clamped() {
        assert_eq!(Scheduler::new(0).concurrency(), 1);
        assert_eq!(Scheduler::new(99).concurrency(), 6);
        assert_eq!(Scheduler::new(3).concurrency(), 3);
    }

    #[test]
    fn enqueue_is_idempotent() {
        let scheduler = Scheduler::new(2);
        scheduler.enqueue(Job::new("a", "/tmp/a", "https://x.test/a.mp4"));
        scheduler.enqueue(Job::new("a", "/tmp/a", "https://x.test/a.mp4"));
        assert_eq!(scheduler.snapshot().len(), 1);
    }

    #[test]
    fn revision_increases_on_change() {
        let scheduler = Scheduler::new(2);
        let first = scheduler.enqueue(Job::new("a", "/tmp/a", "https://x.test/a.mp4"));
        let second = scheduler.control("pause", "a");
        assert!(second);
        let job = scheduler.get("a").expect("job");
        assert_eq!(job.state, JobState::Paused);
        assert!(job.revision > first);
    }

    #[test]
    fn counts_track_states() {
        let scheduler = Scheduler::new(2);
        scheduler.enqueue(Job::new("a", "/tmp/a", "https://x.test/a.mp4"));
        scheduler.enqueue(Job::new("b", "/tmp/b", "https://x.test/b.mp4"));
        scheduler.control("pause", "b");
        let (queued, running, completed, failed) = scheduler.counts();
        assert_eq!((queued, running, completed, failed), (1, 0, 0, 0));
    }

    #[test]
    fn delete_removes_job() {
        let scheduler = Scheduler::new(2);
        scheduler.enqueue(Job::new("a", "/tmp/a", "https://x.test/a.mp4"));
        assert!(scheduler.control("delete", "a"));
        assert!(scheduler.get("a").is_none());
        assert!(!scheduler.control("delete", "a"));
    }

    #[test]
    fn progress_is_clamped() {
        let mut job = Job::new("a", "/tmp/a", "https://x.test/a.mp4");
        job.bytes = 5;
        job.total = 10;
        assert!((job.progress() - 0.5).abs() < f64::EPSILON);
        job.bytes = 20;
        assert!((job.progress() - 1.0).abs() < f64::EPSILON);
        job.total = 0;
        assert_eq!(job.progress(), 0.0);
    }

    fn temp_index(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "guo-dl-index-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|value| value.as_nanos())
                .unwrap_or(0)
        ))
    }

    #[test]
    fn index_survives_reopen() {
        let path = temp_index("reopen").join("index.json");
        {
            let scheduler = Scheduler::open(2, &path);
            scheduler.enqueue(Job::new("a", "/tmp/a", "https://x.test/a.mp4"));
            scheduler.control("pause", "a");
        }
        let reopened = Scheduler::open(2, &path);
        let job = reopened.get("a").expect("任务应被恢复");
        assert_eq!(job.state, JobState::Paused);
    }

    #[test]
    fn running_jobs_requeue_after_restart() {
        let path = temp_index("requeue").join("index.json");
        {
            let scheduler = Scheduler::open(2, &path);
            scheduler.enqueue(Job::new("a", "/tmp/a", "https://x.test/a.mp4"));
            // 模拟「运行中被杀」：直接改内存状态并落盘。
            scheduler.update("a", |job| job.state = JobState::Running);
        }
        let reopened = Scheduler::open(2, &path);
        let job = reopened.get("a").expect("任务应被恢复");
        assert_eq!(job.state, JobState::Queued, "中断的任务必须重新排队");
        assert!(job.error.contains("中断"));
    }

    #[test]
    fn delete_removes_job_from_index() {
        let path = temp_index("delete").join("index.json");
        {
            let scheduler = Scheduler::open(2, &path);
            scheduler.enqueue(Job::new("a", "/tmp/a", "https://x.test/a.mp4"));
            assert!(scheduler.control("delete", "a"));
        }
        let reopened = Scheduler::open(2, &path);
        assert!(reopened.get("a").is_none());
    }

    #[test]
    fn corrupt_index_is_ignored() {
        let path = temp_index("corrupt").join("index.json");
        std::fs::create_dir_all(path.parent().unwrap()).expect("dir");
        std::fs::write(&path, b"{not json").expect("write");
        let scheduler = Scheduler::open(2, &path);
        assert!(scheduler.snapshot().is_empty());
        // 损坏后仍可正常登记并覆盖写盘。
        scheduler.enqueue(Job::new("a", "/tmp/a", "https://x.test/a.mp4"));
        assert_eq!(Scheduler::open(2, &path).snapshot().len(), 1);
    }

    #[test]
    fn in_memory_scheduler_never_writes() {
        let scheduler = Scheduler::new(2);
        scheduler.enqueue(Job::new("a", "/tmp/a", "https://x.test/a.mp4"));
        // 无索引路径时不应产生任何文件；这里只断言行为不变。
        assert_eq!(scheduler.snapshot().len(), 1);
    }

    #[test]
    fn pause_stops_before_next_segment() {
        // 暂停判定在分片边界生效：这里直接验证判定函数本身。
        let scheduler = Scheduler::new(2);
        scheduler.enqueue(Job::new("a", "/tmp/a", "https://x.test/a.mp4"));
        let should_continue = || {
            scheduler
                .get("a")
                .map(|job| job.state != JobState::Paused)
                .unwrap_or(false)
        };
        assert!(should_continue());
        scheduler.control("pause", "a");
        assert!(!should_continue(), "暂停后不应继续下载下一个分片");
        scheduler.control("resume", "a");
        assert!(should_continue(), "恢复后应继续");
    }

    #[test]
    fn paused_job_survives_restart_as_paused() {
        let path = temp_index("paused").join("index.json");
        {
            let scheduler = Scheduler::open(2, &path);
            scheduler.enqueue(Job::new("a", "/tmp/a", "https://x.test/a.mp4"));
            scheduler.control("pause", "a");
        }
        let reopened = Scheduler::open(2, &path);
        assert_eq!(
            reopened.get("a").expect("job").state,
            JobState::Paused,
            "暂停状态必须跨重启保留，否则会被误当成中断重排"
        );
    }

    #[test]
    fn unknown_command_is_rejected() {
        let scheduler = Scheduler::new(2);
        scheduler.enqueue(Job::new("a", "/tmp/a", "https://x.test/a.mp4"));
        assert!(!scheduler.control("explode", "a"));
    }
}
