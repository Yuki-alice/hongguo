//! 供 `flutter_rust_bridge` 生成的 Dart 绑定调用的公开 API。
//!
//! 这一层只做「Dart 数据结构 ↔ 引擎内部类型」的转换，并负责初始化运行时。
//! 引擎本身不感知 Flutter，保持可独立测试。

use std::sync::Arc;

use crate::env::{FetchRequest, LogSink, SourceEnv, SourceStore};
use crate::rule::{RuleDocument, RuleExecutor};
use crate::script::QuickJsHost;
use crate::sources::builtin_registry;
use crate::transport::HttpTransport;
use crate::SourceError;
use crate::{Chapter, Drama, Page};

/// 初始化日志与运行时。Dart 侧在启动时调用一次。
pub fn init_engine() {
    flutter_rust_bridge::setup_default_user_utils();
}

/// 引擎版本，便于 Dart 侧自检与 Go 核心版本对齐。
pub fn engine_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// 内置站源清单，替代 Dart 侧硬编码的 `SourceSite` 列表。
pub fn source_catalog() -> Vec<SourceSummary> {
    builtin_registry()
        .metas()
        .into_iter()
        .map(|meta| SourceSummary {
            id: meta.id,
            name: meta.name,
            group: meta.group,
            api_level: meta.api_level,
            capabilities: meta
                .capabilities
                .iter()
                .map(|capability| format!("{capability:?}").to_lowercase())
                .collect(),
        })
        .collect()
}

/// Dart 可见的站源摘要。
pub struct SourceSummary {
    pub id: String,
    pub name: String,
    pub group: String,
    pub api_level: u32,
    pub capabilities: Vec<String>,
}

/// 用声明式规则解析目录 HTML。纯函数，不发起网络请求。
pub fn parse_catalog_with_rule(
    rule_json: String,
    html: String,
    page: u32,
) -> Result<DramaPage, String> {
    let rule = RuleDocument::from_json(&rule_json).map_err(|err| err.to_string())?;
    let parsed = RuleExecutor::new(&rule)
        .parse_catalog(&html, page)
        .map_err(|err| err.to_string())?;
    Ok(parsed.into())
}

/// 用声明式规则解析详情 HTML。
pub fn parse_detail_with_rule(
    rule_json: String,
    html: String,
    drama: DramaInput,
) -> Result<Vec<ChapterItem>, String> {
    let rule = RuleDocument::from_json(&rule_json).map_err(|err| err.to_string())?;
    let target: Drama = drama.into();
    let chapters = RuleExecutor::new(&rule)
        .parse_chapters(&html, &target)
        .map_err(|err| err.to_string())?;
    Ok(chapters.into_iter().map(ChapterItem::from).collect())
}

/// 校验规则 JSON，供编辑器即时提示。
pub fn validate_rule(rule_json: String) -> Result<String, String> {
    let rule = RuleDocument::from_json(&rule_json).map_err(|err| err.to_string())?;
    Ok(rule.id)
}

/// 拉取一个网页并解析为目录数据（真实网络）。
pub async fn fetch_catalog_with_rule(
    rule_json: String,
    page: u32,
    category: String,
) -> Result<DramaPage, String> {
    let rule = RuleDocument::from_json(&rule_json).map_err(|err| err.to_string())?;
    let catalog = rule
        .catalog
        .as_ref()
        .ok_or_else(|| "规则缺少 catalog 段".to_string())?;
    let path = rule.expand(&catalog.url, page, &category, "");
    let url = join_url(&rule.base, &path);

    let env = build_env("rule".to_string())?;
    let body = env
        .text(FetchRequest::get(&url).header("Referer", format!("{}/", rule.base)))
        .await
        .map_err(|err| err.to_string())?;
    let parsed = RuleExecutor::new(&rule)
        .parse_catalog(&body, page)
        .map_err(|err| err.to_string())?;
    Ok(parsed.into())
}

