//! 供 `flutter_rust_bridge` 生成的 Dart 绑定调用的公开 API。
//!
//! 这一层只做「Dart 数据结构 ↔ 引擎内部类型」的转换。所有状态都挂在
//! `guo_engine_core::Engine` 单例上：注册表、会话存储、目录缓存、下载调度器
//! 在进程内只装配一次，站源实例因此跨 FRB 调用复用（Core-1）。
//!
//! 失败一律返回 [`EngineError`]，不再用 `String`（ADR-8）。`request_id`
//! 由调用方传入，取消语义见 `guo_engine_core::CancellationRegistry`（ADR-9）。
//!
//! 子模块按域拆分：插件安装见 [`plugins`]，站源取数仍在本文件。

pub mod error;
pub mod plugins;

use std::sync::Arc;
use std::time::Duration;

use guo_engine_core::{
    DownloadEvent, Engine, EngineConfig, EngineError, EngineErrorKind, RequestTicket,
};

use crate::api::error::EngineFailure;
use guo_runtime::{catalog_key, DownloadOutcome, Job};
use guo_source_api::{
    Capability, Chapter, Drama, FetchRequest, Page, RecommendCursor, SourcePlugin, SourceRegistry,
};

use crate::sources::register_builtin_sources;

/// 各动作的默认超时。
///
/// 目录 / 详情 / 搜索是用户等待的交互路径，15 秒足够；取流与下载要拉
/// 播放列表或分片，放宽到 30 秒；元数据补全不阻塞首屏，给 20 秒。
fn timeout_for(action: &str) -> Duration {
    match action {
        "resolve" | "download" => Duration::from_secs(30),
        "metadata" | "preload" => Duration::from_secs(20),
        _ => Duration::from_secs(15),
    }
}

/// 初始化日志与运行时。Dart 侧在启动时调用一次。
pub fn init_engine() {
    flutter_rust_bridge::setup_default_user_utils();
}

/// 初始化进程级引擎。重复调用返回既有实例并报告 `false`。
///
/// `data_directory` 下会创建 `catalogs.json`、`sessions.json` 与 `plugins/`；
/// `plugin_directory` 传空字符串表示用默认值 `<data>/plugins`。
pub fn init_engine_with_directory(
    data_directory: String,
    plugin_directory: String,
) -> Result<EngineInitResult, EngineFailure> {
    let mut config = EngineConfig::new(data_directory);
    if !plugin_directory.trim().is_empty() {
        config = config.with_plugin_directory(plugin_directory);
    }
    let (engine, fresh) = guo_engine_core::initialize(config, register_builtin_sources)
        .map_err(EngineFailure::from)?;
    Ok(EngineInitResult {
        version: engine_version(),
        data_directory: engine.config().data_directory.display().to_string(),
        plugin_directory: engine.config().plugin_directory.display().to_string(),
        fresh,
        source_count: engine.registry().len() as u32,
    })
}

/// 初始化结果，供 Dart 侧确认路径与首次装配状态。
pub struct EngineInitResult {
    pub version: String,
    pub data_directory: String,
    pub plugin_directory: String,
    /// 是否为本次调用首次装配。
    pub fresh: bool,
    pub source_count: u32,
}

/// 引擎版本，便于 Dart 侧自检与发布物对齐。
pub fn engine_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// 当前引擎；未初始化时报错而不是 panic。
fn engine() -> Result<Arc<Engine>, EngineFailure> {
    guo_engine_core::require().map_err(EngineFailure::from)
}

/// 取站源并构造执行环境。
fn prepare(
    source_id: &str,
) -> Result<(Arc<dyn SourcePlugin>, guo_source_api::SourceEnv), EngineFailure> {
    let engine = engine()?;
    let source = engine.source(source_id).map_err(EngineFailure::from)?;
    Ok((source, engine.env(source_id)))
}

