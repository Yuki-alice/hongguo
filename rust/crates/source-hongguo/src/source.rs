//! `SourcePlugin` 实现。
//!
//! 两条取数路径，与 Go 版一致：
//! 1. **App 接口**（`api5-normal-sinfonlineb.fqnovel.com`）：数据更全，但需要设备 id
//!    与 X-Gorgon 签名，首次使用要先注册设备；
//! 2. **网页**（`hongguoduanju.com`）：`_ROUTER_DATA` 内嵌 JSON，无需签名，
//!    作为降级路径与离线夹具的来源。
//!
//! 这里把两条路径都实现出来，调用方按「先 App 后网页」的顺序尝试。

use std::time::Duration;

use async_trait::async_trait;
use futures_util::future::join_all;
use serde_json::Value;

use guo_source_api::{
    Capability, Category, Chapter, ContentType, DanmakuPage, Detail, Drama, FetchRequest, Media,
    Page, RankingBoard, RankingPage, RecommendCursor, RecommendPage, SeriesSeason, SourceEnv,
    SourceError, SourceMeta, SourcePlugin, Suggestion, CURRENT_API_LEVEL,
};

use crate::argus::{comment_headers, CommentNonce};
use crate::router::{parse_router_data, router_loader_map, HongguoDrama};
use crate::sign::{gorgon, SignInputs};

/// 网页站点。
pub const WEB_BASE: &str = "https://hongguoduanju.com";
/// App 接口。
pub const APP_BASE: &str = "https://api5-normal-sinfonlineb.fqnovel.com";
/// App 的 UA 与站点强绑定：换掉会被判定为非官方客户端。
pub const APP_USER_AGENT: &str = "com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)";

/// 网页的四条内容路由。顺序决定首页展示顺序。
pub const ROUTES: [(&str, &str); 4] = [
    ("real-drama", "真人剧"),
    ("comic-drama", "漫剧"),
    ("ai-drama", "AI剧"),
    ("comic", "动漫"),
];

/// 推荐流每页条数。分类页本身不分页地给出整批推荐，这里按固定窗口切片，
/// 让「加载更多」有确定的语义（与 App 接口当年的 18 条保持同一量级）。
const RECOMMEND_PAGE_SIZE: u32 = 18;

/// 弹幕可查询的时间轴上限（24 小时，与 Go 版 danmakuMaxDurationMS 一致）。
const DANMAKU_MAX_WINDOW_MS: i64 = 24 * 60 * 60 * 1000;

/// 搜索结果每页条数。网页搜索页一次返回全部匹配，分页只用于估算 `has_more`。
const SEARCH_PAGE_SIZE: u32 = 20;

/// 红果主源。
pub struct HongguoSource {
    /// 是否允许走 App 接口。关掉后只走网页，便于离线测试与问题定位。
    app_enabled: bool,
    web_base: String,
    app_base: String,
    /// 设备身份缓存：首次请求时创建并落盘，之后进程内复用。
    identity: std::sync::OnceLock<crate::DeviceIdentity>,
}

impl Default for HongguoSource {
    fn default() -> Self {
        Self {
            app_enabled: true,
            web_base: WEB_BASE.to_string(),
            app_base: APP_BASE.to_string(),
            identity: std::sync::OnceLock::new(),
        }
    }
}

impl HongguoSource {
    pub fn new() -> Self {
        Self::default()
    }

    /// 只走网页路径，用于测试与降级。
    pub fn web_only() -> Self {
        Self {
            app_enabled: false,
            ..Self::default()
        }
    }

    /// 指向本地夹具服务器，便于集成测试。
    pub fn with_base(web_base: impl Into<String>, app_base: impl Into<String>) -> Self {
        Self {
            app_enabled: true,
            web_base: web_base.into(),
            app_base: app_base.into(),
            identity: std::sync::OnceLock::new(),
        }
    }

    /// 分类页地址。`route` 形如 `real-drama?page=2`。
    fn category_url(&self, route: &str) -> String {
        format!("{}/category/{route}", self.web_base.trim_end_matches('/'))
    }

    fn detail_url(&self, series_id: &str) -> String {
        format!(
            "{}/detail?series_id={}",
            self.web_base.trim_end_matches('/'),
            urlencode(series_id)
        )
    }

    fn player_url(&self, series_id: &str, video_id: &str) -> String {
        format!(
            "{}/player/{}/{}",
            self.web_base.trim_end_matches('/'),
            urlencode(series_id),
            urlencode(video_id)
        )
    }

    fn referer(&self) -> String {
        format!("{}/", self.web_base.trim_end_matches('/'))
    }

    fn request(&self, url: impl Into<String>) -> FetchRequest {
        FetchRequest::get(url)
            .header("Referer", self.referer())
            .limit_bytes(8 * 1024 * 1024)
            // 网页健康时 <1s 返回；20s 默认值只在站点挂起时白烧预算，
            // 配合传输层重试（重试轮次再收 8s），最坏链路仍可预期。
            .timeout(Duration::from_secs(12))
    }

    async fn page_text(&self, env: &SourceEnv, url: String) -> Result<String, SourceError> {
        env.text(self.request(url)).await
    }

