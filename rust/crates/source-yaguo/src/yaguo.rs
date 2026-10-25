use std::collections::HashSet;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use serde_json::Value;

use guo_source_api::preview;
use guo_source_api::{Capability, ContentType, SourceMeta, SourcePlugin, CURRENT_API_LEVEL};
use guo_source_api::{
    Category, Chapter, Detail, Drama, FetchRequest, FetchResponse, Media, Page, SourceEnv,
    SourceError,
};

/// 芽果（星芽）接口站源。
///
/// 迁移自 Go 的三条链路特征：
///
/// 1. 业务接口都要设备登录令牌，有效期 6 小时；失效返回 401，重新登录一次；
/// 2. 分类是 `theater/classes` 的**顶层分组**（剧场 / 新剧 / 排行榜 / …），
///    其中 `9` 是榜单，必须走独立接口而不是目录接口；
/// 3. 分集直接给出 MP4 地址，取流只做透传，不再抓播放页。
pub struct YaguoSource {
    meta: SourceMeta,
    token: Mutex<Option<CachedToken>>,
}

struct CachedToken {
    value: String,
    obtained: Instant,
}

const BASE: &str = "https://app.whjzjx.cn";
const LOGIN_URL: &str = "https://u.shytkjgs.com/user/v1/account/login";
/// Go 版固定使用的设备号，登录端点只认它。
const DEVICE: &str = "24250683a3bdb3f118dff25ba4b1cba1a";
const USER_AGENT: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const PLATFORM: &str = "1";
const VERSION_NAME: &str = "3.8.3.1";
const PAGE_SIZE: u32 = 24;
/// 与 Go 版一致的令牌缓存时长。
const TOKEN_TTL: Duration = Duration::from_secs(6 * 60 * 60);
/// 会话存储里的键。引擎按 `source_id` 命名空间隔离，这里只用局部名字。
const TOKEN_KEY: &str = "token";

/// 落盘结构：值与获取时间。时间是必需的——重启后仍要按 TTL 判断是否过期。
#[derive(serde::Serialize, serde::Deserialize)]
struct SavedToken {
    value: String,
    obtained_at: u64,
}

fn unix_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|value| value.as_secs())
        .unwrap_or(0)
}
/// 同一设备号并发登录时服务端返回 `2010007`（系统繁忙），隔一会重试即可。
const LOGIN_ATTEMPTS: usize = 3;
const LOGIN_RETRY_DELAY: Duration = Duration::from_millis(250);
const BUSY_CODE: &str = "2010007";
/// 榜单分类，走 `/cloud/v1/first_level_ranking/detail`。
const RANKING_CATEGORY: &str = "9";
const RANKING_ID: &str = "1";

impl Default for YaguoSource {
    fn default() -> Self {
        Self::new()
    }
}

impl YaguoSource {
    pub fn new() -> Self {
        Self {
            meta: SourceMeta {
                id: "yaguo".into(),
                name: "芽果".into(),
                group: "duanju".into(),
                api_level: CURRENT_API_LEVEL,
                content_types: vec![ContentType::ShortDrama],
                capabilities: vec![
                    Capability::Catalog,
                    Capability::Detail,
                    Capability::Search,
                    Capability::Categories,
                    Capability::Resolve,
                ],
            },
            token: Mutex::new(None),
        }
    }

    fn cached_token(&self) -> Option<String> {
        let guard = self.token.lock().ok()?;
        let entry = guard.as_ref()?;
        if entry.obtained.elapsed() < TOKEN_TTL {
            Some(entry.value.clone())
        } else {
            None
        }
    }

    fn store_token(&self, value: Option<String>) {
        if let Ok(mut guard) = self.token.lock() {
            *guard = value.map(|value| CachedToken {
                value,
                obtained: Instant::now(),
            });
        }
    }