/// 目录缓存单例。
///
/// 缓存目录由 Dart 侧通过 `init_engine_with_directory` 指定；
/// 未指定时退回临时目录，保证纯函数测试可用。
fn cache() -> &'static crate::cache::CatalogCache {
    static INSTANCE: std::sync::OnceLock<crate::cache::CatalogCache> = std::sync::OnceLock::new();
    INSTANCE.get_or_init(|| {
        let directory = CACHE_DIRECTORY
            .get()
            .cloned()
            .unwrap_or_else(std::env::temp_dir);
        crate::cache::CatalogCache::open(directory)
    })
}

static CACHE_DIRECTORY: std::sync::OnceLock<std::path::PathBuf> = std::sync::OnceLock::new();

/// 指定缓存目录。必须在首次访问缓存前调用。
pub fn set_cache_directory(directory: String) -> bool {
    if CACHE_DIRECTORY.get().is_some() {
        return false;
    }
    CACHE_DIRECTORY
        .set(std::path::PathBuf::from(directory))
        .is_ok()
}

/// 读取缓存中的目录；未命中返回空。
pub fn cached_catalog(source_id: String, category: String) -> DramaPage {
    let key = crate::cache::catalog_key(&source_id, &category);
    let items = cache().items(&key);
    let state = cache().state(&key);
    DramaPage {
        items: items.into_iter().map(DramaItem::from).collect(),
        has_more: state.has_more,
        page: state.page.max(1),
        warning: state.warning,
    }
}

/// 缓存是否仍在有效期内。
pub fn catalog_is_fresh(source_id: String, category: String) -> bool {
    let key = crate::cache::catalog_key(&source_id, &category);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|value| value.as_secs())
        .unwrap_or(0);
    cache().state(&key).is_fresh(now)
}

/// 清空指定键的缓存。
pub fn clear_catalog(source_id: String, category: String) -> Result<(), String> {
    let key = crate::cache::catalog_key(&source_id, &category);
    cache().remove(&key).map_err(|err| err.to_string())
}

/// 按站源 id 读取目录。规则源与代码插件共用这一入口。
///
/// 这是 Dart 侧替换 Go `catalog` action 的对应实现。
pub async fn fetch_catalog(
    source_id: String,
    page: u32,
    category: String,
) -> Result<DramaPage, String> {
    let registry = builtin_registry();
    let source = registry
        .get(&source_id)
        .ok_or_else(|| format!("未知站源：{source_id}"))?;
    let env = build_env(source_id.clone())?;
    let parsed = source
        .catalog(&env, page, &category)
        .await
        .map_err(|err| err.to_string())?;

    // 成功结果写入缓存；写盘失败不影响本次返回。
    let _ = cache().store(
        &source_id,
        &category,
        page,
        parsed.items.clone(),
        parsed.has_more,
        &parsed.warning,
    );
    Ok(parsed.into())
}

/// 按站源 id 读取详情。
pub async fn fetch_detail(
    source_id: String,
    drama_source_id: String,
) -> Result<ChapterList, String> {
    let registry = builtin_registry();
    let source = registry
        .get(&source_id)
        .ok_or_else(|| format!("未知站源：{source_id}"))?;
    let env = build_env(source_id.clone())?;
    let detail = source
        .detail(&env, &drama_source_id)
        .await
        .map_err(|err| err.to_string())?;
    Ok(ChapterList {
        drama: DramaItem::from(detail.drama),
        chapters: detail.chapters.into_iter().map(ChapterItem::from).collect(),
    })
}

/// 按站源 id 搜索。
pub async fn fetch_search(
    source_id: String,
    query: String,
    page: u32,
) -> Result<DramaPage, String> {
    let registry = builtin_registry();
    let source = registry
        .get(&source_id)
        .ok_or_else(|| format!("未知站源：{source_id}"))?;
    let env = build_env(source_id)?;
    let parsed = source
        .search(&env, &query, page)
        .await
        .map_err(|err| err.to_string())?;
    Ok(parsed.into())
}

