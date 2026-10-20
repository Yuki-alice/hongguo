use scraper::{Html, Selector};
use serde_json::Value;

use guo_source_api::{Chapter, Drama, Page, SourceError};

use super::{embedded, JsonRuleExecutor, RuleDocument, RuleFields, RuleKind, SelectorList};

pub struct RuleExecutor<'a> {
    rule: &'a RuleDocument,
}

impl<'a> RuleExecutor<'a> {
    pub fn new(rule: &'a RuleDocument) -> Self {
        Self { rule }
    }

    /// 按站源取数方式解析目录。
    pub fn parse_catalog(&self, body: &str, page: u32) -> Result<Page, SourceError> {
        match self.rule.kind {
            RuleKind::Html => self.parse_catalog_html(body, page),
            kind => {
                JsonRuleExecutor::new(self.rule).parse_catalog(&self.read_root(body, kind)?, page)
            }
        }
    }

    pub fn parse_search(&self, body: &str, page: u32) -> Result<Page, SourceError> {
        match self.rule.kind {
            RuleKind::Html => self.parse_search_html(body, page),
            kind => {
                JsonRuleExecutor::new(self.rule).parse_search(&self.read_root(body, kind)?, page)
            }
        }
    }

    pub fn parse_chapters(&self, body: &str, drama: &Drama) -> Result<Vec<Chapter>, SourceError> {
        match self.rule.kind {
            RuleKind::Html => self.parse_chapters_html(body, drama),
            kind => {
                JsonRuleExecutor::new(self.rule).parse_chapters(&self.read_root(body, kind)?, drama)
            }
        }
    }

    /// 用详情返回的资料补齐剧目字段；HTML 站源没有结构化资料，保持原样。
    pub fn fill_drama(&self, body: &str, drama: &mut Drama) {
        if self.rule.kind == RuleKind::Html {
            return;
        }
        if let Ok(root) = self.read_root(body, self.rule.kind) {
            JsonRuleExecutor::new(self.rule).fill_drama(&root, drama);
        }
    }

    /// 内嵌 JSON 与接口站源直接从规则路径取播放地址。
    pub fn media_url(&self, body: &str) -> Option<String> {
        if self.rule.kind == RuleKind::Html {
            return None;
        }
        let root = self.read_root(body, self.rule.kind).ok()?;
        JsonRuleExecutor::new(self.rule).media_url(&root)
    }

    fn read_root(&self, body: &str, kind: RuleKind) -> Result<Value, SourceError> {
        match kind {
            RuleKind::Json => serde_json::from_str(body)
                .map_err(|err| SourceError::parse("json", format!("{err}"))),
            // 同一站点可能既有内嵌 JSON 的页面，也有直接返回 JSON 的接口。
            RuleKind::Next => embedded::embedded_json(body)
                .or_else(|| serde_json::from_str(body).ok())
                .ok_or_else(|| SourceError::parse("json", "页面未返回可解析的数据")),
            RuleKind::Html => Err(SourceError::parse("json", "HTML 站源不需要 JSON 解析")),
        }
    }

    fn parse_catalog_html(&self, html: &str, page: u32) -> Result<Page, SourceError> {
        let catalog = self
            .rule
            .catalog
            .as_ref()
            .ok_or(SourceError::Unsupported("目录"))?;
        let document = Html::parse_document(html);
        let items = extract_items(
            &document,
            &catalog.item,
            &catalog.fields.clone().normalized(),
            &self.rule.id,
            self.rule.name.as_str(),
            &self.rule.base,
        )?;
        let has_more = catalog
            .next
            .as_ref()
            .map(|selector| has_selector(&document, selector))
            .unwrap_or(false);
        Ok(Page {
            items,
            has_more,
            page,
            warning: String::new(),
        })
    }

    fn parse_search_html(&self, html: &str, page: u32) -> Result<Page, SourceError> {
        let search = self
            .rule
            .search
            .as_ref()
            .ok_or(SourceError::Unsupported("搜索"))?;
        let document = Html::parse_document(html);
        let items = extract_items(
            &document,
            &search.item,
            &search.fields.clone().normalized(),
            &self.rule.id,
            self.rule.name.as_str(),
            &self.rule.base,
        )?;
        Ok(Page {
            items,
            has_more: false,
            page,
            warning: String::new(),
        })
    }