    /// 读取磁盘令牌。内存未命中时回落到 `SourceStore`：
    /// 引擎单例跨 FRB 调用存活，但重启后内存态会丢，令牌必须能落盘复用。
    async fn disk_token(&self, env: &SourceEnv) -> Option<String> {
        let raw = env.store.get(TOKEN_KEY).await.ok().flatten()?;
        let saved: SavedToken = serde_json::from_str(&raw).ok()?;
        if saved.obtained_at > unix_secs() {
            return None;
        }
        if unix_secs().saturating_sub(saved.obtained_at) >= TOKEN_TTL.as_secs() {
            return None;
        }
        let value = saved.value.trim().to_string();
        if value.is_empty() || value.len() > 8192 {
            return None;
        }
        self.store_token(Some(value.clone()));
        Some(value)
    }

    /// 把令牌写回磁盘；写失败只影响下次重启后的登录次数，不影响本次调用。
    async fn persist_token(&self, env: &SourceEnv, value: Option<&str>) {
        let payload = match value {
            Some(token) => SavedToken {
                value: token.to_string(),
                obtained_at: unix_secs(),
            },
            // 显式失效：写入过期时间，读取侧会直接忽略。
            None => SavedToken {
                value: String::new(),
                obtained_at: 0,
            },
        };
        if let Ok(text) = serde_json::to_string(&payload) {
            let _ = env.store.set(TOKEN_KEY, &text).await;
        }
    }

    /// 取设备令牌。内存 → 磁盘 → 登录，三级回落；未过期时不会重复登录。
    async fn access_token(&self, env: &SourceEnv) -> Result<String, SourceError> {
        if let Some(token) = self.cached_token() {
            return Ok(token);
        }
        if let Some(token) = self.disk_token(env).await {
            return Ok(token);
        }
        let body = serde_json::json!({ "device": DEVICE }).to_string();
        let mut detail = String::from("未返回有效的访问令牌");
        for attempt in 0..LOGIN_ATTEMPTS {
            if attempt > 0 {
                tokio::time::sleep(LOGIN_RETRY_DELAY).await;
            }
            let response = env
                .text(
                    FetchRequest::post(LOGIN_URL, body.clone().into_bytes())
                        .header("Content-Type", "application/json")
                        .header("platform", PLATFORM)
                        .header("User-Agent", USER_AGENT),
                )
                .await?;
            let value: Value = serde_json::from_str(&response).map_err(|err| {
                SourceError::parse("yaguo.auth", format!("{err}: {}", preview(&response)))
            })?;
            let token = value
                .pointer("/data/token")
                .and_then(Value::as_str)
                .or_else(|| value.get("token").and_then(Value::as_str))
                .unwrap_or_default()
                .trim()
                .to_string();
            if !token.is_empty() && token.len() <= 8192 {
                self.store_token(Some(token.clone()));
                self.persist_token(env, Some(&token)).await;
                return Ok(token);
            }
            if let Some(message) = value.get("msg").and_then(Value::as_str) {
                detail = message.to_string();
            }
            if value.get("code").and_then(Value::as_str) != Some(BUSY_CODE) {
                break;
            }
        }
        Err(SourceError::parse("yaguo.auth", detail))
    }

    async fn signed(
        &self,
        env: &SourceEnv,
        request: &FetchRequest,
        token: &str,
    ) -> Result<FetchResponse, SourceError> {
        let signed = request
            .clone()
            .header("authorization", token)
            .header("platform", PLATFORM)
            .header("version_name", VERSION_NAME)
            .header("User-Agent", USER_AGENT)
            .header("Referer", format!("{BASE}/"));
        env.transport.fetch(signed).await
    }

    /// 带令牌请求；401/403 时丢弃令牌、重新登录并重试一次。
    async fn send(
        &self,
        env: &SourceEnv,
        request: FetchRequest,
    ) -> Result<FetchResponse, SourceError> {
        let mut token = self.access_token(env).await?;
        let mut retried = false;
        loop {
            match self.signed(env, &request, &token).await {
                Ok(response) if is_unauthorized_status(response.status) && !retried => {
                    retried = true;
                    self.store_token(None);
                    self.persist_token(env, None).await;
                    token = self.access_token(env).await?;
                }
                Ok(response) => {
                    response.ensure_success()?;
                    return Ok(response);
                }
                Err(error) if !retried && is_unauthorized(&error) => {
                    retried = true;
                    self.store_token(None);
                    self.persist_token(env, None).await;
                    token = self.access_token(env).await?;
                }
                Err(error) => return Err(error),
            }
        }
    }

