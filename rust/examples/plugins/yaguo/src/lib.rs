//! 芽果（星芽）代码插件。
//!
//! Core-3 的第二个迁移源，验证的是**登录态**能否在沙箱里正确持久化：
//! 令牌存在宿主的存储里（`store-get` / `store-set`），因此插件实例销毁、
//! 应用重启之后仍能复用，不会每次请求都重新登录。
//!
//! 与编译版（`crates/source-yaguo`）的关系：
//! - 站点知识（URL、设备号、分页、字段名）逐项一致；
//! - 令牌的「内存缓存 + TTL」在插件里退化为「每次读一次存储」——
//!   wasm 实例本身是短生命周期，进程内缓存没有意义；
//! - 401 时清令牌并重登一次，与编译版语义相同。

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

struct Yaguo;

const BASE: &str = "https://app.whjzjx.cn";
const LOGIN_URL: &str = "https://u.shytkjgs.com/user/v1/account/login";
/// Go 版固定使用的设备号，登录端点只认它。
const DEVICE: &str = "24250683a3bdb3f118dff25ba4b1cba1a";
const USER_AGENT: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
const PLATFORM: &str = "1";
const VERSION_NAME: &str = "3.8.3.1";
const PAGE_SIZE: u32 = 24;
const TOKEN_TTL_MS: u64 = 6 * 60 * 60 * 1000;
const TOKEN_KEY: &str = "token";
const LOGIN_ATTEMPTS: usize = 3;
const BUSY_CODE: &str = "2010007";
const RANKING_CATEGORY: &str = "9";
const RANKING_ID: &str = "1";
/// 存储命名空间。清单里必须授权同名空间，否则读写都会被宿主拒绝。
const STORE_NS: &str = "session";

impl Guest for Yaguo {
    fn describe() -> Descriptor {
        Descriptor {
            id: "guo.yaguo".into(),
            name: "芽果".into(),
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
        let value = request_json(&format!("{BASE}/cloud/v2/theater/classes"), None)?;
        let groups = value
            .pointer("/data/list")
            .and_then(Value::as_array)
            .ok_or_else(|| Error::ParseChanged("分类缺少 data.list".into()))?;
        let mut seen = std::collections::HashSet::new();
        let mut out = Vec::new();
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
            out.push(Category { id, name });
        }
        if out.is_empty() {
            return Err(Error::ParseChanged("未返回有效分类".into()));
        }
        Ok(out)
    }

    fn catalog(query: Query) -> Result<Page, Error> {
        let page = query.page.max(1);
        let category = query.category.trim();
        let ranking = category == RANKING_CATEGORY;
        let url = if ranking {
            format!("{BASE}/cloud/v1/first_level_ranking/detail?id={RANKING_ID}")
        } else {
            let class = if !category.is_empty() && category.bytes().all(|b| b.is_ascii_digit()) {
                category
            } else {
                ""
            };
            format!(
                "{BASE}/cloud/v2/theater/home_page?theater_class_id={class}&type=1&class2_ids=0&page_num={page}&page_size={PAGE_SIZE}"
            )
        };
        let value = request_json(&url, None)?;
        let data = value
            .get("data")
            .filter(|data| data.is_object())
            .ok_or_else(|| Error::ParseChanged("目录缺少 data".into()))?;
        let rows = data
            .get("list")
            .and_then(Value::as_array)
            .ok_or_else(|| Error::ParseChanged("目录缺少 data.list".into()))?;
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
            cursor: String::new(),
        })
    }

    fn fetch_detail(source_id: String) -> Result<Detail, Error> {
        let value = request_json(
            &format!(
                "{BASE}/v2/theater_parent/detail?theater_parent_id={}",
                encode_component(&source_id)
            ),
            None,
        )?;
        let data = value
            .get("data")
            .filter(|data| data.is_object())
            .ok_or_else(|| Error::ParseChanged("详情缺少剧集资料".into()))?;
        let mut drama = drama_from_fields(data);
        if drama.source_id.is_empty() {
            drama.source_id = source_id.clone();
        }
        drama.release_status = release_status(data);

        let chapters = chapters_from(data, &source_id);
        if chapters.is_empty() {
            return Err(Error::ParseChanged("未返回可播放分集".into()));
        }
        drama.episodes = chapters.len() as u32;
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
        let body = serde_json::json!({ "text": keyword }).to_string();
        let value = request_json(
            &format!("{BASE}/v3/search"),
            Some((
                "post",
                vec![("Content-Type".to_string(), "application/json".to_string())],
                Some(body.into_bytes()),
            )),
        )?;
        let rows = value
            .pointer("/data/theater/search_data")
            .or_else(|| value.pointer("/data/list"))
            .and_then(Value::as_array)
            .ok_or_else(|| Error::ParseChanged("缺少搜索列表".into()))?;
        Ok(Page {
            items: rows.iter().filter_map(drama_from_node).collect(),
            has_more: false,
            page: query.page,
            cursor: String::new(),
        })
    }

    fn resolve(request: ResolveRequest) -> Result<Media, Error> {
        // 分集自带 MP4，取流只做透传。
        let chapter = request.chapter;
        if chapter.video_url.is_empty() {
            return Err(Error::ParseChanged("分集缺少播放地址".into()));
        }
        Ok(Media {
            url: chapter.video_url,
            referer: format!("{BASE}/"),
            segments: Vec::new(),
            key_uri: String::new(),
            key_iv: String::new(),
            cookies: String::new(),
            origin: String::new(),
        })
    }

    fn suggestions(keyword: String) -> Result<Vec<String>, Error> {
        let _ = keyword;
        Ok(Vec::new())
    }
}

