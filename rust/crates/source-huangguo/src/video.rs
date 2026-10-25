use async_trait::async_trait;

use guo_source_api::{Capability, ContentType, SourceMeta, SourcePlugin, CURRENT_API_LEVEL};
use guo_source_api::{Chapter, Detail, Drama, FetchRequest, Media, Page, SourceEnv, SourceError};

/// 黄果视频（huangguo.video）。
///
/// 目录是 `/videos?page=N` 的网页，卡片为 `article.video-card`；详情分
/// `series/{id}` 与 `video/{id}` 两种：前者是剧集（分集列表），后者是单集
/// （页面里直接带 `data-hls`）。
pub struct HuangguoVideoSource {
    meta: SourceMeta,
}

const BASE: &str = "https://huangguo.video";

impl Default for HuangguoVideoSource {
    fn default() -> Self {
        Self::new()
    }
}

impl HuangguoVideoSource {
    pub fn new() -> Self {
        Self {
            meta: SourceMeta {
                id: "huangguo-video".into(),
                name: "黄果视频".into(),
                group: "duanju".into(),
                api_level: CURRENT_API_LEVEL,
                content_types: vec![ContentType::ShortDrama],
                capabilities: vec![Capability::Catalog, Capability::Detail],
            },
        }
    }

    async fn fetch(&self, env: &SourceEnv, path: &str) -> Result<String, SourceError> {
        env.text(FetchRequest::get(format!("{BASE}{path}")).header("Referer", format!("{BASE}/")))
            .await
    }
}

#[async_trait]
impl SourcePlugin for HuangguoVideoSource {
    fn meta(&self) -> SourceMeta {
        self.meta.clone()
    }

    async fn catalog(
        &self,
        env: &SourceEnv,
        page: u32,
        _category: &str,
    ) -> Result<Page, SourceError> {
        let body = self
            .fetch(env, &format!("/videos?page={}", page.max(1)))
            .await?;
        let items = video_cards(&body);
        Ok(Page {
            items: items.clone(),
            has_more: !items.is_empty(),
            page,
            warning: String::new(),
        })
    }

    async fn detail(&self, env: &SourceEnv, source_id: &str) -> Result<Detail, SourceError> {
        let id = source_id.trim().trim_matches('/');
        if id.is_empty() {
            return Err(SourceError::parse("huangguo-video.detail", "缺少剧集标识"));
        }
        let path = if id.starts_with("series/") || id.starts_with("video/") {
            id.to_string()
        } else {
            format!("series/{id}")
        };
        let body = self.fetch(env, &format!("/{path}")).await?;
        let page_url = format!("{BASE}/{path}");

        let mut drama = Drama {
            id: Drama::identity("huangguo-video", id),
            source: "huangguo-video".into(),
            source_id: id.to_string(),
            title: html_title(&body),
            description: html_description(&body),
            cover: html_cover(&body),
            ..Default::default()
        };
        if drama.title.is_empty() {
            drama.title = id.to_string();
        }

        let mut chapters = if path.starts_with("video/") {
            Vec::new()
        } else {
            episode_cards(&body)
        };
        if chapters.is_empty() {
            // 单集页或整页只有一个播放器：直接取 `data-hls`。
            if let Some(url) = attr_of_first(&body, "data-hls") {
                chapters.push(Chapter {
                    id: format!("{id}:1"),
                    title: drama.title.clone(),
                    source: "huangguo-video".into(),
                    video_url: absolute(&url),
                    page_url: page_url.clone(),
                    referer: format!("{BASE}/"),
                    ..Default::default()
                });
            }
        }
        if chapters.is_empty() {
            return Err(SourceError::parse(
                "huangguo-video.detail",
                "未解析到可播放分集",
            ));
        }
        Ok(Detail { drama, chapters })
    }