    async fn request_json(
        &self,
        env: &SourceEnv,
        request: FetchRequest,
    ) -> Result<Value, SourceError> {
        let response = self.send(env, request).await?;
        let body = response.text();
        serde_json::from_str(&body)
            .map_err(|err| SourceError::parse("yaguo", format!("{err}: {}", preview(&body))))
    }

    fn catalog_request(category: &str, page: u32) -> FetchRequest {
        let category = category.trim();
        if category == RANKING_CATEGORY {
            return FetchRequest::get(format!(
                "{BASE}/cloud/v1/first_level_ranking/detail?id={RANKING_ID}"
            ));
        }
        let class = if !category.is_empty() && category.bytes().all(|byte| byte.is_ascii_digit()) {
            category
        } else {
            ""
        };
        FetchRequest::get(format!(
            "{BASE}/cloud/v2/theater/home_page?theater_class_id={class}&type=1&class2_ids=0&page_num={}&page_size={PAGE_SIZE}",
            page.max(1)
        ))
    }

    fn detail_request(source_id: &str) -> FetchRequest {
        FetchRequest::get(format!(
            "{BASE}/v2/theater_parent/detail?theater_parent_id={}",
            encode_component(source_id)
        ))
    }

    fn search_request(query: &str) -> FetchRequest {
        let body = serde_json::json!({ "text": query }).to_string();
        FetchRequest::post(format!("{BASE}/v3/search"), body.into_bytes())
            .header("Content-Type", "application/json")
    }
}

#[async_trait]
impl SourcePlugin for YaguoSource {
    fn meta(&self) -> SourceMeta {
        self.meta.clone()
    }

    async fn categories(&self, env: &SourceEnv) -> Result<Vec<Category>, SourceError> {
        let value = self
            .request_json(
                env,
                FetchRequest::get(format!("{BASE}/cloud/v2/theater/classes")),
            )
            .await?;
        let groups = value
            .pointer("/data/list")
            .and_then(Value::as_array)
            .ok_or_else(|| SourceError::parse("yaguo.categories", "缺少 data.list"))?;
        let mut seen = HashSet::new();
        let mut categories = Vec::new();
        for group in groups {
            let id = pick(group, &["id"]);
            let name = pick(group, &["class_name", "name"]);
            if id.is_empty()
                || name.is_empty()
                || name.chars().count() > 24
                || !seen.insert(id.clone())
            {
                continue;
            }
            categories.push(Category { id, name });
        }
        if categories.is_empty() {
            return Err(SourceError::parse("yaguo.categories", "未返回有效分类"));
        }
        Ok(categories)
    }

    async fn catalog(
        &self,
        env: &SourceEnv,
        page: u32,
        category: &str,
    ) -> Result<Page, SourceError> {
        let page = page.max(1);
        let ranking = category.trim() == RANKING_CATEGORY;
        let value = self
            .request_json(env, Self::catalog_request(category, page))
            .await?;
        let data = value
            .get("data")
            .filter(|data| data.is_object())
            .ok_or_else(|| SourceError::parse("yaguo.catalog", "缺少 data"))?;
        let rows = data
            .get("list")
            .and_then(Value::as_array)
            .ok_or_else(|| SourceError::parse("yaguo.catalog", "缺少 data.list"))?;
        let items: Vec<Drama> = rows.iter().filter_map(drama_from_node).collect();
        let has_more = if ranking {
            false
        } else {
            let total = pick(data, &["total"]).parse::<u64>().unwrap_or(0);
            !truthy(data.get("is_end"))
                && !items.is_empty()
                && total > u64::from(page) * items.len() as u64
        };
        Ok(Page {
            items,
            has_more,
            page,
            warning: String::new(),
        })
    }

