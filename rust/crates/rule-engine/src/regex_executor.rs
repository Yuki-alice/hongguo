//! 正则型站源的提取器（`kind = "regex"`）。
//!
//! 与 CSS 选择器路径的区别：条目不是 DOM 节点，而是正则在整页文本上切出的块。
//! 语义固定在这一层，规则作者只依赖下面三条：
//!
//! - `item`：全局匹配，**每个完整匹配是一个条目的原文块**；
//! - 字段：在块内找第一个匹配，有捕获组取**第 1 个捕获组**，无捕获组取整段匹配；
//! - 内联 flag 可用（`(?is)` 等），与 Go 的 `regexp` 语法基本一致，
//!   因此 guoapp2 里的规则可以近乎原样搬过来。
//!
//! 所有正则在**一次解析开始时编译一次**（不是每个条目一次）：
//! 站点改版时最容易写的是「一条正则 × 几百个条目」，编译放在条目循环里
//! 会把成本放大几百倍。

use regex::Regex;

use guo_source_api::{Chapter, Drama, Page, SourceError};

use super::{RuleDocument, RuleFields, SelectorList};

/// 正则型站源的执行器。
pub struct RegexExecutor<'a> {
    rule: &'a RuleDocument,
}

impl<'a> RegexExecutor<'a> {
    pub fn new(rule: &'a RuleDocument) -> Self {
        Self { rule }
    }

    pub fn parse_catalog(&self, body: &str, page: u32) -> Result<Page, SourceError> {
        let catalog = self
            .rule
            .catalog
            .as_ref()
            .ok_or(SourceError::Unsupported("目录"))?;
        let compiled = CompiledFields::new(&catalog.fields.clone().normalized())?;
        let blocks = split_blocks(body, &catalog.item)?;
        let mut items = Vec::new();
        let mut seen = std::collections::HashSet::new();
        for block in blocks {
            let Some(drama) =
                build_drama(&block, &compiled, &self.rule.id, &self.rule.base, &mut seen)?
            else {
                continue;
            };
            items.push(drama);
        }
        let has_more = match &catalog.next {
            Some(pattern) if !pattern.trim().is_empty() => Regex::new(pattern)
                .map(|re| re.is_match(body))
                .unwrap_or(false),
            _ => false,
        };
        Ok(Page {
            items,
            has_more,
            page,
            warning: String::new(),
        })
    }

    pub fn parse_search(&self, body: &str, page: u32) -> Result<Page, SourceError> {
        let search = self
            .rule
            .search
            .as_ref()
            .ok_or(SourceError::Unsupported("搜索"))?;
        let compiled = CompiledFields::new(&search.fields.clone().normalized())?;
        let blocks = split_blocks(body, &search.item)?;
        let mut items = Vec::new();
        let mut seen = std::collections::HashSet::new();
        for block in blocks {
            let Some(drama) =
                build_drama(&block, &compiled, &self.rule.id, &self.rule.base, &mut seen)?
            else {
                continue;
            };
            items.push(drama);
        }
        Ok(Page {
            items,
            has_more: false,
            page,
            warning: String::new(),
        })
    }

    pub fn parse_chapters(&self, body: &str, drama: &Drama) -> Result<Vec<Chapter>, SourceError> {
        let detail = self
            .rule
            .detail
            .as_ref()
            .ok_or(SourceError::Unsupported("详情"))?;
        let spec = detail.episodes.regex().ok_or_else(|| SourceError::Rule {
            rule_id: self.rule.id.clone(),
            detail: "正则型站源的 detail.episodes 需要 pattern".into(),
        })?;
        let pattern = compile(&spec.pattern, "detail.episodes.pattern")?;
        let mut chapters = Vec::new();
        let mut seen = std::collections::HashSet::new();
        for captures in pattern.captures_iter(body) {
            let Some(url) = captures.get(1) else {
                continue;
            };
            let url = url.as_str().trim();
            if url.is_empty() || !seen.insert(url.to_string()) {
                continue;
            }
            let number = chapters.len() + 1;
            let title = spec
                .title_group
                .unwrap_or(2)
                .max(1)
                .min(captures.len())
                .to_string()
                .parse::<usize>()
                .ok()
                .and_then(|group| captures.get(group))
                .map(|value| collapse(value.as_str()))
                .unwrap_or_default();
            chapters.push(Chapter {
                id: format!("{}:{}", drama.id, number),
                title: if title.is_empty() {
                    render_title(spec.title_template.as_deref(), number)
                } else {
                    title
                },
                source: drama.source.clone(),
                page_url: super::jsonpath::absolute(&self.rule.base, url),
                ..Default::default()
            });
        }
        if chapters.is_empty() {
            return Err(SourceError::NoResult);
        }
        Ok(chapters)
    }

