//! 进度与事件总线：替代 Dart 侧的轮询快照。
//!
//! 引擎只负责把状态变化「推」出去，订阅者在 FFI 边界外由 FRB 的 `Stream`
//! 承接（`stream_download_progress`）。总线本身不做背压：下载任务状态变化频率
//! 远低于 UI 帧率，丢弃旧快照没有意义，只会让进度条回跳。
//!
//! 设计取舍：用 `tokio::sync::broadcast` 而不是 `watch`，因为 UI 需要看到
//! 「已完成 / 失败」这类瞬时事件；迟到订阅者只需要最新快照，两者都在
//! `Engine::download_progress` 里合并处理。

use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};
use tokio::sync::broadcast;

use guo_runtime::Job;

/// 下载任务的一次状态变化。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DownloadEvent {
    pub id: String,
    pub drama_id: String,
    pub episode_id: String,
    pub title: String,
    /// `queued` / `running` / `completed` / `failed` / `paused`。
    pub state: String,
    pub bytes: u64,
    pub total: i64,
    pub progress: f64,
    pub error: String,
    pub revision: u64,
}

impl From<&Job> for DownloadEvent {
    fn from(job: &Job) -> Self {
        Self {
            id: job.id.clone(),
            drama_id: job.drama_id.clone(),
            episode_id: job.episode_id.clone(),
            title: job.title.clone(),
            state: job.state.as_str().to_string(),
            bytes: job.bytes,
            total: job.total,
            progress: job.progress(),
            error: job.error.clone(),
            revision: job.revision,
        }
    }
}

/// 广播总线。容量足够覆盖一次「批量入队 + 逐个完成」的瞬时高峰。
#[derive(Clone)]
pub struct EventBus {
    sender: broadcast::Sender<DownloadEvent>,
    /// 最近一次广播的事件；新订阅者先拿到它，避免进度条从 0 跳。
    latest: Arc<Mutex<Option<DownloadEvent>>>,
}

impl Default for EventBus {
    fn default() -> Self {
        Self::new(256)
    }
}

impl EventBus {
    pub fn new(capacity: usize) -> Self {
        let (sender, _) = broadcast::channel(capacity.max(1));
        Self {
            sender,
            latest: Arc::new(Mutex::new(None)),
        }
    }

    /// 发布事件。没有订阅者时静默丢弃（`send` 的 `Err` 不代表失败）。
    pub fn publish(&self, event: DownloadEvent) {
        if let Ok(mut latest) = self.latest.lock() {
            *latest = Some(event.clone());
        }
        let _ = self.sender.send(event);
    }

    /// 最近一次事件。
    pub fn latest(&self) -> Option<DownloadEvent> {
        self.latest.lock().ok().and_then(|slot| slot.clone())
    }

    /// 订阅后续事件。
    pub fn subscribe(&self) -> broadcast::Receiver<DownloadEvent> {
        self.sender.subscribe()
    }

    /// 当前订阅者数量，供诊断。
    pub fn subscriber_count(&self) -> usize {
        self.sender.receiver_count()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn subscribers_receive_published_events() {
        let bus = EventBus::new(8);
        let mut receiver = bus.subscribe();
        let mut job = Job::new("a", "/tmp/a", "https://x.test/a.mp4");
        job.state = guo_runtime::JobState::Running;
        job.bytes = 5;
        job.total = 10;
        bus.publish(DownloadEvent::from(&job));
        let event = receiver.try_recv().expect("event");
        assert_eq!(event.id, "a");
        assert_eq!(event.state, "running");
        assert!((event.progress - 0.5).abs() < f64::EPSILON);
    }

    #[test]
    fn latest_is_available_to_late_subscribers() {
        let bus = EventBus::new(4);
        let mut job = Job::new("a", "/tmp/a", "https://x.test/a.mp4");
        job.state = guo_runtime::JobState::Completed;
        bus.publish(DownloadEvent::from(&job));
        assert_eq!(bus.latest().expect("latest").state, "completed");
    }

    #[test]
    fn publishing_without_subscribers_is_silent() {
        let bus = EventBus::new(2);
        let job = Job::new("a", "/tmp/a", "https://x.test/a.mp4");
        bus.publish(DownloadEvent::from(&job));
        assert_eq!(bus.subscriber_count(), 0);
        assert!(bus.latest().is_some());
    }
}
