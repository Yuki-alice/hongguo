use std::collections::{BTreeMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};

use crate::SourceError;
use crate::{Category, Drama};

/// 缓存有效期。与 Go 实现保持一致（15 分钟）。
pub const TTL_SECS: u64 = 15 * 60;

/// 单个目录的持久化上限，避免异常数据把磁盘写满。
pub const MAX_BYTES: usize = 32 * 1024 * 1024;

/// 当前磁盘格式版本。
pub const FORMAT_VERSION: u32 = 1;

/// 单个目录键的游标状态。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogState {
    /// 已加载到的页码。
    #[serde(default)]
    pub page: u32,
    #[serde(default)]
    pub has_more: bool,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub warning: String,
    /// 最后成功更新时间（Unix 秒）；0 表示从未成功。
    #[serde(default)]
    pub updated_at: u64,
}

impl CatalogState {
    /// 是否在有效期内。
    pub fn is_fresh(&self, now: u64) -> bool {
        self.updated_at > 0 && now.saturating_sub(self.updated_at) < TTL_SECS
    }
}

/// 落盘结构。
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogDisk {
    pub version: u32,
    #[serde(default)]
    pub catalogs: BTreeMap<String, Vec<Drama>>,
    #[serde(default)]
    pub states: BTreeMap<String, CatalogState>,
    #[serde(default)]
    pub categories: BTreeMap<String, Vec<Category>>,
}

/// 目录键：`source` 或 `source|category`。
pub fn catalog_key(source: &str, category: &str) -> String {
    let category = category.trim();
    if category.is_empty() {
        source.to_string()
    } else {
        format!("{source}|{category}")
    }
}

/// 从分类键拆出基础源。
fn base_source(key: &str) -> Option<&str> {
    key.split_once('|').map(|(base, _)| base)
}

/// 按 ID 合并两组剧目，保持旧顺序并把新条目追加到末尾。
pub fn merge(existing: &[Drama], incoming: &[Drama]) -> Vec<Drama> {
    let mut seen = HashSet::new();
    let mut merged: Vec<Drama> = Vec::with_capacity(existing.len() + incoming.len());
    let incoming_by_id: BTreeMap<&str, &Drama> = incoming
        .iter()
        .map(|item| (item.id.as_str(), item))
        .collect();

    // 旧条目保留位置，但用新数据刷新字段。
    for item in existing {
        if seen.insert(item.id.clone()) {
            match incoming_by_id.get(item.id.as_str()) {
                Some(fresh) => merged.push((*fresh).clone()),
                None => merged.push(item.clone()),
            }
        }
    }
    for item in incoming {
        if seen.insert(item.id.clone()) {
            merged.push(item.clone());
        }
    }
    merged
}

/// 第一页替换：以新数据为主，保留旧数据中未出现且仍有效的条目。
pub fn replace_first_page(previous: &[Drama], incoming: &[Drama]) -> Vec<Drama> {
    let fresh: HashSet<&str> = incoming.iter().map(|item| item.id.as_str()).collect();
    // 第一页语义：新数据在前，旧数据中未被刷新过的条目追加在后。
    let mut ordered: Vec<Drama> = incoming.to_vec();
    let mut seen = fresh.clone();
    for item in previous {
        if seen.insert(item.id.as_str()) {
            ordered.push(item.clone());
        }
    }
    ordered
}

/// 进程内目录缓存。
#[derive(Clone)]
pub struct CatalogCache {
    inner: Arc<Mutex<CatalogDisk>>,
    directory: PathBuf,
}

impl CatalogCache {
    /// 从磁盘加载；文件缺失或损坏时返回空缓存而不是失败。
    pub fn open(directory: impl Into<PathBuf>) -> Self {
        let directory = directory.into();
        let disk = read_disk(&directory).unwrap_or_default();
        Self {
            inner: Arc::new(Mutex::new(disk)),
            directory,
        }
    }

    pub fn path(&self) -> PathBuf {
        self.directory.join("catalogs.json")
    }

    /// 读取缓存条目。
    pub fn items(&self, key: &str) -> Vec<Drama> {
        self.inner
            .lock()
            .expect("cache lock")
            .catalogs
            .get(key)
            .cloned()
            .unwrap_or_default()
    }

    pub fn state(&self, key: &str) -> CatalogState {
        self.inner
            .lock()
            .expect("cache lock")
            .states
            .get(key)
            .cloned()
            .unwrap_or_default()
    }

    pub fn categories(&self, source: &str) -> Vec<Category> {
        self.inner
            .lock()
            .expect("cache lock")
            .categories
            .get(source)
            .cloned()
            .unwrap_or_default()
    }