    /// 从整页里取播放地址：`resolve.urlRegex` 按顺序取第一个命中。
    pub fn media_url(&self, body: &str) -> Option<String> {
        let resolve = self.rule.resolve.as_ref()?;
        for pattern in &resolve.url_regex {
            let pattern = pattern.trim();
            if pattern.is_empty() {
                continue;
            }
            let Ok(re) = Regex::new(pattern) else {
                continue;
            };
            if let Some(captures) = re.captures(body) {
                let value = captures
                    .get(1)
                    .or_else(|| captures.get(0))
                    .map(|m| m.as_str().trim().to_string())
                    .unwrap_or_default();
                if !value.is_empty() {
                    return Some(value);
                }
            }
        }
        None
    }

    /// 用详情页补标题 / 封面 / 简介：三项都可写成正则，缺则保持原值。
    pub fn fill_drama(&self, body: &str, drama: &mut Drama) {
        let Some(detail) = &self.rule.detail else {
            return;
        };
        if let Some(pattern) = &detail.title {
            if let Some(value) = first_capture(body, pattern) {
                if !value.is_empty() {
                    drama.title = value;
                }
            }
        }
        if let Some(pattern) = &detail.cover {
            if let Some(value) = first_capture(body, pattern) {
                if !value.is_empty() {
                    drama.cover = super::jsonpath::absolute(&self.rule.base, &value);
                }
            }
        }
        if let Some(pattern) = &detail.description {
            if let Some(value) = first_capture(body, pattern) {
                if !value.is_empty() {
                    drama.description = value;
                }
            }
        }
    }
}

/// 一次解析里复用的已编译字段正则。
struct CompiledFields {
    id: Vec<Regex>,
    title: Vec<Regex>,
    cover: Vec<Regex>,
    category: Vec<Regex>,
    description: Vec<Regex>,
    id_pattern: Option<Regex>,
}

impl CompiledFields {
    fn new(fields: &RuleFields) -> Result<Self, SourceError> {
        Ok(Self {
            id: compile_all(&fields.id, "id")?,
            title: compile_all(&fields.title, "title")?,
            cover: compile_all(&fields.cover, "cover")?,
            category: compile_all(&fields.category, "category")?,
            description: compile_all(&fields.description, "description")?,
            id_pattern: match fields.id_pattern.as_deref() {
                Some(pattern) if !pattern.trim().is_empty() => Some(compile(pattern, "idPattern")?),
                _ => None,
            },
        })
    }

    /// 依次尝试候选正则，返回第一个非空结果。
    fn read(&self, block: &str, patterns: &[Regex]) -> String {
        for pattern in patterns {
            if let Some(captures) = pattern.captures(block) {
                let value = captures
                    .get(1)
                    .or_else(|| captures.get(0))
                    .map(|m| m.as_str())
                    .unwrap_or_default();
                let value = collapse(value);
                if !value.is_empty() {
                    return value;
                }
            }
        }
        String::new()
    }
}

fn compile_all(list: &SelectorList, field: &'static str) -> Result<Vec<Regex>, SourceError> {
    list.0
        .iter()
        .filter(|item| !item.trim().is_empty())
        .map(|item| compile(item, field))
        .collect()
}

fn compile(pattern: &str, field: &'static str) -> Result<Regex, SourceError> {
    Regex::new(pattern)
        .map_err(|err| SourceError::parse(field, format!("正则无效 {pattern}：{err}")))
}