    async fn detail(&self, env: &SourceEnv, source_id: &str) -> Result<Detail, SourceError> {
        let value = self
            .request_json(env, Self::detail_request(source_id))
            .await?;
        let data = value
            .get("data")
            .filter(|data| data.is_object())
            .ok_or_else(|| SourceError::parse("yaguo.detail", "缺少剧集资料"))?;
        let mut drama = drama_from_fields(data);
        drama.id = Drama::identity("yaguo", source_id);
        drama.source = "yaguo".into();
        drama.source_id = source_id.to_string();
        drama.release_status = release_status(data);

        let chapters = chapters_from(data, source_id);
        if chapters.is_empty() {
            return Err(SourceError::parse("yaguo.detail", "未返回可播放分集"));
        }
        drama.episodes = chapters.len() as u32;
        Ok(Detail { drama, chapters })
    }

    async fn search(&self, env: &SourceEnv, query: &str, page: u32) -> Result<Page, SourceError> {
        let query = query.trim();
        if query.is_empty() {
            return Ok(Page {
                items: Vec::new(),
                has_more: false,
                page,
                warning: String::new(),
            });
        }
        let value = self.request_json(env, Self::search_request(query)).await?;
        let rows = value
            .pointer("/data/theater/search_data")
            .or_else(|| value.pointer("/data/list"))
            .and_then(Value::as_array)
            .ok_or_else(|| SourceError::parse("yaguo.search", "缺少搜索列表"))?;
        let items = rows.iter().filter_map(drama_from_node).collect();
        Ok(Page {
            items,
            has_more: false,
            page,
            warning: String::new(),
        })
    }

    async fn resolve(
        &self,
        _env: &SourceEnv,
        _drama: &Drama,
        chapter: &Chapter,
    ) -> Result<Media, SourceError> {
        let url = chapter.video_url.trim();
        if url.is_empty() {
            return Err(SourceError::parse("yaguo.resolve", "分集缺少播放地址"));
        }
        let referer = if chapter.referer.trim().is_empty() {
            format!("{BASE}/")
        } else {
            chapter.referer.clone()
        };
        Ok(Media {
            url: url.to_string(),
            referer,
            ..Default::default()
        })
    }
}

fn is_unauthorized_status(status: u16) -> bool {
    matches!(status, 401 | 403)
}

fn is_unauthorized(error: &SourceError) -> bool {
    matches!(error.http_status(), Some(401) | Some(403))
}

/// 列表条目既可能是 `{"theater": {...}}`（目录），也可能是剧目字段本身（搜索、榜单）。
fn drama_from_node(node: &Value) -> Option<Drama> {
    let target = node
        .get("theater")
        .filter(|theater| theater.is_object())
        .unwrap_or(node);
    let drama = drama_from_fields(target);
    if drama.source_id.is_empty() {
        None
    } else {
        Some(drama)
    }
}

fn drama_from_fields(node: &Value) -> Drama {
    let source_id = pick(node, &["id", "theater_id", "theater_parent_id"]);
    Drama {
        id: Drama::identity("yaguo", &source_id),
        source: "yaguo".into(),
        source_id,
        title: pick(node, &["title", "name"]),
        description: pick(node, &["descrip", "introduction", "desc"]),
        cover: cover(node),
        episodes: pick(node, &["total", "total_num", "current_num"])
            .parse::<u32>()
            .unwrap_or(0),
        category: tags(node).join(", "),
        ..Default::default()
    }
}

fn chapters_from(data: &Value, source_id: &str) -> Vec<Chapter> {
    let mut rows = Vec::new();
    if let Some(theaters) = data.get("theaters").and_then(Value::as_array) {
        for (index, node) in theaters.iter().enumerate() {
            let video_url = pick(node, &["son_video_url", "video_url"]);
            if video_url.is_empty() {
                continue;
            }
            let number = pick(node, &["num", "sort"])
                .parse::<u32>()
                .ok()
                .filter(|number| *number > 0)
                .unwrap_or(index as u32 + 1);
            let title = {
                let title = pick(node, &["son_title", "title"]);
                if title.is_empty() {
                    format!("第{number}集")
                } else {
                    title
                }
            };
            rows.push((
                number,
                Chapter {
                    id: format!("{source_id}:{number}"),
                    title,
                    source: "yaguo".into(),
                    video_url,
                    referer: format!("{BASE}/"),
                    ..Default::default()
                },
            ));
        }
    }
    // `sort_by_key` 稳定排序，与 Go 的 `SliceStable` 一致。
    rows.sort_by_key(|(number, _)| *number);
    rows.into_iter().map(|(_, chapter)| chapter).collect()
}

