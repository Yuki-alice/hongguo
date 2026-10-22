//! 目录请求限流：并发上限 + 最小间隔。
//!
//! 站源多为个人站点，并发过高会被限流甚至封禁。这里把「同时最多几个请求」
//! 与「两次请求之间至少隔多久」放在一处，读的是运行期 [`ResourceSettings`]，
//! 因此用户在设置页改完立即生效。
//!
//! 间隔是**全局**的（不按站源分开）：用户的诉求是「别把这个站刷爆」，
//! 按源分别计时会让总请求量随源数量线性增长。
//!
//! [`ResourceSettings`]: crate::ResourceSettings

use std::sync::Arc;
use std::time::{Duration, Instant};

use tokio::sync::{Mutex, Semaphore};

/// 目录请求限流器。
pub struct RequestGate {
    /// 并发许可。数量随设置变化（见 [`RequestGate::reconfigure`]）。
    permits: Arc<Semaphore>,
    /// 上一次放行的时间，用于计算最小间隔。
    last: Arc<Mutex<Option<Instant>>>,
    /// 当前并发配置值（`available_permits()` 反映的是空闲数，不是配置）。
    concurrency: std::sync::atomic::AtomicU32,
}

impl RequestGate {
    pub fn new(concurrency: u32) -> Self {
        let limit = concurrency.clamp(1, 8) as usize;
        Self {
            permits: Arc::new(Semaphore::new(limit)),
            last: Arc::new(Mutex::new(None)),
            concurrency: std::sync::atomic::AtomicU32::new(limit as u32),
        }
    }

    /// 调整并发。缩容只回收空闲许可，不会掐断在途请求。
    pub fn reconfigure(&self, concurrency: u32) {
        let limit = concurrency.clamp(1, 8);
        let current = self
            .concurrency
            .swap(limit, std::sync::atomic::Ordering::SeqCst);
        if limit > current {
            self.permits.add_permits((limit - current) as usize);
        } else if limit < current {
            let idle = self.permits.available_permits();
            let reclaim = ((current - limit) as usize).min(idle);
            if reclaim > 0 {
                self.permits.forget_permits(reclaim);
            }
        }
    }

    /// 取得一次请求许可，并按最小间隔等待。
    ///
    /// 返回的守卫在 drop 时归还并发许可；调用方应把它持有到请求结束。
    pub async fn acquire(&self, interval: Duration) -> tokio::sync::SemaphorePermit<'_> {
        let permit = self
            .permits
            .acquire()
            .await
            .expect("目录请求信号量不会关闭");
        if !interval.is_zero() {
            // 间隔只在拿到并发许可之后计算：否则排队时间会被误当成「已经等过」。
            let mut last = self.last.lock().await;
            if let Some(previous) = *last {
                let elapsed = previous.elapsed();
                if elapsed < interval {
                    tokio::time::sleep(interval - elapsed).await;
                }
            }
            *last = Some(Instant::now());
        }
        permit
    }
}

impl Default for RequestGate {
    fn default() -> Self {
        Self::new(3)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn permits_are_bounded_by_concurrency() {
        let gate = Arc::new(RequestGate::new(1));
        let first = gate.acquire(Duration::ZERO).await;
        // 第二个许可必须等第一个归还。
        let gate2 = Arc::clone(&gate);
        let waiting = tokio::spawn(async move {
            let _permit = gate2.acquire(Duration::ZERO).await;
            1
        });
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(!waiting.is_finished(), "并发为 1 时第二个请求应排队");
        drop(first);
        assert_eq!(waiting.await.expect("join"), 1);
    }

    #[tokio::test]
    async fn interval_is_enforced_between_requests() {
        let gate = RequestGate::new(4);
        let interval = Duration::from_millis(120);
        let started = Instant::now();
        {
            let _permit = gate.acquire(interval).await;
        }
        {
            let _permit = gate.acquire(interval).await;
        }
        // 第一次不等待，第二次至少等一个间隔。
        assert!(started.elapsed() >= interval);
    }

    #[tokio::test]
    async fn reconfigure_grows_and_shrinks_without_hanging() {
        let gate = Arc::new(RequestGate::new(2));
        gate.reconfigure(4);
        // 扩容后可以同时拿到 4 个。
        let mut held = Vec::new();
        for _ in 0..4 {
            held.push(gate.acquire(Duration::ZERO).await);
        }
        drop(held);
        // 缩容到 1：空闲许可被回收，仍能正常获取。
        gate.reconfigure(1);
        let _permit = gate.acquire(Duration::ZERO).await;
    }
}