    /// 解析一个分类页。返回剧目与总页数。
    pub fn parse_category_page(
        body: &str,
        category: &str,
    ) -> Result<(Vec<HongguoDrama>, u32), SourceError> {
        let data = parse_router_data(body).ok_or_else(|| {
            SourceError::parse(
                "hongguo",
                "页面里没有 _ROUTER_DATA，可能是结构变化或需要登录",
            )
        })?;
        let page = router_loader_map(&data, &["category_page", "category_$"]).ok_or_else(|| {
            SourceError::parse("hongguo", "分类数据不可用，可能是页面结构或访问权限变化")
        })?;
        if page.get("isSuccess").and_then(Value::as_bool) == Some(false) {
            return Err(SourceError::parse("hongguo", "站源返回 isSuccess=false"));
        }
        let items = any_list(page.get("recommendList"));
        let mut out = Vec::with_capacity(items.len());
        for item in items {
            if let Some(drama) = HongguoDrama::from_value(item, category) {
                out.push(drama);
            }
        }
        let total_pages = page
            .get("pagination")
            .and_then(|value| value.get("totalPages"))
            .and_then(|value| match value {
                Value::String(text) => text.parse().ok(),
                Value::Number(number) => number.as_u64().map(|value| value as u32),
                _ => None,
            })
            .unwrap_or(0);
        Ok((out, total_pages))
    }

    /// 解析详情页，返回剧名与分集。
    pub fn parse_detail_page(
        body: &str,
        series_id: &str,
    ) -> Result<(String, Vec<Chapter>), SourceError> {
        let data = parse_router_data(body)
            .ok_or_else(|| SourceError::parse("hongguo", "详情页里没有 _ROUTER_DATA"))?;
        let page = router_loader_map(&data, &["detail_page", "detail_"])
            .ok_or_else(|| SourceError::parse("hongguo", "详情数据为空"))?;
        let detail = page
            .get("seriesDetail")
            .and_then(Value::as_object)
            .ok_or_else(|| SourceError::parse("hongguo", "详情缺少 seriesDetail"))?;
        let title = ["series_name", "series_title", "name"]
            .iter()
            .find_map(|key| detail.get(*key).and_then(Value::as_str))
            .map(str::to_string)
            .unwrap_or_else(|| series_id.to_string());
        let mut chapters = Vec::new();
        for (index, value) in any_list(detail.get("vid_list")).iter().enumerate() {
            let video_id = text_of(value);
            if video_id.is_empty() {
                continue;
            }
            chapters.push(Chapter {
                id: format!("{series_id}:{}", index + 1),
                title: format!("第{}集", index + 1),
                source: series_id.to_string(),
                // 与 Go 版一致：用自定义 scheme 携带视频 id，取流时再解析。
                video_url: format!("hongguo-cenc://{video_id}"),
                ..Default::default()
            });
        }
        if chapters.is_empty() {
            return Err(SourceError::parse("hongguo", "详情没有返回剧集 ID"));
        }
        Ok((title, chapters))
    }

    /// 从播放页提取媒体地址。
    pub fn parse_player_page(
        body: &str,
        series_id: &str,
        video_id: &str,
    ) -> Result<Media, SourceError> {
        let data = parse_router_data(body)
            .ok_or_else(|| SourceError::parse("hongguo", "播放页里没有 _ROUTER_DATA"))?;
        let page = router_loader_map(&data, &["player_page", "player_"])
            .ok_or_else(|| SourceError::parse("hongguo", "播放页数据为空"))?;
        let returned_video = page.get("vid").map(text_of).unwrap_or_default();
        let returned_series = page.get("series_id").map(text_of).unwrap_or_default();
        if returned_video != video_id || returned_series != series_id {
            return Err(SourceError::parse(
                "hongguo",
                "站源未返回所请求的剧集，可能仅允许网页试看",
            ));
        }
        // 2026-10 起播放页不再下发 `video_player_info`：媒体地址改由客户端
        // 拉取，网页只保留公开试看通道。按顺序尝试两种承载。
        if let Some(info) = page.get("video_player_info").and_then(Value::as_object) {
            let mut addresses = Vec::new();
            for key in ["video_list", "video_model", "play_addr"] {
                collect_addresses(info.get(key), &mut addresses);
            }
            if let Some(url) = addresses.first() {
                return Ok(Self::web_media(url));
            }
        }
        if let Some(media) = Self::public_preview_media(page, video_id) {
            return Ok(media);
        }
        Err(SourceError::parse(
            "hongguo",
            "该集未提供公开播放地址，可能需要登录或 App 授权",
        ))
    }

    /// 网页公开试看地址：`/video/public/<vid>/360p.mp4`。
    ///
    /// 站点只对 `publicVideoSeo.available` 为真、且 `itemId` 与请求一致的
    /// 分集开放这条路。它是**降级通道**：画质固定 360p、部分分集 404。
    /// 能播就比不能播好，但调用方不该把它当成原画。
    fn public_preview_media(page: &Value, video_id: &str) -> Option<Media> {
        let seo = page.get("publicVideoSeo")?.as_object()?;
        if seo.get("available").and_then(Value::as_bool) != Some(true) {
            return None;
        }
        let item_id = seo.get("itemId").map(text_of)?;
        if item_id != video_id {
            return None;
        }
        Some(Self::web_media(&format!(
            "{WEB_BASE}/video/public/{video_id}/360p.mp4"
        )))
    }

    fn web_media(url: &str) -> Media {
        Media {
            url: url.to_string(),
            referer: format!("{WEB_BASE}/"),
            playlist: None,
            key_uri: String::new(),
            key_iv: String::new(),
            cookies: String::new(),
            origin: String::new(),
            cenc_key: String::new(),
            quality: 0,
            qualities: Vec::new(),
        }
    }

    /// App 接口的公共查询参数。与 Go 版逐项一致。
    fn app_query(&self, device_id: &str, install_id: &str) -> Vec<(String, String)> {
        [
            ("aid", "8662"),
            ("app_name", "novelread"),
            ("version_code", "73532"),
            ("version_name", "7.3.5.32"),
            ("manifest_version_code", "73532"),
            ("update_version_code", "73532"),
            ("channel", "update_64"),
            ("device_platform", "android"),
            ("os", "android"),
            ("ssmix", "a"),
            ("device_type", "25053RT47C"),
            ("device_brand", "Redmi"),
            ("language", "zh"),
            ("os_api", "36"),
            ("os_version", "16"),
            ("resolution", "1280*2772"),
            ("dpi", "520"),
            ("ac", "wifi"),
            ("device_id", device_id),
            ("iid", install_id),
        ]
        .iter()
        .map(|(key, value)| ((*key).to_string(), (*value).to_string()))
        .collect()
    }