/// 包一层超时与错误映射：站源错误补上 `source_id` / `request_id`。
async fn run<T, F>(
    source_id: &str,
    request_id: &str,
    action: &str,
    work: F,
) -> Result<T, EngineFailure>
where
    F: std::future::Future<Output = Result<T, guo_source_api::SourceError>>,
{
    match tokio::time::timeout(timeout_for(action), work).await {
        Ok(Ok(value)) => Ok(value),
        Ok(Err(error)) => Err(EngineFailure::from(EngineError::from_source(
            &error, source_id, request_id,
        ))),
        Err(_) => Err(EngineFailure::from(
            guo_engine_core::timeout_error(request_id, timeout_for(action)).with_source(source_id),
        )),
    }
}

/// 内置站源清单，Dart 源列表的唯一来源。
pub fn source_catalog() -> Result<Vec<SourceSummary>, EngineFailure> {
    let engine = engine()?;
    Ok(engine
        .registry()
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
        .collect())
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
) -> Result<DramaPage, EngineFailure> {
    let rule = guo_rule_engine::RuleDocument::from_json(&rule_json).map_err(|err| {
        EngineFailure::from(EngineError::new(
            EngineErrorKind::ParseChanged,
            err.to_string(),
        ))
    })?;
    let parsed = guo_rule_engine::RuleExecutor::new(&rule)
        .parse_catalog(&html, page)
        .map_err(|err| EngineFailure::from(EngineError::from(&err)))?;
    Ok(parsed.into())
}

/// 用声明式规则解析详情 HTML。
pub fn parse_detail_with_rule(
    rule_json: String,
    html: String,
    drama: DramaInput,
) -> Result<Vec<ChapterItem>, EngineFailure> {
    let rule = guo_rule_engine::RuleDocument::from_json(&rule_json).map_err(|err| {
        EngineFailure::from(EngineError::new(
            EngineErrorKind::ParseChanged,
            err.to_string(),
        ))
    })?;
    let target: Drama = drama.into();
    let chapters = guo_rule_engine::RuleExecutor::new(&rule)
        .parse_chapters(&html, &target)
        .map_err(|err| EngineFailure::from(EngineError::from(&err)))?;
    Ok(chapters.into_iter().map(ChapterItem::from).collect())
}

/// 校验规则 JSON，供编辑器即时提示。返回规则 id。
pub fn validate_rule(rule_json: String) -> Result<String, EngineFailure> {
    let rule = guo_rule_engine::RuleDocument::from_json(&rule_json).map_err(|err| {
        EngineFailure::from(EngineError::new(
            EngineErrorKind::ParseChanged,
            err.to_string(),
        ))
    })?;
    Ok(rule.id)
}

/// 拉取一个网页并解析为目录数据（真实网络）。
pub async fn fetch_catalog_with_rule(
    rule_json: String,
    page: u32,
    category: String,
) -> Result<DramaPage, EngineFailure> {
    let rule = guo_rule_engine::RuleDocument::from_json(&rule_json).map_err(|err| {
        EngineFailure::from(EngineError::new(
            EngineErrorKind::ParseChanged,
            err.to_string(),
        ))
    })?;
    let catalog = rule
        .catalog
        .as_ref()
        .ok_or_else(|| EngineFailure::from(EngineError::unsupported("规则缺少 catalog 段")))?;
    let path = rule.expand(&catalog.url, page, &category, "");
    let url = join_url(&rule.base, &path);

    let env = engine()?.env("rule");
    let body = run("rule", "", "catalog", async {
        env.text(FetchRequest::get(&url).header("Referer", format!("{}/", rule.base)))
            .await
    })
    .await?;
    let parsed = guo_rule_engine::RuleExecutor::new(&rule)
        .parse_catalog(&body, page)
        .map_err(|err| EngineFailure::from(EngineError::from(&err)))?;
    Ok(parsed.into())
}

/// 读取缓存中的目录；未命中返回空。
pub fn cached_catalog(source_id: String, category: String) -> Result<DramaPage, EngineFailure> {
    let engine = engine()?;
    let cache = engine.cache();
    let key = catalog_key(&source_id, &category);
    let items = cache.items(&key);
    let state = cache.state(&key);
    Ok(DramaPage {
        items: items.into_iter().map(DramaItem::from).collect(),
        has_more: state.has_more,
        page: state.page.max(1),
        warning: state.warning,
    })
}