    /// 写入一页目录并更新游标。
    ///
    /// 与 Go 实现一致：第 1 页替换并保留旧条目，后续页按 ID 合并；
    /// 分类键同时回写基础源，避免「全部」看不到分类内容。
    pub fn store(
        &self,
        source: &str,
        category: &str,
        page: u32,
        incoming: Vec<Drama>,
        has_more: bool,
        warning: &str,
    ) -> Result<CatalogState, SourceError> {
        let key = catalog_key(source, category);
        let now = now_secs();
        let mut disk = self.inner.lock().expect("cache lock");

        let previous = disk.catalogs.get(&key).cloned().unwrap_or_default();
        let mut state = disk.states.get(&key).cloned().unwrap_or_default();

        let merged = if page <= 1 {
            replace_first_page(&previous, &incoming)
        } else {
            merge(&previous, &incoming)
        };
        disk.catalogs.insert(key.clone(), merged.clone());

        // 分类键的内容也要汇总到基础源。
        if let Some(base) = base_source(&key) {
            let base_items = disk.catalogs.get(base).cloned().unwrap_or_default();
            let combined = merge(&base_items, &merged);
            disk.catalogs.insert(base.to_string(), combined);
        }

        if warning.is_empty() {
            state.page = state.page.max(page);
            state.has_more = has_more;
            state.warning.clear();
            state.updated_at = now;
        } else {
            // 有警告时保留旧游标，避免用失败结果覆盖进度。
            state.warning = warning.to_string();
        }
        disk.states.insert(key, state.clone());

        write_disk(&self.directory, &disk)?;
        Ok(state)
    }

    /// 保存分类清单。
    pub fn store_categories(
        &self,
        source: &str,
        categories: Vec<Category>,
    ) -> Result<(), SourceError> {
        let mut disk = self.inner.lock().expect("cache lock");
        disk.categories.insert(source.to_string(), categories);
        write_disk(&self.directory, &disk)
    }

    /// 移除某个键。
    pub fn remove(&self, key: &str) -> Result<(), SourceError> {
        let mut disk = self.inner.lock().expect("cache lock");
        disk.catalogs.remove(key);
        disk.states.remove(key);
        write_disk(&self.directory, &disk)
    }

    /// 当前键数量，供诊断。
    pub fn len(&self) -> usize {
        self.inner.lock().expect("cache lock").catalogs.len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|value| value.as_secs())
        .unwrap_or(0)
}

fn read_disk(directory: &Path) -> Option<CatalogDisk> {
    let path = directory.join("catalogs.json");
    let info = std::fs::metadata(&path).ok()?;
    if info.len() as usize > MAX_BYTES {
        return None;
    }
    let bytes = std::fs::read(&path).ok()?;
    if bytes.len() > MAX_BYTES {
        return None;
    }
    let disk: CatalogDisk = serde_json::from_slice(&bytes).ok()?;
    // 版本不符时丢弃，避免误读旧格式。
    if disk.version != FORMAT_VERSION {
        return None;
    }
    Some(disk)
}