    async fn resolve(
        &self,
        _env: &SourceEnv,
        _drama: &Drama,
        chapter: &Chapter,
    ) -> Result<Media, SourceError> {
        if chapter.video_url.is_empty() {
            return Err(SourceError::parse(
                "huangguo-video.resolve",
                "分集缺少播放地址，请刷新详情",
            ));
        }
        Ok(Media {
            url: chapter.video_url.clone(),
            referer: format!("{BASE}/"),
            ..Default::default()
        })
    }
}

/// `article.video-card` 卡片 → 剧集条目。
fn video_cards(body: &str) -> Vec<Drama> {
    let mut out = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for block in articles(body) {
        let Some(href) = first_link(&block) else {
            continue;
        };
        let (path, source_id) = split_link(&href);
        if source_id.is_empty() || !seen.insert(source_id.clone()) {
            continue;
        }
        let title = attr_of_first(&block, "title")
            .or_else(|| attr_of_first(&block, "alt"))
            .or_else(|| attr_of_first(&block, "aria-label"))
            .unwrap_or_else(|| text_of(&block));
        out.push(Drama {
            id: Drama::identity("huangguo-video", &source_id),
            source: "huangguo-video".into(),
            source_id,
            title: if title.is_empty() {
                String::new()
            } else {
                title
            },
            cover: attr_of_first(&block, "data-src")
                .or_else(|| attr_of_first(&block, "data-original"))
                .or_else(|| attr_of_first(&block, "src"))
                .map(|value| absolute(&value))
                .unwrap_or_default(),
            category: if path.starts_with("series/") {
                "series".into()
            } else {
                "video".into()
            },
            ..Default::default()
        });
    }
    out.retain(|drama| !drama.title.is_empty());
    out
}

/// 详情页里的分集卡片：`/video/...` 链接，按出现顺序编号。
fn episode_cards(body: &str) -> Vec<Chapter> {
    let mut chapters = Vec::new();
    let mut numbered_flags = Vec::new();
    let mut seen = std::collections::HashSet::new();
    let mut numbered = false;
    for block in articles(body) {
        let Some(href) = first_link(&block) else {
            continue;
        };
        let (path, key) = split_link(&href);
        if key.is_empty() || !path.starts_with("video/") || !seen.insert(key.clone()) {
            continue;
        }
        let text = text_of(&block);
        let number = episode_number(&text).unwrap_or(0);
        numbered = numbered || number > 0;
        let from_number = number > 0;
        let index = if from_number {
            number
        } else {
            chapters.len() as u32 + 1
        };
        numbered_flags.push(from_number);
        chapters.push(Chapter {
            id: format!("{key}:{index}"),
            title: if text.is_empty() {
                format!("第{index}集")
            } else {
                text
            },
            source: "huangguo-video".into(),
            video_url: attr_of_first(&block, "data-hls")
                .map(|value| absolute(&value))
                .unwrap_or_default(),
            page_url: absolute(&href),
            referer: format!("{BASE}/"),
            ..Default::default()
        });
    }
    if numbered {
        // 有编号时丢弃没有编号的条目，避免把推荐位当成分集。
        let mut keep = numbered_flags.into_iter();
        chapters.retain(|_| keep.next().unwrap_or(false));
    }
    chapters.sort_by_key(|chapter| {
        chapter
            .id
            .rsplit(':')
            .next()
            .and_then(|tail| tail.parse::<u32>().ok())
            .unwrap_or(u32::MAX)
    });
    chapters
}

fn articles(body: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = body;
    while let Some(start) = rest.find("<article") {
        let after = &rest[start..];
        let Some(end) = after.find("</article>") else {
            break;
        };
        let block = &after[..end];
        if block.to_ascii_lowercase().contains("video-card") {
            out.push(block.to_string());
        }
        rest = &after[end + "</article>".len()..];
    }
    out
}

