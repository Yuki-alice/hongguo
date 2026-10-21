//! 黄果 AI 代码插件。
//!
//! Core-3 的第六个迁移源。它验证两点：
//! 1. **镜像回退**：主站与五个镜像按序尝试，全部失败才算失败；
//! 2. **递归 JSON 挖掘**：目录接口的结构不稳定，剧集对象可能出现在任意嵌套层，
//!    编译版是 `walk_json` 递归找「长得像剧集的对象」——插件用宿主的
//!    `json_path` + 自带递归实现同样语义。
//!
//! 与编译版（`crates/source-huangguo::ai`）逐项对应；分类清单与 Go 版一致。

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

struct HuangguoAi;

const MIRRORS: &[&str] = &[
    "https://huangguoai.com",
    "https://ttvoij.ediayikma.cc",
    "https://thu.ediayikma.cc",
    "https://pku.ediayikma.cc",
    "https://fdu.ediayikma.cc",
    "https://thu.agdkczeyx.cc",
];
const PAGE_SIZE: u32 = 24;

/// 分类清单与 Go 版 `nativeAICategories` 一致。
const CATEGORIES: &[(&str, &str)] = &[
    ("ai-duanju", "AI 短剧"),
    ("ai-manju", "AI 漫剧"),
    ("ai-huanlian", "AI 换脸"),
    ("ai-mogai", "AI 魔改"),
];

impl Guest for HuangguoAi {
    fn describe() -> Descriptor {
        Descriptor {
            // 与插件包 id 保持一致（`pack_component` 按文件名生成 `guo.huangguo-ai`）。
            // 描述符 id 决定注册表里的源 id，两者不一致会让预装与清单对不上。
            id: "guo.huangguo-ai".into(),
            name: "黄果 AI".into(),
            group: "huangguo".into(),
            api_level: 1,
            capabilities: vec![
                "catalog".into(),
                "detail".into(),
                "categories".into(),
            ],
        }
    }

    fn categories() -> Result<Vec<Category>, Error> {
        Ok(CATEGORIES
            .iter()
            .map(|(id, name)| Category {
                id: (*id).to_string(),
                name: (*name).to_string(),
            })
            .collect())
    }

    fn catalog(query: Query) -> Result<Page, Error> {
        let category = query.category.trim();
        let wanted: Vec<(&str, &str)> = if category.is_empty() {
            CATEGORIES.to_vec()
        } else {
            CATEGORIES
                .iter()
                .filter(|(id, _)| *id == category)
                .copied()
                .collect()
        };
        if wanted.is_empty() {
            return Err(Error::ParseChanged("未知分类".into()));
        }
        let mut items = Vec::new();
        let mut seen = std::collections::HashSet::new();
        let mut failures = Vec::new();
        for (id, name) in wanted {
            let path = format!(
                "/api/videos/category/{id}?sort=hot&page={}&size={PAGE_SIZE}",
                query.page.max(1)
            );
            match fetch_text(&path) {
                Ok((body, base)) => {
                    for drama in json_cards(&body, &base, name) {
                        if seen.insert(drama.source_id.clone()) {
                            items.push(drama);
                        }
                    }
                }
                Err(error) => failures.push(format!("{name}: {error}")),
            }
        }
        if items.is_empty() && !failures.is_empty() {
            return Err(Error::Network(failures.join("; ")));
        }
        Ok(Page {
            items,
            // 部分分类失败说明还有别的分类没拉全，提示可以继续翻页。
            has_more: !failures.is_empty(),
            page: query.page,
            cursor: String::new(),
        })
    }

    fn fetch_detail(source_id: String) -> Result<Detail, Error> {
        let id = source_id.trim().trim_matches('/').to_string();
        if id.is_empty() {
            return Err(Error::ParseChanged("缺少剧集标识".into()));
        }
        let id = id.strip_prefix("detail/").unwrap_or(&id).to_string();
        let (body, base) = fetch_text(&format!("/detail/{id}/"))?;

        let mut drama = Drama {
            id: id.clone(),
            source_id: id.clone(),
            title: {
                let from_h1 = first_text(&body, "h1");
                if from_h1.is_empty() {
                    first_text(&body, "title")
                } else {
                    from_h1
                }
            },
            description: meta_content(&body, "description"),
            cover: absolute(&base, &meta_content(&body, "og:image")),
            category: String::new(),
            episodes: 0,
            tags: Vec::new(),
            views: String::new(),
            heat: String::new(),
            release_status: String::new(),
        };
        if drama.title.is_empty() {
            drama.title = id.clone();
        }

        let mut chapters = episode_links(&body, &base, &id);
        if chapters.is_empty() {
            if let Some(url) = media_url(&body, &base) {
                chapters.push(Chapter {
                    id: format!("{id}:1"),
                    title: drama.title.clone(),
                    video_url: url,
                    page_url: format!("{base}/detail/{id}/"),
                    referer: format!("{base}/"),
                    vip: false,
                });
            }
        }
        if chapters.is_empty() {
            return Err(Error::ParseChanged("未解析到可播放分集".into()));
        }
        drama.episodes = chapters.len() as u32;
        Ok(Detail { drama, chapters })
    }

