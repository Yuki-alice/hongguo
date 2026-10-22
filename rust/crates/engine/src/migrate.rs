//! Go 下载索引的只读迁移。
//!
//! 旧版 App 把下载任务记在 `<app support>/downloads/index.json`，结构是
//! `nativeDownloadRecord[]`。切到引擎后这些文件仍在磁盘上，用户期望它们
//! 还能播。这个模块**只读**旧索引，把「已完成」的条目转成引擎任务表：
//!
//! - 不修改、不删除旧文件（迁移失败时用户仍能回到旧版本）；
//! - 只迁移 `completed` 且文件确实存在的条目；
//! - 目录布局与旧版一致：`<root>/<folder 或 id>/<file>`。
//!
//! 迁移是幂等的：引擎任务表按 id 去重，重复导入不会产生重复任务。

use std::path::{Path, PathBuf};

use serde::Deserialize;

use guo_runtime::{Job, JobState, Scheduler};

/// 旧索引的单个条目。只声明迁移需要的字段，其余忽略。
///
/// 字段名与 Go 结构体一致（camelCase）。
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LegacyRecord {
    id: String,
    drama: LegacyDrama,
    chapter: LegacyChapter,
    #[serde(default)]
    state: String,
    #[serde(default)]
    archived: bool,
    #[serde(default)]
    folder: String,
    /// `media.mp4` / `index.m3u8`；为空表示没有可播放文件。
    #[serde(default)]
    file: String,
    #[serde(default)]
    bytes: i64,
    #[serde(default)]
    error: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LegacyDrama {
    #[serde(default)]
    id: String,
    #[serde(default)]
    title: String,
}

#[derive(Debug, Deserialize)]
struct LegacyChapter {
    #[serde(default)]
    id: String,
    #[serde(default)]
    title: String,
}

/// 迁移结果。
#[derive(Debug, Default, PartialEq, Eq)]
pub struct MigrationReport {
    /// 成功登记的条目数。
    pub imported: usize,
    /// 跳过原因 → 条数。用于诊断页展示，不暴露给普通用户。
    pub skipped: Vec<(String, usize)>,
    /// 旧索引是否被读取。
    pub found: bool,
}

impl MigrationReport {
    fn skip(&mut self, reason: &str) {
        if let Some(entry) = self.skipped.iter_mut().find(|(name, _)| name == reason) {
            entry.1 += 1;
        } else {
            self.skipped.push((reason.to_string(), 1));
        }
    }
}

/// 旧索引路径：`<download root>/index.json`。
pub fn legacy_index_path(download_root: impl AsRef<Path>) -> PathBuf {
    download_root.as_ref().join("index.json")
}

/// 把旧索引里的已完成任务导入调度器。
///
/// `download_root` 是旧版下载目录（`NativeRepository.storage()['directory']`）。
/// 索引缺失或损坏时返回 `found: false`，不产生错误——旧数据不可读不应该
/// 拦住应用启动。
pub fn import_legacy_index(
    download_root: impl AsRef<Path>,
    scheduler: &Scheduler,
) -> MigrationReport {
    let root = download_root.as_ref();
    let path = legacy_index_path(root);
    let mut report = MigrationReport::default();
    let Ok(bytes) = std::fs::read(&path) else {
        return report;
    };
    // 旧版同样限制 32 MiB；超过说明文件异常，直接放弃。
    if bytes.len() > 32 * 1024 * 1024 {
        return report;
    }
    let Ok(records) = serde_json::from_slice::<Vec<LegacyRecord>>(&bytes) else {
        return report;
    };
    report.found = true;

    for record in records {
        if record.state != "completed" {
            report.skip("未完成");
            continue;
        }
        if record.archived {
            report.skip("已归档");
            continue;
        }
        if record.file.is_empty() {
            report.skip("无媒体文件");
            continue;
        }
        let directory = if record.folder.is_empty() {
            root.join(&record.id)
        } else {
            root.join(record.folder.replace('\\', "/"))
        };
        let file = directory.join(&record.file);
        if !file.is_file() {
            report.skip("文件不存在");
            continue;
        }

        let mut job = Job::new(
            record.id.clone(),
            file.to_string_lossy().to_string(),
            String::new(),
        );
        job.drama_id = record.drama.id;
        job.episode_id = record.chapter.id;
        job.title = if record.chapter.title.is_empty() {
            record.drama.title
        } else {
            record.chapter.title
        };
        job.state = JobState::Completed;
        job.bytes = record.bytes.max(0) as u64;
        job.total = job.bytes as i64;
        job.error = record.error;
        scheduler.enqueue(job);
        report.imported += 1;
    }
    report
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_root(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "guo-legacy-{name}-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|value| value.as_nanos())
                .unwrap_or(0)
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("dir");
        dir
    }

    fn write_index(root: &Path, records: &str) {
        std::fs::write(root.join("index.json"), records).expect("write index");
    }

    #[test]
    fn imports_completed_records_with_existing_files() {
        let root = temp_root("import");
        std::fs::create_dir_all(root.join("job1")).expect("dir");
        std::fs::write(root.join("job1/media.mp4"), b"data").expect("file");
        write_index(
            &root,
            r#"[{
                "id":"job1",
                "drama":{"id":"hongguo:1","title":"剧"},
                "chapter":{"id":"ep1","title":"第1集"},
                "index":1,
                "state":"completed",
                "file":"media.mp4",
                "bytes":4
            }]"#,
        );
        let index = root.join("engine-index.json");
        let scheduler = Scheduler::open(2, &index);
        let report = import_legacy_index(&root, &scheduler);

        assert!(report.found);
        assert_eq!(report.imported, 1);
        let job = scheduler.get("job1").expect("job");
        assert_eq!(job.state, JobState::Completed);
        assert_eq!(job.drama_id, "hongguo:1");
        assert_eq!(job.episode_id, "ep1");
        assert!(job.target.ends_with("media.mp4"));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn skips_unfinished_archived_and_missing_files() {
        let root = temp_root("skip");
        write_index(
            &root,
            r#"[
                {"id":"a","drama":{"id":"d"},"chapter":{},"index":1,"state":"paused","file":"media.mp4"},
                {"id":"b","drama":{"id":"d"},"chapter":{},"index":2,"state":"completed","archived":true,"file":"media.mp4"},
                {"id":"c","drama":{"id":"d"},"chapter":{},"index":3,"state":"completed","file":"media.mp4"},
                {"id":"dd","drama":{"id":"d"},"chapter":{},"index":4,"state":"completed","file":""}
            ]"#,
        );
        let scheduler = Scheduler::open(2, root.join("engine-index.json"));
        let report = import_legacy_index(&root, &scheduler);
        assert!(report.found);
        assert_eq!(report.imported, 0);
        let reasons: Vec<&str> = report.skipped.iter().map(|(r, _)| r.as_str()).collect();
        assert!(reasons.contains(&"未完成"), "{reasons:?}");
        assert!(reasons.contains(&"已归档"), "{reasons:?}");
        assert!(reasons.contains(&"文件不存在"), "{reasons:?}");
        assert!(reasons.contains(&"无媒体文件"), "{reasons:?}");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn missing_index_is_not_an_error() {
        let root = temp_root("missing");
        let scheduler = Scheduler::open(2, root.join("engine-index.json"));
        let report = import_legacy_index(&root, &scheduler);
        assert!(!report.found);
        assert_eq!(report.imported, 0);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn corrupt_index_is_not_an_error() {
        let root = temp_root("corrupt");
        write_index(&root, "{not json");
        let scheduler = Scheduler::open(2, root.join("engine-index.json"));
        let report = import_legacy_index(&root, &scheduler);
        assert!(!report.found);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn migration_is_idempotent() {
        let root = temp_root("idempotent");
        std::fs::create_dir_all(root.join("job1")).expect("dir");
        std::fs::write(root.join("job1/media.mp4"), b"data").expect("file");
        write_index(
            &root,
            r#"[{"id":"job1","drama":{"id":"d"},"chapter":{},"index":1,"state":"completed","file":"media.mp4","bytes":4}]"#,
        );
        let scheduler = Scheduler::open(2, root.join("engine-index.json"));
        assert_eq!(import_legacy_index(&root, &scheduler).imported, 1);
        // 第二次导入不应产生重复任务。
        import_legacy_index(&root, &scheduler);
        assert_eq!(scheduler.snapshot().len(), 1);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn uses_folder_layout_when_recorded() {
        let root = temp_root("folder");
        std::fs::create_dir_all(root.join("huangju/job1")).expect("dir");
        std::fs::write(root.join("huangju/job1/index.m3u8"), b"#EXTM3U").expect("file");
        write_index(
            &root,
            r#"[{"id":"job1","drama":{"id":"d"},"chapter":{},"index":1,"state":"completed","folder":"huangju/job1","file":"index.m3u8"}]"#,
        );
        let scheduler = Scheduler::open(2, root.join("engine-index.json"));
        assert_eq!(import_legacy_index(&root, &scheduler).imported, 1);
        let job = scheduler.get("job1").expect("job");
        // 旧索引里的 folder 用正斜杠，落到磁盘路径后由平台决定分隔符：
        // Windows 上是 `huangju\job1\index.m3u8`，所以比较 Path 而不是字符串。
        let expected = root.join("huangju").join("job1").join("index.m3u8");
        assert_eq!(PathBuf::from(&job.target), expected, "{}", job.target);
        let _ = std::fs::remove_dir_all(&root);
    }
}
