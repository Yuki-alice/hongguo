use async_trait::async_trait;
use serde_json::Value;

use guo_source_api::{Capability, ContentType, SourceMeta, SourcePlugin, CURRENT_API_LEVEL};
use guo_source_api::{
    Category, Chapter, Detail, Drama, FetchRequest, Media, Page, SourceEnv, SourceError,
};

/// 黄果 AI（huangguoai.com）。
///
/// 目录走 JSON 接口 `/api/videos/category/{id}?sort=hot&page=N&size=24`，
/// 详情是 `/detail/{id}/` 的网页，分集从页面里的 `/video/...` 链接解析。
pub struct HuangguoAiSource {
    meta: SourceMeta,
}

/// 主站与备用镜像。主站不可用时按顺序回退，与 Go 版一致。
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

impl Default for HuangguoAiSource {
    fn default() -> Self {
        Self::new()
    }
}

impl HuangguoAiSource {
    pub fn new() -> Self {
        Self {
            meta: SourceMeta {
                id: "huangguoai".into(),
                name: "黄果 AI".into(),
                group: "duanju".into(),
                api_level: CURRENT_API_LEVEL,
                content_types: vec![ContentType::ShortDrama],
                capabilities: vec![
                    Capability::Catalog,
                    Capability::Detail,
                    Capability::Categories,
                ],
            },
        }
    }

    /// 依次尝试主站与镜像，返回第一个成功响应的正文与基地址。
    async fn fetch_text(
        &self,
        env: &SourceEnv,
        path: &str,
    ) -> Result<(String, String), SourceError> {
        let mut last = SourceError::NoResult;
        for base in MIRRORS {
            let url = format!("{}{path}", base.trim_end_matches('/'));
            let request = FetchRequest::get(&url).header("Referer", format!("{base}/"));
            match env.text(request).await {
                Ok(body) if !body.trim().is_empty() => return Ok((body, (*base).to_string())),
                Ok(_) => last = SourceError::NoResult,
                Err(err) => last = err,
            }
        }
        Err(last)
    }
}

#[async_trait]
impl SourcePlugin for HuangguoAiSource {
    fn meta(&self) -> SourceMeta {
        self.meta.clone()
    }

    async fn catalog(
        &self,
        env: &SourceEnv,
        page: u32,
        category: &str,
    ) -> Result<Page, SourceError> {
        let category = category.trim();
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
            return Err(SourceError::parse("huangguoai.catalog", "未知分类"));
        }
        let mut items = Vec::new();
        let mut seen = std::collections::HashSet::new();
        let mut failures = Vec::new();
        for (id, name) in wanted {
            let path = format!(
                "/api/videos/category/{id}?sort=hot&page={}&size={PAGE_SIZE}",
                page.max(1)
            );
            match self.fetch_text(env, &path).await {
                Ok((body, base)) => {
                    for drama in json_cards(&body, &base, name) {
                        if seen.insert(drama.source_id.clone()) {
                            items.push(drama);
                        }
                    }
                }
                Err(err) => failures.push(format!("{name}: {err}")),
            }
        }
        if items.is_empty() && !failures.is_empty() {
            return Err(SourceError::parse(
                "huangguoai.catalog",
                failures.join("; "),
            ));
        }
        Ok(Page {
            items,
            has_more: !failures.is_empty(),
            page,
            warning: failures.join("; "),
        })
    }

    async fn categories(&self, _env: &SourceEnv) -> Result<Vec<Category>, SourceError> {
        // 分类是固定清单，与 Go 版 `nativeAICategories` 一致；
        // 首项「全部」由调用方约定补上，这里只返回真实分类。
        Ok(CATEGORIES
            .iter()
            .map(|(id, name)| Category {
                id: (*id).to_string(),
                name: (*name).to_string(),
            })
            .collect())
    }

    async fn detail(&self, env: &SourceEnv, source_id: &str) -> Result<Detail, SourceError> {
        let id = source_id.trim().trim_matches('/');
        if id.is_empty() {
            return Err(SourceError::parse("huangguoai.detail", "缺少剧集标识"));
        }
        let id = id.strip_prefix("detail/").unwrap_or(id);
        let (body, base) = self.fetch_text(env, &format!("/detail/{id}/")).await?;

        let mut drama = Drama {
            id: Drama::identity("huangguoai", id),
            source: "huangguoai".into(),
            source_id: id.to_string(),
            title: html_title(&body),
            description: html_description(&body),
            cover: html_cover(&body, &base),
            ..Default::default()
        };
        if drama.title.is_empty() {
            drama.title = id.to_string();
        }

        let mut chapters = episode_links(&body, &base, id);
        if chapters.is_empty() {
            // 单集页：直接从页面里取一次媒体地址。
            if let Some(url) = media_url(&body, &base) {
                chapters.push(Chapter {
                    id: format!("{id}:1"),
                    title: drama.title.clone(),
                    source: "huangguoai".into(),
                    video_url: url,
                    page_url: format!("{base}/detail/{id}/"),
                    referer: format!("{base}/"),
                    ..Default::default()
                });
            }
        }
        if chapters.is_empty() {
            return Err(SourceError::parse(
                "huangguoai.detail",
                "未解析到可播放分集",
            ));
        }
        Ok(Detail { drama, chapters })
    }

    async fn resolve(
        &self,
        _env: &SourceEnv,
        drama: &Drama,
        chapter: &Chapter,
    ) -> Result<Media, SourceError> {
        if chapter.video_url.is_empty() {
            return Err(SourceError::parse(
                "huangguoai.resolve",
                "分集缺少播放地址，请刷新详情",
            ));
        }
        let referer = if chapter.referer.is_empty() {
            format!("{}/", MIRRORS[0])
        } else {
            chapter.referer.clone()
        };
        let _ = drama;
        Ok(Media {
            url: chapter.video_url.clone(),
            referer,
            ..Default::default()
        })
    }
}

