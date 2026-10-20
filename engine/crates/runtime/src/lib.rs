//! 运行时：注册表、目录缓存、下载调度。
//!
//! 站源实现（规则源、代码插件）在这里被装配成对外的统一入口；
//! 网络与脚本能力来自 `guo-host`，纯解析来自 `guo-rule-engine`。

mod cache;
mod download;
mod plugins;
mod repo_client;
mod rule_source;
mod scheduler;

pub use cache::{catalog_key, merge, replace_first_page, CatalogCache, CatalogDisk, CatalogState};
pub use download::{
    commit, discard, download_file, download_hls, playlist_signature, DownloadOutcome, FileState,
    HlsKey,
};
pub use plugins::{load_installed, plugin_root, ComponentLoader, LoadReport};
pub use repo_client::{join_url, precheck_entry, FetchedIndex, RepoClient};
pub use rule_source::RuleSource;
pub use scheduler::{Job, JobState, Scheduler};
