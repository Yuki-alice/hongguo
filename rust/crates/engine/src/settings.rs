//! 运行时资源设置：目录并发 / 请求间隔 / 下载并发 / 代理。
//!
//! 与 [`EngineConfig`](crate::EngineConfig) 的区别：那是**装配期**的静态配置，
//! 这里是**运行期**可改的用户偏好，改动即时生效并落盘。
//!
//! 落盘位置：`<data>/settings.json`。读取失败一律回落默认值——设置文件损坏
//! 不该让应用起不来。

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

/// 目录并发与间隔的取值范围。
///
/// 上限刻意保守：站源多为个人站点，并发过高会被限流甚至封禁。
pub const CATALOG_CONCURRENCY_RANGE: (u32, u32) = (1, 8);
/// 请求间隔下限（毫秒）。0 表示不限速。
pub const CATALOG_INTERVAL_MAX_MS: u32 = 5000;
/// 下载并发上限，与 `Scheduler` 的夹取范围一致。
pub const DOWNLOAD_CONCURRENCY_RANGE: (u32, u32) = (1, 6);

/// 用户可调的资源设置。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ResourceSettings {
    /// `auto`（跟随系统代理）/ `direct`（直连）/ `manual`（自定义地址）。
    pub proxy_mode: String,
    /// `manual` 模式下的代理地址，例如 `http://127.0.0.1:7890`。
    pub proxy_url: String,
    /// 目录请求并发。
    pub catalog_concurrency: u32,
    /// 两次目录请求之间的最小间隔（毫秒）。
    pub catalog_interval_ms: u32,
    /// 下载并发。
    pub download_concurrency: u32,
    /// 按站源分流下载（每个源各自排队）。
    pub download_by_source: bool,
    /// 生效时的提示（例如代理不可用时的降级说明），只读。
    pub warning: String,
}

impl Default for ResourceSettings {
    fn default() -> Self {
        Self {
            proxy_mode: "auto".to_string(),
            proxy_url: String::new(),
            catalog_concurrency: 3,
            catalog_interval_ms: 250,
            download_concurrency: 2,
            download_by_source: false,
            warning: String::new(),
        }
    }
}

impl ResourceSettings {
    /// 把越界字段夹回合法范围。返回是否有字段被修正。
    ///
    /// 非法输入不报错而是夹取：设置页的输入框允许中间态（例如清空后为 0），
    /// 报错会让用户卡在无法保存的状态。
    pub fn clamp(&mut self) -> bool {
        let mut changed = false;
        let clamp_u32 = |value: &mut u32, range: (u32, u32), changed: &mut bool| {
            let clamped = (*value).clamp(range.0, range.1);
            if clamped != *value {
                *value = clamped;
                *changed = true;
            }
        };
        clamp_u32(
            &mut self.catalog_concurrency,
            CATALOG_CONCURRENCY_RANGE,
            &mut changed,
        );
        clamp_u32(
            &mut self.download_concurrency,
            DOWNLOAD_CONCURRENCY_RANGE,
            &mut changed,
        );
        let interval = self.catalog_interval_ms.min(CATALOG_INTERVAL_MAX_MS);
        if interval != self.catalog_interval_ms {
            self.catalog_interval_ms = interval;
            changed = true;
        }
        if !matches!(self.proxy_mode.as_str(), "auto" | "direct" | "manual") {
            self.proxy_mode = "auto".to_string();
            changed = true;
        }
        if self.proxy_mode != "manual" && !self.proxy_url.is_empty() {
            self.proxy_url.clear();
            changed = true;
        }
        changed
    }

    /// 目录请求之间的最小间隔。
    pub fn catalog_interval(&self) -> std::time::Duration {
        std::time::Duration::from_millis(u64::from(self.catalog_interval_ms))
    }
}

/// 运行期设置的持有者。
///
/// 值本身用 `Mutex` 保护：写入频率极低（用户改设置），读频率也不高，
/// 不值得引入更重的并发结构。另外用 `AtomicU64` 记录修订号，供调用方
/// 判断「设置是否变过」而无需反复比较整个结构。
pub struct SettingsStore {
    path: PathBuf,
    current: Mutex<ResourceSettings>,
    revision: AtomicU64,
}

impl SettingsStore {
    /// 打开设置存储。文件缺失或损坏时使用默认值。
    pub fn open(data_directory: impl AsRef<Path>) -> Self {
        let path = data_directory.as_ref().join("settings.json");
        let current = Self::read(&path).unwrap_or_default();
        Self {
            path,
            current: Mutex::new(current),
            revision: AtomicU64::new(1),
        }
    }