/// 从 JSON 响应里递归找出剧集对象，与 Go 版 `parseHuangguoAIJSONCards` 等价。
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

fn drama_from_map(
    map: &serde_json::Map<String, Value>,
    base: &str,
    category: &str,
) -> Option<Drama> {
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
        id: Drama::identity("huangguoai", &source_id),
        source: "huangguoai".into(),
        source_id,
        title,
        description: pick_map(map, &["desc", "description", "intro", "summary"]),
        cover: absolute(base, &cover),
        category: category.to_string(),
        ..Default::default()
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

/// 从详情页解析 `/video/...` 链接作为分集。
fn episode_links(body: &str, base: &str, source_id: &str) -> Vec<Chapter> {
    let mut chapters = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for (href, title) in anchors(body) {
        if !href.contains("/video/") {
            continue;
        }
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
        chapters.push(Chapter {
            id: format!("{source_id}:{number}"),
            title: if title.is_empty() {
                format!("第{number}集")
            } else {
                title
            },
            source: "huangguoai".into(),
            video_url: String::new(),
            page_url: absolute(base, &href),
            referer: format!("{base}/"),
            ..Default::default()
        });
    }
    chapters
}

/// 极简锚点抽取：返回 `(href, 文本)`。只覆盖黄果页面用到的形态。
fn anchors(body: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let mut rest = body;
    while let Some(start) = rest.find("<a") {
        let after = &rest[start..];
        let Some(end) = after.find("</a>") else {
            break;
        };
        let tag = &after[..end];
        if let Some(href) = attr(tag, "href") {
            let text = strip_tags(&tag[tag.find('>').map(|index| index + 1).unwrap_or(0)..]);
            out.push((href, text));
        }
        rest = &after[end + 4..];
    }
    out
}

fn attr(tag: &str, name: &str) -> Option<String> {
    let needle = format!("{name}=");
    let mut rest = tag;
    while let Some(index) = rest.find(&needle) {
        let after = &rest[index + needle.len()..];
        let trimmed = after.trim_start();
        let quote = trimmed.chars().next()?;
        if quote == '"' || quote == '\'' {
            let body = &trimmed[1..];
            let end = body.find(quote)?;
            let value = body[..end].trim();
            if !value.is_empty() {
                return Some(value.to_string());
            }
            return None;
        }
        rest = after;
    }
    None
}

fn html_title(body: &str) -> String {
    extract_tag(body, "h1")
        .or_else(|| extract_tag(body, "title"))
        .map(|text| strip_tags(&text))
        .unwrap_or_default()
}

fn extract_tag(body: &str, tag: &str) -> Option<String> {
    let open = format!("<{tag}");
    let start = body.find(&open)?;
    let after = &body[start..];
    let content_start = after.find('>')? + 1;
    let close = format!("</{tag}>");
    let end = after[content_start..].find(&close)?;
    Some(after[content_start..content_start + end].to_string())
}

fn html_description(body: &str) -> String {
    let mut rest = body;
    while let Some(index) = rest.find("<meta") {
        let after = &rest[index..];
        let Some(end) = after.find('>') else {
            break;
        };
        let tag = &after[..end];
        let name = attr(tag, "name").or_else(|| attr(tag, "property"));
        if matches!(
            name.as_deref(),
            Some("description") | Some("og:description")
        ) {
            return attr(tag, "content").unwrap_or_default();
        }
        rest = &after[end..];
    }
    String::new()
}

fn html_cover(body: &str, base: &str) -> String {
    let mut rest = body;
    while let Some(index) = rest.find("<meta") {
        let after = &rest[index..];
        let Some(end) = after.find('>') else {
            break;
        };
        let tag = &after[..end];
        if attr(tag, "property").as_deref() == Some("og:image") {
            if let Some(content) = attr(tag, "content") {
                return absolute(base, &content);
            }
        }
        rest = &after[end..];
    }
    String::new()
}

/// 页面里的媒体地址：`data-play-src` 优先，其次 `videoInitialData` 脚本。
fn media_url(body: &str, base: &str) -> Option<String> {
    if let Some(value) = attr(body, "data-play-src") {
        let resolved = absolute(base, &value);
        if is_media(&resolved) {
            return Some(resolved);
        }
    }
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
        Value::Object(map) => map
            .values()
            .find_map(|child| find_media_in_json(child, base)),
        _ => None,
    }
}