/// 用 `item` 正则把整页切成条目块。
fn split_blocks(body: &str, item: &SelectorList) -> Result<Vec<String>, SourceError> {
    let mut blocks = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for pattern in &item.0 {
        let pattern = pattern.trim();
        if pattern.is_empty() {
            continue;
        }
        let compiled = compile(pattern, "item")?;
        for found in compiled.find_iter(body) {
            let block = found.as_str().to_string();
            if seen.insert(block.clone()) {
                blocks.push(block);
            }
        }
    }
    Ok(blocks)
}

fn build_drama(
    block: &str,
    fields: &CompiledFields,
    source: &str,
    base: &str,
    seen: &mut std::collections::HashSet<String>,
) -> Result<Option<Drama>, SourceError> {
    let raw_id = fields.read(block, &fields.id);
    let source_id = match &fields.id_pattern {
        Some(pattern) => pattern
            .captures(&raw_id)
            .and_then(|caps| caps.get(1).or_else(|| caps.get(0)))
            .map(|m| m.as_str().trim().to_string())
            .unwrap_or_default(),
        None => super::executor::extract_id(&raw_id),
    };
    if source_id.is_empty() || !seen.insert(source_id.clone()) {
        return Ok(None);
    }
    let title = fields.read(block, &fields.title);
    if title.is_empty() {
        return Ok(None);
    }
    Ok(Some(Drama {
        id: Drama::identity(source, &source_id),
        source: source.to_string(),
        source_id,
        title,
        cover: super::jsonpath::absolute(base, &fields.read(block, &fields.cover)),
        category: fields.read(block, &fields.category),
        description: fields.read(block, &fields.description),
        ..Default::default()
    }))
}

/// 取第一个匹配的第 1 个捕获组（无捕获组取整段），失败返回 None。
pub(crate) fn first_capture(text: &str, pattern: &str) -> Option<String> {
    let pattern = pattern.trim();
    if pattern.is_empty() {
        return None;
    }
    let Ok(compiled) = Regex::new(pattern) else {
        return None;
    };
    compiled
        .captures(text)
        .and_then(|caps| caps.get(1).or_else(|| caps.get(0)))
        .map(|m| collapse(m.as_str()))
}