    /// 构造一次**评论签名**的 App 请求（弹幕 / 文字接口专用）。
    ///
    /// 与 [signed_app_request] 的差别：X-Argus / X-Ladon / 评论版 X-Gorgon
    /// （2026-10-24 实测：没有这一层，弹幕接口返回 `110001 未知异常`）；
    /// `X-SS-STUB` 固定为空串而不是请求体摘要；另带 `Comment-Source` 与
    /// `Server-Channel` 两个头（Go 版对弹幕路径如此）。
    pub fn signed_comment_request(
        &self,
        path: &str,
        device_id: &str,
        install_id: &str,
        body: Vec<u8>,
        now_ms: u64,
    ) -> FetchRequest {
        let mut query = self.app_query(device_id, install_id);
        query.push(("_rticket".to_string(), now_ms.to_string()));
        let raw_query = encode_query(&query);
        let nonce = CommentNonce::generate();
        let headers = comment_headers(&raw_query, nonce, now_ms);

        let url = format!("{}{path}?{raw_query}", self.app_base.trim_end_matches('/'));
        let mut request = FetchRequest::post(url, body);
        request
            .headers
            .insert("User-Agent".into(), APP_USER_AGENT.into());
        request
            .headers
            .insert("Accept".into(), "application/json".into());
        request.headers.insert(
            "Content-Type".into(),
            "application/json; charset=utf-8".into(),
        );
        request.headers.insert("X-XS-From-Web".into(), "0".into());
        request.headers.insert("Sdk-Version".into(), "2".into());
        request
            .headers
            .insert("Comment-Source".into(), "601".into());
        request
            .headers
            .insert("Server-Channel".into(), "1000".into());
        request
            .headers
            .insert("X-Khronos".into(), headers.x_khronos);
        request.headers.insert("X-Gorgon".into(), headers.x_gorgon);
        request
            .headers
            .insert("X-SS-Req-Ticket".into(), headers.x_ss_req_ticket);
        request.headers.insert("X-SS-STUB".into(), String::new());
        request.headers.insert("X-Argus".into(), headers.x_argus);
        request.headers.insert("X-Ladon".into(), headers.x_ladon);
        request
    }

    /// 构造一次已签名的 App 请求。
    ///
    /// 签名覆盖**编码后的**查询串，因此必须先拼好 query 再签；
    /// 时间戳由调用方注入，保证签名与 `X-Khronos` 一致。
    pub fn signed_app_request(
        &self,
        path: &str,
        extra: &[(String, String)],
        device_id: &str,
        install_id: &str,
        body: Option<Vec<u8>>,
        now_ms: u64,
    ) -> FetchRequest {
        let mut query = self.app_query(device_id, install_id);
        query.extend_from_slice(extra);
        query.push(("_rticket".to_string(), now_ms.to_string()));
        let raw_query = encode_query(&query);
        let timestamp = (now_ms / 1000) as u32;
        let headers = gorgon(&SignInputs {
            raw_query: &raw_query,
            body: body.as_deref(),
            timestamp,
            ticket_ms: now_ms,
        });

        let url = format!("{}{path}?{raw_query}", self.app_base.trim_end_matches('/'));
        let mut request = match body {
            Some(payload) => FetchRequest::post(url, payload),
            None => FetchRequest::get(url),
        };
        request
            .headers
            .insert("User-Agent".into(), APP_USER_AGENT.into());
        request
            .headers
            .insert("Accept".into(), "application/json".into());
        request.headers.insert("X-XS-From-Web".into(), "0".into());
        request.headers.insert("Sdk-Version".into(), "2".into());
        request
            .headers
            .insert("X-Khronos".into(), headers.x_khronos);
        request.headers.insert("X-Gorgon".into(), headers.x_gorgon);
        request
            .headers
            .insert("X-SS-Req-Ticket".into(), headers.x_ss_req_ticket);
        if let Some(stub) = headers.x_ss_stub {
            request.headers.insert("X-SS-STUB".into(), stub);
        }
        if request.body.is_some() {
            request.headers.insert(
                "Content-Type".into(),
                "application/json; charset=utf-8".into(),
            );
        }
        request
    }

    async fn web_catalog(
        &self,
        env: &SourceEnv,
        page: u32,
        category: &str,
    ) -> Result<Page, SourceError> {
        // 分类为空时按路由顺序聚合首页；否则只取匹配的路由。
        let routes: Vec<(&str, &str)> = ROUTES
            .iter()
            .copied()
            .filter(|(_, name)| category.trim().is_empty() || *name == category.trim())
            .collect();
        if routes.is_empty() {
            return Ok(Page {
                items: Vec::new(),
                has_more: false,
                page,
                warning: format!("未知分类：{category}"),
            });
        }

        let mut items: Vec<Drama> = Vec::new();
        let mut seen = std::collections::HashSet::new();
        let mut max_pages = 0u32;
        let mut failures = Vec::new();
        // 路由页并行拉取：健康时总耗时 = 最慢一页而非各页之和；
        // 站点抖动（实测约半数请求挂满超时）时，串行会让一个坏页
        // 吃光调用方的整个时间预算。join_all 在当前任务内轮询，无额外线程。
        let fetches = routes.into_iter().map(|(route, name)| {
            let url = self.category_url(&format!("{route}?page={page}"));
            async move { self.page_text(env, url).await.map(|body| (name, body)) }
        });
        for result in join_all(fetches).await {
            match result {
                Ok((name, body)) => match Self::parse_category_page(&body, name) {
                    Ok((dramas, total)) => {
                        max_pages = max_pages.max(total);
                        for drama in dramas {
                            let drama = drama.into_drama();
                            if !drama.id.is_empty() && seen.insert(drama.id.clone()) {
                                items.push(drama);
                            }
                        }
                    }
                    Err(err) => failures.push(err.to_string()),
                },
                Err(err) => failures.push(err.to_string()),
            }
        }

        if items.is_empty() {
            if let Some(first) = failures.first() {
                return Err(SourceError::parse("hongguo", first.clone()));
            }
        }
        items.sort_by(|left, right| left.title.cmp(&right.title));
        Ok(Page {
            items,
            has_more: max_pages == 0 || page < max_pages,
            page,
            warning: if failures.is_empty() {
                String::new()
            } else {
                format!("部分分类加载失败：{}", failures.join("；"))
            },
        })
    }