/// 按站源 id 读取分类清单。
///
/// 与 Go 侧一致，首项固定为「全部」；站源未声明分类时报错，由 Dart 侧回退。
pub async fn fetch_categories(source_id: String) -> Result<Vec<CategorySummary>, String> {
    let registry = builtin_registry();
    let source = registry
        .get(&source_id)
        .ok_or_else(|| format!("未知站源：{source_id}"))?;
    if !source
        .meta()
        .supports(crate::source::Capability::Categories)
    {
        return Err(format!("{source_id} 未提供分类清单"));
    }
    let env = build_env(source_id)?;
    let list = source
        .categories(&env)
        .await
        .map_err(|err| err.to_string())?;
    if list.is_empty() {
        return Err("站源暂未返回内容分类，请稍后重试".to_string());
    }
    let mut out = Vec::with_capacity(list.len() + 1);
    out.push(CategorySummary {
        id: String::new(),
        name: "全部".to_string(),
    });
    out.extend(list.into_iter().map(|entry| CategorySummary {
        id: entry.id,
        name: entry.name,
    }));
    Ok(out)
}

/// 站源分类项。
pub struct CategorySummary {
    pub id: String,
    pub name: String,
}

/// 取流：把分集地址解析为可播放地址。
///
/// 播放页会先抓取并提取媒体地址；HLS 会拉取播放列表并返回分片清单。
pub async fn fetch_media(source_id: String, chapter: ChapterInput) -> Result<MediaResult, String> {
    let registry = builtin_registry();
    let source = registry
        .get(&source_id)
        .ok_or_else(|| format!("未知站源：{source_id}"))?;
    let env = build_env(source_id)?;
    let drama = Drama {
        id: Drama::identity(&source.meta().id, &chapter.source_id),
        source: source.meta().id.clone(),
        source_id: chapter.source_id.clone(),
        ..Default::default()
    };
    let target = Chapter {
        id: chapter.id.clone(),
        title: chapter.title.clone(),
        source: chapter.source_id.clone(),
        video_url: chapter.video_url.clone(),
        page_url: chapter.page_url.clone(),
        referer: chapter.referer.clone(),
        ..Default::default()
    };
    let media = source
        .resolve(&env, &drama, &target)
        .await
        .map_err(|err| err.to_string())?;
    Ok(MediaResult {
        url: media.url,
        referer: media.referer,
        playlist: media.playlist.unwrap_or_default(),
        key_uri: media.key_uri,
        key_iv: media.key_iv,
    })
}

/// 下载任务快照，供 Dart 侧渲染。
pub struct DownloadSnapshot {
    pub id: String,
    pub drama_id: String,
    pub episode_id: String,
    pub title: String,
    pub state: String,
    pub bytes: u64,
    pub total: i64,
    pub progress: f64,
    pub error: String,
    pub revision: u64,
}

/// 全局下载调度器。
///
/// 进程内单例，避免 Dart 侧每次调用都重建任务表。
fn scheduler() -> &'static crate::scheduler::Scheduler {
    static INSTANCE: std::sync::OnceLock<crate::scheduler::Scheduler> = std::sync::OnceLock::new();
    INSTANCE.get_or_init(|| crate::scheduler::Scheduler::new(2))
}

/// 登记一个下载任务。
pub fn enqueue_download(request: DownloadRequest) -> u64 {
    let mut job = crate::scheduler::Job::new(request.id, request.target, request.url);
    job.referer = request.referer;
    job.title = request.title;
    job.segments = request.segments;
    job.key_uri = request.key_uri;
    job.key_iv = request.key_iv;
    scheduler().enqueue(job)
}

