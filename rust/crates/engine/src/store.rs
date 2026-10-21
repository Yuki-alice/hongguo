//! 站源会话存储：按 `source_id` 命名空间落盘。
//!
//! 站源需要跨调用、跨重启保留的东西都在这里：芽果的登录令牌、红果的设备标识、
//! 剧果的签名 Cookie。键在写入时统一加 `<source_id>/` 前缀，站源本身只看到
//! 自己的局部键，因此不同源之间不可能互相覆盖。
//!
//! 写盘策略：整体文件 + 临时文件 rename。单个 `set` 只改内存与一次原子写，
//! 不会留下半截 JSON（见 ARCHITECTURE.md §10.3）。

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use serde::{Deserialize, Serialize};

use guo_source_api::{SourceError, SourceStore};

/// 落盘格式版本。不匹配时丢弃旧文件，避免误读历史结构。
const FORMAT_VERSION: u32 = 1;

/// 单文件上限，防止异常值把磁盘写满。
const MAX_BYTES: usize = 4 * 1024 * 1024;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StoreDisk {
    version: u32,
    #[serde(default)]
    values: BTreeMap<String, String>,
}

/// 磁盘支持的会话存储。
///
/// 内部用 `Arc<Mutex<…>>`，克隆后共享同一份数据与同一个文件，
/// 便于把 `Arc<dyn SourceStore>` 注入到多个 `SourceEnv`。
#[derive(Clone)]
pub struct DiskSourceStore {
    inner: Arc<Mutex<StoreDisk>>,
    path: PathBuf,
}

impl DiskSourceStore {
    /// 打开（或创建）`<directory>/sessions.json`。
    ///
    /// 文件缺失或损坏时返回空存储而不是失败：会话丢失只会让站源重新登录，
    /// 不应该拦住整个应用启动。
    pub fn open(directory: impl Into<PathBuf>) -> Self {
        let directory = directory.into();
        let path = directory.join("sessions.json");
        let disk = read_disk(&path).unwrap_or_default();
        Self {
            inner: Arc::new(Mutex::new(disk)),
            path,
        }
    }

    /// 落盘路径，供诊断接口展示。
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// 已保存的键数量。
    pub fn len(&self) -> usize {
        self.inner.lock().map(|disk| disk.values.len()).unwrap_or(0)
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// 某个站源命名空间下的键（不含前缀），按字典序。
    pub fn keys_of(&self, source_id: &str) -> Vec<String> {
        let prefix = format!("{source_id}/");
        let Ok(disk) = self.inner.lock() else {
            return Vec::new();
        };
        disk.values
            .keys()
            .filter_map(|key| key.strip_prefix(&prefix).map(str::to_string))
            .collect()
    }

    /// 删除某个站源的全部会话（插件卸载、账号切换）。
    pub fn clear_source(&self, source_id: &str) -> Result<usize, SourceError> {
        let prefix = format!("{source_id}/");
        let mut disk = self
            .inner
            .lock()
            .map_err(|_| SourceError::parse("store", "会话存储锁已损坏"))?;
        let before = disk.values.len();
        disk.values.retain(|key, _| !key.starts_with(&prefix));
        let removed = before - disk.values.len();
        write_disk(&self.path, &disk)?;
        Ok(removed)
    }
}

fn namespaced(source_id: &str, key: &str) -> String {
    format!("{source_id}/{key}")
}

#[async_trait]
impl SourceStore for DiskSourceStore {
    async fn get(&self, key: &str) -> Result<Option<String>, SourceError> {
        let disk = self
            .inner
            .lock()
            .map_err(|_| SourceError::parse("store", "会话存储锁已损坏"))?;
        Ok(disk.values.get(key).cloned())
    }

    async fn set(&self, key: &str, value: &str) -> Result<(), SourceError> {
        let mut disk = self
            .inner
            .lock()
            .map_err(|_| SourceError::parse("store", "会话存储锁已损坏"))?;
        disk.values.insert(key.to_string(), value.to_string());
        write_disk(&self.path, &disk)
    }
}

/// 给某个站源用的视图：读写自动加 `<source_id>/` 前缀。
///
/// `SourceEnv` 只暴露一个 `SourceStore`，而站源实现里的键都是局部名字
/// （`token`、`device`）。这一层保证同名键在不同源之间不会串。
pub struct NamespacedStore {
    inner: Arc<dyn SourceStore>,
    source_id: String,
}

impl NamespacedStore {
    pub fn new(inner: Arc<dyn SourceStore>, source_id: impl Into<String>) -> Self {
        Self {
            inner,
            source_id: source_id.into(),
        }
    }