    fn search(query: Query) -> Result<Page, Error> {
        // 编译版不实现搜索（能力位里没有），保持一致。
        let _ = query;
        Ok(Page {
            items: Vec::new(),
            has_more: false,
            page: query.page,
            cursor: String::new(),
        })
    }

    fn resolve(request: ResolveRequest) -> Result<Media, Error> {
        if request.chapter.video_url.is_empty() {
            return Err(Error::ParseChanged("分集缺少播放地址".into()));
        }
        let referer = if request.chapter.referer.is_empty() {
            format!("{}/", MIRRORS[0])
        } else {
            request.chapter.referer.clone()
        };
        Ok(Media {
            url: request.chapter.video_url,
            referer,
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

export!(HuangguoAi);

// ---- 传输：镜像回退 ----

/// 依次尝试主站与镜像，返回第一个成功响应的正文与基地址。
fn fetch_text(path: &str) -> Result<(String, String), Error> {
    let mut last = Error::Empty;
    for base in MIRRORS {
        let url = format!("{}{path}", base.trim_end_matches('/'));
        let headers = vec![("Referer".to_string(), format!("{base}/"))];
        match host::fetch("get", &url, &headers, None) {
            Ok(response) if response.status == 200 => {
                let body = String::from_utf8_lossy(&response.body).into_owned();
                if !body.trim().is_empty() {
                    return Ok((body, (*base).to_string()));
                }
                last = Error::Empty;
            }
            Ok(response) => last = Error::Http(response.status),
            Err(error) => last = error,
        }
    }
    Err(last)
}

// ---- 目录：递归 JSON 挖掘 ----

/// 从 JSON 响应里递归找出剧集对象，与编译版 `walk_json` 等价。
fn json_cards(body: &str, base: &str, category: &str) -> Vec<Drama> {
    let Ok(value) = serde_json::from_str::<Value>(body) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    walk_json(&value, base, category, &mut out);
    out
}

fn walk_json(value: &Value, base: &str, category: &str, out: &mut Vec<Drama>) {
    match value {
        Value::Array(items) => {
            for item in items {
                walk_json(item, base, category, out);
            }
        }
        Value::Object(map) => {
            if let Some(drama) = drama_from_map(map, base, category) {
                out.push(drama);
                return;
            }
            for child in map.values() {
                walk_json(child, base, category, out);
            }
        }
        _ => {}
    }
}

fn drama_from_map(map: &serde_json::Map<String, Value>, base: &str, category: &str) -> Option<Drama> {
    let source_id = pick_map(map, &["id", "videoId", "video_id", "vid", "slug"]);
    let source_id = clean_id(&source_id);
    if source_id.is_empty() {
        return None;
    }
    let title = pick_map(
        map,
        &[
            "title",
            "name",
            "videoTitle",
            "video_title",
            "videoName",
            "video_name",
        ],
    );
    if title.is_empty() {
        return None;
    }
    let cover = pick_map(
        map,
        &[
            "cover",
            "coverUrl",
            "cover_url",
            "coverImage",
            "cover_image",
            "image",
            "imageUrl",
            "thumbnail",
            "poster",
            "posterUrl",
        ],
    );
    Some(Drama {
        id: source_id.clone(),
        source_id,
        title,
        description: pick_map(map, &["desc", "description", "intro", "summary"]),
        cover: absolute(base, &cover),
        category: category.to_string(),
        episodes: 0,
        tags: Vec::new(),
        views: String::new(),
        heat: String::new(),
        release_status: String::new(),
    })
}

fn pick_map(map: &serde_json::Map<String, Value>, keys: &[&str]) -> String {
    for key in keys {
        let Some(value) = map.get(*key) else {
            continue;
        };
        match value {
            Value::String(text) if !text.trim().is_empty() => return text.trim().to_string(),
            Value::Number(number) => return number.to_string(),
            _ => {}
        }
    }
    String::new()
}

/// 清洗 id：详情链接取 `/detail/` 之后的一段；普通值去掉查询串与斜杠。
fn clean_id(value: &str) -> String {
    let value = value.trim();
    if let Some(index) = value.find("/detail/") {
        let rest = &value[index + "/detail/".len()..];
        return rest
            .split(['/', '?', '#'])
            .next()
            .unwrap_or_default()
            .to_string();
    }
    value
        .split(['?', '#'])
        .next()
        .unwrap_or_default()
        .trim_matches('/')
        .to_string()
}

// ---- 详情：锚点解析（走宿主原语） ----

/// 从详情页解析 `/video/...` 链接作为分集。
fn episode_links(body: &str, base: &str, source_id: &str) -> Vec<Chapter> {
    let mut chapters = Vec::new();
    let mut seen = std::collections::HashSet::new();
    // 链接与文本按同一选择器取两次，顺序由宿主保证一致（文档序）。
    let hrefs = host::html_select(body, "a[href*=\"/video/\"]", Some("href"));
    let texts = host::html_select(body, "a[href*=\"/video/\"]", None);
    for (index, href) in hrefs.iter().enumerate() {
        let key = href
            .rsplit('/')
            .next()
            .unwrap_or_default()
            .split(['?', '#'])
            .next()
            .unwrap_or_default()
            .to_string();
        if key.is_empty() || !seen.insert(key.clone()) {
            continue;
        }
        let number = chapters.len() as u32 + 1;
        let title = texts.get(index).cloned().unwrap_or_default();
        chapters.push(Chapter {
            id: format!("{source_id}:{number}"),
            title: if title.is_empty() {
                format!("第{number}集")
            } else {
                title
            },
            video_url: String::new(),
            page_url: absolute(base, href),
            referer: format!("{base}/"),
            vip: false,
        });
    }
    chapters
}

/// 单集页取媒体地址：`data-play-src` 优先，其次 `videoInitialData` 脚本。
fn media_url(body: &str, base: &str) -> Option<String> {
    let direct = host::html_select(body, "[data-play-src]", Some("data-play-src"))
        .into_iter()
        .find(|value| !value.is_empty());
    if let Some(value) = direct {
        let resolved = absolute(base, &value);
        if is_media(&resolved) {
            return Some(resolved);
        }
    }
    // JSON 脚本里递归找媒体地址：宿主的 json_path 没有递归通配，
    // 这里把脚本内容挖出来后用自带递归（与编译版 `find_media_in_json` 一致）。
    let script = extract_script(body, "videoInitialData")?;
    let value: Value = serde_json::from_str(&script).ok()?;
    find_media_in_json(&value, base)
}

fn extract_script(body: &str, id: &str) -> Option<String> {
    let marker = format!("id=\"{id}\"");
    let start = body
        .find(&marker)
        .or_else(|| body.find(&format!("id='{id}'")))?;
    let after = &body[start..];
    let content_start = after.find('>')? + 1;
    let end = after[content_start..].find("</script>")?;
    Some(after[content_start..content_start + end].to_string())
}

fn find_media_in_json(value: &Value, base: &str) -> Option<String> {
    match value {
        Value::String(text) if is_media(text) => Some(absolute(base, text)),
        Value::Array(items) => items.iter().find_map(|item| find_media_in_json(item, base)),
        Value::Object(map) => map.values().find_map(|child| find_media_in_json(child, base)),
        _ => None,
    }
}

fn is_media(value: &str) -> bool {
    value.contains(".m3u8") || value.contains(".mp4")
}

/// 页面首个匹配元素的文本（`h1` / `title` 用）。
fn first_text(body: &str, selector: &str) -> String {
    host::html_select(body, selector, None)
        .into_iter()
        .next()
        .unwrap_or_default()
}

/// `<meta name="..." content="...">` 的 content 值。
fn meta_content(body: &str, name: &str) -> String {
    host::html_select(
        body,
        &format!("meta[name=\"{name}\"]"),
        Some("content"),
    )
    .into_iter()
    .next()
    .unwrap_or_default()
}

fn absolute(base: &str, value: &str) -> String {
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
        base.trim_end_matches('/'),
        value.trim_start_matches('/')
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clean_id_extracts_detail_segment() {
        assert_eq!(clean_id("123"), "123");
        assert_eq!(
            clean_id("https://huangguoai.com/detail/abc/?x=1"),
            "abc"
        );
        assert_eq!(clean_id("/detail/xyz/"), "xyz");
    }

    #[test]
    fn walk_json_finds_nested_drama_objects() {
        let body = r#"{"code":0,"data":{"blocks":[
            {"type":"ad","title":"广告位"},
            {"type":"video","id":"vid-9","videoTitle":"递归剧","cover":"//img.test/c.jpg"}
        ]}}"#;
        let cards = json_cards(body, "https://huangguoai.com", "AI 短剧");
        assert_eq!(cards.len(), 1);
        assert_eq!(cards[0].source_id, "vid-9");
        assert_eq!(cards[0].title, "递归剧");
        assert_eq!(cards[0].cover, "https://img.test/c.jpg");
    }

    #[test]
    fn walk_json_ignores_objects_without_title() {
        let body = r#"{"data":[{"id":"vid-1"},{"name":"无 id 对象"}]}"#;
        assert!(json_cards(body, "https://huangguoai.com", "AI 短剧").is_empty());
    }

    #[test]
    fn absolute_handles_protocol_relative_and_relative() {
        assert_eq!(
            absolute("https://huangguoai.com", "//img.test/a.jpg"),
            "https://img.test/a.jpg"
        );
        assert_eq!(
            absolute("https://huangguoai.com", "/detail/1/"),
            "https://huangguoai.com/detail/1/"
        );
        assert_eq!(absolute("https://huangguoai.com", ""), "");
    }

    #[test]
    fn is_media_checks_extensions() {
        assert!(is_media("https://cdn.test/a.m3u8"));
        assert!(is_media("https://cdn.test/a.mp4"));
        assert!(!is_media("https://cdn.test/page"));
    }
}