/// 下载登记参数。
pub struct DownloadRequest {
    pub id: String,
    pub url: String,
    pub target: String,
    pub referer: String,
    pub title: String,
    /// HLS 分片；非空时走分片下载。
    pub segments: Vec<String>,
    /// HLS AES-128 密钥地址。
    pub key_uri: String,
    /// HLS AES-128 的 IV。
    pub key_iv: String,
}

/// 执行一个已登记的任务。
pub async fn run_download(id: String) -> Result<u64, String> {
    let env = build_env("download".to_string())?;
    let outcome = scheduler()
        .run(&env, &id)
        .await
        .map_err(|err| err.to_string())?;
    Ok(match outcome {
        crate::download::DownloadOutcome::Completed(bytes) => bytes,
        crate::download::DownloadOutcome::Restart => 0,
    })
}

/// 当前所有下载任务。
pub fn download_snapshot() -> Vec<DownloadSnapshot> {
    scheduler()
        .snapshot()
        .into_iter()
        .map(|job| {
            let progress = job.progress();
            DownloadSnapshot {
                id: job.id,
                drama_id: job.drama_id,
                episode_id: job.episode_id,
                title: job.title,
                state: job.state.as_str().to_string(),
                bytes: job.bytes,
                total: job.total,
                progress,
                error: job.error,
                revision: job.revision,
            }
        })
        .collect()
}

/// 暂停 / 继续 / 重试 / 删除。
pub fn control_download(command: String, id: String) -> bool {
    scheduler().control(&command, &id)
}

/// 取流输入。
pub struct ChapterInput {
    pub id: String,
    pub title: String,
    pub source_id: String,
    pub video_url: String,
    pub page_url: String,
    pub referer: String,
}

/// 取流结果。
pub struct MediaResult {
    pub url: String,
    pub referer: String,
    pub playlist: Vec<String>,
    /// HLS AES-128 密钥地址。
    pub key_uri: String,
    /// HLS AES-128 的 IV。
    pub key_iv: String,
}

/// 详情结果。
pub struct ChapterList {
    pub drama: DramaItem,
    pub chapters: Vec<ChapterItem>,
}

/// 站源元信息，用于 Dart 侧动态构建站源列表。
pub struct DramaInput {
    pub id: String,
    pub source: String,
    pub source_id: String,
    pub title: String,
}

impl From<DramaInput> for Drama {
    fn from(input: DramaInput) -> Self {
        Drama {
            id: input.id,
            source: input.source,
            source_id: input.source_id,
            title: input.title,
            ..Default::default()
        }
    }
}

/// 分页结果。
pub struct DramaPage {
    pub items: Vec<DramaItem>,
    pub has_more: bool,
    pub page: u32,
    pub warning: String,
}

impl From<Page> for DramaPage {
    fn from(page: Page) -> Self {
        Self {
            items: page.items.into_iter().map(DramaItem::from).collect(),
            has_more: page.has_more,
            page: page.page,
            warning: page.warning,
        }
    }
}

/// 单条剧目。
pub struct DramaItem {
    pub id: String,
    pub source: String,
    pub source_id: String,
    pub title: String,
    pub description: String,
    pub cover: String,
    pub episodes: u32,
    pub category: String,
    pub vip: Option<bool>,
    pub heat: String,
    pub views: String,
    pub online_date: String,
    pub tags: Vec<String>,
    pub release_status: String,
}

impl From<Drama> for DramaItem {
    fn from(drama: Drama) -> Self {
        Self {
            id: drama.id,
            source: drama.source,
            source_id: drama.source_id,
            title: drama.title,
            description: drama.description,
            cover: drama.cover,
            episodes: drama.episodes,
            category: drama.category,
            vip: drama.vip,
            heat: drama.heat,
            views: drama.views,
            online_date: drama.online_date,
            tags: drama.tags,
            release_status: drama.release_status,
        }
    }
}

/// 单个分集。
pub struct ChapterItem {
    pub id: String,
    pub title: String,
    pub source: String,
    pub video_url: String,
    pub page_url: String,
    pub referer: String,
}