fn write_disk(directory: &Path, disk: &CatalogDisk) -> Result<(), SourceError> {
    std::fs::create_dir_all(directory)
        .map_err(|err| SourceError::parse("cache", format!("创建缓存目录失败：{err}")))?;
    let payload = CatalogDisk {
        version: FORMAT_VERSION,
        ..disk.clone()
    };
    let encoded = serde_json::to_vec(&payload)
        .map_err(|err| SourceError::parse("cache", format!("序列化失败：{err}")))?;
    if encoded.len() > MAX_BYTES {
        return Err(SourceError::parse(
            "cache",
            format!("目录缓存超过 {} MiB，已停止写入", MAX_BYTES / 1024 / 1024),
        ));
    }
    // 先写临时文件再 rename，避免中断留下半截 JSON。
    let temporary = directory.join(".catalogs.json.tmp");
    std::fs::write(&temporary, &encoded)
        .map_err(|err| SourceError::parse("cache", format!("写入失败：{err}")))?;
    std::fs::rename(&temporary, directory.join("catalogs.json"))
        .map_err(|err| SourceError::parse("cache", format!("提交失败：{err}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn drama(id: &str, title: &str) -> Drama {
        Drama {
            id: format!("src:{id}"),
            source: "src".into(),
            source_id: id.into(),
            title: title.into(),
            ..Default::default()
        }
    }

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("guo-cache-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn key_includes_category_only_when_present() {
        assert_eq!(catalog_key("wuguo", ""), "wuguo");
        assert_eq!(catalog_key("wuguo", "  "), "wuguo");
        assert_eq!(catalog_key("wuguo", "7"), "wuguo|7");
        assert_eq!(catalog_key("wuguo", " 7 "), "wuguo|7");
    }

    #[test]
    fn merge_keeps_order_and_appends_new() {
        let existing = vec![drama("1", "旧一"), drama("2", "旧二")];
        let incoming = vec![drama("2", "新二"), drama("3", "新三")];
        let merged = merge(&existing, &incoming);
        assert_eq!(merged.len(), 3);
        assert_eq!(merged[0].title, "旧一");
        assert_eq!(merged[1].title, "新二", "同 ID 应使用新数据");
        assert_eq!(merged[2].title, "新三");
    }

    #[test]
    fn merge_dedupes_by_id() {
        let existing = vec![drama("1", "a")];
        let incoming = vec![drama("1", "b"), drama("1", "c")];
        let merged = merge(&existing, &incoming);
        assert_eq!(merged.len(), 1);
    }

    #[test]
    fn replace_first_page_puts_new_items_first() {
        // 同一 ID 在旧数据中标题不同，第一页应使用新标题。
        let previous = vec![drama("1", "旧一"), drama("9", "旧九")];
        let incoming = vec![drama("1", "新一"), drama("2", "新二")];
        let merged = replace_first_page(&previous, &incoming);

        assert_eq!(merged[0].title, "新一");
        assert_eq!(merged[1].title, "新二");
        assert!(
            merged.iter().any(|item| item.title == "旧九"),
            "未刷新的旧条目应保留"
        );
        assert!(
            merged.iter().all(|item| item.title != "旧一"),
            "同 ID 的旧条目应被新数据替换"
        );
        assert_eq!(merged.len(), 3, "不应重复计入同 ID 条目");
    }

    #[test]
    fn state_freshness_follows_ttl() {
        let mut state = CatalogState::default();
        assert!(!state.is_fresh(1000), "从未更新不算新鲜");
        state.updated_at = 1000;
        assert!(state.is_fresh(1000 + TTL_SECS - 1));
        assert!(!state.is_fresh(1000 + TTL_SECS));
    }

    #[test]
    fn stores_and_reloads_across_instances() {
        let dir = temp_dir("persist");
        {
            let cache = CatalogCache::open(&dir);
            cache
                .store("wuguo", "", 1, vec![drama("1", "一")], true, "")
                .expect("store");
        }
        let reopened = CatalogCache::open(&dir);
        let items = reopened.items("wuguo");
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].title, "一");
        assert!(reopened.state("wuguo").has_more);
    }

    #[test]
    fn category_writes_back_to_base_source() {
        let dir = temp_dir("category");
        let cache = CatalogCache::open(&dir);
        cache
            .store("wuguo", "7", 1, vec![drama("7", "分类七")], false, "")
            .expect("store");

        assert_eq!(cache.items("wuguo|7").len(), 1);
        assert_eq!(cache.items("wuguo").len(), 1, "分类内容应汇总到基础源");
    }

    #[test]
    fn warning_preserves_previous_cursor() {
        let dir = temp_dir("warning");
        let cache = CatalogCache::open(&dir);
        cache
            .store("wuguo", "", 3, vec![drama("1", "一")], true, "")
            .expect("first");
        let state = cache
            .store("wuguo", "", 4, Vec::new(), false, "网络错误")
            .expect("second");
        assert_eq!(state.page, 3, "失败不应推进游标");
        assert_eq!(state.warning, "网络错误");
    }

    #[test]
    fn rejects_corrupt_file() {
        let dir = temp_dir("corrupt");
        std::fs::create_dir_all(&dir).expect("dir");
        std::fs::write(dir.join("catalogs.json"), b"{not json").expect("write");
        let cache = CatalogCache::open(&dir);
        assert!(cache.is_empty(), "损坏文件应被忽略而不是崩溃");
    }

    #[test]
    fn rejects_wrong_version() {
        let dir = temp_dir("version");
        std::fs::create_dir_all(&dir).expect("dir");
        std::fs::write(
            dir.join("catalogs.json"),
            br#"{"version":99,"catalogs":{"a":[]}}"#,
        )
        .expect("write");
        let cache = CatalogCache::open(&dir);
        assert!(cache.is_empty());
    }

    #[test]
    fn stores_categories() {
        let dir = temp_dir("cats");
        let cache = CatalogCache::open(&dir);
        cache
            .store_categories(
                "wuguo",
                vec![Category {
                    id: "7".into(),
                    name: "都市".into(),
                }],
            )
            .expect("store");
        assert_eq!(cache.categories("wuguo").len(), 1);
    }
}
