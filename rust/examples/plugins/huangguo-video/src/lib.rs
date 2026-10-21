//! 黄果视频代码插件。
//!
//! Core-3 的第五个迁移源，验证的是 **ADR-12 的提取原语**：插件不内嵌
//! HTML 解析器，全部解析走宿主的 `html_select`（CSS 选择器），插件只拿结果。
//! 这是「宿主做重解析、插件保持小体积」这个架构决策的实践。
//!
//! 与编译版（`crates/source-huangguo::video`）的关系：
//! - 目录 `/videos?page=N`，卡片 `article.video-card`；
//! - 详情 `series/{id}`（分集列表）与 `video/{id}`（单集，`data-hls`）两种；
//! - 分集编号语义一致：有编号时丢弃无编号条目（避免把推荐位当分集）。

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

struct HuangguoVideo;

const BASE: &str = "https://huangguo.video";

impl Guest for HuangguoVideo {
    fn describe() -> Descriptor {
        Descriptor {
            id: "guo.huangguo-video".into(),
            name: "黄果视频".into(),
            group: "huangguo".into(),
            api_level: 1,
            capabilities: vec!["catalog".into(), "detail".into()],
        }
    }

    fn categories() -> Result<Vec<Category>, Error> {
        // 编译版也没有分类；保持一致。
        Ok(Vec::new())
    }

    fn catalog(query: Query) -> Result<Page, Error> {
        let body = fetch_html(&format!("/videos?page={}", query.page.max(1)))?;
        Ok(Page {
            items: video_cards(&body),
            has_more: true,
            page: query.page,
            cursor: String::new(),
        })
    }