    fn read(path: &Path) -> Option<ResourceSettings> {
        let info = std::fs::metadata(path).ok()?;
        // 设置文件不该这么大；超限说明不是我们的文件。
        if info.len() > 64 * 1024 {
            return None;
        }
        let bytes = std::fs::read(path).ok()?;
        let mut settings: ResourceSettings = serde_json::from_slice(&bytes).ok()?;
        settings.clamp();
        Some(settings)
    }

    /// 当前设置。
    pub fn get(&self) -> ResourceSettings {
        self.current.lock().expect("settings lock").clone()
    }

    /// 修订号，每次成功保存后递增。
    pub fn revision(&self) -> u64 {
        self.revision.load(Ordering::SeqCst)
    }

    /// 保存设置：夹取范围、落盘、返回生效值。
    ///
    /// 落盘失败不回滚内存值——用户下次打开设置页看到的应是自己刚改的值，
    /// 而不是「保存失败后悄悄变回去」。
    pub fn save(&self, mut settings: ResourceSettings) -> ResourceSettings {
        settings.clamp();
        settings.warning.clear();
        {
            let mut current = self.current.lock().expect("settings lock");
            *current = settings.clone();
        }
        self.revision.fetch_add(1, Ordering::SeqCst);
        self.persist(&settings);
        settings
    }

    fn persist(&self, settings: &ResourceSettings) {
        let Ok(encoded) = serde_json::to_vec_pretty(settings) else {
            return;
        };
        if let Some(parent) = self.path.parent() {
            if std::fs::create_dir_all(parent).is_err() {
                return;
            }
        }
        let temporary = self.path.with_extension("json.tmp");
        if std::fs::write(&temporary, &encoded).is_err() {
            return;
        }
        let _ = std::fs::rename(&temporary, &self.path);
    }

    /// 设置文件路径（诊断页展示用）。
    pub fn path(&self) -> &Path {
        &self.path
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "guo-settings-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|value| value.as_nanos())
                .unwrap_or(0)
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("dir");
        dir
    }

    #[test]
    fn defaults_when_file_missing() {
        let dir = temp_dir("missing");
        let store = SettingsStore::open(&dir);
        assert_eq!(store.get(), ResourceSettings::default());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn save_then_reopen_keeps_values() {
        let dir = temp_dir("persist");
        {
            let store = SettingsStore::open(&dir);
            store.save(ResourceSettings {
                catalog_concurrency: 5,
                catalog_interval_ms: 800,
                download_concurrency: 4,
                proxy_mode: "manual".to_string(),
                proxy_url: "http://127.0.0.1:7890".to_string(),
                ..ResourceSettings::default()
            });
        }
        let reopened = SettingsStore::open(&dir);
        let settings = reopened.get();
        assert_eq!(settings.catalog_concurrency, 5);
        assert_eq!(settings.catalog_interval_ms, 800);
        assert_eq!(settings.download_concurrency, 4);
        assert_eq!(settings.proxy_mode, "manual");
        assert_eq!(settings.proxy_url, "http://127.0.0.1:7890");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn out_of_range_values_are_clamped() {
        let dir = temp_dir("clamp");
        let store = SettingsStore::open(&dir);
        let saved = store.save(ResourceSettings {
            catalog_concurrency: 99,
            catalog_interval_ms: 999_999,
            download_concurrency: 0,
            proxy_mode: "bogus".to_string(),
            proxy_url: "http://stale".to_string(),
            ..ResourceSettings::default()
        });
        assert_eq!(saved.catalog_concurrency, CATALOG_CONCURRENCY_RANGE.1);
        assert_eq!(saved.catalog_interval_ms, CATALOG_INTERVAL_MAX_MS);
        assert_eq!(saved.download_concurrency, DOWNLOAD_CONCURRENCY_RANGE.0);
        assert_eq!(saved.proxy_mode, "auto");
        // 非 manual 模式不保留自定义地址，避免切回 manual 时用到过期值。
        assert!(saved.proxy_url.is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn corrupt_file_falls_back_to_defaults() {
        let dir = temp_dir("corrupt");
        std::fs::write(dir.join("settings.json"), b"{not json").expect("write");
        let store = SettingsStore::open(&dir);
        assert_eq!(store.get(), ResourceSettings::default());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn revision_advances_on_save() {
        let dir = temp_dir("revision");
        let store = SettingsStore::open(&dir);
        let before = store.revision();
        store.save(ResourceSettings::default());
        assert!(store.revision() > before);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
