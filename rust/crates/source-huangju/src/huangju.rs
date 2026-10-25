use std::sync::Mutex;

use async_trait::async_trait;
use serde_json::Value;

use guo_source_api::{Capability, ContentType, SourceMeta, SourcePlugin, CURRENT_API_LEVEL};
use guo_source_api::{Chapter, Detail, Drama, FetchRequest, Media, Page, SourceEnv, SourceError};

/// 剧果（huangju.net）接口站源。
///
/// 与牛果不同，这里的难点不在加密而在**会话与凭证**：
///
/// 1. 所有接口都要访客令牌，令牌过期后必须重新申请一次（401 时刷新重试）；
/// 2. 详情按 `slug`（如 `yanyu-2788`）取，不是数字 id；
/// 3. 取流响应会下发 CDN 签名 Cookie，播放列表与分片必须带着它。
pub struct HuangjuSource {
    meta: SourceMeta,
    /// 访客令牌与申请次数上限的守卫。密钥在进程内复用，避免每次请求都登录。
    token: Mutex<Option<String>>,
}

const API_BASE: &str = "https://api.huangju.net";
const SITE: &str = "https://huangju.net";
const USER_AGENT: &str = "Mozilla/5.0 (Linux; Android 11; Pixel 5) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/90.0.4430.91 Mobile Safari/537.36";
/// 目录页固定 20 条，与接口默认值一致。
const PAGE_SIZE: u32 = 20;
/// 「最新」分类用排序而不是分类过滤，与 Web 端一致。
const NEWEST: &str = "__newest";

impl Default for HuangjuSource {
    fn default() -> Self {
        Self::new()
    }
}

impl HuangjuSource {
    pub fn new() -> Self {
        Self {
            meta: SourceMeta {
                id: "huangju".into(),
                name: "剧果".into(),
                group: "duanju".into(),
                api_level: CURRENT_API_LEVEL,
                content_types: vec![ContentType::ShortDrama],
                capabilities: vec![
                    Capability::Catalog,
                    Capability::Detail,
                    Capability::Search,
                    Capability::Categories,
                ],
            },
            token: Mutex::new(None),
        }
    }

    fn cached_token(&self) -> Option<String> {
        self.token.lock().ok().and_then(|guard| guard.clone())
    }

    fn store_token(&self, token: Option<String>) {
        if let Ok(mut guard) = self.token.lock() {
            *guard = token;
        }
    }

    /// 申请访客令牌。`POST /auth/guest` 只认 `deviceId`，格式是 UUID v4。
    async fn guest_token(&self, env: &SourceEnv) -> Result<String, SourceError> {
        if let Some(token) = self.cached_token() {
            return Ok(token);
        }
        let device = device_id();
        let body = serde_json::json!({ "deviceId": device }).to_string();
        let response = env
            .text(
                FetchRequest::post(format!("{API_BASE}/auth/guest"), body.into_bytes())
                    .header("Content-Type", "application/json")
                    .header("User-Agent", USER_AGENT)
                    .header("Referer", format!("{SITE}/"))
                    .header("Origin", SITE),
            )
            .await?;
        let value: Value = serde_json::from_str(&response)
            .map_err(|err| SourceError::parse("huangju.auth", format!("{err}")))?;
        let token = value
            .get("token")
            .and_then(Value::as_str)
            .or_else(|| {
                value
                    .get("data")
                    .and_then(|data| data.get("token"))
                    .and_then(Value::as_str)
            })
            .unwrap_or_default()
            .trim()
            .to_string();
        if token.is_empty() || token.len() > 8192 {
            return Err(SourceError::parse("huangju.auth", "未返回有效的访客授权"));
        }
        self.store_token(Some(token.clone()));
        Ok(token)
    }

