//! 剧果代码插件。
//!
//! Core-3 的第四个迁移源，验证的是 **WIT v2 的播放凭证透传**：
//! 取流响应会下发 CDN 签名 Cookie，播放器与下载器都必须带上它才能拉到
//! 播放列表与分片。插件的 `Media.cookies` / `Media.origin` 会由宿主原样
//! 传给播放计划。
//!
//! 访客令牌：`POST /auth/guest` 只认 UUID v4 格式的 `deviceId`。插件用宿主的
//! `random` 生成，并把令牌存进宿主存储——与芽果同一套会话语义。

use serde_json::Value;

wit_bindgen::generate!({
    path: "../../../crates/plugin-wasm/wit/source-plugin.wit",
    world: "plugin",
});

use exports::guo::source::source::Guest;
use guo::source::host;
use guo::source::types::{
    Category, Chapter, Descriptor, Detail, Drama, Error, Media, Page, Query, ResolveRequest,
};

struct Huangju;

const API_BASE: &str = "https://api.huangju.net";
const SITE: &str = "https://huangju.net";
const USER_AGENT: &str = "Mozilla/5.0 (Linux; Android 11; Pixel 5) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36";
const PAGE_SIZE: u32 = 20;
/// 「最新」伪分类，与编译版一致。
const NEWEST: &str = "__newest";
const TOKEN_KEY: &str = "guest-token";
const DEVICE_KEY: &str = "device-id";
const STORE_NS: &str = "session";

impl Guest for Huangju {
    fn describe() -> Descriptor {
        Descriptor {
            id: "guo.huangju".into(),
            name: "剧果".into(),
            group: "duanju".into(),
            api_level: 1,
            capabilities: vec![
                "catalog".into(),
                "detail".into(),
                "search".into(),
                "categories".into(),
                "resolve".into(),
            ],
        }
    }

    fn categories() -> Result<Vec<Category>, Error> {
        // 编译版声明了该能力但没实现；插件保持一致，返回空让宿主隐藏筛选。
        Ok(Vec::new())
    }

    fn catalog(query: Query) -> Result<Page, Error> {
        let value = get_json(&catalog_path(&query.category, query.page))?;
        page_from(&value, query.page)
    }

    fn fetch_detail(source_id: String) -> Result<Detail, Error> {
        let value = get_json(&format!("/dramas/{}", encode_component(&source_id)))?;
        let mut drama = drama_from_node(&value)?;

        let episodes = value
            .get("episodes")
            .and_then(Value::as_array)
            .ok_or_else(|| Error::ParseChanged("详情缺少 episodes".into()))?;
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
                // 分集数字 id，取流时拼进 `/play/<id>`。
                video_url: id,
                page_url: String::new(),
                referer: format!("{SITE}/"),
                vip: false,
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
            return Err(Error::ParseChanged("未返回可播放分集".into()));
        }
        Ok(Detail { drama, chapters })
    }

    fn search(query: Query) -> Result<Page, Error> {
        let keyword = query.keyword.trim();
        if keyword.is_empty() {
            return Ok(Page {
                items: Vec::new(),
                has_more: false,
                page: query.page,
                cursor: String::new(),
            });
        }
        let path = format!(
            "/dramas?q={}&page={}",
            encode_component(keyword),
            query.page.max(1)
        );
        let value = get_json(&path)?;
        page_from(&value, query.page)
    }

    fn resolve(request: ResolveRequest) -> Result<Media, Error> {
        let episode_id = request.chapter.video_url.trim().to_string();
        if episode_id.is_empty() {
            return Err(Error::ParseChanged("分集缺少播放标识".into()));
        }
        let token = guest_token()?;
        let path = format!("/play/{}", encode_component(&episode_id));
        let headers = vec![
            ("Authorization".to_string(), format!("Bearer {token}")),
            ("User-Agent".to_string(), USER_AGENT.to_string()),
            ("Referer".to_string(), format!("{SITE}/")),
            ("Origin".to_string(), SITE.to_string()),
        ];
        let response = host::fetch("get", &format!("{API_BASE}{path}"), &headers, None)?;
        if is_unauthorized(response.status) {
            persist_token(None);
            return Err(Error::SessionFailed("访客授权失效".into()));
        }
        if response.status != 200 {
            return Err(Error::Http(response.status));
        }
        let body = String::from_utf8_lossy(&response.body).into_owned();
        let value: Value = serde_json::from_str(&body)
            .map_err(|err| Error::ParseChanged(format!("取流返回不是 JSON：{err}")))?;
        let url = pick(&value, &["url"]);
        if url.is_empty() {
            return Err(Error::ParseChanged("未返回播放地址".into()));
        }
        Ok(Media {
            url,
            referer: format!("{SITE}/"),
            segments: Vec::new(),
            key_uri: String::new(),
            key_iv: String::new(),
            // WIT v2：把 CDN 签名 Cookie 带回宿主，播放器与下载器都要带它。
            cookies: cookie_header(&response.headers),
            origin: SITE.to_string(),
        })
    }

    fn suggestions(keyword: String) -> Result<Vec<String>, Error> {
        let _ = keyword;
        Ok(Vec::new())
    }
}