impl From<Chapter> for ChapterItem {
    fn from(chapter: Chapter) -> Self {
        Self {
            id: chapter.id,
            title: chapter.title,
            source: chapter.source,
            video_url: chapter.video_url,
            page_url: chapter.page_url,
            referer: chapter.referer,
        }
    }
}

#[flutter_rust_bridge::frb(ignore)]
struct MemoryStore {}

#[async_trait::async_trait]
impl SourceStore for MemoryStore {
    async fn get(&self, _key: &str) -> Result<Option<String>, SourceError> {
        Ok(None)
    }
    async fn set(&self, _key: &str, _value: &str) -> Result<(), SourceError> {
        Ok(())
    }
}

#[flutter_rust_bridge::frb(ignore)]
struct SilentLog {}

impl LogSink for SilentLog {
    fn debug(&self, _message: &str) {}
    fn warn(&self, _message: &str) {}
}

/// 构造站源执行环境。
///
/// 传输层构建失败属于可上报的环境错误，不在此处 panic（C-UNWRAP）。
/// 供示例与集成测试构造执行环境。
pub fn debug_env(source_id: String) -> Result<SourceEnv, String> {
    build_env(source_id)
}

fn build_env(source_id: String) -> Result<SourceEnv, String> {
    let transport = HttpTransport::global().map_err(|err| err.to_string())?;
    Ok(SourceEnv {
        source_id,
        transport,
        store: Arc::new(MemoryStore {}),
        scripts: Some(Arc::new(QuickJsHost::new())),
        log: Arc::new(SilentLog {}),
    })
}

fn join_url(base: &str, path: &str) -> String {
    if path.starts_with("http") {
        return path.to_string();
    }
    format!(
        "{}/{}",
        base.trim_end_matches('/'),
        path.trim_start_matches('/')
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_is_reported() {
        assert!(!engine_version().is_empty());
    }

    #[test]
    fn catalog_lists_builtin_sources() {
        let catalog = source_catalog();
        assert!(catalog.iter().any(|entry| entry.id == "maoguo"));
        assert!(catalog.iter().any(|entry| entry.id == "heguo"));
        assert!(catalog
            .iter()
            .all(|entry| entry.api_level >= 1 && !entry.capabilities.is_empty()));
    }

    #[tokio::test]
    async fn categories_start_with_all_entry() {
        let list = fetch_categories("fanguo".into()).await.expect("分类");
        assert_eq!(list[0].name, "全部");
        assert_eq!(list[0].id, "");
        assert_eq!(list.len(), 8);
        assert!(list.iter().any(|entry| entry.id == "萌宝"));
        assert!(fetch_categories("heguo".into()).await.is_ok());
        assert!(fetch_categories("maoguo".into()).await.is_err());
    }

    #[test]
    fn rule_validation_rejects_broken_json() {
        assert!(validate_rule("{".into()).is_err());
    }

    #[test]
    fn rule_validation_accepts_valid_document() {
        let text = include_str!("../../rules/wuguo.json");
        assert_eq!(validate_rule(text.into()).expect("valid"), "wuguo");
    }

    #[test]
    fn parse_catalog_is_pure_and_deterministic() {
        let rule = include_str!("../../rules/wuguo.json").to_string();
        let html = include_str!("../tests/fixtures/wuguo_catalog.html").to_string();
        let first = parse_catalog_with_rule(rule.clone(), html.clone(), 1).expect("parse");
        let second = parse_catalog_with_rule(rule, html, 1).expect("parse");
        assert_eq!(first.items.len(), second.items.len());
        assert!(!first.items.is_empty());
    }

    #[test]
    fn join_url_handles_both_forms() {
        assert_eq!(join_url("https://a.test", "/b"), "https://a.test/b");
        assert_eq!(
            join_url("https://a.test/", "http://c.test/x"),
            "http://c.test/x"
        );
    }
}