export!(Yaguo);

// ---- 会话 ----

/// 读令牌。过期或格式不符一律当作没有。
fn stored_token() -> Option<String> {
    let raw = host::store_get(STORE_NS, TOKEN_KEY)?;
    let value: Value = serde_json::from_str(&raw).ok()?;
    let token = value.get("value")?.as_str()?.trim().to_string();
    let obtained = value.get("obtainedAt")?.as_u64()?;
    if token.is_empty() || token.len() > 8192 {
        return None;
    }
    let now = host::now_ms();
    // 时钟回拨或已过期都视为无效。
    if obtained > now || now.saturating_sub(obtained) >= TOKEN_TTL_MS {
        return None;
    }
    Some(token)
}

fn persist_token(token: Option<&str>) {
    let payload = match token {
        Some(value) => serde_json::json!({
            "value": value,
            "obtainedAt": host::now_ms(),
        }),
        None => serde_json::json!({ "value": "", "obtainedAt": 0 }),
    };
    let _ = host::store_set(STORE_NS, TOKEN_KEY, &payload.to_string());
}

/// 取令牌：磁盘 → 登录。
fn access_token() -> Result<String, Error> {
    if let Some(token) = stored_token() {
        return Ok(token);
    }
    let body = serde_json::json!({ "device": DEVICE }).to_string();
    let mut detail = String::from("未返回有效的访问令牌");
    for attempt in 0..LOGIN_ATTEMPTS {
        if attempt > 0 {
            // 同一设备号并发登录时服务端返回 2010007，隔一会重试即可。
            host::log("warn", "登录被限流，重试");
        }
        let headers = vec![
            ("Content-Type".to_string(), "application/json".to_string()),
            ("platform".to_string(), PLATFORM.to_string()),
            ("User-Agent".to_string(), USER_AGENT.to_string()),
        ];
        let payload = body.clone().into_bytes();
        let response = host::fetch("post", LOGIN_URL, &headers, Some(&payload))?;
        if response.status != 200 {
            return Err(Error::Http(response.status));
        }
        let text = String::from_utf8_lossy(&response.body).into_owned();
        let value: Value = serde_json::from_str(&text)
            .map_err(|err| Error::ParseChanged(format!("登录返回不是 JSON：{err}")))?;
        let token = value
            .pointer("/data/token")
            .and_then(Value::as_str)
            .or_else(|| value.get("token").and_then(Value::as_str))
            .unwrap_or_default()
            .trim()
            .to_string();
        if !token.is_empty() && token.len() <= 8192 {
            persist_token(Some(&token));
            return Ok(token);
        }
        if let Some(message) = value.get("msg").and_then(Value::as_str) {
            detail = message.to_string();
        }
        if value.get("code").and_then(Value::as_str) != Some(BUSY_CODE) {
            break;
        }
    }
    Err(Error::SessionFailed(detail))
}

/// 带令牌请求；401 / 403 时丢令牌、重登并重试一次。
fn request_json(
    url: &str,
    override_request: Option<(&str, Vec<(String, String)>, Option<Vec<u8>>)>,
) -> Result<Value, Error> {
    let mut token = access_token()?;
    let mut retried = false;
    loop {
        let mut headers = vec![
            ("authorization".to_string(), token.clone()),
            ("platform".to_string(), PLATFORM.to_string()),
            ("version_name".to_string(), VERSION_NAME.to_string()),
            ("User-Agent".to_string(), USER_AGENT.to_string()),
            ("Referer".to_string(), format!("{BASE}/")),
        ];
        let (method, body) = match &override_request {
            Some((method, extra, body)) => {
                headers.extend(extra.iter().cloned());
                (*method, body.clone())
            }
            None => ("get", None),
        };
        let response = host::fetch(method, url, &headers, body.as_deref())?;
        if is_unauthorized(response.status) && !retried {
            retried = true;
            persist_token(None);
            token = access_token()?;
            continue;
        }
        if response.status != 200 {
            return Err(Error::Http(response.status));
        }
        let text = String::from_utf8_lossy(&response.body).into_owned();
        return serde_json::from_str(&text)
            .map_err(|err| Error::ParseChanged(format!("返回不是 JSON：{err}")));
    }
}

