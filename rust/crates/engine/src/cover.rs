//! 封面缓存。
//!
//! 目录与详情只带封面 URL，播放页和列表需要本地文件。这里做最小实现：
//! 按 URL 的 SHA-256 命名，`<data>/covers/<前两位>/<哈希>`，命中即返回，
//! 未命中才发一次请求。
//!
//! 刻意不做的事：
//! - 不猜测扩展名（播放器按文件头判断，扩展名只会误导）；
//! - 不做图片解码 / 转码（HEIC 转码在 Dart 侧已有 `CoverDecoder`）；
//! - 不做容量淘汰（首版依赖用户手动清理，见 PLAN.md §2.2 非目标）。

use std::path::{Path, PathBuf};

use guo_source_api::{FetchRequest, SourceEnv, SourceError};

/// 单张封面上限。超过说明不是图片，直接拒绝，避免把磁盘写满。
const MAX_BYTES: usize = 8 * 1024 * 1024;

/// 封面缓存。
pub struct CoverCache {
    directory: PathBuf,
}

/// 取封面的结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CoverResult {
    /// 本地文件路径。
    pub path: String,
    /// 是否命中缓存（未发网络请求）。
    pub cached: bool,
}

impl CoverCache {
    pub fn open(directory: impl Into<PathBuf>) -> Self {
        Self {
            directory: directory.into(),
        }
    }

    pub fn directory(&self) -> &Path {
        &self.directory
    }

    /// 封面文件路径。`.` 开头的 URL 与空串没有稳定哈希，直接由调用方拒绝。
    pub fn path_for(&self, url: &str) -> Option<PathBuf> {
        let digest = guo_source_api::sha256_hex(url.as_bytes());
        let (prefix, _) = digest.split_at(2);
        Some(self.directory.join(prefix).join(&digest))
    }

    /// 取封面：命中直接返回，未命中下载并落盘。
    ///
    /// `force` 为真时忽略缓存重新下载（对应 UI 的「重试」）。
    pub async fn fetch(
        &self,
        env: &SourceEnv,
        url: &str,
        referer: &str,
        force: bool,
    ) -> Result<CoverResult, SourceError> {
        let url = url.trim();
        if !is_http(url) {
            return Err(SourceError::parse("cover", "封面地址无效"));
        }
        let path = self
            .path_for(url)
            .ok_or_else(|| SourceError::parse("cover", "封面地址无法缓存"))?;
        if !force && path.is_file() {
            return Ok(CoverResult {
                path: path.display().to_string(),
                cached: true,
            });
        }

        let mut request = FetchRequest::get(url).header("Accept", "image/*");
        if !referer.is_empty() {
            request = request.header("Referer", referer);
        }
        let response = env.transport.fetch(request).await?;
        response.ensure_success()?;
        let body = response.body;
        if body.is_empty() {
            return Err(SourceError::parse("cover", "封面返回空内容"));
        }
        if body.len() > MAX_BYTES {
            return Err(SourceError::parse(
                "cover",
                format!("封面超过 {} MiB，已拒绝缓存", MAX_BYTES / 1024 / 1024),
            ));
        }

        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|err| SourceError::parse("cover", format!("创建缓存目录失败：{err}")))?;
        }
        // 临时文件 + rename：中途被杀不会留下半张图被当成有效缓存。
        let temporary = path.with_extension("tmp");
        std::fs::write(&temporary, &body)
            .map_err(|err| SourceError::parse("cover", format!("写入封面失败：{err}")))?;
        std::fs::rename(&temporary, &path)
            .map_err(|err| SourceError::parse("cover", format!("提交封面失败：{err}")))?;

        Ok(CoverResult {
            path: path.display().to_string(),
            cached: false,
        })
    }

    /// 清空缓存目录。返回删除的文件数。
    pub fn clear(&self) -> Result<usize, SourceError> {
        let mut removed = 0;
        let Ok(entries) = std::fs::read_dir(&self.directory) else {
            return Ok(0);
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                if let Ok(inner) = std::fs::read_dir(&path) {
                    for file in inner.flatten() {
                        if std::fs::remove_file(file.path()).is_ok() {
                            removed += 1;
                        }
                    }
                }
            } else if std::fs::remove_file(&path).is_ok() {
                removed += 1;
            }
        }
        Ok(removed)
    }
}