fn first_link(block: &str) -> Option<String> {
    let mut rest = block;
    while let Some(index) = rest.find("<a") {
        let after = &rest[index..];
        let end = after.find('>')?;
        if let Some(href) = attr(&after[..end], "href") {
            return Some(href);
        }
        rest = &after[end..];
    }
    None
}

/// 把链接拆成 `(路径, 主键)`。`series/x` 与 `video/x` 都取最后一段。
fn split_link(href: &str) -> (String, String) {
    let path = href
        .split(['?', '#'])
        .next()
        .unwrap_or_default()
        .trim_start_matches('/')
        .to_string();
    let key = path.rsplit('/').next().unwrap_or_default().to_string();
    (path, key)
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

fn attr_of_first(body: &str, name: &str) -> Option<String> {
    attr(body, name)
}

fn text_of(block: &str) -> String {
    let mut out = String::with_capacity(block.len());
    let mut inside = false;
    for ch in block.chars() {
        match ch {
            '<' => inside = true,
            '>' => inside = false,
            _ if !inside => out.push(ch),
            _ => {}
        }
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn episode_number(text: &str) -> Option<u32> {
    let chars: Vec<char> = text.chars().collect();
    let mut index = 0;
    while index < chars.len() {
        if chars[index].is_ascii_digit() {
            let start = index;
            while index < chars.len() && chars[index].is_ascii_digit() {
                index += 1;
            }
            let number: String = chars[start..index].iter().collect();
            if let Ok(value) = number.parse::<u32>() {
                return Some(value);
            }
        }
        index += 1;
    }
    None
}

fn html_title(body: &str) -> String {
    extract_tag(body, "h1")
        .or_else(|| extract_tag(body, "title"))
        .map(|text| text_of(&text))
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

fn html_cover(body: &str) -> String {
    let mut rest = body;
    while let Some(index) = rest.find("<meta") {
        let after = &rest[index..];
        let Some(end) = after.find('>') else {
            break;
        };
        let tag = &after[..end];
        if attr(tag, "property").as_deref() == Some("og:image") {
            if let Some(content) = attr(tag, "content") {
                return absolute(&content);
            }
        }
        rest = &after[end..];
    }
    String::new()
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
    format!("{BASE}/{}", value.trim_start_matches('/'))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn video_cards_read_series_and_video_links() {
        let body = r#"<article class="video-card">
            <a href="/series/abc" title="剧集甲"><img data-src="/c/a.jpg"></a>
            </article>
            <article class="video-card">
            <a href="/video/xyz" title="单集乙"><img src="https://img/b.jpg"></a>
            </article>"#;
        let items = video_cards(body);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].source_id, "abc");
        assert_eq!(items[0].category, "series");
        assert_eq!(items[0].cover, "https://huangguo.video/c/a.jpg");
        assert_eq!(items[1].source_id, "xyz");
        assert_eq!(items[1].category, "video");
    }

    #[test]
    fn video_cards_skip_articles_without_video_card_class() {
        let body = r#"<article class="other"><a href="/series/x" title="不应命中"></a></article>"#;
        assert!(video_cards(body).is_empty());
    }

    #[test]
    fn episode_cards_keep_only_numbered_when_any_is_numbered() {
        let body = r#"<article class="video-card"><a href="/video/1">第1集</a></article>
            <article class="video-card"><a href="/video/2">第2集</a></article>
            <article class="video-card"><a href="/video/rec">推荐位</a></article>"#;
        let chapters = episode_cards(body);
        assert_eq!(chapters.len(), 2, "无编号的推荐位要被丢弃");
        assert!(chapters[0].id.ends_with(":1"));
    }

    #[test]
    fn split_link_returns_path_and_key() {
        assert_eq!(
            split_link("/series/abc?x=1"),
            ("series/abc".to_string(), "abc".to_string())
        );
    }

    #[test]
    fn episode_number_reads_chinese_marker() {
        assert_eq!(episode_number("第12集"), Some(12));
        assert_eq!(episode_number("推荐位"), None);
    }
}