    /// 带令牌请求；401/403 时丢弃令牌重试一次。
    async fn get_json(&self, env: &SourceEnv, path: &str) -> Result<(Value, String), SourceError> {
        for attempt in 0..2 {
            let token = self.guest_token(env).await?;
            let request = FetchRequest::get(format!("{API_BASE}{path}"))
                .header("Authorization", format!("Bearer {token}"))
                .header("User-Agent", USER_AGENT)
                .header("Accept", "application/json, text/plain, */*")
                .header("Referer", format!("{SITE}/"))
                .header("Origin", SITE);
            match env.text(request).await {
                Ok(body) => {
                    let value: Value = serde_json::from_str(&body).map_err(|err| {
                        SourceError::parse("huangju", format!("{err}: {body:.120}"))
                    })?;
                    return Ok((value, token));
                }
                Err(err) if attempt == 0 && is_unauthorized(&err) => {
                    self.store_token(None);
                }
                Err(err) => return Err(err),
            }
        }
        Err(SourceError::parse("huangju.auth", "访客授权失效，请重试"))
    }

    fn catalog_path(category: &str, page: u32) -> String {
        let page = page.max(1);
        let category = category.trim();
        let filter = if category.is_empty() {
            format!("sort=hot&page={page}")
        } else if category == NEWEST {
            format!("sort=new&page={page}")
        } else {
            format!("category={}&page={page}", encode_component(category))
        };
        format!("/dramas?{filter}")
    }

    fn detail_path(source_id: &str) -> String {
        format!("/dramas/{}", encode_component(source_id))
    }
}

#[async_trait]
impl SourcePlugin for HuangjuSource {
    fn meta(&self) -> SourceMeta {
        self.meta.clone()
    }

    async fn catalog(
        &self,
        env: &SourceEnv,
        page: u32,
        category: &str,
    ) -> Result<Page, SourceError> {
        let (value, _) = self
            .get_json(env, &Self::catalog_path(category, page))
            .await?;
        let items = items_from(&value)?;
        let page_size = value
            .get("pageSize")
            .and_then(Value::as_u64)
            .unwrap_or(PAGE_SIZE as u64)
            .max(1);
        let has_more = match value.get("total").and_then(Value::as_u64) {
            Some(total) => (page as u64) * page_size < total,
            None => items.len() as u64 >= page_size,
        };
        Ok(Page {
            items,
            has_more,
            page,
            warning: String::new(),
        })
    }

    async fn detail(&self, env: &SourceEnv, source_id: &str) -> Result<Detail, SourceError> {
        let (value, _) = self.get_json(env, &Self::detail_path(source_id)).await?;
        let mut drama = drama_from_node(&value)?;
        drama.id = Drama::identity("huangju", source_id);
        drama.source = "huangju".into();
        drama.source_id = source_id.to_string();

        let episodes = value
            .get("episodes")
            .and_then(Value::as_array)
            .ok_or_else(|| SourceError::parse("huangju.detail", "缺少 episodes"))?;
        let mut chapters = Vec::with_capacity(episodes.len());
        for (index, node) in episodes.iter().enumerate() {
            let id = pick(node, &["id"]);
            if id.is_empty() {
                continue;
            }
            let number = node
                .get("epNo")
                .and_then(Value::as_u64)
                .map(|value| value as u32)
                .unwrap_or(index as u32 + 1)
                .max(1);
            let title = pick(node, &["title"]);
            chapters.push(Chapter {
                id: format!("{source_id}:{number}"),
                title: if title.is_empty() {
                    format!("第{number}集")
                } else {
                    title
                },
                source: "huangju".into(),
                // 这里存的是分集数字 id，取流时拼进 `/play/<id>`。
                video_url: id,
                referer: format!("{SITE}/"),
                ..Default::default()
            });
        }
        chapters.sort_by_key(|chapter| {
            chapter
                .id
                .rsplit(':')
                .next()
                .and_then(|tail| tail.parse::<u32>().ok())
                .unwrap_or(u32::MAX)
        });
        if chapters.is_empty() {
            return Err(SourceError::parse("huangju.detail", "未返回可播放分集"));
        }
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
        let path = format!("/dramas?q={}&page={}", encode_component(query), page.max(1));
        let (value, _) = self.get_json(env, &path).await?;
        let items = items_from(&value)?;
        let page_size = value
            .get("pageSize")
            .and_then(Value::as_u64)
            .unwrap_or(PAGE_SIZE as u64)
            .max(1);
        let has_more = match value.get("total").and_then(Value::as_u64) {
            Some(total) => (page as u64) * page_size < total,
            None => items.len() as u64 >= page_size,
        };
        Ok(Page {
            items,
            has_more,
            page,
            warning: String::new(),
        })
    }