    fn parse_chapters_html(&self, html: &str, drama: &Drama) -> Result<Vec<Chapter>, SourceError> {
        let detail = self
            .rule
            .detail
            .as_ref()
            .ok_or(SourceError::Unsupported("详情"))?;
        let selectors = detail
            .episodes
            .selectors()
            .ok_or_else(|| SourceError::Rule {
                rule_id: self.rule.id.clone(),
                detail: "detail.episodes 需要 CSS 选择器".into(),
            })?;
        let document = Html::parse_document(html);
        let mut parsed = Vec::new();
        for candidate in &selectors.0 {
            let candidate = candidate.trim();
            if candidate.is_empty() {
                continue;
            }
            parsed.push(Selector::parse(candidate).map_err(|err| {
                SourceError::parse("detail.episodes", format!("选择器无效：{err:?}"))
            })?);
        }
        let mut nodes = Vec::new();
        for selector in &parsed {
            nodes.extend(document.select(selector));
        }
        let mut chapters = Vec::new();
        let mut seen = std::collections::HashSet::new();
        for node in nodes.into_iter() {
            let href = node.value().attr("href").unwrap_or_default().trim();
            if href.is_empty() {
                continue;
            }
            // 多个候选选择器可能命中同一节点，按链接去重。
            if !seen.insert(href.to_string()) {
                continue;
            }
            let title: String = first_text(node);
            let number = chapters.len() + 1;
            chapters.push(Chapter {
                id: format!("{}:{}", drama.id, number),
                title: if title.is_empty() {
                    format!("第{number}集")
                } else {
                    title
                },
                source: drama.source.clone(),
                page_url: absolute(&self.rule.base, href),
                ..Default::default()
            });
        }
        if chapters.is_empty() {
            return Err(SourceError::NoResult);
        }
        Ok(chapters)
    }
}

fn extract_items(
    document: &Html,
    item_selector: &SelectorList,
    fields: &RuleFields,
    source: &str,
    source_name: &str,
    base: &str,
) -> Result<Vec<Drama>, SourceError> {
    let mut parsed_selectors = Vec::new();
    for candidate in &item_selector.0 {
        let candidate = candidate.trim();
        if candidate.is_empty() {
            continue;
        }
        parsed_selectors.push(
            Selector::parse(candidate)
                .map_err(|err| SourceError::parse("item", format!("选择器无效：{err:?}")))?,
        );
    }
    let mut nodes = Vec::new();
    for selector in &parsed_selectors {
        nodes.extend(document.select(selector));
    }
    let mut items = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for node in nodes {
        let raw_id = field_text(node, &fields.id)?;
        // 规则声明了 `idPattern` 时以它为准；否则退回「路径末段里的数字」。
        let source_id = match fields.id_pattern.as_deref() {
            Some(pattern) if !pattern.is_empty() => {
                crate::rules::extract_pattern(&raw_id, pattern).unwrap_or_default()
            }
            _ => extract_id(&raw_id),
        };
        if source_id.is_empty() || !seen.insert(source_id.clone()) {
            continue;
        }
        let title = field_text(node, &fields.title)?;
        if title.is_empty() {
            continue;
        }
        items.push(Drama {
            id: Drama::identity(source, &source_id),
            source: source.to_string(),
            source_id,
            title,
            cover: absolute(base, &field_text(node, &fields.cover)?),
            category: field_text(node, &fields.category)?,
            description: field_text(node, &fields.description)?,
            ..Default::default()
        });
        let _ = source_name;
    }
    Ok(items)
}

fn field_text(node: scraper::ElementRef<'_>, field: &SelectorList) -> Result<String, SourceError> {
    read_first_match(node, field, |expression, element| {
        match expression.split_once('@') {
            Some((selector, attr)) => {
                let _ = selector;
                Ok(decode_entities(
                    element.value().attr(attr).unwrap_or_default(),
                ))
            }
            None => Ok(decode_entities(&first_text(element))),
        }
    })
}