fn is_http(url: &str) -> bool {
    let lower = url.to_lowercase();
    (lower.starts_with("http://") || lower.starts_with("https://")) && !lower.contains(' ')
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use async_trait::async_trait;
    use guo_source_api::{FetchRequest, FetchResponse, LogSink, SourceStore, Transport};

    use super::*;

    struct FakeTransport {
        requested: Mutex<Vec<String>>,
        body: Vec<u8>,
        status: u16,
    }

    #[async_trait]
    impl Transport for FakeTransport {
        async fn fetch(&self, request: FetchRequest) -> Result<FetchResponse, SourceError> {
            self.requested
                .lock()
                .expect("lock")
                .push(request.url.clone());
            Ok(FetchResponse::new(
                self.status,
                self.body.clone(),
                request.url.clone(),
            ))
        }
    }

    struct NoStore;
    #[async_trait]
    impl SourceStore for NoStore {
        async fn get(&self, _: &str) -> Result<Option<String>, SourceError> {
            Ok(None)
        }
        async fn set(&self, _: &str, _: &str) -> Result<(), SourceError> {
            Ok(())
        }
    }

    struct NoLog;
    impl LogSink for NoLog {
        fn debug(&self, _: &str) {}
        fn warn(&self, _: &str) {}
    }

    fn env_with(transport: Arc<FakeTransport>) -> SourceEnv {
        SourceEnv {
            source_id: "test".into(),
            transport,
            store: Arc::new(NoStore),
            scripts: None,
            log: Arc::new(NoLog),
        }
    }

    fn temp_dir(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "guo-cover-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|value| value.as_nanos())
                .unwrap_or(0)
        ))
    }

    fn transport(body: &[u8]) -> Arc<FakeTransport> {
        Arc::new(FakeTransport {
            requested: Mutex::new(Vec::new()),
            body: body.to_vec(),
            status: 200,
        })
    }

    #[tokio::test]
    async fn downloads_once_then_hits_cache() {
        let dir = temp_dir("hit");
        let cache = CoverCache::open(&dir);
        let env = env_with(transport(b"\xff\xd8\xff"));
        let url = "https://img.test/a.jpg";

        let first = cache.fetch(&env, url, "", false).await.expect("首次");
        assert!(!first.cached);
        assert!(Path::new(&first.path).is_file());

        let second = cache.fetch(&env, url, "", false).await.expect("二次");
        assert!(second.cached, "第二次必须命中缓存");
        assert_eq!(second.path, first.path);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn force_bypasses_cache() {
        let dir = temp_dir("force");
        let cache = CoverCache::open(&dir);
        let env = env_with(transport(b"\xff\xd8\xff"));
        let url = "https://img.test/b.jpg";
        cache.fetch(&env, url, "", false).await.expect("首次");
        let forced = cache.fetch(&env, url, "", true).await.expect("强制");
        assert!(!forced.cached, "force 必须重新下载");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn rejects_non_http_urls() {
        let dir = temp_dir("reject");
        let cache = CoverCache::open(&dir);
        let env = env_with(transport(b"x"));
        for url in ["", "file:///etc/passwd", "/local/a.jpg"] {
            assert!(cache.fetch(&env, url, "", false).await.is_err(), "{url}");
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn rejects_oversized_and_empty_bodies() {
        let dir = temp_dir("oversize");
        let cache = CoverCache::open(&dir);
        let empty = env_with(transport(b""));
        assert!(cache
            .fetch(&empty, "https://img.test/e.jpg", "", false)
            .await
            .is_err());

        let huge = env_with(transport(&vec![0u8; MAX_BYTES + 1]));
        assert!(cache
            .fetch(&huge, "https://img.test/h.jpg", "", false)
            .await
            .is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn http_error_propagates() {
        let dir = temp_dir("http");
        let cache = CoverCache::open(&dir);
        let failing = Arc::new(FakeTransport {
            requested: Mutex::new(Vec::new()),
            body: b"nope".to_vec(),
            status: 404,
        });
        let error = cache
            .fetch(&env_with(failing), "https://img.test/m.jpg", "", false)
            .await
            .expect_err("404 必须失败");
        assert_eq!(error.http_status(), Some(404));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn distinct_urls_get_distinct_paths() {
        let dir = temp_dir("distinct");
        let cache = CoverCache::open(&dir);
        let env = env_with(transport(b"x"));
        let a = cache
            .fetch(&env, "https://img.test/a.jpg", "", false)
            .await
            .expect("a");
        let b = cache
            .fetch(&env, "https://img.test/b.jpg", "", false)
            .await
            .expect("b");
        assert_ne!(a.path, b.path);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn clear_removes_cached_files() {
        let dir = temp_dir("clear");
        let cache = CoverCache::open(&dir);
        let env = env_with(transport(b"x"));
        cache
            .fetch(&env, "https://img.test/c.jpg", "", false)
            .await
            .expect("fetch");
        assert_eq!(cache.clear().expect("clear"), 1);
        let again = cache
            .fetch(&env, "https://img.test/c.jpg", "", false)
            .await
            .expect("再取");
        assert!(!again.cached, "清空后必须重新下载");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