    async fn resolve(
        &self,
        env: &SourceEnv,
        _drama: &Drama,
        chapter: &Chapter,
    ) -> Result<Media, SourceError> {
        let episode_id = chapter.video_url.trim();
        if episode_id.is_empty() {
            return Err(SourceError::parse("huangju.resolve", "分集缺少播放标识"));
        }
        let token = self.guest_token(env).await?;
        let path = format!("/play/{}", encode_component(episode_id));
        let response = env
            .transport
            .fetch(
                FetchRequest::get(format!("{API_BASE}{path}"))
                    .header("Authorization", format!("Bearer {token}"))
                    .header("User-Agent", USER_AGENT)
                    .header("Referer", format!("{SITE}/"))
                    .header("Origin", SITE),
            )
            .await?;
        response.ensure_success()?;
        let body = response.text();
        let value: Value = serde_json::from_str(&body)
            .map_err(|err| SourceError::parse("huangju.resolve", format!("{err}")))?;
        let url = pick(&value, &["url"]);
        if url.is_empty() {
            return Err(SourceError::parse("huangju.resolve", "未返回播放地址"));
        }
        // 媒体域走 CDN 签名：把本次响应下发的 Cookie 带给播放器与下载器。
        let cookies = cookie_header(&response.headers);
        Ok(Media {
            url,
            referer: format!("{SITE}/"),
            cookies,
            origin: SITE.to_string(),
            ..Default::default()
        })
    }
}

/// 401/403 都视为令牌失效。用类型化状态码判断，不靠错误文案匹配。
fn is_unauthorized(error: &SourceError) -> bool {
    matches!(error.http_status(), Some(401) | Some(403))
}

/// 从响应头拼出 `Cookie:` 值。
///
/// 传输层把多个 `set-cookie` 用换行拼进同一个键；这里按行拆分，只取
/// `name=value` 部分，丢掉 `Domain` / `Path` / `Expires` 等属性。
fn cookie_header(headers: &guo_source_api::HeaderMap) -> String {
    let Some(raw) = headers.get("set-cookie") else {
        return String::new();
    };
    let mut pairs = Vec::new();
    for line in raw.split('\n') {
        // 一条 `Set-Cookie` 形如 `name=value; Attr=..; Attr`，只有第一段是 Cookie。
        let pair = line.split(';').next().unwrap_or_default().trim();
        let Some((name, value)) = pair.split_once('=') else {
            continue;
        };
        let name = name.trim();
        let value = value.trim();
        if name.is_empty() || value.is_empty() || is_cookie_attribute(name) {
            continue;
        }
        pairs.push(format!("{name}={value}"));
    }
    pairs.join("; ")
}

/// `Set-Cookie` 里 `;` 之后是属性；若整行以属性开头（没有 Cookie 名）要跳过。
fn is_cookie_attribute(name: &str) -> bool {
    const ATTRIBUTES: [&str; 7] = [
        "domain", "path", "expires", "max-age", "secure", "httponly", "samesite",
    ];
    ATTRIBUTES
        .iter()
        .any(|attribute| name.eq_ignore_ascii_case(attribute))
}

fn items_from(value: &Value) -> Result<Vec<Drama>, SourceError> {
    let rows = value
        .get("items")
        .and_then(Value::as_array)
        .ok_or_else(|| SourceError::parse("huangju.catalog", "缺少 items"))?;
    let mut items = Vec::new();
    for row in rows {
        items.push(drama_from_node(row)?);
    }
    Ok(items)
}

fn drama_from_node(node: &Value) -> Result<Drama, SourceError> {
    let source_id = pick(node, &["slug"]);
    if source_id.is_empty() {
        return Err(SourceError::parse("huangju", "条目缺少 slug"));
    }
    let status = match pick(node, &["status"]).as_str() {
        "completed" => "finished",
        "ongoing" => "ongoing",
        _ => "",
    };
    Ok(Drama {
        id: Drama::identity("huangju", &source_id),
        source: "huangju".into(),
        source_id,
        title: pick(node, &["title"]),
        description: pick(node, &["description"]),
        cover: pick(node, &["coverUrl"]),
        episodes: node
            .get("totalEpisodes")
            .and_then(Value::as_u64)
            .unwrap_or(0) as u32,
        category: pick(node, &["category"]),
        release_status: status.to_string(),
        ..Default::default()
    })
}