/// 依次尝试候选选择器，返回第一个非空结果。
fn read_first_match(
    node: scraper::ElementRef<'_>,
    field: &SelectorList,
    read: impl Fn(&str, scraper::ElementRef<'_>) -> Result<String, SourceError>,
) -> Result<String, SourceError> {
    for expression in &field.0 {
        let expression = expression.trim();
        if expression.is_empty() {
            continue;
        }
        let value = match expression.split_once('@') {
            Some((selector, _)) => select_and_read(node, selector, "字段", |element| {
                read(expression, element)
            })?,
            None => select_and_read(node, expression, "字段", |element| {
                read(expression, element)
            })?,
        };
        if !value.is_empty() {
            return Ok(value);
        }
    }
    Ok(String::new())
}

fn select_and_read(
    node: scraper::ElementRef<'_>,
    selector: &str,
    field: &'static str,
    read: impl Fn(scraper::ElementRef<'_>) -> Result<String, SourceError>,
) -> Result<String, SourceError> {
    let selector = selector.trim();
    if selector.is_empty() {
        return read(node);
    }
    let parsed = Selector::parse(selector)
        .map_err(|err| SourceError::parse(field, format!("选择器无效 {selector}：{err:?}")))?;
    let _ = field;
    if let Some(found) = node.select(&parsed).next() {
        return read(found);
    }
    if self_matches(node, selector) {
        return read(node);
    }
    Ok(String::new())
}

/// 取节点内第一个非空文本，避免把嵌套的评分、集数标签也拼进标题。
fn first_text(element: scraper::ElementRef<'_>) -> String {
    for text in element.text() {
        let normalized = text.split_whitespace().collect::<Vec<_>>().join(" ");
        if !normalized.is_empty() {
            return normalized;
        }
    }
    String::new()
}

/// `scraper` 只解析文档结构，不还原实体；标题里的 `&amp;` 需要手动解码。
fn decode_entities(raw: &str) -> String {
    let text = raw.trim();
    if !text.contains('&') {
        return text.to_string();
    }
    let once = text
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
        .replace("&nbsp;", " ");
    once.replace("&amp;", "&")
}

/// CSS 的 `select` 只查后代，不会匹配节点自身；规则里常见的 `a@href`
/// 作用在 `<a>` 条目上时需要显式支持。
fn self_matches(node: scraper::ElementRef<'_>, selector: &str) -> bool {
    let head = selector
        .split(|c: char| c.is_whitespace() || c == '>' || c == '+' || c == '~')
        .next_back()
        .unwrap_or(selector)
        .trim();
    if head.is_empty() || head.starts_with('.') || head.starts_with('#') || head.starts_with('[') {
        return false;
    }
    head.split(['.', '#', '[', ':'])
        .next()
        .map(|tag| tag.eq_ignore_ascii_case(node.value().name()))
        .unwrap_or(false)
}

fn has_selector(document: &Html, selector: &str) -> bool {
    match Selector::parse(selector) {
        Ok(parsed) => document.select(&parsed).next().is_some(),
        Err(_) => false,
    }
}

fn extract_id(raw: &str) -> String {
    let cleaned = raw.split(['?', '#']).next().unwrap_or(raw);
    let last = cleaned
        .rsplit('/')
        .find(|part| !part.is_empty())
        .unwrap_or(cleaned);
    let stem = last.rsplit_once('.').map(|(head, _)| head).unwrap_or(last);
    let digits: String = stem
        .chars()
        .rev()
        .take_while(char::is_ascii_digit)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect();
    if digits.is_empty() {
        stem.to_string()
    } else {
        digits
    }
}

fn absolute(base: &str, href: &str) -> String {
    if href.starts_with("http") {
        return href.to_string();
    }
    let base = base.trim_end_matches('/');
    let href = href.trim_start_matches('/');
    format!("{base}/{href}")
}

#[cfg(test)]
mod tests {
    use super::super::RuleDocument;
    use super::*;

    fn rule() -> RuleDocument {
        RuleDocument::from_json(
            r#"{
                "schema": "1.0",
                "id": "wuguo",
                "name": "伍果",
                "base": "https://www.duanju55.com",
                "catalog": {
                    "url": "index.php/vod/type/id/{category}/page/{page}.html",
                    "item": "a.module-item",
                    "fields": { "id": "a@href", "title": ".title", "cover": "img@data-original" }
                },
                "detail": { "episodes": "a[href*=play]" },
                "search": {
                    "url": "index.php/vod/search/page/{page}/wd/{keyword}.html",
                    "item": "a.module-item"
                }
            }"#,
        )
        .expect("rule")
    }

    const CATALOG_HTML: &str = r#"<html><body>
        <a class="module-item" href="/index.php/vod/detail/id/101.html">
            <span class="title">剧名一</span>
            <img data-original="https://img.test/1.jpg">
        </a>
        <a class="module-item" href="/index.php/vod/detail/id/101.html">
            <span class="title">重复</span>
        </a>
        <a class="module-item" href="/index.php/vod/detail/id/202.html">
            <span class="title">剧名二</span>
        </a>
    </body></html>"#;

    #[test]
    fn extracts_catalog_items_and_dedupes() {
        let rule = rule();
        let executor = RuleExecutor::new(&rule);
        let page = executor.parse_catalog(CATALOG_HTML, 1).expect("catalog");
        assert_eq!(page.items.len(), 2);
        assert_eq!(page.items[0].source_id, "101");
        assert_eq!(page.items[0].title, "剧名一");
        assert_eq!(page.items[0].cover, "https://img.test/1.jpg");
        assert_eq!(page.items[1].id, "wuguo:202");
    }

    #[test]
    fn extracts_chapters_with_absolute_urls() {
        let rule = rule();
        let executor = RuleExecutor::new(&rule);
        let drama = Drama {
            id: "wuguo:101".into(),
            source: "wuguo".into(),
            source_id: "101".into(),
            title: "剧名一".into(),
            ..Default::default()
        };
        let html = r#"<div>
            <a href="/index.php/vod/play/id/101/sid/1/nid/1.html">第1集</a>
            <a href="/index.php/vod/play/id/101/sid/1/nid/2.html">第2集</a>
        </div>"#;
        let chapters = executor.parse_chapters(html, &drama).expect("chapters");
        assert_eq!(chapters.len(), 2);
        assert_eq!(chapters[0].title, "第1集");
        assert!(chapters[0]
            .page_url
            .starts_with("https://www.duanju55.com/"));
    }

    #[test]
    fn empty_chapter_list_reports_no_result() {
        let rule = rule();
        let executor = RuleExecutor::new(&rule);
        let drama = Drama {
            id: "wuguo:1".into(),
            source: "wuguo".into(),
            ..Default::default()
        };
        let err = executor
            .parse_chapters("<div></div>", &drama)
            .expect_err("must fail");
        assert!(matches!(err, SourceError::NoResult));
    }

    #[test]
    fn unbalanced_selector_is_rejected_at_load_time() {
        let broken = r#"{
            "schema": "1.0",
            "id": "wuguo",
            "name": "伍果",
            "base": "https://www.duanju55.com",
            "catalog": { "url": "x/{page}", "item": "a[href" },
            "detail": { "episodes": "a" }
        }"#;
        let err = RuleDocument::from_json(broken).expect_err("must fail");
        assert!(err.to_string().contains("括号不配对"), "{err}");
    }

    #[test]
    fn empty_selector_is_rejected_at_load_time() {
        let broken = r#"{
            "schema": "1.0",
            "id": "wuguo",
            "name": "伍果",
            "base": "https://www.duanju55.com",
            "catalog": { "url": "x/{page}", "item": "  " },
            "detail": { "episodes": "a" }
        }"#;
        let err = RuleDocument::from_json(broken).expect_err("must fail");
        assert!(err.to_string().contains("不能为空"), "{err}");
    }

    #[test]
    fn next_selector_controls_has_more() {
        let rule = rule();
        let executor = RuleExecutor::new(&rule);
        let page = executor.parse_catalog(CATALOG_HTML, 1).expect("catalog");
        assert!(!page.has_more, "rule has no next selector");
    }
}