    /// 用联想接口做搜索（降级路径）。
    ///
    /// 站点一次最多返回 `SUGGESTION_LIMIT` 条，因此结果集有限；如实把这件事
    /// 写进 `warning`，UI 才不会让用户以为「只有这么多」。
    async fn search_by_suggestion(
        &self,
        env: &SourceEnv,
        keyword: &str,
        page: u32,
    ) -> Result<Page, SourceError> {
        if page > 1 {
            return Ok(Page {
                items: Vec::new(),
                has_more: false,
                page,
                warning: "红果联想搜索每页最多 10 条，已到末页".into(),
            });
        }
        let url = format!(
            "{}/incent_resource/suggestion?app_id=8662&query={}&count={}",
            self.web_base.trim_end_matches('/'),
            urlencode(keyword),
            crate::capabilities::SUGGESTION_LIMIT
        );
        let body = self.page_text(env, url).await?;
        let items = crate::capabilities::parse_suggestion_dramas(&body)?;
        let mut seen = std::collections::HashSet::new();
        let items: Vec<Drama> = items
            .into_iter()
            .filter(|drama| seen.insert(drama.id.clone()))
            .collect();
        Ok(Page {
            items,
            has_more: false,
            page,
            warning: "红果网页搜索暂不可用，当前为联想结果（最多 10 条）".into(),
        })
    }
}

impl HongguoSource {
    /// 解析榜单，并对「数据未完整」做**重新请求**。
    ///
    /// 站点会偶发返回半截页面（`content` 为空、`rankList` 缺失），
    /// 对同一份 body 再解析一次毫无意义——必须重新拉一次页面。
    /// 只对这一类可重试错误重取；格式 / 分页不符是确定性的，重试也白费。
    async fn fetch_ranking_with_retry(
        &self,
        env: &SourceEnv,
        url: &str,
        board: &str,
        page: u32,
    ) -> Result<RankingPage, SourceError> {
        let mut last = None;
        for attempt in 0..2 {
            let body = self.page_text(env, url.to_string()).await?;
            match crate::rankings::parse_ranking_page(&body, board, page) {
                Ok(result) => return Ok(result),
                Err(err) if is_incomplete(&err) && attempt == 0 => {
                    last = Some(err);
                    continue;
                }
                Err(err) => return Err(err),
            }
        }
        Err(last.unwrap_or(SourceError::NoResult))
    }

    /// 第三方解析接口：`djapi.999888456.xyz`，v2 加密响应 + CENC 密钥。
    ///
    /// 协议细节见 [`crate::playback`]；该函数只负责构造引用、发请求、
    /// 把候选变成 [`Media`]（选最高画质，全部画质写进 `qualities`）。
    async fn resolve_via_playback_api(
        &self,
        env: &SourceEnv,
        series_id: &str,
        video_id: &str,
    ) -> Result<Media, SourceError> {
        let reference = serde_json::json!({
            "content_type": 1004,
            "from_video_id": "",
            "series_id": series_id,
            "vid": video_id,
            "video_platform": 3,
        });
        use base64::Engine as _;
        let encoded =
            base64::engine::general_purpose::STANDARD.encode(reference.to_string().as_bytes());
        let url = format!(
            "{}?id={}",
            crate::playback::PLAYBACK_API,
            urlencode(&encoded)
        );
        let body = self.page_text(env, url).await?;
        match crate::playback::parse_playback(&body)? {
            crate::playback::PlaybackOutcome::NoResult => Err(SourceError::NoResult),
            crate::playback::PlaybackOutcome::Variants(variants) => {
                let best = variants.iter().max_by_key(|item| item.quality).unwrap();
                let mut qualities: Vec<u32> = variants.iter().map(|item| item.quality).collect();
                qualities.sort_unstable();
                qualities.dedup();
                qualities.reverse(); // 契约约定降序
                Ok(Media {
                    url: best.url.clone(),
                    referer: crate::playback::PLAYBACK_MEDIA_REFERER.into(),
                    cenc_key: hex::encode(best.key),
                    quality: best.quality,
                    qualities,
                    ..Default::default()
                })
            }
        }
    }

    /// 取（并按需创建）设备身份。缓存到进程内，避免每次请求两次 IO。
    async fn identity(&self, env: &SourceEnv) -> Result<crate::DeviceIdentity, SourceError> {
        if let Some(cached) = self.identity.get() {
            return Ok(cached.clone());
        }
        let identity = crate::DeviceIdentity::load_or_create(env.store.as_ref()).await?;
        let _ = self.identity.set(identity.clone());
        Ok(identity)
    }
}

/// 是否为「站点返回了半截数据」这类可重试错误。
///
/// 判据是错误文案里的固定短语——解析层只在两种情况下这么说，且都属于
/// 「再拉一次可能就好」；用文案匹配是因为 `SourceError` 没有更细的类别。
fn is_incomplete(error: &SourceError) -> bool {
    let text = error.to_string();
    text.contains("尚未完整") || text.contains("缺少 rankList")
}

