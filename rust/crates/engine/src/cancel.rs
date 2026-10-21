//! 请求取消：`request_id` 与代次闸门。
//!
//! 语义对齐 Go 的 `beginRead`：同一 `session` 上发起新请求会作废旧请求，
//! 被作废的请求在返回前发现自己已过期，改为返回 `Cancelled`，
//! UI 因此不会用旧结果覆盖新页面（ADR-9）。
//!
//! 这里只维护「谁还有效」，不持有任何业务数据；请求体与结果都在调用方。

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use crate::error::EngineError;

/// 一次可取消调用持有的票据。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RequestTicket {
    /// 调用方可见的请求标识；Dart 侧用它丢弃过期回调。
    pub request_id: String,
    /// 会话名（例如 `catalog-wuguo`、`detail`）。为空表示不参与代次淘汰。
    pub session: String,
    /// 代次。同一会话内单调递增。
    pub sequence: u64,
}

/// 取消注册表。
///
/// 全局唯一实例挂在 `Engine` 上；`clone` 共享状态，便于跨 async 任务持有。
#[derive(Clone, Default)]
pub struct CancellationRegistry {
    inner: Arc<Mutex<Inner>>,
    next_sequence: Arc<AtomicU64>,
}

#[derive(Default)]
struct Inner {
    /// 会话 → 当前有效代次。
    sessions: HashMap<String, u64>,
    /// 已显式取消、但调用方可能尚未返回的代次。
    cancelled: Vec<(String, u64)>,
}

impl CancellationRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// 开始一次调用：分配代次，并把同一会话的旧代次作废。
    ///
    /// `session` 为空时只分配请求号，不参与代次淘汰（用于一次性的独立请求）。
    pub fn begin(&self, session: &str, request_id: impl Into<String>) -> RequestTicket {
        let sequence = self.next_sequence.fetch_add(1, Ordering::SeqCst) + 1;
        if !session.is_empty() {
            if let Ok(mut inner) = self.inner.lock() {
                inner.sessions.insert(session.to_string(), sequence);
            }
        }
        RequestTicket {
            request_id: request_id.into(),
            session: session.to_string(),
            sequence,
        }
    }

    /// 票据是否仍然有效（未被同会话的新请求或显式取消作废）。
    pub fn is_active(&self, ticket: &RequestTicket) -> bool {
        if ticket.session.is_empty() {
            return true;
        }
        let Ok(inner) = self.inner.lock() else {
            return true;
        };
        if inner
            .cancelled
            .iter()
            .any(|(session, sequence)| *session == ticket.session && *sequence == ticket.sequence)
        {
            return false;
        }
        match inner.sessions.get(&ticket.session) {
            Some(current) => *current == ticket.sequence,
            None => false,
        }
    }

    /// 显式取消某个会话的当前请求。
    ///
    /// 返回被取消的代次；会话不存在时返回 `None`。
    pub fn cancel(&self, session: &str) -> Option<u64> {
        let mut inner = self.inner.lock().ok()?;
        let sequence = inner.sessions.remove(session)?;
        inner.cancelled.push((session.to_string(), sequence));
        Some(sequence)
    }

    /// 显式取消一个已知票据。
    pub fn cancel_ticket(&self, ticket: &RequestTicket) -> bool {
        if ticket.session.is_empty() {
            return false;
        }
        let Ok(mut inner) = self.inner.lock() else {
            return false;
        };
        inner
            .cancelled
            .push((ticket.session.clone(), ticket.sequence));
        if inner.sessions.get(&ticket.session) == Some(&ticket.sequence) {
            inner.sessions.remove(&ticket.session);
        }
        true
    }

    /// 请求结束：回收该会话的代次记录。
    ///
    /// 只在该代次仍是当前代次时清理，避免把后来者的记录删掉。
    pub fn finish(&self, ticket: &RequestTicket) {
        if ticket.session.is_empty() {
            return;
        }
        if let Ok(mut inner) = self.inner.lock() {
            if inner.sessions.get(&ticket.session) == Some(&ticket.sequence) {
                inner.sessions.remove(&ticket.session);
            }
            inner.cancelled.retain(|(session, sequence)| {
                !(*session == ticket.session && *sequence == ticket.sequence)
            });
        }
    }

    /// 有效会话数，供诊断。
    pub fn session_count(&self) -> usize {
        self.inner
            .lock()
            .map(|inner| inner.sessions.len())
            .unwrap_or(0)
    }

    /// 已取消但未被回收的记录数，供诊断与泄漏排查。
    pub fn cancelled_count(&self) -> usize {
        self.inner
            .lock()
            .map(|inner| inner.cancelled.len())
            .unwrap_or(0)
    }

    /// 票据已失效时返回 `Cancelled`，否则 `Ok(())`。
    pub fn ensure_active(&self, ticket: &RequestTicket) -> Result<(), EngineError> {
        if self.is_active(ticket) {
            Ok(())
        } else {
            Err(EngineError::cancelled(ticket.request_id.clone()))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn newer_request_invalidates_older() {
        let registry = CancellationRegistry::new();
        let first = registry.begin("catalog-wuguo", "r1");
        assert!(registry.is_active(&first));
        let second = registry.begin("catalog-wuguo", "r2");
        assert!(!registry.is_active(&first), "旧请求必须失效");
        assert!(registry.is_active(&second));
        assert_eq!(
            registry.ensure_active(&first).unwrap_err().kind,
            crate::error::EngineErrorKind::Cancelled
        );
    }

    #[test]
    fn sessions_are_independent() {
        let registry = CancellationRegistry::new();
        let catalog = registry.begin("catalog", "r1");
        let detail = registry.begin("detail", "r2");
        registry.begin("catalog", "r3");
        assert!(!registry.is_active(&catalog));
        assert!(registry.is_active(&detail), "其它会话不受影响");
    }

    #[test]
    fn explicit_cancel_marks_ticket() {
        let registry = CancellationRegistry::new();
        let ticket = registry.begin("catalog", "r1");
        assert_eq!(registry.cancel("catalog"), Some(ticket.sequence));
        assert!(!registry.is_active(&ticket));
        assert_eq!(registry.cancel("catalog"), None, "重复取消无效果");
    }

    #[test]
    fn finish_releases_session_but_keeps_newer() {
        let registry = CancellationRegistry::new();
        let first = registry.begin("catalog", "r1");
        let second = registry.begin("catalog", "r2");
        registry.finish(&first);
        assert!(registry.is_active(&second), "旧票据结束不能带走新代次");
        assert_eq!(registry.session_count(), 1);
        registry.finish(&second);
        assert_eq!(registry.session_count(), 0);
        assert_eq!(registry.cancelled_count(), 0);
    }

    #[test]
    fn sessions_without_name_never_expire() {
        let registry = CancellationRegistry::new();
        let ticket = registry.begin("", "r1");
        assert!(registry.is_active(&ticket));
        assert!(registry.is_active(&ticket));
    }
}