fn is_media(value: &str) -> bool {
    value.contains(".m3u8") || value.contains(".mp4")
}

fn strip_tags(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    let mut inside = false;
    for ch in value.chars() {
        match ch {
            '<' => inside = true,
            '>' => inside = false,
            _ if !inside => out.push(ch),
            _ => {}
        }
    }
    out.trim().to_string()
}

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
    fn categories_capability_matches_the_declared_list() {
        // 声明了 `Categories` 就必须真的返回分类：能力位是 UI 决定是否
        // 显示筛选入口的唯一依据，声明与实现不符会让用户看到一个空列表。
        let source = HuangguoAiSource::new();
        assert!(source.meta().supports(Capability::Categories));
        assert!(!CATEGORIES.is_empty());
        assert!(CATEGORIES
            .iter()
            .all(|(id, name)| !id.is_empty() && !name.is_empty()));
    }

    #[test]
    fn json_cards_find_nested_drama_objects() {
        let body = r#"{"data":{"list":[
            {"id":101,"title":"甲","cover":"/c/1.jpg"},
            {"id":102,"title":"乙","coverUrl":"https://img.example/2.jpg"}
        ]}}"#;
        let items = json_cards(body, "https://huangguoai.com", "AI 短剧");
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].source_id, "101");
        assert_eq!(items[0].cover, "https://huangguoai.com/c/1.jpg");
        assert_eq!(items[1].cover, "https://img.example/2.jpg");
        assert_eq!(items[0].category, "AI 短剧");
    }

    #[test]
    fn json_cards_skip_objects_without_id_or_title() {
        let body = r#"{"data":[{"title":"没有 id"},{"id":9}]}"#;
        assert!(json_cards(body, "https://x", "c").is_empty());
    }

    #[test]
    fn clean_id_extracts_detail_segment() {
        assert_eq!(clean_id("/detail/abc123/"), "abc123");
        assert_eq!(clean_id("https://host/detail/x9/?a=1"), "x9");
        assert_eq!(clean_id(" plain "), "plain");
    }

    #[test]
    fn episode_links_deduplicate_and_number() {
        let body = r#"<a href="/video/1">第一集</a><a href="/video/1">重复</a>
            <a href="/video/2">第二集</a>"#;
        let chapters = episode_links(body, "https://h", "abc");
        assert_eq!(chapters.len(), 2);
        assert_eq!(chapters[0].id, "abc:1");
        assert_eq!(chapters[1].page_url, "https://h/video/2");
    }

    #[test]
    fn media_url_prefers_data_play_src() {
        let body = r#"<div data-play-src="/hls/a.m3u8"></div>"#;
        assert_eq!(
            media_url(body, "https://h").as_deref(),
            Some("https://h/hls/a.m3u8")
        );
    }

    #[test]
    fn media_url_falls_back_to_initial_data_script() {
        let body = r#"<script id="videoInitialData">{"url":"https://cdn.example/x.mp4"}</script>"#;
        assert_eq!(
            media_url(body, "https://h").as_deref(),
            Some("https://cdn.example/x.mp4")
        );
    }

    #[test]
    fn absolute_handles_protocol_relative_and_relative() {
        assert_eq!(absolute("https://h", "//c/x.jpg"), "https://c/x.jpg");
        assert_eq!(absolute("https://h/", "/a.jpg"), "https://h/a.jpg");
        assert_eq!(absolute("https://h", "https://x/y"), "https://x/y");
        assert_eq!(absolute("https://h", ""), "");
    }
}