    fn fetch_detail(source_id: String) -> Result<Detail, Error> {
        let id = source_id.trim().trim_matches('/').to_string();
        if id.is_empty() {
            return Err(Error::ParseChanged("缺少剧集标识".into()));
        }
        let path = if id.starts_with("series/") || id.starts_with("video/") {
            id.clone()
        } else {
            format!("series/{id}")
        };
        let body = fetch_html(&format!("/{path}"))?;
        let page_url = format!("{BASE}/{path}");

        let mut drama = Drama {
            // 源前缀由宿主按清单补上。
            id: id.clone(),
            source_id: id.clone(),
            title: {
                // 编译版优先 h1，其次 title。
                let from_h1 = first_html(&body, "h1");
                if from_h1.is_empty() {
                    first_html(&body, "title")
                } else {
                    from_h1
                }
            },
            description: meta_content(&body, "description"),
            cover: absolute(&first_attr(&body, "og:image", "content").unwrap_or_default()),
            category: if path.starts_with("video/") {
                "video".into()
            } else {
                "series".into()
            },
            episodes: 0,
            tags: Vec::new(),
            views: String::new(),
            heat: String::new(),
            release_status: String::new(),
        };
        if drama.title.is_empty() {
            drama.title = id.clone();
        }

        let mut chapters = if path.starts_with("video/") {
            Vec::new()
        } else {
            episode_cards(&body)
        };
        if chapters.is_empty() {
            // 单集页：整页只有一个播放器，直接取 `data-hls`。
            let hls = first_attr(&body, "[data-hls]", "data-hls");
            if let Some(url) = hls {
                chapters.push(Chapter {
                    id: format!("{id}:1"),
                    title: drama.title.clone(),
                    video_url: absolute(&url),
                    page_url,
                    referer: format!("{BASE}/"),
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

    fn resolve(request: ResolveRequest) -> Result<Media, Error> {
        if request.chapter.video_url.is_empty() {
            return Err(Error::ParseChanged("分集缺少播放地址".into()));
        }
        Ok(Media {
            url: request.chapter.video_url,
            referer: format!("{BASE}/"),
            segments: Vec::new(),
            key_uri: String::new(),
            key_iv: String::new(),
            cookies: String::new(),
            origin: String::new(),
        })
    }

    fn search(query: Query) -> Result<Page, Error> {
        // 编译版不实现搜索（能力位里也没有），与宿主约定一致。
        let _ = query;
        Ok(Page {
            items: Vec::new(),
            has_more: false,
            page: query.page,
            cursor: String::new(),
        })
    }

    fn suggestions(keyword: String) -> Result<Vec<String>, Error> {
        let _ = keyword;
        Ok(Vec::new())
    }
}

export!(HuangguoVideo);

// ---- 传输 ----

fn fetch_html(path: &str) -> Result<String, Error> {
    let headers = vec![("Referer".to_string(), format!("{BASE}/"))];
    let response = host::fetch("get", &format!("{BASE}{path}"), &headers, None)?;
    if response.status != 200 {
        return Err(Error::Http(response.status));
    }
    Ok(String::from_utf8_lossy(&response.body).into_owned())
}

// ---- 解析（全部走宿主的 html_select / json_path） ----

/// 目录卡片：`article.video-card`。
fn video_cards(body: &str) -> Vec<Drama> {
    let mut out = Vec::new();
    let mut seen = std::collections::HashSet::new();
    // 先取每张卡片的首个链接，链接里带 `series/{id}` 或 `video/{id}`。
    let links = host::html_select(body, "article.video-card a[href]", Some("href"));
    for href in links {
        let path = href
            .split(['?', '#'])
            .next()
            .unwrap_or_default()
            .trim_start_matches('/')
            .to_string();
        let key = path.rsplit('/').next().unwrap_or_default().to_string();
        if key.is_empty() || !seen.insert(key.clone()) {
            continue;
        }
        // 卡片元数据：对该卡片再做一次作用域查询（选择器带 :has 不可用时
        // 退化为全页首匹配，语义与编译版的「首个非空」一致）。
        let title = scoped_text(body, &path, "a[title], a[alt], a[aria-label]");
        let cover = scoped_attr(body, &path, "img", "data-src")
            .or_else(|| scoped_attr(body, &path, "img", "data-original"))
            .or_else(|| scoped_attr(body, &path, "img", "src"))
            .map(|value| absolute(&value))
            .unwrap_or_default();
        out.push(Drama {
            id: key.clone(),
            source_id: key,
            title: if title.is_empty() { path.clone() } else { title },
            cover,
            category: if path.starts_with("series/") {
                "series".into()
            } else {
                "video".into()
            },
            episodes: 0,
            tags: Vec::new(),
            views: String::new(),
            heat: String::new(),
            release_status: String::new(),
            description: String::new(),
        });
    }
    out
}

/// 分集卡片：只保留 `video/` 链接；有编号时丢弃无编号条目。
fn episode_cards(body: &str) -> Vec<Chapter> {
    let links = host::html_select(body, "article.video-card a[href]", Some("href"));
    let mut rows: Vec<(u32, bool, Chapter)> = Vec::new();
    let mut numbered = false;
    let mut seen = std::collections::HashSet::new();
    for href in links {
        let path = href
            .split(['?', '#'])
            .next()
            .unwrap_or_default()
            .trim_start_matches('/')
            .to_string();
        let key = path.rsplit('/').next().unwrap_or_default().to_string();
        if key.is_empty() || !path.starts_with("video/") || !seen.insert(key.clone()) {
            continue;
        }
        let text = scoped_text(body, &path, "a[title], a[alt], a[aria-label]");
        let number = episode_number(&text).unwrap_or(0);
        // 记住这条是否带编号：有编号时无编号条目要被丢弃。
        let from_number = number > 0;
        numbered = numbered || from_number;
        let index = if from_number {
            number
        } else {
            rows.len() as u32 + 1
        };
        let hls = scoped_attr(body, &path, "[data-hls]", "data-hls")
            .map(|value| absolute(&value))
            .unwrap_or_default();
        rows.push((
            index,
            from_number,
            Chapter {
                id: format!("{key}:{index}"),
                title: if text.is_empty() {
                    format!("第{index}集")
                } else {
                    text
                },
                video_url: hls,
                page_url: absolute(&href),
                referer: format!("{BASE}/"),
                vip: false,
            },
        ));
    }
    if numbered {
        // 有编号时丢弃没有编号的条目，避免把推荐位当成分集。
        rows.retain(|(_, from_number, _)| *from_number);
    }
    let mut chapters: Vec<Chapter> = rows.into_iter().map(|(_, _, chapter)| chapter).collect();
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

/// 取文本里的首个数字（与编译版 `episode_number` 一致）。
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

/// 作用域文本：按链接的 `href` 值构造**精确选择器**，一次只取一个卡片。
///
/// `html_select` 没有作用域概念；靠「第 N 个匹配」对齐在嵌套结构下会错位
/// （一个卡片里有 img / video 时位置就不再一一对应）。CSS 属性选择器
/// `a[href$="<path>"]` 是真正的定位，语义等价于编译版按块扫描。
fn scoped_text(body: &str, path: &str, _selectors: &str) -> String {
    let selector = format!("article.video-card a[href$=\"{path}\"]");
    if let Some(text) = host::html_select(body, &selector, None).into_iter().find(|text| !text.is_empty()) {
        return text;
    }
    for attribute in ["title", "alt", "aria-label"] {
        let values = host::html_select(body, &selector, Some(attribute));
        if let Some(value) = values.into_iter().find(|value| !value.is_empty()) {
            return value;
        }
    }
    String::new()
}

/// 作用域属性：先定位卡片，再在该卡片内读指定属性。
fn scoped_attr(body: &str, path: &str, selector: &str, attr: &str) -> Option<String> {
    // 卡片内的目标元素：a 本身或其后代。`a[href$="..."] <selector>` 在
    // `selector == a` 时不会重复命中，因此分两种写法。
    let link_selector = format!("article.video-card a[href$=\"{path}\"]");
    if selector.starts_with('a') {
        return host::html_select(body, &link_selector, Some(attr))
            .into_iter()
            .find(|value| !value.is_empty());
    }
    let descendant = format!("article.video-card:has(a[href$=\"{path}\"]) {selector}");
    if let Some(value) = host::html_select(body, &descendant, Some(attr))
        .into_iter()
        .find(|value| !value.is_empty())
    {
        return Some(value);
    }
    // `:has` 不可用时退化为「页面里第一个匹配」：详情页通常只有一个播放器。
    host::html_select(body, selector, Some(attr))
        .into_iter()
        .find(|value| !value.is_empty())
}

/// 页面首个匹配元素的文本（`h1` / `title` 用）。
fn first_html(body: &str, selector: &str) -> String {
    host::html_select(body, selector, None)
        .into_iter()
        .next()
        .unwrap_or_default()
}

/// `<meta name="..." content="...">` 的 content 值。
fn meta_content(body: &str, name: &str) -> String {
    let selector = format!("meta[name=\"{name}\"]");
    host::html_select(body, &selector, Some("content"))
        .into_iter()
        .next()
        .unwrap_or_default()
}

/// 页面首个匹配元素的属性（`og:image` 的 content 用）。
fn first_attr(body: &str, selector: &str, attr: &str) -> Option<String> {
    host::html_select(body, selector, Some(attr))
        .into_iter()
        .next()
        .filter(|value| !value.is_empty())
}

fn absolute(value: &str) -> String {
    let value = value.trim();
    if value.is_empty() || value.starts_with("http") {
        return value.to_string();
    }
    format!(
        "{}/{}",
        BASE.trim_end_matches('/'),
        value.trim_start_matches('/')
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    const CATALOG: &str = r#"<html><body>
        <article class="video-card"><a href="/series/abc" title="剧集甲"><img data-src="/c/a.jpg"></a></article>
        <article class="video-card"><a href="/video/def" title="第1集"><img data-src="/c/b.jpg"></a></article>
        <article class="other"><a href="/video/skip">忽略</a></article>
    </body></html>"#;

    #[test]
    fn absolute_joins_base_and_keeps_full_urls() {
        assert_eq!(absolute("/c/a.jpg"), "https://huangguo.video/c/a.jpg");
        assert_eq!(absolute("https://cdn.test/x.jpg"), "https://cdn.test/x.jpg");
        assert_eq!(absolute(""), "");
    }

    #[test]
    fn episode_number_extracts_first_digits() {
        assert_eq!(episode_number("第12集"), Some(12));
        assert_eq!(episode_number("第3集 预告"), Some(3));
        assert_eq!(episode_number("预告"), None);
    }

    #[test]
    fn detail_paths_normalise_the_id() {
        // 与编译版一致：不带前缀的 id 自动归入 series/。
        let id = "abc";
        let path = if id.starts_with("series/") || id.starts_with("video/") {
            id.to_string()
        } else {
            format!("series/{id}")
        };
        assert_eq!(path, "series/abc");
        let id = "video/def";
        assert_eq!(
            if id.starts_with("series/") || id.starts_with("video/") {
                id.to_string()
            } else {
                format!("series/{id}")
            },
            "video/def"
        );
    }
}
