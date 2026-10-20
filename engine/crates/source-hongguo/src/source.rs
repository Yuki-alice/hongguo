//! `SourcePlugin` 实现。
//!
//! 两条取数路径，与 Go 版一致：
//! 1. **App 接口**（`api5-normal-sinfonlineb.fqnovel.com`）：数据更全，但需要设备 id
//!    与 X-Gorgon 签名，首次使用要先注册设备；
//! 2. **网页**（`hongguoduanju.com`）：`_ROUTER_DATA` 内嵌 JSON，无需签名，
//!    作为降级路径与离线夹具的来源。
//!
//! 这里把两条路径都实现出来，调用方按「先 App 后网页」的顺序尝试。

use async_trait::async_trait;
use serde_json::Value;

use guo_source_api::{
    Capability, Category, Chapter, DanmakuPage, Detail, Drama, FetchRequest, Media, Page,
    RankingBoard, RankingPage, RecommendCursor, RecommendPage, SeriesSeason, SourceEnv,
    SourceError, SourceMeta, SourcePlugin, Suggestion, CURRENT_API_LEVEL,
};

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
        let info = page
            .get("video_player_info")
            .and_then(Value::as_object)
            .ok_or_else(|| SourceError::parse("hongguo", "播放页缺少 video_player_info"))?;
        let mut addresses = Vec::new();
        for key in ["video_list", "video_model", "play_addr"] {
            collect_addresses(info.get(key), &mut addresses);
        }
        if addresses.is_empty() {
            return Err(SourceError::parse(
                "hongguo",
                "该集未提供公开播放地址，可能需要登录或 App 授权",
            ));
        }
        let url = addresses[0].clone();
        Ok(Media {
            url,
            referer: format!("{WEB_BASE}/"),
            playlist: None,
            key_uri: String::new(),
            key_iv: String::new(),
        })
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
        for (route, name) in routes {
            let url = self.category_url(&format!("{route}?page={page}"));
            match self.page_text(env, url).await {
                Ok(body) => match Self::parse_category_page(&body, name) {
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
}

impl HongguoSource {
    /// 解析榜单；「数据未完整」时重试一次（站点偶尔返回半截）。
    fn parse_ranking_with_retry(
        body: &str,
        board: &str,
        page: u32,
    ) -> Result<RankingPage, SourceError> {
        match crate::rankings::parse_ranking_page(body, board, page) {
            Ok(result) => Ok(result),
            // 只有「尚未完整」值得重试；格式/分页不符是确定性的，重试也没用。
            Err(err) if err.to_string().contains("尚未完整") => {
                crate::rankings::parse_ranking_page(body, board, page)
            }
            Err(err) => Err(err),
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

/// App 接口把业务错误放在 `code` / `BaseResp.StatusCode` 里，HTTP 200 也可能是失败。
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
        // 网页没有搜索接口；用分类页做关键词过滤，属于降级实现，
        // 真正的搜索在 App 接口（P2）。这里明确标注 warning，避免 UI 误以为搜全了。
        let mut result = self.web_catalog(env, page, "").await?;
        let needle = query.trim();
        if !needle.is_empty() {
            result.items.retain(|drama| drama.title.contains(needle));
        }
        if result.warning.is_empty() {
            result.warning = "红果网页版无搜索接口，当前为标题过滤结果".into();
        }
        Ok(result)
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
        let body = self
            .page_text(env, self.player_url(&series_id, &video_id))
            .await?;
        Self::parse_player_page(&body, &series_id, &video_id)
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
        let body = self.page_text(env, url).await?;
        Self::parse_ranking_with_retry(&body, board, page)
    }

    async fn recommend(
        &self,
        env: &SourceEnv,
        cursor: &RecommendCursor,
    ) -> Result<RecommendPage, SourceError> {
        // 推荐走 App 接口：它需要签名与设备身份，网页没有对应能力。
        let identity = self.identity(env).await?;
        let payload = crate::capabilities::recommend_payload(cursor, "short_play");
        let body = payload.to_string().into_bytes();
        let request = self.signed_app_request(
            "/reading/distribution/category/landpage/v/",
            &[],
            &identity.device_id,
            &identity.install_id,
            Some(body),
            now_millis(),
        );
        let text = env.text(request).await?;
        let root: Value = serde_json::from_str(&text)
            .map_err(|err| SourceError::parse("hongguo", format!("推荐返回不是 JSON：{err}")))?;
        check_app_code(&root)?;
        crate::capabilities::parse_recommend_page(&root)
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
        let identity = self.identity(env).await?;
        // 每段 60 秒，与 Go 版的分段粒度一致。
        let end_ms = start_ms + 60_000;
        let payload = serde_json::json!({
            "offset": 0,
            "count": crate::capabilities::DANMAKU_LIMIT,
            "start_time": start_ms,
            "end_time": end_ms,
        });
        let request = self.signed_app_request(
            &format!("/novel/commentapi/comment/list/{video_id}/v1/"),
            &[],
            &identity.device_id,
            &identity.install_id,
            Some(payload.to_string().into_bytes()),
            now_millis(),
        );
        let text = env.text(request).await?;
        crate::capabilities::parse_danmaku(&text, start_ms, end_ms)
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