/// App 接口把业务错误放在 `code` / `BaseResp.StatusCode` 里，HTTP 200 也可能是失败。
///
/// 当前没有调用方：推荐曾经走 App 接口，2026-10 改成网页分类页后不再需要。
/// 保留它是为弹幕与将来的 App 路径备好统一校验，**不要**因为当前零引用就删掉。
#[allow(dead_code)]
fn check_app_code(root: &Value) -> Result<(), SourceError> {
    let code = root
        .get("code")
        .or_else(|| root.get("status_code"))
        .and_then(|value| match value {
            Value::Number(number) => Some(number.to_string()),
            Value::String(text) => Some(text.clone()),
            _ => None,
        })
        .unwrap_or_default();
    if !code.is_empty() && code != "0" {
        return Err(SourceError::parse(
            "hongguo",
            format!("App 接口返回 {code}"),
        ));
    }
    Ok(())
}

/// 解析网页搜索页。站点把结果放在 `search_(keyword)/page` 的 loader 里。
fn parse_search_page(body: &str, keyword: &str, page: u32) -> Result<Page, SourceError> {
    let data = parse_router_data(body)
        .ok_or_else(|| SourceError::parse("hongguo", "搜索页里没有 _ROUTER_DATA"))?;
    let content = router_loader_map(&data, &["search_(keyword)/page", "search_"])
        .ok_or_else(|| SourceError::parse("hongguo", "搜索结果为空"))?;
    if content.get("isSuccess").and_then(Value::as_bool) == Some(false) {
        return Err(SourceError::parse(
            "hongguo",
            "搜索接口返回 isSuccess=false",
        ));
    }
    // 站点会校验回传的 query 与请求一致，避免把别的词的结果当成当前结果。
    let returned = content.get("query").map(text_of).unwrap_or_default();
    if !returned.is_empty() && returned != keyword {
        return Err(SourceError::parse(
            "hongguo",
            format!("返回了「{returned}」的结果，不是「{keyword}」"),
        ));
    }
    let rows = content
        .get("searchList")
        .and_then(Value::as_array)
        .ok_or_else(|| SourceError::parse("hongguo", "搜索结果里没有 searchList"))?;
    let mut items = Vec::with_capacity(rows.len());
    let mut seen = std::collections::HashSet::new();
    for row in rows {
        let Some(drama) = HongguoDrama::from_value(row, "短剧") else {
            continue;
        };
        let drama = drama.into_drama();
        if !drama.id.is_empty() && seen.insert(drama.id.clone()) {
            items.push(drama);
        }
    }
    let total = content
        .get("totalCount")
        .map(text_of)
        .and_then(|value| value.parse::<u32>().ok())
        .unwrap_or(items.len() as u32);
    Ok(Page {
        items,
        has_more: total as usize > page as usize * SEARCH_PAGE_SIZE as usize,
        page,
        warning: String::new(),
    })
}

fn now_millis() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|value| value.as_millis() as u64)
        .unwrap_or(0)
}

impl HongguoDrama {
    /// 转成契约层 `Drama`。
    pub fn into_drama(self) -> Drama {
        Drama {
            id: Drama::identity("hongguo", &self.series_id),
            source: "hongguo".into(),
            source_id: self.series_id,
            title: self.title,
            description: self.description,
            cover: self.cover,
            episodes: self.episodes,
            category: self.category,
            tags: self.tags,
            views: self.views,
            heat: self.heat,
            release_status: self.release_status,
            online_date: self.online_date,
            vip: None,
        }
    }
}

#[async_trait]
impl SourcePlugin for HongguoSource {
    fn meta(&self) -> SourceMeta {
        SourceMeta {
            id: "hongguo".into(),
            name: "红果".into(),
            group: "duanju".into(),
            api_level: CURRENT_API_LEVEL,
            content_types: vec![ContentType::ShortDrama],
            capabilities: vec![
                Capability::Catalog,
                Capability::Detail,
                Capability::Search,
                Capability::Resolve,
                Capability::Categories,
                // D4 要求主源能力面完整：榜单 / 推荐 / 联想 / 弹幕 / 系列剧。
                Capability::Rankings,
                Capability::Recommend,
                Capability::Suggestions,
                Capability::Danmaku,
                Capability::Series,
            ],
        }
    }

    async fn categories(&self, _env: &SourceEnv) -> Result<Vec<Category>, SourceError> {
        // 分类 id 用中文名本身：网页路由是 `real-drama` 这类英文，
        // 但对外暴露的筛选值一直是中文（与 Go 版 UI 一致）。
        Ok(ROUTES
            .iter()
            .map(|(_, name)| Category {
                id: (*name).to_string(),
                name: (*name).to_string(),
            })
            .collect())
    }

    async fn catalog(
        &self,
        env: &SourceEnv,
        page: u32,
        category: &str,
    ) -> Result<Page, SourceError> {
        // App 接口需要先注册设备（`/service/2/device_register/`），
        // 迁移期尚未接入设备状态机，先走网页路径；App 路径在 P2 补。
        let _ = self.app_enabled;
        self.web_catalog(env, page, category).await
    }

    async fn detail(&self, env: &SourceEnv, source_id: &str) -> Result<Detail, SourceError> {
        let series_id = source_id.trim_start_matches("hg-series-v1:");
        if series_id.is_empty() {
            return Err(SourceError::EmptyRequest("红果剧 ID"));
        }
        let body = self.page_text(env, self.detail_url(series_id)).await?;
        let (title, chapters) = Self::parse_detail_page(&body, series_id)?;
        Ok(Detail {
            drama: Drama {
                id: Drama::identity("hongguo", series_id),
                source: "hongguo".into(),
                source_id: series_id.to_string(),
                title,
                episodes: chapters.len() as u32,
                ..Default::default()
            },
            chapters,
        })
    }