export!(Huangju);

// ---- 站点地址 ----

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

// ---- 会话 ----

/// 设备号：首次生成后固定存下来。换设备号会让访客令牌一起失效。
fn device_id() -> String {
    if let Some(existing) = host::store_get(STORE_NS, DEVICE_KEY) {
        if existing.len() == 36 && existing.chars().all(|ch| ch == '-' || ch.is_ascii_hexdigit()) {
            return existing;
        }
    }
    let bytes = host::random(16);
    let mut out = String::with_capacity(36);
    for (index, byte) in bytes.iter().enumerate().take(16) {
        if matches!(index, 4 | 6 | 8 | 10) {
            out.push('-');
        }
        let mut value = *byte;
        if index == 6 {
            // 版本位固定为 4（UUID v4）。
            value = (value & 0x0f) | 0x40;
        }
        if index == 8 {
            // 变体位：10xx。
            value = (value & 0x3f) | 0x80;
        }
        out.push_str(&format!("{value:02x}"));
    }
    let _ = host::store_set(STORE_NS, DEVICE_KEY, &out);
    out
}

fn persist_token(token: Option<&str>) {
    match token {
        Some(value) => {
            let _ = host::store_set(STORE_NS, TOKEN_KEY, value);
        }
        None => {
            let _ = host::store_set(STORE_NS, TOKEN_KEY, "");
        }
    }
}

fn cached_token() -> Option<String> {
    let value = host::store_get(STORE_NS, TOKEN_KEY)?;
    let value = value.trim().to_string();
    if value.is_empty() || value.len() > 8192 {
        None
    } else {
        Some(value)
    }
}

fn guest_token() -> Result<String, Error> {
    if let Some(token) = cached_token() {
        return Ok(token);
    }
    let body = serde_json::json!({ "deviceId": device_id() }).to_string();
    let payload = body.into_bytes();
    let headers = vec![
        ("Content-Type".to_string(), "application/json".to_string()),
        ("User-Agent".to_string(), USER_AGENT.to_string()),
        ("Referer".to_string(), format!("{SITE}/")),
        ("Origin".to_string(), SITE.to_string()),
    ];
    let response = host::fetch(
        "post",
        &format!("{API_BASE}/auth/guest"),
        &headers,
        Some(&payload),
    )?;
    if response.status != 200 {
        return Err(Error::Http(response.status));
    }
    let text = String::from_utf8_lossy(&response.body).into_owned();
    let value: Value = serde_json::from_str(&text)
        .map_err(|err| Error::ParseChanged(format!("授权返回不是 JSON：{err}")))?;
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
        return Err(Error::SessionFailed("未返回有效的访客授权".into()));
    }
    persist_token(Some(&token));
    Ok(token)
}

/// 带令牌请求；401 / 403 时丢令牌重试一次。
fn get_json(path: &str) -> Result<Value, Error> {
    for attempt in 0..2 {
        let token = guest_token()?;
        let headers = vec![
            ("Authorization".to_string(), format!("Bearer {token}")),
            ("User-Agent".to_string(), USER_AGENT.to_string()),
            (
                "Accept".to_string(),
                "application/json, text/plain, */*".to_string(),
            ),
            ("Referer".to_string(), format!("{SITE}/")),
            ("Origin".to_string(), SITE.to_string()),
        ];
        let response = host::fetch("get", &format!("{API_BASE}{path}"), &headers, None)?;
        if is_unauthorized(response.status) && attempt == 0 {
            persist_token(None);
            continue;
        }
        if response.status != 200 {
            return Err(Error::Http(response.status));
        }
        let text = String::from_utf8_lossy(&response.body).into_owned();
        return serde_json::from_str(&text)
            .map_err(|err| Error::ParseChanged(format!("返回不是 JSON：{err}")));
    }
    Err(Error::SessionFailed("访客授权失效，请重试".into()))
}

fn is_unauthorized(status: u16) -> bool {
    matches!(status, 401 | 403)
}