fn release_status(node: &Value) -> String {
    let is_over = pick(node, &["is_over"]).parse::<i64>().unwrap_or(0);
    let total = pick(node, &["total"]).parse::<i64>().unwrap_or(0);
    let current = pick(node, &["current_num"]).parse::<i64>().unwrap_or(0);
    match is_over {
        2 => "finished",
        1 => "ongoing",
        _ if total > 0 && current >= total => "finished",
        _ if current > 0 => "ongoing",
        _ => "",
    }
    .to_string()
}

fn cover(node: &Value) -> String {
    for key in ["cover_url", "son_cover_url", "cover"] {
        let value = cover_value(node.get(key));
        if !value.is_empty() {
            return value;
        }
    }
    String::new()
}

fn cover_value(value: Option<&Value>) -> String {
    let Some(value) = value else {
        return String::new();
    };
    match value {
        Value::String(text) => absolute(text),
        Value::Array(items) => items
            .iter()
            .map(|item| cover_value(Some(item)))
            .find(|value| !value.is_empty())
            .unwrap_or_default(),
        Value::Object(map) => ["url", "contentUrl", "thumbnailUrl"]
            .iter()
            .map(|key| cover_value(map.get(*key)))
            .find(|value| !value.is_empty())
            .unwrap_or_default(),
        _ => String::new(),
    }
}

fn absolute(value: &str) -> String {
    let value = value.trim();
    if value.is_empty() {
        return String::new();
    }
    if value.starts_with("http://") || value.starts_with("https://") {
        return value.to_string();
    }
    if value.starts_with("//") {
        return format!("https:{value}");
    }
    format!(
        "{}/{}",
        BASE.trim_end_matches('/'),
        value.trim_start_matches('/')
    )
}

fn tags(node: &Value) -> Vec<String> {
    let Some(rows) = node.get("tags").and_then(Value::as_array) else {
        return Vec::new();
    };
    rows.iter()
        .filter_map(|row| match row {
            Value::String(text) => {
                let text = text.trim();
                if text.is_empty() {
                    None
                } else {
                    Some(text.to_string())
                }
            }
            Value::Object(_) => {
                let text = pick(row, &["name", "title", "class_name"]);
                if text.is_empty() {
                    None
                } else {
                    Some(text)
                }
            }
            _ => None,
        })
        .collect()
}

/// 兼容字符串与数字两种标量；数字用于 `id` / `total` 这类字段。
fn pick(node: &Value, keys: &[&str]) -> String {
    for key in keys {
        let Some(value) = node.get(*key) else {
            continue;
        };
        if let Some(text) = value.as_str() {
            let text = text.trim();
            if !text.is_empty() {
                return text.to_string();
            }
        } else if let Some(number) = value.as_i64() {
            return number.to_string();
        }
    }
    String::new()
}

fn truthy(value: Option<&Value>) -> bool {
    match value {
        Some(Value::Bool(flag)) => *flag,
        Some(Value::String(text)) => text == "true" || text == "1",
        Some(Value::Number(number)) => number.as_f64().is_some_and(|value| value != 0.0),
        _ => false,
    }
}