    async fn search(&self, env: &SourceEnv, query: &str, page: u32) -> Result<Page, SourceError> {
        let keyword = query.trim();
        if keyword.is_empty() {
            return Err(SourceError::EmptyRequest("红果搜索词"));
        }
        // 网页搜索页：`/search/<keyword>`。站点在 2026-10 改成了客户端渲染，
        // 页面里不再有 `_ROUTER_DATA`，因此**不能**再假设能解析出结果；
        // 抓不到时明确报「暂不可用」，而不是拿首页做标题过滤冒充搜索结果
        // ——那种做法会把「搜不到」和「站源坏了」混为一谈。
        let url = format!(
            "{}/search/{}",
            self.web_base.trim_end_matches('/'),
            urlencode(keyword)
        );
        let body = self.page_text(env, url).await?;
        if let Ok(page_data) = parse_search_page(&body, keyword, page) {
            return Ok(page_data);
        }
        // 搜索页已改为客户端渲染（无 `_ROUTER_DATA`）。联想接口仍可用，且
        // `word_type == "short_play_name"` 的行带完整 `video_data`，能直接
        // 构造可点开的条目——这是当前唯一可用的真实搜索数据源。
        self.search_by_suggestion(env, keyword, page).await
    }

    async fn resolve(
        &self,
        env: &SourceEnv,
        drama: &Drama,
        chapter: &Chapter,
    ) -> Result<Media, SourceError> {
        let video_id = chapter
            .video_url
            .strip_prefix("hongguo-cenc://")
            .unwrap_or(&chapter.video_url)
            .to_string();
        if video_id.is_empty() || !video_id.chars().all(|c| c.is_ascii_digit()) {
            return Err(SourceError::parse(
                "hongguo",
                "章节 ID 无效，请重新获取章节",
            ));
        }
        let series_id = if drama.source_id.is_empty() {
            chapter.source.clone()
        } else {
            drama.source_id.clone()
        };
        if series_id.is_empty() || !series_id.chars().all(|c| c.is_ascii_digit()) {
            return Err(SourceError::parse("hongguo", "缺少剧 ID，请刷新剧库后重试"));
        }
        // 通道 1：第三方解析接口（Go 版主通道）。2026-10-25 实测服务存活但
        // 对全部请求返回 parse=0（无解析结果），静默落到下一通道；
        // 一旦它恢复数据，这里直接给出全画质 CENC 流，无需发版。
        let mut playback_error = None;
        match self
            .resolve_via_playback_api(env, &series_id, &video_id)
            .await
        {
            Ok(media) => return Ok(media),
            Err(SourceError::NoResult) => {}
            Err(err) => playback_error = Some(err),
        }
        // 通道 2：网页播放页。`video_player_info` 若回归优先用它，
        // 否则落到 `publicVideoSeo` 公开试看（固定 360p，多数剧仅第 1 集）。
        let body = self
            .page_text(env, self.player_url(&series_id, &video_id))
            .await?;
        match Self::parse_player_page(&body, &series_id, &video_id) {
            Ok(media) => Ok(media),
            // 两条通道都失败时优先暴露解析通道的具体错误——它能区分
            // 「服务没数据」「版本不支持」「密钥损坏」，比网页侧的笼统文案可定位。
            Err(web_error) => Err(playback_error.unwrap_or(web_error)),
        }
    }

    async fn ranking_boards(&self, _env: &SourceEnv) -> Result<Vec<RankingBoard>, SourceError> {
        Ok(crate::rankings::boards())
    }

    async fn ranking(
        &self,
        env: &SourceEnv,
        board: &str,
        page: u32,
    ) -> Result<RankingPage, SourceError> {
        let (_, _, path, _) = crate::rankings::find_board(board)
            .ok_or_else(|| SourceError::parse("hongguo", format!("未知榜单 {board}")))?;
        let url = format!(
            "{}{}",
            self.web_base.trim_end_matches('/'),
            crate::rankings::board_path(path, page)
        );
        self.fetch_ranking_with_retry(env, &url, board, page).await
    }

    async fn recommend(
        &self,
        env: &SourceEnv,
        cursor: &RecommendCursor,
    ) -> Result<RecommendPage, SourceError> {
        // App 推荐接口（`/reading/distribution/category/landpage/v/`）在
        // 2026-10-24 实测对本机一律返回空响应体，已不可用。改用网页分类页
        // 的 `recommendList`：同一批内容，只是少了「按 genre 精排」。
        //
        // genre 仍参与选择路由：真人剧 / 漫剧 / AI 剧各取对应分类页；
        // 翻页用 `offset` 换算成页码，`session_id` 不再需要。
        let (route, name) = match cursor.genre.as_str() {
            "comic_series" => ("comic-drama", "漫剧"),
            "ai_series" => ("ai-drama", "AI剧"),
            _ => ("real-drama", "真人剧"),
        };
        let page = cursor.offset / RECOMMEND_PAGE_SIZE + 1;
        let url = self.category_url(&format!("{route}?page={page}"));
        let body = self.page_text(env, url).await?;
        let (dramas, total_pages) = Self::parse_category_page(&body, name)?;
        let items: Vec<Drama> = dramas
            .into_iter()
            .map(|drama| drama.into_drama())
            .filter(|drama| !drama.id.is_empty())
            .collect();
        let has_more =
            items.len() >= RECOMMEND_PAGE_SIZE as usize && (total_pages == 0 || page < total_pages);
        Ok(RecommendPage {
            items,
            cursor: RecommendCursor {
                offset: cursor.offset + RECOMMEND_PAGE_SIZE,
                session_id: String::new(),
                genre: cursor.genre.clone(),
            },
            has_more,
        })
    }