/// 缓存是否仍在有效期内。
pub fn catalog_is_fresh(source_id: String, category: String) -> Result<bool, EngineFailure> {
    let engine = engine()?;
    let cache = engine.cache();
    let key = catalog_key(&source_id, &category);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|value| value.as_secs())
        .unwrap_or(0);
    Ok(cache.state(&key).is_fresh(now))
}

/// 清空指定键的缓存。
pub fn clear_catalog(source_id: String, category: String) -> Result<(), EngineFailure> {
    let engine = engine()?;
    let cache = engine.cache();
    let key = catalog_key(&source_id, &category);
    cache
        .remove(&key)
        .map_err(|err| EngineFailure::from(EngineError::from_source(&err, &source_id, "")))
}

/// 按站源 id 读取目录。
///
/// `request_id` 由调用方生成；同一 `session` 上的新请求会作废旧请求，
/// 旧请求返回 `Cancelled`（ADR-9）。
pub async fn fetch_catalog(
    source_id: String,
    page: u32,
    category: String,
    request_id: String,
    session: String,
) -> Result<DramaPage, EngineFailure> {
    let engine = engine()?;
    let ticket = engine.begin(&session, &request_id);
    let result = catalog_inner(&engine, &source_id, page, &category, &ticket).await;
    engine.finish(&ticket);
    result
}

async fn catalog_inner(
    engine: &Engine,
    source_id: &str,
    page: u32,
    category: &str,
    ticket: &RequestTicket,
) -> Result<DramaPage, EngineFailure> {
    let (source, env) = prepare(source_id)?;
    let parsed = run(source_id, &ticket.request_id, "catalog", async {
        source.catalog(&env, page, category).await
    })
    .await?;
    engine.cancel_registry().ensure_active(ticket)?;
    // 成功结果写入缓存；写盘失败不影响本次返回。
    let _ = engine.cache().store(
        source_id,
        category,
        page,
        parsed.items.clone(),
        parsed.has_more,
        &parsed.warning,
    );
    Ok(parsed.into())
}

/// 取消某个会话的当前请求。返回是否真的取消了在途请求。
pub fn cancel_request(session: String) -> Result<bool, EngineFailure> {
    Ok(engine()?.cancel(&session).is_some())
}

/// 按站源 id 读取详情。
pub async fn fetch_detail(
    source_id: String,
    drama_source_id: String,
    request_id: String,
) -> Result<ChapterList, EngineFailure> {
    let engine = engine()?;
    let ticket = engine.begin("detail", &request_id);
    let result = detail_inner(&engine, &source_id, &drama_source_id, &ticket).await;
    engine.finish(&ticket);
    result
}

async fn detail_inner(
    engine: &Engine,
    source_id: &str,
    drama_source_id: &str,
    ticket: &RequestTicket,
) -> Result<ChapterList, EngineFailure> {
    let (source, env) = prepare(source_id)?;
    let detail = run(source_id, &ticket.request_id, "detail", async {
        source.detail(&env, drama_source_id).await
    })
    .await?;
    engine.cancel_registry().ensure_active(ticket)?;
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
    request_id: String,
) -> Result<DramaPage, EngineFailure> {
    let engine = engine()?;
    let ticket = engine.begin("search", &request_id);
    let result = search_inner(&engine, &source_id, &query, page, &ticket).await;
    engine.finish(&ticket);
    result
}

async fn search_inner(
    engine: &Engine,
    source_id: &str,
    query: &str,
    page: u32,
    ticket: &RequestTicket,
) -> Result<DramaPage, EngineFailure> {
    let (source, env) = prepare(source_id)?;
    let parsed = run(source_id, &ticket.request_id, "search", async {
        source.search(&env, query, page).await
    })
    .await?;
    engine.cancel_registry().ensure_active(ticket)?;
    Ok(parsed.into())
}