fn encode_component(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*byte as char);
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_request_switches_between_groups_and_ranking() {
        let empty = YaguoSource::catalog_request("", 1);
        assert!(empty
            .url
            .contains("/cloud/v2/theater/home_page?theater_class_id=&type=1"));
        assert!(empty.url.ends_with("page_num=1&page_size=24"));

        let group = YaguoSource::catalog_request("4", 2);
        assert!(group.url.contains("theater_class_id=4"));
        assert!(group.url.ends_with("page_num=2&page_size=24"));

        // 非数字分类不能原样拼进查询串。
        let invalid = YaguoSource::catalog_request("都市", 1);
        assert!(invalid.url.contains("theater_class_id=&"));

        let ranking = YaguoSource::catalog_request(RANKING_CATEGORY, 3);
        assert_eq!(
            ranking.url,
            format!("{BASE}/cloud/v1/first_level_ranking/detail?id=1")
        );
    }

    #[test]
    fn page_zero_is_clamped_to_one() {
        let request = YaguoSource::catalog_request("", 0);
        assert!(request.url.ends_with("page_num=1&page_size=24"));
    }

    #[test]
    fn drama_mapping_accepts_wrapped_and_flat_nodes() {
        let wrapped = serde_json::json!({
            "type": "Theater",
            "theater": {
                "id": 51,
                "title": "女神的近身高手",
                "descrip": "我是神医",
                "cover_url": "https://qiniu.example/cover",
                "tags": ["都市", {"name": "逆袭"}],
                "total": 100
            }
        });
        let drama = drama_from_node(&wrapped).expect("目录条目");
        assert_eq!(drama.id, "yaguo:51");
        assert_eq!(drama.source, "yaguo");
        assert_eq!(drama.source_id, "51");
        assert_eq!(drama.title, "女神的近身高手");
        assert_eq!(drama.description, "我是神医");
        assert_eq!(drama.episodes, 100);
        assert_eq!(drama.category, "都市, 逆袭");

        let flat = serde_json::json!({
            "id": 2207,
            "title": "开局离婚",
            "cover_url": "/img/cover.jpg",
            "introduction": "简介",
            "total": 89
        });
        let drama = drama_from_node(&flat).expect("搜索条目");
        assert_eq!(drama.id, "yaguo:2207");
        assert_eq!(drama.cover, format!("{BASE}/img/cover.jpg"));
        assert_eq!(drama.description, "简介");

        assert!(drama_from_node(&serde_json::json!({"title": "没有 id"})).is_none());
    }

    #[test]
    fn chapters_sort_by_number_and_skip_missing_video() {
        let data = serde_json::json!({
            "theaters": [
                {"num": 3, "son_title": "第三集", "son_video_url": "http://cdn/3.mp4"},
                {"num": 0, "son_title": "", "video_url": "http://cdn/x.mp4"},
                {"num": 1, "son_title": "第一集", "son_video_url": "http://cdn/1.mp4"},
                {"num": 2, "son_title": "没有地址"}
            ]
        });
        let chapters = chapters_from(&data, "51");
        assert_eq!(chapters.len(), 3);
        assert_eq!(
            chapters
                .iter()
                .map(|chapter| chapter.id.as_str())
                .collect::<Vec<_>>(),
            vec!["51:1", "51:2", "51:3"]
        );
        assert_eq!(chapters[0].title, "第一集");
        assert_eq!(chapters[1].title, "第2集", "缺标题时按集数回退");
        assert_eq!(chapters[2].title, "第三集");
        assert_eq!(chapters[0].referer, format!("{BASE}/"));
        assert_eq!(chapters[0].source, "yaguo");
    }

    #[test]
    fn release_status_maps_is_over_and_progress() {
        assert_eq!(
            release_status(&serde_json::json!({"is_over": 2})),
            "finished"
        );
        assert_eq!(
            release_status(&serde_json::json!({"is_over": 1})),
            "ongoing"
        );
        assert_eq!(
            release_status(&serde_json::json!({"is_over": 0, "total": 10, "current_num": 10})),
            "finished"
        );
        assert_eq!(
            release_status(&serde_json::json!({"is_over": 0, "total": 10, "current_num": 3})),
            "ongoing"
        );
        assert_eq!(release_status(&serde_json::json!({})), "");
    }

    #[test]
    fn meta_declares_expected_capabilities() {
        let meta = YaguoSource::new().meta();
        assert_eq!(meta.id, "yaguo");
        assert_eq!(meta.name, "芽果");
        for capability in [
            Capability::Catalog,
            Capability::Detail,
            Capability::Search,
            Capability::Categories,
            Capability::Resolve,
        ] {
            assert!(
                meta.capabilities.contains(&capability),
                "缺少能力位 {capability:?}"
            );
        }
    }
}