    async fn suggestions(
        &self,
        env: &SourceEnv,
        keyword: &str,
    ) -> Result<Vec<Suggestion>, SourceError> {
        let keyword = keyword.trim();
        if keyword.is_empty() {
            return Ok(Vec::new());
        }
        // 网页接口：`/incent_resource/suggestion`，带 app_id 与 count。
        let url = format!(
            "{}/incent_resource/suggestion?app_id=8662&query={}&count={}",
            self.web_base.trim_end_matches('/'),
            urlencode(keyword),
            crate::capabilities::SUGGESTION_LIMIT
        );
        let body = self.page_text(env, url).await?;
        crate::capabilities::parse_suggestions(&body)
    }

    async fn danmaku(
        &self,
        env: &SourceEnv,
        chapter: &Chapter,
        start_ms: i64,
    ) -> Result<DanmakuPage, SourceError> {
        let video_id = chapter
            .video_url
            .strip_prefix("hongguo-cenc://")
            .unwrap_or(&chapter.video_url)
            .to_string();
        if video_id.is_empty() || !video_id.chars().all(|c| c.is_ascii_digit()) {
            return Err(SourceError::parse("hongguo", "章节 ID 无效，无法加载弹幕"));
        }
        if !(0..DANMAKU_MAX_WINDOW_MS).contains(&start_ms) {
            return Err(SourceError::parse("hongguo", "弹幕时间轴超出可查询范围"));
        }
        let identity = self.identity(env).await?;
        // series_id 是弹幕的 book_id（剧维度）。详情解析把它放在分集的
        // `source` 字段；为空说明调用方没经过详情直接构造分集，无法定位剧集。
        let series_id = chapter.source.clone();
        if series_id.is_empty() || !series_id.chars().all(|c| c.is_ascii_digit()) {
            return Err(SourceError::parse("hongguo", "缺少剧 ID，无法加载弹幕"));
        }
        // 请求体与 Go 版逐字段一致（comment_source/group_type/comment_type 都是
        // 服务端风控的校验位，改任何一个都会回到 110001）。
        // `playlet_item_duration` 用 start+60s 作为窗口提示；服务端按自己的
        // 窗口策略返回 30s 或 60s 分段，真实窗口以响应里的
        // `next_query_danmaku_list_time` 为准（见 parse_danmaku）。
        let duration_hint = start_ms.saturating_add(60_000);
        let payload = serde_json::json!({
            "comment_source": 601,
            "server_channel": 1000,
            "group_id": video_id,
            "group_type": 30,
            "comment_type": 20,
            "sort": 1,
            "count": crate::capabilities::DANMAKU_LIMIT,
            "cursor": "",
            "aid": 8662,
            "compliance_status": 0,
            "business_param": {
                "book_id": series_id,
                "start_offset_time": start_ms,
                "playlet_item_duration": duration_hint,
                "need_danmaku_guide_type": [1, 3, 4, 2],
            },
        });
        let request = self.signed_comment_request(
            &format!("/novel/commentapi/comment/list/{video_id}/v1/"),
            &identity.device_id,
            &identity.install_id,
            payload.to_string().into_bytes(),
            now_millis(),
        );
        let text = env.text(request).await?;
        crate::capabilities::parse_danmaku(&text, &video_id, start_ms)
    }

    async fn seasons(
        &self,
        env: &SourceEnv,
        drama: &Drama,
    ) -> Result<Vec<SeriesSeason>, SourceError> {
        // 系列剧靠「搜索同名剧再按标题里的季号聚合」得到，与 Go 版一致。
        let base = crate::capabilities::base_title_for_search(&drama.title);
        if base.is_empty() {
            return Ok(Vec::new());
        }
        let page = self.search(env, &base, 1).await?;
        Ok(crate::capabilities::group_seasons(
            &drama.title,
            &page.items,
        ))
    }
}

/// 收集播放地址：既接受字符串，也接受 `{"url": …}` / `{"main_url": …}` 这类结构。
fn collect_addresses(value: Option<&Value>, out: &mut Vec<String>) {
    match value {
        Some(Value::String(text)) if text.starts_with("http") => {
            if !out.iter().any(|item| item == text) {
                out.push(text.clone());
            }
        }
        Some(Value::Array(items)) => {
            for item in items {
                collect_addresses(Some(item), out);
            }
        }
        Some(Value::Object(map)) => {
            for key in ["url", "main_url", "backup_url", "src"] {
                if let Some(Value::String(text)) = map.get(key) {
                    if text.starts_with("http") && !out.iter().any(|item| item == text) {
                        out.push(text.clone());
                    }
                }
            }
            for key in ["url_list", "video_list", "play_addr"] {
                if map.contains_key(key) {
                    collect_addresses(map.get(key), out);
                }
            }
        }
        _ => {}
    }
}

fn any_list(value: Option<&Value>) -> Vec<&Value> {
    match value {
        Some(Value::Array(items)) => items.iter().collect(),
        Some(Value::Object(map)) => {
            for key in ["list", "items", "data"] {
                let nested = any_list(map.get(key));
                if !nested.is_empty() {
                    return nested;
                }
            }
            Vec::new()
        }
        _ => Vec::new(),
    }
}

fn text_of(value: &Value) -> String {
    match value {
        Value::String(text) => text.trim().to_string(),
        Value::Number(number) => number.to_string(),
        _ => String::new(),
    }
}

