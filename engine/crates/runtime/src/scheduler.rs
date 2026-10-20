use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};
use tokio::sync::Semaphore;

use crate::download::{commit, discard, download_file, download_hls, DownloadOutcome, HlsKey};
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

/// 下载调度器：有界并发 + 状态快照。
///
/// 并发上限由 `Semaphore` 控制，符合「先定并发预算再选执行模型」的要求；
/// 状态放在 `Mutex<BTreeMap>` 中，读多写少且临界区短。
pub struct Scheduler {
    jobs: Mutex<BTreeMap<String, Job>>,
    gate: Arc<Semaphore>,
    revision: AtomicU64,
}

impl Scheduler {
    pub fn new(concurrency: usize) -> Self {
        let limit = concurrency.clamp(1, 6);
        Self {
            jobs: Mutex::new(BTreeMap::new()),
            gate: Arc::new(Semaphore::new(limit)),
            revision: AtomicU64::new(0),
        }
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
        if let Some(job) = self.jobs.lock().expect("jobs lock").get_mut(id) {
            apply(job);
            job.revision = revision;
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
        let result = if segments.is_empty() {
            download_file(env, &job.url, &job.referer, &target, recorder).await
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
            download_hls(env, &segments, &job.referer, &target, material, recorder).await
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
                let removed = self.jobs.lock().expect("jobs lock").remove(id).is_some();
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

    #[test]
    fn unknown_command_is_rejected() {
        let scheduler = Scheduler::new(2);
        scheduler.enqueue(Job::new("a", "/tmp/a", "https://x.test/a.mp4"));
        assert!(!scheduler.control("explode", "a"));
    }
}