/// 折叠空白并去掉标签残留：正则常切到含换行的 HTML 片段。
fn collapse(raw: &str) -> String {
    let trimmed = raw.trim();
    if !trimmed.contains('<') {
        return trimmed.split_whitespace().collect::<Vec<_>>().join(" ");
    }
    let mut out = String::with_capacity(trimmed.len());
    let mut skipping = false;
    for ch in trimmed.chars() {
        match ch {
            '<' => skipping = true,
            '>' => skipping = false,
            _ if !skipping => out.push(ch),
            _ => {}
        }
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn render_title(template: Option<&str>, number: usize) -> String {
    match template {
        Some(template) if !template.trim().is_empty() => {
            template.replace("{n}", &number.to_string())
        }
        _ => format!("第{number}集"),
    }
}

#[cfg(test)]
mod tests {
    use super::super::RuleDocument;
    use super::*;

    fn rule() -> RuleDocument {
        RuleDocument::from_json(
            r#"{
                "schema": "1.0",
                "id": "huangguo",
                "name": "黄果",
                "base": "https://huangguo.test",
                "kind": "regex",
                "catalog": {
                    "url": "/category/{category}?page={page}",
                    "item": "(?is)<article\\b[^>]*class=[\"'][^\"']*video-card[^\"']*[\"'][^>]*>.*?</article>",
                    "fields": {
                        "id": "(?is)href=[\"']([^\"']*/series/([^\"'/?#]+)[^\"']*)[\"']",
                        "idPattern": "(\\d+)",
                        "title": "(?is)<h3[^>]*>(.*?)</h3>",
                        "cover": "(?is)data-src=[\"']([^\"']+)[\"']"
                    }
                },
                "detail": {
                    "episodes": {
                        "pattern": "(?is)<a\\b[^>]*href=[\"']([^\"']*/video/[^\"']+)[\"'][^>]*>(.*?)</a>",
                        "titleGroup": 2
                    }
                },
                "resolve": { "urlRegex": ["(?is)data-hls=[\"']([^\"']+)[\"']"] }
            }"#,
        )
        .expect("rule")
    }

    const CATALOG: &str = r#"<html><body>
        <article class="video-card">
            <a href="/series/12345.html"><h3>剧名一</h3></a>
            <img data-src="https://img.test/1.jpg">
        </article>
        <article class="video-card">
            <a href="/series/12345.html"><h3>重复条目</h3></a>
        </article>
        <article class="video-card">
            <a href="/series/67890.html"><h3>剧名二</h3></a>
            <img data-src="https://img.test/2.jpg">
        </article>
    </body></html>"#;

    #[test]
    fn splits_blocks_and_dedupes_by_id() {
        let rule = rule();
        let page = RegexExecutor::new(&rule)
            .parse_catalog(CATALOG, 1)
            .expect("catalog");
        assert_eq!(page.items.len(), 2, "同 id 的重复块必须被去掉");
        assert_eq!(page.items[0].source_id, "12345");
        assert_eq!(page.items[0].title, "剧名一");
        assert_eq!(page.items[0].cover, "https://img.test/1.jpg");
        assert_eq!(page.items[1].id, "huangguo:67890");
    }

    #[test]
    fn chapters_use_first_group_as_url_and_title_group_for_title() {
        let rule = rule();
        let drama = Drama {
            id: "huangguo:12345".into(),
            source: "huangguo".into(),
            source_id: "12345".into(),
            ..Default::default()
        };
        let html = r#"<div>
            <a href="/video/111.html">第1集</a>
            <a href="/video/222.html">第2集</a>
            <a href="/video/111.html">重复</a>
        </div>"#;
        let chapters = RegexExecutor::new(&rule)
            .parse_chapters(html, &drama)
            .expect("chapters");
        assert_eq!(chapters.len(), 2, "同地址的分集必须去重");
        assert_eq!(chapters[0].title, "第1集");
        assert_eq!(chapters[0].page_url, "https://huangguo.test/video/111.html");
    }

    #[test]
    fn media_url_prefers_first_capture_group() {
        let rule = rule();
        let found = RegexExecutor::new(&rule)
            .media_url(r#"<video data-hls="https://cdn.test/a.m3u8"></video>"#);
        assert_eq!(found.as_deref(), Some("https://cdn.test/a.m3u8"));
        assert_eq!(RegexExecutor::new(&rule).media_url("<div></div>"), None);
    }

    #[test]
    fn collapse_strips_tags_and_normalizes_whitespace() {
        assert_eq!(collapse("  剧名\n  一  "), "剧名 一");
        assert_eq!(collapse("<span>剧名</span>二"), "剧名二");
    }

    #[test]
    fn invalid_regex_is_rejected_at_load_time() {
        let broken = r#"{
            "schema": "1.0",
            "id": "huangguo",
            "name": "黄果",
            "base": "https://huangguo.test",
            "kind": "regex",
            "catalog": { "url": "/c/{page}", "item": "(?is)<article[a-" },
            "detail": { "episodes": { "pattern": "a" } }
        }"#;
        let err = RuleDocument::from_json(broken).expect_err("must fail");
        assert!(err.to_string().contains("正则无效"), "{err}");
        assert!(
            err.to_string().contains("catalog.item"),
            "{err} 应指出出错的段"
        );
    }

    #[test]
    fn empty_item_regex_is_rejected_at_load_time() {
        let broken = r#"{
            "schema": "1.0",
            "id": "huangguo",
            "name": "黄果",
            "base": "https://huangguo.test",
            "kind": "regex",
            "catalog": { "url": "/c/{page}", "item": "  " },
            "detail": { "episodes": { "pattern": "a" } }
        }"#;
        let err = RuleDocument::from_json(broken).expect_err("must fail");
        assert!(err.to_string().contains("正则不能为空"), "{err}");
    }

    #[test]
    fn episodes_regex_is_not_swallowed_by_json_variant() {
        let rule = rule();
        let spec = rule.detail.as_ref().expect("detail").episodes.regex();
        assert!(spec.is_some(), "EpisodesSpec::Regex 必须排在 Json 之前");
    }
}