/// 最小百分号编码：只处理查询参数里会出问题的字符，不用额外依赖。
fn urlencode(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for byte in text.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(byte as char)
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

/// 与 Go 的 `url.Values.Encode()` 一致：键按字典序，值内按出现顺序，空格编码为 `+`。
fn encode_query(pairs: &[(String, String)]) -> String {
    let mut sorted: Vec<&(String, String)> = pairs.iter().collect();
    sorted.sort_by(|left, right| left.0.cmp(&right.0));
    sorted
        .iter()
        .map(|(key, value)| format!("{}={}", urlencode(key), urlencode_value(value)))
        .collect::<Vec<_>>()
        .join("&")
}

fn urlencode_value(text: &str) -> String {
    urlencode(text).replace("%20", "+")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn category_page_parses_router_data() {
        let body = r#"<script>window._ROUTER_DATA = {"loaderData":{"category_page":{"isSuccess":true,"recommendList":[
            {"video_data":{"series_id":101,"series_title":"剧一","episode_cnt":"10","series_cover":"https://c/1.jpg"}},
            {"video_data":{"series_id":102,"series_title":"剧二","episode_cnt":"20"}}
        ],"pagination":{"totalPages":"3"}}}};</script>"#;
        let (dramas, total) = HongguoSource::parse_category_page(body, "真人剧").expect("parse");
        assert_eq!(dramas.len(), 2);
        assert_eq!(total, 3);
        assert_eq!(dramas[0].series_id, "101");
        assert_eq!(dramas[0].category, "真人剧");
    }

    #[test]
    fn category_page_reports_missing_router_data() {
        let err = HongguoSource::parse_category_page("<html></html>", "真人剧").expect_err("fail");
        assert!(err.to_string().contains("_ROUTER_DATA"), "{err}");
    }

    #[test]
    fn detail_page_builds_chapters_with_custom_scheme() {
        let body = r#"<script>window._ROUTER_DATA = {"loaderData":{"detail_page":{"seriesDetail":{"series_name":"示例","vid_list":["111","222"]}}}};</script>"#;
        let (title, chapters) = HongguoSource::parse_detail_page(body, "9").expect("parse");
        assert_eq!(title, "示例");
        assert_eq!(chapters.len(), 2);
        assert_eq!(chapters[0].video_url, "hongguo-cenc://111");
        assert_eq!(chapters[1].title, "第2集");
    }

    #[test]
    fn detail_page_rejects_empty_vid_list() {
        let body = r#"<script>window._ROUTER_DATA = {"loaderData":{"detail_page":{"seriesDetail":{"series_name":"x","vid_list":[]}}}};</script>"#;
        let err = HongguoSource::parse_detail_page(body, "9").expect_err("fail");
        assert!(err.to_string().contains("剧集 ID"), "{err}");
    }

    #[test]
    fn player_page_extracts_first_address() {
        let body = r#"<script>window._ROUTER_DATA = {"loaderData":{"player_page":{"vid":"111","series_id":"9","video_player_info":{"video_list":[{"main_url":"https://cdn.test/1.m3u8"}]}}}};</script>"#;
        let media = HongguoSource::parse_player_page(body, "9", "111").expect("parse");
        assert_eq!(media.url, "https://cdn.test/1.m3u8");
        assert!(media.referer.starts_with("https://hongguoduanju.com"));
    }

    #[test]
    fn player_page_rejects_mismatched_video() {
        let body = r#"<script>window._ROUTER_DATA = {"loaderData":{"player_page":{"vid":"222","series_id":"9","video_player_info":{}}}};</script>"#;
        let err = HongguoSource::parse_player_page(body, "9", "111").expect_err("fail");
        assert!(err.to_string().contains("试看"), "{err}");
    }

    #[test]
    fn signed_app_request_sets_gorgon_headers() {
        let source = HongguoSource::new();
        let request = source.signed_app_request(
            "/service/2/feed",
            &[("tab".into(), "5".into())],
            "1234567890123456789",
            "9876543210987654321",
            None,
            1_700_000_000_000,
        );
        assert_eq!(
            request.headers.get("X-Khronos").map(String::as_str),
            Some("1700000000")
        );
        assert_eq!(
            request.headers.get("X-SS-Req-Ticket").map(String::as_str),
            Some("1700000000000")
        );
        let gorgon = request.headers.get("X-Gorgon").expect("gorgon");
        assert!(gorgon.starts_with("8404401c0000"), "{gorgon}");
        assert!(request.url.contains("aid=8662"), "{}", request.url);
        assert!(request.url.contains("tab=5"), "{}", request.url);
        assert!(
            request.url.contains("_rticket=1700000000000"),
            "{}",
            request.url
        );
    }

    #[test]
    fn app_query_is_sorted_like_go() {
        let encoded = encode_query(&[
            ("b".into(), "2".into()),
            ("a".into(), "1".into()),
            ("c".into(), "中文".into()),
        ]);
        assert_eq!(encoded, "a=1&b=2&c=%E4%B8%AD%E6%96%87");
    }

    #[test]
    fn urlencode_matches_rfc3986_subset() {
        assert_eq!(urlencode("a b+c"), "a%20b%2Bc");
        assert_eq!(urlencode_value("a b"), "a+b");
        assert_eq!(urlencode("剧"), "%E5%89%A7");
    }

    #[test]
    fn collect_addresses_finds_nested_urls() {
        let value: Value = serde_json::from_str(
            r#"{"video_list":[{"main_url":"https://a/1.m3u8"},{"backup_url":"https://b/1.m3u8"}],"play_addr":{"url_list":[{"url":"https://c/1.m3u8"}]}}"#,
        )
        .expect("json");
        let mut out = Vec::new();
        collect_addresses(Some(&value), &mut out);
        assert_eq!(out.len(), 3);
        assert_eq!(out[0], "https://a/1.m3u8");
    }

    #[test]
    fn meta_declares_all_five_capabilities() {
        let source = HongguoSource::new();
        let meta = source.meta();
        assert_eq!(meta.id, "hongguo");
        for capability in [
            Capability::Catalog,
            Capability::Detail,
            Capability::Search,
            Capability::Resolve,
            Capability::Categories,
        ] {
            assert!(meta.supports(capability), "{capability:?} 缺失");
        }
    }
}