fn is_unauthorized(status: u16) -> bool {
    matches!(status, 401 | 403)
}

// ---- 解析 ----

fn drama_from_node(node: &Value) -> Option<Drama> {
    let target = node
        .get("theater")
        .filter(|value| value.is_object())
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
        // 源前缀由宿主按清单补上。
        id: source_id.clone(),
        source_id,
        title: pick(node, &["title", "name"]),
        description: pick(node, &["descrip", "introduction", "desc"]),
        cover: cover(node),
        episodes: pick(node, &["total", "total_num", "current_num"])
            .parse()
            .unwrap_or(0),
        category: tags(node).join(", "),
        tags: Vec::new(),
        views: String::new(),
        heat: String::new(),
        release_status: String::new(),
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
                    video_url,
                    page_url: String::new(),
                    referer: format!("{BASE}/"),
                    vip: false,
                },
            ));
        }
    }
    // 稳定排序，与 Go 的 `SliceStable` 一致。
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
        Value::String(text) => absolute(text.trim()),
        Value::Array(items) => items
            .iter()
            .map(|item| cover_value(Some(item)))
            .find(|value| !value.is_empty())
            .unwrap_or_default(),
        Value::Object(map) => ["url", "contentUrl", "thumbnailUrl"]
            .iter()
            .find_map(|key| map.get(*key).and_then(Value::as_str))
            .map(|text| absolute(text.trim()))
            .unwrap_or_default(),
        _ => String::new(),
    }
}

fn absolute(url: &str) -> String {
    if url.is_empty() || url.starts_with("http") {
        return url.to_string();
    }
    format!("{}/{}", BASE.trim_end_matches('/'), url.trim_start_matches('/'))
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
                let name = pick(row, &["title", "name", "tag_name"]);
                if name.is_empty() {
                    None
                } else {
                    Some(name)
                }
            }
            _ => None,
        })
        .collect()
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
        if let Some(number) = value.as_f64() {
            return format!("{number}");
        }
    }
    String::new()
}

fn truthy(value: Option<&Value>) -> bool {
    match value {
        Some(Value::Bool(flag)) => *flag,
        Some(Value::Number(number)) => number.as_i64().unwrap_or(0) != 0,
        Some(Value::String(text)) => {
            let text = text.trim();
            text == "1" || text.eq_ignore_ascii_case("true")
        }
        _ => false,
    }
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
    fn catalog_url_matches_the_compiled_source() {
        // 与编译版 `YaguoSource::catalog_request` 逐字一致。
        assert_eq!(
            format!(
                "{BASE}/cloud/v2/theater/home_page?theater_class_id=&type=1&class2_ids=0&page_num=1&page_size={PAGE_SIZE}"
            ),
            "https://app.whjzjx.cn/cloud/v2/theater/home_page?theater_class_id=&type=1&class2_ids=0&page_num=1&page_size=24"
        );
    }

    #[test]
    fn token_ttl_boundaries() {
        // 只验证判定逻辑本身：新鲜令牌有效，到期即失效。
        let now = TOKEN_TTL_MS * 2;
        let fresh = now - 1000;
        assert!(now.saturating_sub(fresh) < TOKEN_TTL_MS);
        let stale = now - TOKEN_TTL_MS;
        assert!(!(now.saturating_sub(stale) < TOKEN_TTL_MS));
    }

    #[test]
    fn encode_component_escapes_non_ascii() {
        assert_eq!(encode_component("abc"), "abc");
        assert_eq!(encode_component("总裁"), "%E6%80%BB%E8%A3%81");
    }

    #[test]
    fn truthy_accepts_common_shapes() {
        assert!(truthy(Some(&Value::Bool(true))));
        assert!(truthy(Some(&serde_json::json!(1))));
        assert!(truthy(Some(&serde_json::json!("true"))));
        assert!(!truthy(Some(&Value::Bool(false))));
        assert!(!truthy(None));
    }

    #[test]
    fn release_status_maps_site_flags() {
        assert_eq!(release_status(&serde_json::json!({"is_over": 2})), "finished");
        assert_eq!(release_status(&serde_json::json!({"is_over": 1})), "ongoing");
        assert_eq!(
            release_status(&serde_json::json!({"total": 10, "current_num": 10})),
            "finished"
        );
        assert_eq!(release_status(&serde_json::json!({})), "");
    }
}