/// 按站源 id 读取分类清单。
///
/// 与 Go 侧一致，首项固定为「全部」；站源未声明分类能力时报 `Unsupported`，
/// 由 Dart 侧回退到缓存或隐藏筛选。
pub async fn fetch_categories(
    source_id: String,
    request_id: String,
) -> Result<Vec<CategorySummary>, EngineFailure> {
    let engine = engine()?;
    let ticket = engine.begin("categories", &request_id);
    let result = categories_inner(&engine, &source_id, &ticket).await;
    engine.finish(&ticket);
    result
}

async fn categories_inner(
    engine: &Engine,
    source_id: &str,
    ticket: &RequestTicket,
) -> Result<Vec<CategorySummary>, EngineFailure> {
    let (source, env) = prepare(source_id)?;
    if !source.meta().supports(Capability::Categories) {
        return Err(EngineFailure::from(
            EngineError::unsupported(format!("{source_id} 未提供分类清单"))
                .with_source(source_id)
                .with_request_id(&ticket.request_id),
        ));
    }
    let list = run(source_id, &ticket.request_id, "categories", async {
        source.categories(&env).await
    })
    .await?;
    engine.cancel_registry().ensure_active(ticket)?;
    if list.is_empty() {
        return Err(EngineFailure::from(
            EngineError::new(
                EngineErrorKind::ParseChanged,
                "站源暂未返回内容分类，请稍后重试",
            )
            .with_source(source_id)
            .with_request_id(&ticket.request_id),
        ));
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
pub async fn fetch_media(
    source_id: String,
    chapter: ChapterInput,
    request_id: String,
) -> Result<MediaResult, EngineFailure> {
    let engine = engine()?;
    let ticket = engine.begin("resolve", &request_id);
    let result = media_inner(&engine, &source_id, chapter, &ticket).await;
    engine.finish(&ticket);
    result
}

async fn media_inner(
    engine: &Engine,
    source_id: &str,
    chapter: ChapterInput,
    ticket: &RequestTicket,
) -> Result<MediaResult, EngineFailure> {
    let (source, env) = prepare(source_id)?;
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
    let media = run(source_id, &ticket.request_id, "resolve", async {
        source.resolve(&env, &drama, &target).await
    })
    .await?;
    engine.cancel_registry().ensure_active(ticket)?;
    Ok(MediaResult {
        url: media.url,
        referer: media.referer,
        playlist: media.playlist.unwrap_or_default(),
        key_uri: media.key_uri,
        key_iv: media.key_iv,
        cookies: media.cookies,
        origin: media.origin,
    })
}

/// 榜单看板列表。
pub async fn fetch_ranking_boards(
    source_id: String,
    request_id: String,
) -> Result<Vec<RankingBoardItem>, EngineFailure> {
    let (source, env) = prepare(&source_id)?;
    let boards = run(&source_id, &request_id, "ranking", async {
        source.ranking_boards(&env).await
    })
    .await?;
    Ok(boards
        .into_iter()
        .map(|board| RankingBoardItem {
            id: board.id,
            name: board.name,
            group: board.group,
        })
        .collect())
}

/// 榜单的一页。
pub async fn fetch_ranking(
    source_id: String,
    board_id: String,
    page: u32,
    request_id: String,
) -> Result<RankingResult, EngineFailure> {
    let (source, env) = prepare(&source_id)?;
    let result = run(&source_id, &request_id, "ranking", async {
        source.ranking(&env, &board_id, page).await
    })
    .await?;
    Ok(RankingResult {
        items: result
            .items
            .into_iter()
            .map(|item| RankingEntry {
                rank: item.rank,
                drama: DramaItem::from(item.drama),
                metric: item.metric,
            })
            .collect(),
        has_more: result.has_more,
        page: result.page,
        updated_text: result.updated_text,
        stale: result.stale,
        warning: result.warning,
    })
}

/// 推荐流的一页。
pub async fn fetch_recommend(
    source_id: String,
    offset: u32,
    session_id: String,
    genre: String,
    request_id: String,
) -> Result<RecommendResult, EngineFailure> {
    let (source, env) = prepare(&source_id)?;
    let cursor = RecommendCursor {
        offset,
        session_id,
        genre,
    };
    let page = run(&source_id, &request_id, "recommend", async {
        source.recommend(&env, &cursor).await
    })
    .await?;
    Ok(RecommendResult {
        items: page.items.into_iter().map(DramaItem::from).collect(),
        offset: page.cursor.offset,
        session_id: page.cursor.session_id,
        has_more: page.has_more,
    })
}

/// 搜索联想词。
pub async fn fetch_suggestions(
    source_id: String,
    keyword: String,
    request_id: String,
) -> Result<Vec<String>, EngineFailure> {
    let (source, env) = prepare(&source_id)?;
    let items = run(&source_id, &request_id, "suggestions", async {
        source.suggestions(&env, &keyword).await
    })
    .await?;
    Ok(items.into_iter().map(|item| item.name).collect())
}

/// 一集的分段弹幕。
pub async fn fetch_danmaku(
    source_id: String,
    chapter: ChapterInput,
    start_ms: i64,
    request_id: String,
) -> Result<Vec<DanmakuItem>, EngineFailure> {
    let (source, env) = prepare(&source_id)?;
    let target = Chapter {
        id: chapter.id,
        title: chapter.title,
        source: chapter.source_id,
        video_url: chapter.video_url,
        page_url: chapter.page_url,
        referer: chapter.referer,
        ..Default::default()
    };
    let page = run(&source_id, &request_id, "danmaku", async {
        source.danmaku(&env, &target, start_ms).await
    })
    .await?;
    Ok(page
        .items
        .into_iter()
        .map(|item| DanmakuItem {
            time_ms: item.time_ms,
            text: item.text,
            color: item.color,
        })
        .collect())
}

/// 找出同一部剧的其它季。
pub async fn fetch_seasons(
    source_id: String,
    drama: DramaInput,
    request_id: String,
) -> Result<Vec<SeasonItem>, EngineFailure> {
    let (source, env) = prepare(&source_id)?;
    let target: Drama = drama.into();
    let seasons = run(&source_id, &request_id, "seasons", async {
        source.seasons(&env, &target).await
    })
    .await?;
    Ok(seasons
        .into_iter()
        .map(|item| SeasonItem {
            season: item.season,
            title: item.title,
            source_id: item.source_id,
        })
        .collect())
}

/// 榜单看板。
pub struct RankingBoardItem {
    pub id: String,
    pub name: String,
    pub group: String,
}

/// 榜单条目。
pub struct RankingEntry {
    pub rank: u32,
    pub drama: DramaItem,
    pub metric: String,
}

/// 榜单的一页。
pub struct RankingResult {
    pub items: Vec<RankingEntry>,
    pub has_more: bool,
    pub page: u32,
    pub updated_text: String,
    pub stale: bool,
    pub warning: String,
}

/// 推荐流的一页。
pub struct RecommendResult {
    pub items: Vec<DramaItem>,
    pub offset: u32,
    pub session_id: String,
    pub has_more: bool,
}

/// 一条弹幕。
pub struct DanmakuItem {
    pub time_ms: i64,
    pub text: String,
    pub color: String,
}

/// 一季。
pub struct SeasonItem {
    pub season: u32,
    pub title: String,
    pub source_id: String,
}

/// 下载进度事件：由引擎主动推送，替代 Dart 侧轮询快照。
pub struct DownloadProgressEvent {
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

impl From<guo_engine_core::DownloadEvent> for DownloadProgressEvent {
    fn from(event: guo_engine_core::DownloadEvent) -> Self {
        Self {
            id: event.id,
            drama_id: event.drama_id,
            episode_id: event.episode_id,
            title: event.title,
            state: event.state,
            bytes: event.bytes,
            total: event.total,
            progress: event.progress,
            error: event.error,
            revision: event.revision,
        }
    }
}

/// 订阅下载进度。
///
/// 先补发一次当前全部任务（迟到订阅者不会从 0 开始），随后持续推送状态变化。
/// 引擎未初始化时立即以 `Internal` 结束流，不 panic。
pub fn download_progress_stream(
    sink: crate::frb_generated::StreamSink<DownloadProgressEvent>,
) -> Result<(), EngineFailure> {
    let engine = match engine() {
        Ok(engine) => engine,
        Err(error) => {
            let _ = sink.add_error(error);
            return Ok(());
        }
    };
    for job in engine.scheduler().snapshot() {
        if sink
            .add(DownloadProgressEvent::from(DownloadEvent::from(&job)))
            .is_err()
        {
            return Ok(());
        }
    }
    let mut receiver = engine.events().subscribe();
    tokio::spawn(async move {
        loop {
            match receiver.recv().await {
                Ok(event) => {
                    if sink.add(DownloadProgressEvent::from(event)).is_err() {
                        break;
                    }
                }
                // 落后太多时广播会报 `Lagged`；跳过并继续，进度只关心最新状态。
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
            }
        }
    });
    Ok(())
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

/// 登记一个下载任务。
pub fn enqueue_download(request: DownloadRequest) -> Result<u64, EngineFailure> {
    let engine = engine()?;
    let mut job = Job::new(request.id, request.target, request.url);
    job.drama_id = request.drama_id;
    job.episode_id = request.episode_id;
    job.referer = request.referer;
    job.title = request.title;
    job.segments = request.segments;
    job.key_uri = request.key_uri;
    job.key_iv = request.key_iv;
    Ok(engine.enqueue_download(job))
}

/// 下载登记参数。
pub struct DownloadRequest {
    pub id: String,
    pub url: String,
    pub target: String,
    pub referer: String,
    pub title: String,
    pub drama_id: String,
    pub episode_id: String,
    /// HLS 分片；非空时走分片下载。
    pub segments: Vec<String>,
    /// HLS AES-128 密钥地址。
    pub key_uri: String,
    /// HLS AES-128 的 IV。
    pub key_iv: String,
}

/// 执行一个已登记的任务。
pub async fn run_download(id: String) -> Result<u64, EngineFailure> {
    let engine = engine()?;
    let env = engine.env("download");
    let outcome = engine
        .scheduler()
        .run(&env, &id)
        .await
        .map_err(|err| EngineFailure::from(EngineError::from_source(&err, "download", &id)))?;
    engine.broadcast_job(&id);
    Ok(match outcome {
        DownloadOutcome::Completed(bytes) => bytes,
        // 暂停与「数据变化需重来」都没有完成字节数；任务状态由索引承载，
        // Dart 侧读 `download_snapshot` 或进度流即可。
        DownloadOutcome::Restart | DownloadOutcome::Paused => 0,
    })
}

/// 当前所有下载任务。
pub fn download_snapshot() -> Result<Vec<DownloadSnapshot>, EngineFailure> {
    let engine = engine()?;
    Ok(engine
        .scheduler()
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
        .collect())
}

/// 离线播放：把已完成任务映射为本地播放计划。
///
/// `episode_id` 与 `drama_id` 由 Dart 侧传入（下载登记时的标识）。
/// 找不到已完成任务或文件已被删除时返回 `None`，由调用方回退到在线播放。
pub fn local_playback(
    drama_id: String,
    episode_id: String,
) -> Result<Option<LocalPlayback>, EngineFailure> {
    let engine = engine()?;
    let job = engine
        .scheduler()
        .snapshot()
        .into_iter()
        .find(|job| {
            job.drama_id == drama_id
                && job.episode_id == episode_id
                && job.state == guo_runtime::JobState::Completed
        })
        .ok_or_else(|| {
            EngineFailure::from(EngineError::new(
                EngineErrorKind::Unsupported,
                "该分集尚未下载完成",
            ))
        })?;
    let path = std::path::PathBuf::from(&job.target);
    if !path.is_file() {
        return Ok(None);
    }
    Ok(Some(LocalPlayback {
        url: path.display().to_string(),
        title: job.title,
        bytes: job.bytes,
    }))
}

/// 离线播放计划。
pub struct LocalPlayback {
    /// 本地文件路径（不带 `file://` 前缀，播放器自行处理）。
    pub url: String,
    pub title: String,
    pub bytes: u64,
}

/// 暂停 / 继续 / 重试 / 删除。
pub fn control_download(command: String, id: String) -> Result<bool, EngineFailure> {
    let engine = engine()?;
    let handled = engine.scheduler().control(&command, &id);
    if handled {
        engine.broadcast_job(&id);
    }
    Ok(handled)
}

/// 批量控制。返回每个任务是否被处理。
pub fn control_downloads(command: String, ids: Vec<String>) -> Result<u32, EngineFailure> {
    let engine = engine()?;
    let mut handled = 0;
    for id in ids {
        if engine.scheduler().control(&command, &id) {
            handled += 1;
            engine.broadcast_job(&id);
        }
    }
    Ok(handled)
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
    /// 播放时必须随请求发送的 Cookie（CDN 签名源需要）。
    pub cookies: String,
    /// 播放请求必须携带的 `Origin`（部分 CDN 会校验来源）。
    pub origin: String,
}

/// 详情结果。
pub struct ChapterList {
    pub drama: DramaItem,
    pub chapters: Vec<ChapterItem>,
}

/// 剧集输入。
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

/// 诊断快照：版本、路径、能力矩阵、插件报告、最近错误与请求计数。
pub struct EngineDiagnostics {
    pub version: String,
    pub data_directory: String,
    pub plugin_directory: String,
    pub session_file: String,
    pub catalog_file: String,
    pub uptime_ms: u64,
    pub request_count: u64,
    pub registry_revision: u64,
    pub active_sessions: u32,
    pub session_keys: u32,
    pub cached_catalogs: u32,
    pub queued_jobs: u32,
    pub running_jobs: u32,
    pub completed_jobs: u32,
    pub failed_jobs: u32,
    pub sources: Vec<SourceCapabilities>,
    pub plugins_loaded: Vec<String>,
    pub plugins_failed: Vec<FailedPluginReport>,
    pub recent_errors: Vec<EngineFailure>,
}

/// 单个站源的能力矩阵。
pub struct SourceCapabilities {
    pub id: String,
    pub name: String,
    pub group: String,
    pub api_level: u32,
    pub capabilities: Vec<String>,
}

/// 插件加载失败记录。
pub struct FailedPluginReport {
    pub id: String,
    pub detail: String,
}

/// 读取诊断快照。
pub fn engine_diagnostics() -> Result<EngineDiagnostics, EngineFailure> {
    let engine = engine()?;
    let report = engine.load_report();
    let (queued, running, completed, failed) = engine.scheduler().counts();
    Ok(EngineDiagnostics {
        version: engine_version(),
        data_directory: engine.config().data_directory.display().to_string(),
        plugin_directory: engine.config().plugin_directory.display().to_string(),
        session_file: engine.store().path().display().to_string(),
        catalog_file: engine.cache().path().display().to_string(),
        uptime_ms: engine.uptime().as_millis() as u64,
        request_count: engine.request_count(),
        registry_revision: engine.registry_revision(),
        active_sessions: engine.cancel_registry().session_count() as u32,
        session_keys: engine.store().len() as u32,
        cached_catalogs: engine.cache().len() as u32,
        queued_jobs: queued as u32,
        running_jobs: running as u32,
        completed_jobs: completed as u32,
        failed_jobs: failed as u32,
        sources: engine
            .registry()
            .metas()
            .into_iter()
            .map(|meta| SourceCapabilities {
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
            .collect(),
        plugins_loaded: report.loaded,
        plugins_failed: report
            .failed
            .into_iter()
            .map(|(id, detail)| FailedPluginReport { id, detail })
            .collect(),
        recent_errors: engine
            .recent_errors()
            .into_iter()
            .map(EngineFailure::from)
            .collect(),
    })
}

/// 清空某个站源的会话（令牌 / Cookie）。
pub fn clear_source_session(source_id: String) -> Result<u32, EngineFailure> {
    let engine = engine()?;
    Ok(engine
        .clear_source_session(&source_id)
        .map_err(EngineFailure::from)? as u32)
}

/// 重新装配注册表（插件安装 / 卸载后调用）。会话与下载任务保持不变。
pub fn reload_sources() -> Result<u32, EngineFailure> {
    let engine = engine()?;
    engine
        .rebuild_registry(register_builtin_sources)
        .map_err(EngineFailure::from)?;
    Ok(engine.registry().len() as u32)
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

/// 可安装 / 已安装插件的摘要。`installed` 与 `enabled` 共同决定 UI 上的按钮状态。
pub struct PluginSummary {
    pub id: String,
    pub name: String,
    pub version: String,
    /// `declarative` 或 `component`。
    pub kind: String,
    pub installed: bool,
    pub enabled: bool,
    /// 来源仓库是否签名（未签名仓库每次升级都要用户确认，见 D3）。
    pub signed: bool,
}

/// 仓库摘要。
pub struct RepoSummary {
    pub id: String,
    pub name: String,
    /// 索引路径，可能是相对路径或绝对 URL。
    pub index: String,
    pub signed: bool,
    /// `ed25519:<base64>`；未签名仓库为空。
    pub fingerprint: String,
}

/// 仅供集成测试：直接构造注册表（不经过单例）。
///
/// 与 `Engine` 的装配逻辑保持一致，避免测试夹具与实际运行时漂移。
#[flutter_rust_bridge::frb(ignore)]
pub fn debug_registry() -> SourceRegistry {
    let mut registry = SourceRegistry::new();
    register_builtin_sources(&mut registry);
    for text in [
        include_str!("../../../rules/wuguo.json"),
        include_str!("../../../rules/huaguo.json"),
        include_str!("../../../rules/fanguo.json"),
        include_str!("../../../rules/guanguo.json"),
        include_str!("../../../rules/xingguo.json"),
        include_str!("../../../rules/heguo.json"),
        include_str!("../../../rules/wangguo.json"),
        include_str!("../../../rules/dsd.json"),
        include_str!("../../../rules/faguo.json"),
    ] {
        if let Ok(source) = guo_runtime::RuleSource::from_json(text) {
            registry.register(Arc::new(source));
        }
    }
    registry
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_is_reported() {
        assert!(!engine_version().is_empty());
    }

    #[test]
    fn debug_registry_lists_builtin_sources() {
        let catalog: Vec<_> = debug_registry()
            .metas()
            .into_iter()
            .map(|meta| meta.id)
            .collect();
        for id in [
            "hongguo", "maoguo", "yaguo", "heguo", "dsd", "wuguo", "faguo",
        ] {
            assert!(catalog.iter().any(|entry| entry == id), "{id} 未注册");
        }
        assert!(
            !catalog.iter().any(|entry| entry == "diguo"),
            "diguo 必须已改名为 dsd"
        );
    }

    #[test]
    fn rule_validation_rejects_broken_json() {
        assert!(validate_rule("{".into()).is_err());
    }

    #[test]
    fn rule_validation_accepts_valid_document() {
        let text = include_str!("../../../rules/wuguo.json");
        assert_eq!(validate_rule(text.into()).expect("valid"), "wuguo");
    }

    #[test]
    fn parse_catalog_is_pure_and_deterministic() {
        let rule = include_str!("../../../rules/wuguo.json").to_string();
        let html = include_str!("../../tests/fixtures/wuguo_catalog.html").to_string();
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

    #[test]
    fn uninitialized_engine_reports_internal_error() {
        let error = match source_catalog() {
            Ok(_) => panic!("未初始化必须报错"),
            Err(error) => error,
        };
        assert_eq!(error.kind, error::kind::INTERNAL);
    }
}