/// 从响应头拼出 `Cookie:` 值。
///
/// 一条 `Set-Cookie` 是 `name=value; Attr=..`，只有第一段是 Cookie。
/// 多个同名头由宿主用换行拼接，因此这里按行拆。
fn cookie_header(headers: &[(String, String)]) -> String {
    let Some((_, raw)) = headers
        .iter()
        .find(|(name, _)| name.eq_ignore_ascii_case("set-cookie"))
    else {
        return String::new();
    };
    let mut pairs = Vec::new();
    for line in raw.split('\n') {
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

fn is_cookie_attribute(name: &str) -> bool {
    const ATTRIBUTES: [&str; 7] = [
        "domain", "path", "expires", "max-age", "secure", "httponly", "samesite",
    ];
    ATTRIBUTES
        .iter()
        .any(|attribute| name.eq_ignore_ascii_case(attribute))
}

// ---- 解析 ----

fn page_from(value: &Value, page: u32) -> Result<Page, Error> {
    let rows = value
        .get("items")
        .and_then(Value::as_array)
        .ok_or_else(|| Error::ParseChanged("目录缺少 items".into()))?;
    let mut items = Vec::new();
    for row in rows {
        if let Ok(drama) = drama_from_node(row) {
            items.push(drama);
        }
    }
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
        cursor: String::new(),
    })
}

fn drama_from_node(node: &Value) -> Result<Drama, Error> {
    let source_id = pick(node, &["slug"]);
    if source_id.is_empty() {
        return Err(Error::ParseChanged("条目缺少 slug".into()));
    }
    let status = match pick(node, &["status"]).as_str() {
        "completed" => "finished",
        "ongoing" => "ongoing",
        _ => "",
    };
    Ok(Drama {
        // 源前缀由宿主按清单补上。
        id: source_id.clone(),
        source_id,
        title: pick(node, &["title"]),
        description: pick(node, &["description"]),
        cover: pick(node, &["coverUrl"]),
        episodes: node
            .get("totalEpisodes")
            .and_then(Value::as_u64)
            .unwrap_or(0) as u32,
        category: category_of(node),
        tags: Vec::new(),
        views: String::new(),
        heat: String::new(),
        release_status: status.to_string(),
    })
}

fn category_of(node: &Value) -> String {
    if let Some(list) = node.get("categories").and_then(Value::as_array) {
        let names: Vec<String> = list
            .iter()
            .filter_map(|item| item.as_str().map(str::to_string).or_else(|| {
                item.get("name").and_then(Value::as_str).map(str::to_string)
            }))
            .collect();
        if !names.is_empty() {
            return names.join(",");
        }
    }
    pick(node, &["category"])
}

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
        }
        if let Some(number) = value.as_i64() {
            return number.to_string();
        }
    }
    String::new()
}

fn encode_component(value: &str) -> String {
    value
        .bytes()
        .map(|byte| match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (byte as char).to_string()
            }
            _ => format!("%{byte:02X}"),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_path_matches_the_compiled_source() {
        assert_eq!(catalog_path("", 2), "/dramas?sort=hot&page=2");
        assert_eq!(catalog_path(NEWEST, 1), "/dramas?sort=new&page=1");
        assert_eq!(catalog_path("urban", 3), "/dramas?category=urban&page=3");
    }

    #[test]
    fn cookie_header_keeps_only_name_value_pairs() {
        let headers = vec![(
            "set-cookie".to_string(),
            "cf_sign=abc123; Path=/; HttpOnly\nsession=xyz; Domain=.net".to_string(),
        )];
        assert_eq!(cookie_header(&headers), "cf_sign=abc123; session=xyz");
    }

    #[test]
    fn cookie_header_skips_attribute_only_lines() {
        let headers = vec![(
            "set-cookie".to_string(),
            "Path=/\nreal=1".to_string(),
        )];
        assert_eq!(cookie_header(&headers), "real=1");
    }

    #[test]
    fn cookie_header_is_empty_without_header() {
        assert!(cookie_header(&[]).is_empty());
        assert!(cookie_header(&[("etag".to_string(), "x".to_string())]).is_empty());
    }

    #[test]
    fn encode_component_escapes_non_ascii() {
        assert_eq!(encode_component("abc"), "abc");
        assert_eq!(encode_component("总裁"), "%E6%80%BB%E8%A3%81");
    }

    #[test]
    fn drama_requires_a_slug() {
        let value = serde_json::json!({ "title": "无 slug" });
        assert!(drama_from_node(&value).is_err());
        let value = serde_json::json!({ "slug": "abc", "title": "剧", "status": "completed" });
        let drama = drama_from_node(&value).expect("应成功");
        assert_eq!(drama.source_id, "abc");
        assert_eq!(drama.release_status, "finished");
    }
}