fn pick(node: &Value, keys: &[&str]) -> String {
    for key in keys {
        let Some(value) = node.get(*key) else {
            continue;
        };
        if let Some(text) = value.as_str() {
            if !text.trim().is_empty() {
                return text.trim().to_string();
            }
        }
        if let Some(number) = value.as_i64() {
            return number.to_string();
        }
    }
    String::new()
}

/// 生成 UUID v4 形式的设备标识。只用于申请访客授权，不参与签名。
fn device_id() -> String {
    let mut bytes = [0u8; 16];
    // 用系统时间与地址做种子；不追求密码学强度，只要每次进程不同。
    let seed = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos() as u64)
        .unwrap_or(0)
        ^ (std::process::id() as u64).rotate_left(17)
        ^ (&bytes as *const _ as usize as u64);
    let mut state = seed | 1;
    for chunk in bytes.chunks_mut(8) {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        let bytes_of = state.to_le_bytes();
        chunk.copy_from_slice(&bytes_of[..chunk.len()]);
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
    )
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
    fn device_id_looks_like_uuid_v4() {
        let id = device_id();
        assert_eq!(id.len(), 36);
        let parts: Vec<&str> = id.split('-').collect();
        assert_eq!(
            parts.iter().map(|part| part.len()).collect::<Vec<_>>(),
            vec![8, 4, 4, 4, 12]
        );
        assert!(id.chars().all(|ch| ch == '-' || ch.is_ascii_hexdigit()));
        assert_eq!(&id[14..15], "4", "版本位必须是 4");
    }

    #[test]
    fn device_ids_differ_between_calls() {
        assert_ne!(device_id(), device_id());
    }

    #[test]
    fn catalog_path_switches_between_hot_newest_and_category() {
        assert_eq!(
            HuangjuSource::catalog_path("", 2),
            "/dramas?sort=hot&page=2"
        );
        assert_eq!(
            HuangjuSource::catalog_path(NEWEST, 1),
            "/dramas?sort=new&page=1"
        );
        assert_eq!(
            HuangjuSource::catalog_path("urban", 3),
            "/dramas?category=urban&page=3"
        );
    }

    #[test]
    fn cookie_header_keeps_only_name_value_pairs() {
        let mut headers = guo_source_api::HeaderMap::new();
        headers.insert(
            "set-cookie".into(),
            "Policy=abc; Domain=.huangju.net; Path=/; Secure\nSignature=xyz~1; Path=/".into(),
        );
        assert_eq!(cookie_header(&headers), "Policy=abc; Signature=xyz~1");

        // 没有 Cookie 名、只有属性的行要整行丢弃。
        let mut attributes_only = guo_source_api::HeaderMap::new();
        attributes_only.insert("set-cookie".into(), "; Path=/; Secure".into());
        assert_eq!(cookie_header(&attributes_only), "");
    }

    #[test]
    fn cookie_header_is_empty_without_header() {
        assert_eq!(cookie_header(&guo_source_api::HeaderMap::new()), "");
    }

    #[test]
    fn drama_requires_slug_and_maps_completed_status() {
        let node = serde_json::json!({
            "id": 1728,
            "slug": "yanyu-2788",
            "title": "我的女友景甜",
            "coverUrl": "https://video.huangju.net/posters/a.jpg",
            "status": "completed",
            "totalEpisodes": 8
        });
        let drama = drama_from_node(&node).expect("drama");
        assert_eq!(drama.source_id, "yanyu-2788");
        assert_eq!(drama.id, "huangju:yanyu-2788");
        assert_eq!(drama.release_status, "finished");
        assert_eq!(drama.episodes, 8);

        let missing = serde_json::json!({"id": 1, "title": "无 slug"});
        assert!(drama_from_node(&missing).is_err());
    }

    #[test]
    fn detail_path_encodes_source_id() {
        assert_eq!(
            HuangjuSource::detail_path("yanyu-2788"),
            "/dramas/yanyu-2788"
        );
        assert_eq!(HuangjuSource::detail_path("a b"), "/dramas/a%20b");
    }
}