    /// 包装后的完整键，便于日志与诊断。
    pub fn key(&self, key: &str) -> String {
        namespaced(&self.source_id, key)
    }
}

#[async_trait]
impl SourceStore for NamespacedStore {
    async fn get(&self, key: &str) -> Result<Option<String>, SourceError> {
        self.inner.get(&self.key(key)).await
    }

    async fn set(&self, key: &str, value: &str) -> Result<(), SourceError> {
        self.inner.set(&self.key(key), value).await
    }
}

fn read_disk(path: &Path) -> Option<StoreDisk> {
    let info = std::fs::metadata(path).ok()?;
    if info.len() as usize > MAX_BYTES {
        return None;
    }
    let bytes = std::fs::read(path).ok()?;
    if bytes.len() > MAX_BYTES {
        return None;
    }
    let disk: StoreDisk = serde_json::from_slice(&bytes).ok()?;
    if disk.version != FORMAT_VERSION {
        return None;
    }
    Some(disk)
}

fn write_disk(path: &Path, disk: &StoreDisk) -> Result<(), SourceError> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|err| SourceError::parse("store", format!("创建会话目录失败：{err}")))?;
    }
    let payload = StoreDisk {
        version: FORMAT_VERSION,
        values: disk.values.clone(),
    };
    let encoded = serde_json::to_vec(&payload)
        .map_err(|err| SourceError::parse("store", format!("序列化会话失败：{err}")))?;
    if encoded.len() > MAX_BYTES {
        return Err(SourceError::parse("store", "会话数据超过上限，已停止写入"));
    }
    let temporary = path.with_extension("json.tmp");
    std::fs::write(&temporary, &encoded)
        .map_err(|err| SourceError::parse("store", format!("写入会话失败：{err}")))?;
    std::fs::rename(&temporary, path)
        .map_err(|err| SourceError::parse("store", format!("提交会话失败：{err}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "guo-store-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|value| value.as_nanos())
                .unwrap_or(0)
        ));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    #[tokio::test]
    async fn survives_reopen() {
        let dir = temp_dir("reopen");
        {
            let store = DiskSourceStore::open(&dir);
            store.set("yaguo/token", "abc").await.expect("set");
        }
        let reopened = DiskSourceStore::open(&dir);
        assert_eq!(
            reopened.get("yaguo/token").await.expect("get").as_deref(),
            Some("abc")
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn namespaced_views_do_not_collide() {
        let dir = temp_dir("namespaced");
        let disk = Arc::new(DiskSourceStore::open(&dir));
        let yaguo = NamespacedStore::new(disk.clone(), "yaguo");
        let niuguo = NamespacedStore::new(disk.clone(), "niuguo");
        yaguo.set("token", "a").await.expect("set");
        niuguo.set("token", "b").await.expect("set");
        assert_eq!(yaguo.get("token").await.expect("get").as_deref(), Some("a"));
        assert_eq!(
            niuguo.get("token").await.expect("get").as_deref(),
            Some("b")
        );
        assert_eq!(disk.keys_of("yaguo"), vec!["token".to_string()]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn clear_source_removes_only_that_namespace() {
        let dir = temp_dir("clear");
        let disk = DiskSourceStore::open(&dir);
        disk.set("yaguo/token", "a").await.expect("set");
        disk.set("niuguo/token", "b").await.expect("set");
        assert_eq!(disk.clear_source("yaguo").expect("clear"), 1);
        assert!(disk.get("yaguo/token").await.expect("get").is_none());
        assert!(disk.get("niuguo/token").await.expect("get").is_some());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn corrupt_file_is_ignored() {
        let dir = temp_dir("corrupt");
        std::fs::create_dir_all(&dir).expect("dir");
        std::fs::write(dir.join("sessions.json"), b"{not json").expect("write");
        let store = DiskSourceStore::open(&dir);
        assert!(store.is_empty());
        store.set("a/b", "c").await.expect("set");
        assert_eq!(store.get("a/b").await.expect("get").as_deref(), Some("c"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
