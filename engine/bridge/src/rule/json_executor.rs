use std::collections::HashSet;

use serde_json::Value;

use crate::SourceError;
use crate::{Chapter, Drama, Page};

use super::jsonpath;
use super::rules::{
    EpisodesRule, HasMoreRule, NumberFieldRule, ReleaseStatusRule, RuleDocument, RuleFields,
    TemplateCtx,
};

/// 按 JSON 路径取数，覆盖接口站源与页面内嵌 JSON 两类。
pub struct JsonRuleExecutor<'a> {
    rule: &'a RuleDocument,
}

impl<'a> JsonRuleExecutor<'a> {
    pub fn new(rule: &'a RuleDocument) -> Self {
        Self { rule }
    }

    pub fn parse_catalog(&self, root: &Value, page: u32) -> Result<Page, SourceError> {
        let catalog = self
            .rule
            .catalog
            .as_ref()
            .ok_or(SourceError::Unsupported("目录"))?;
        let items = self.map_items(&catalog.fields, &catalog.items, root);
        let has_more = self.has_more(&catalog.has_more, root, page, items.len());
        Ok(Page {
            items,
            has_more,
            page,
            warning: String::new(),
        })
    }

    pub fn parse_search(&self, root: &Value, page: u32) -> Result<Page, SourceError> {
        let search = self
            .rule
            .search
            .as_ref()
            .ok_or(SourceError::Unsupported("搜索"))?;
        let items = self.map_items(&search.fields, &search.items, root);
        let has_more = self.has_more(&search.has_more, root, page, items.len());
        Ok(Page {
            items,
            has_more,
            page,
            warning: String::new(),
        })
    }

    pub fn parse_chapters(&self, root: &Value, drama: &Drama) -> Result<Vec<Chapter>, SourceError> {
        let detail = self
            .rule
            .detail
            .as_ref()
            .ok_or(SourceError::Unsupported("详情"))?;
        let spec = detail
            .json_episodes()
            .ok_or_else(|| self.rule_error("分集规格不是 JSON 形式"))?;
        let mut chapters: Vec<(i64, Chapter)> = Vec::new();
        let mut seen = HashSet::new();
        for (index, node) in jsonpath::first_nodes(root, &spec.paths)
            .into_iter()
            .enumerate()
        {
            if !node.is_object() {
                continue;
            }
            let mut number = jsonpath::int_at(node, &spec.number);
            if number <= 0 {
                number = index as i64 + 1;
            }
            if !seen.insert(number) {
                continue;
            }
            let video_url = self.episode_url(node, spec);
            let page_url = self.episode_page_url(node, spec, drama, number);
            if video_url.is_empty() && page_url.is_empty() {
                continue;
            }
            let title = jsonpath::text_at(node, &spec.title);
            chapters.push((
                number,
                Chapter {
                    id: format!("{}:{}", drama.id, number),
                    title: if title.is_empty() {
                        format!("第{number}集")
                    } else {
                        title
                    },
                    source: drama.source.clone(),
                    video_url,
                    page_url,
                    referer: format!("{}/", self.rule.base.trim_end_matches('/')),
                    vip: false,
                },
            ));
        }
        if chapters.is_empty() {
            return Err(match spec.empty_message.as_deref() {
                Some(message) => SourceError::parse("detail.episodes", message),
                None => SourceError::NoResult,
            });
        }
        chapters.sort_by_key(|(number, _)| *number);
        Ok(chapters.into_iter().map(|(_, chapter)| chapter).collect())
    }

    /// 用详情接口返回的资料补齐剧目字段，详情返回的值优先，缺失时保留原值。
    pub fn fill_drama(&self, root: &Value, drama: &mut Drama) {
        let Some(detail) = self.rule.detail.as_ref() else {
            return;
        };
        if detail.meta.is_empty() {
            return;
        }
        let Some(node) = jsonpath::first_object(root, &detail.meta) else {
            return;
        };
        let fields = &detail.fields;
        let title = jsonpath::text_at(node, &fields.title.as_paths());
        if !title.is_empty() {
            drama.title = title;
        }
        let cover = jsonpath::text_at(node, &fields.cover.as_paths());
        if !cover.is_empty() {
            drama.cover = jsonpath::absolute(&self.rule.base, &cover);
        }
        let description = jsonpath::text_at(node, &fields.description.as_paths());
        if !description.is_empty() {
            drama.description = description;
        }
        let category = self.field_category(node, fields);
        if !category.is_empty() {
            drama.category = category;
        }
        if drama.tags.is_empty() {
            drama.tags = jsonpath::string_list_at(node, &fields.tags);
        }
        let views = self.number_field(node, fields.views.as_ref());
        if !views.is_empty() {
            drama.views = views;
        }
        let status = self.release_status(node, fields.release_status.as_ref());
        if !status.is_empty() {
            drama.release_status = status;
        }
        let episodes = usize::try_from(jsonpath::int_at(node, &fields.episodes.as_paths()))
            .unwrap_or_default();
        drama.episodes = drama.episodes.max(episodes as u32);
    }

    pub fn media_url(&self, root: &Value) -> Option<String> {
        let resolve = self.rule.resolve.as_ref()?;
        let url = jsonpath::text_at(root, &resolve.url_paths);
        (!url.is_empty()).then_some(url)
    }

    fn map_items(&self, fields: &RuleFields, paths: &[String], root: &Value) -> Vec<Drama> {
        let mut seen = HashSet::new();
        let mut items = Vec::new();
        for path in paths {
            for node in jsonpath::select_items(root, path) {
                if !node.is_object() {
                    continue;
                }
                let source_id = fields.identity(node);
                if source_id.is_empty() || !seen.insert(source_id.clone()) {
                    continue;
                }
                let title = jsonpath::text_at(node, &fields.title.as_paths());
                if title.is_empty() {
                    continue;
                }
                items.push(self.build_drama(node, &source_id, &title, fields));
            }
        }
        items
    }

    fn build_drama(
        &self,
        node: &Value,
        source_id: &str,
        title: &str,
        fields: &RuleFields,
    ) -> Drama {
        Drama {
            id: Drama::identity(&self.rule.id, source_id),
            source: self.rule.id.clone(),
            source_id: source_id.to_string(),
            title: title.to_string(),
            cover: jsonpath::absolute(
                &self.rule.base,
                &jsonpath::text_at(node, &fields.cover.as_paths()),
            ),
            description: jsonpath::text_at(node, &fields.description.as_paths()),
            category: self.field_category(node, fields),
            episodes: u32::try_from(jsonpath::int_at(node, &fields.episodes.as_paths()))
                .unwrap_or(0),
            tags: jsonpath::string_list_at(node, &fields.tags),
            views: self.number_field(node, fields.views.as_ref()),
            release_status: self.release_status(node, fields.release_status.as_ref()),
            ..Default::default()
        }
    }

    /// 分类既可能是纯文本，也可能是标签数组。
    fn field_category(&self, node: &Value, fields: &RuleFields) -> String {
        for path in &fields.category.0 {
            for value in jsonpath::select(node, path) {
                let list = jsonpath::string_list_of(value);
                if !list.is_empty() {
                    return list.join(", ");
                }
                let text = jsonpath::text_of(value);
                if !text.is_empty() {
                    return text;
                }
            }
        }
        String::new()
    }

    fn number_field(&self, node: &Value, spec: Option<&NumberFieldRule>) -> String {
        let Some(spec) = spec else {
            return String::new();
        };
        let value = jsonpath::int_at(node, &spec.paths);
        if value <= 0 {
            return String::new();
        }
        let divide = spec.divide.unwrap_or(0);
        let from = spec.divide_from.unwrap_or(0);
        if divide > 0 && value as u64 >= from && value as u64 >= divide {
            let scaled = value as f64 / divide as f64;
            return format!(
                "{scaled:.1}{}",
                spec.high_suffix.as_deref().unwrap_or_default()
            );
        }
        format!("{value}{}", spec.suffix.as_deref().unwrap_or_default())
    }

    /// 与 Go 端一致：先看状态文本，再按已更新集数与总集数比较。
    fn release_status(&self, node: &Value, spec: Option<&ReleaseStatusRule>) -> String {
        let Some(spec) = spec else {
            return String::new();
        };
        let raw = jsonpath::text_at(node, &spec.paths).to_lowercase();
        match raw.as_str() {
            "over" | "finished" | "completed" | "2" | "已完结" | "完结" => {
                return "finished".into()
            }
            "ongoing" | "serializing" | "1" | "连载中" | "更新中" => return "ongoing".into(),
            _ => {}
        }
        let total = spec
            .total
            .as_ref()
            .map(|path| jsonpath::int_at(node, std::slice::from_ref(path)))
            .unwrap_or(0);
        let current = spec
            .current
            .as_ref()
            .map(|path| jsonpath::int_at(node, std::slice::from_ref(path)))
            .unwrap_or(0);
        if total > 0 && current >= total {
            "finished".to_string()
        } else if current > 0 {
            "ongoing".to_string()
        } else {
            String::new()
        }
    }

    fn has_more(&self, spec: &Option<HasMoreRule>, root: &Value, page: u32, count: usize) -> bool {
        let Some(spec) = spec else {
            return false;
        };
        if let Some(total_path) = &spec.total {
            let total = jsonpath::int_at(root, std::slice::from_ref(total_path));
            let current = match &spec.current {
                Some(path) => {
                    let parsed = jsonpath::int_at(root, std::slice::from_ref(path));
                    if parsed > 0 {
                        parsed
                    } else {
                        i64::from(page)
                    }
                }
                None => i64::from(page),
            };
            return total > current;
        }
        spec.min_items > 0 && count >= spec.min_items as usize
    }

    fn episode_url(&self, node: &Value, spec: &EpisodesRule) -> String {
        if !spec.video_url.is_empty() {
            let direct = jsonpath::text_at(node, &spec.video_url);
            if !direct.is_empty() {
                return jsonpath::absolute(&self.rule.base, &direct);
            }
            if spec.recurse {
                let found = jsonpath::find_url(node, &spec.video_url, 0);
                if !found.is_empty() {
                    return jsonpath::absolute(&self.rule.base, &found);
                }
            }
        }
        if let Some(best) = &spec.best {
            for path in &best.paths {
                let mut address = String::new();
                let mut rank = i64::MIN;
                for entry in jsonpath::select_items(node, path) {
                    let candidate = jsonpath::text_at(entry, &best.url);
                    if candidate.is_empty() {
                        continue;
                    }
                    let value = jsonpath::int_at(entry, &best.rank);
                    if value > rank {
                        rank = value;
                        address = candidate;
                    }
                }
                if !address.is_empty() {
                    return jsonpath::absolute(&self.rule.base, &address);
                }
            }
        }
        String::new()
    }

    fn episode_page_url(
        &self,
        node: &Value,
        spec: &EpisodesRule,
        drama: &Drama,
        number: i64,
    ) -> String {
        let direct = jsonpath::text_at(node, &spec.page_url);
        if !direct.is_empty() {
            return jsonpath::absolute(&self.rule.base, &direct);
        }
        let Some(template) = spec.page_url_template.as_deref() else {
            return String::new();
        };
        let chapter_id = jsonpath::text_at(node, &spec.chapter_id);
        if template.contains("{chapterId}") && chapter_id.is_empty() {
            return String::new();
        }
        let rendered = template
            .replace("{chapterId}", &chapter_id)
            .replace("{number}", &number.to_string());
        let url = self.rule.render(
            &rendered,
            &TemplateCtx {
                page: 1,
                category: "",
                keyword: "",
                id: &drama.source_id,
            },
        );
        jsonpath::absolute(&self.rule.base, &url)
    }

    fn rule_error(&self, detail: &str) -> SourceError {
        SourceError::Rule {
            rule_id: self.rule.id.clone(),
            detail: detail.to_string(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const RULE: &str = r##"{
        "schema": "1.0",
        "id": "testjson",
        "name": "接口测试源",
        "base": "https://api.test",
        "kind": "json",
        "idSplit": "#",
        "catalog": {
            "url": "{base}/list?page={page}&keyword={category}",
            "items": ["result.elements[].contents[].duanjuVo"],
            "fields": {
                "id": ["duanjuId"],
                "idTemplate": "{id}#{source}",
                "title": ["title", "name"],
                "cover": ["cover"],
                "episodes": ["total"],
                "category": ["categories"],
                "tags": ["categories"],
                "views": {"paths": ["heat"], "suffix": "万播放"}
            },
            "hasMore": {"minItems": 2}
        },
        "detail": {
            "url": "{base}/info?duanjuId={idFirst}",
            "meta": ["result"],
            "episodes": {
                "paths": ["result.episodeList"],
                "videoUrl": ["playUrl"],
                "recurse": true,
                "number": ["index"],
                "title": ["title"]
            },
            "fields": {
                "id": ["duanjuId"],
                "title": ["title"],
                "episodes": ["total"],
                "releaseStatus": {"paths": ["updateStatus"], "total": "total", "current": "current"}
            }
        },
        "search": {
            "url": "{base}/search?kw={keyword}",
            "items": ["result.list"],
            "fields": {"id": ["id"], "title": ["title"]}
        }
    }"##;

    const BEST_RULE: &str = r##"{
        "schema": "1.0",
        "id": "besttest",
        "name": "清晰度测试源",
        "base": "https://v.test",
        "kind": "json",
        "catalog": {
            "url": "{base}/list",
            "items": ["data.list"],
            "fields": {
                "id": ["id"],
                "title": ["title"],
                "views": {
                    "paths": ["viewCount"],
                    "divide": 10000,
                    "divideFrom": 10000,
                    "highSuffix": "万次播放",
                    "suffix": "次播放"
                }
            }
        },
        "detail": {
            "url": "{base}/detail/{id}",
            "meta": ["data"],
            "episodes": {
                "paths": ["data.episodes"],
                "videoUrl": ["playUrl"],
                "best": {"paths": ["clarityList"], "url": ["playUrl", "url"], "rank": ["clarity"]},
                "pageUrlTemplate": "{base}/ep/{id}/{chapterId}?n={number}",
                "chapterId": ["chapterId"],
                "number": ["playOrder"],
                "title": ["name"],
                "emptyMessage": "暂无分集"
            },
            "fields": {"id": ["id"], "title": ["title"], "episodes": ["episodeCount"]}
        },
        "resolve": {"urlPaths": ["data.mp4", "data.episodes[].playUrl"]}
    }"##;

    fn rule(text: &str) -> RuleDocument {
        RuleDocument::from_json(text).expect("规则可解析")
    }

    fn drama(source: &str, source_id: &str) -> Drama {
        Drama {
            id: Drama::identity(source, source_id),
            source: source.to_string(),
            source_id: source_id.to_string(),
            ..Default::default()
        }
    }

    #[test]
    fn catalog_maps_nested_paths_and_composite_ids() {
        let body = serde_json::json!({
            "result": {"elements": [
                {"contents": [
                    {"duanjuVo": {"duanjuId": 11, "title": "剧A", "cover": "/c/1.jpg", "total": 20,
                                 "categories": ["都市", "穿越"], "source": "src1", "heat": 123}},
                    {"duanjuVo": {"duanjuId": 11, "title": "重复条目", "source": "src1"}}
                ]},
                {"contents": [{"duanjuVo": {"duanjuId": 12, "name": "剧B"}}]}
            ]}
        });
        let page = JsonRuleExecutor::new(&rule(RULE))
            .parse_catalog(&body, 1)
            .expect("目录");
        assert_eq!(page.items.len(), 2);
        let first = &page.items[0];
        assert_eq!(first.source_id, "11#src1");
        assert_eq!(first.id, "testjson:11#src1");
        assert_eq!(first.title, "剧A");
        assert_eq!(first.cover, "https://api.test/c/1.jpg");
        assert_eq!(first.episodes, 20);
        assert_eq!(first.category, "都市, 穿越");
        assert_eq!(first.tags, vec!["都市".to_string(), "穿越".to_string()]);
        assert_eq!(first.views, "123万播放");
        assert_eq!(page.items[1].source_id, "12");
        assert!(page.has_more);
    }

    #[test]
    fn has_more_uses_total_and_current() {
        let mut document = rule(RULE);
        if let Some(catalog) = &mut document.catalog {
            catalog.has_more = Some(HasMoreRule {
                min_items: 0,
                total: Some("result.pages".into()),
                current: Some("result.page".into()),
            });
        }
        let executor = JsonRuleExecutor::new(&document);
        let body = serde_json::json!({"result": {"pages": 5, "page": 2, "elements": []}});
        assert!(executor.parse_catalog(&body, 2).expect("目录").has_more);
        let last = serde_json::json!({"result": {"pages": 5, "page": 5, "elements": []}});
        assert!(!executor.parse_catalog(&last, 5).expect("目录").has_more);
        // current 缺失时退化为请求页码。
        let missing = serde_json::json!({"result": {"pages": 3, "elements": []}});
        assert!(executor.parse_catalog(&missing, 2).expect("目录").has_more);
        assert!(!executor.parse_catalog(&missing, 3).expect("目录").has_more);
    }

    #[test]
    fn chapters_recurse_for_nested_addresses() {
        let body = serde_json::json!({
            "result": {"episodeList": [
                {"index": 1, "title": "首集", "playUrl": "https://v.test/1.mp4"},
                {"index": 2, "video": {"info": {"playUrl": "/2.mp4"}}},
                {"index": 2, "title": "重复集数", "playUrl": "https://v.test/dup.mp4"},
                {"title": "缺集数", "playUrl": "https://v.test/3.mp4"}
            ]}
        });
        let chapters = JsonRuleExecutor::new(&rule(RULE))
            .parse_chapters(&body, &drama("testjson", "11#src1"))
            .expect("分集");
        assert_eq!(chapters.len(), 3);
        assert_eq!(chapters[0].video_url, "https://v.test/1.mp4");
        assert_eq!(chapters[1].video_url, "https://api.test/2.mp4");
        assert_eq!(chapters[2].title, "缺集数");
        assert_eq!(chapters[2].id, "testjson:11#src1:4");
        assert_eq!(chapters[1].referer, "https://api.test/");
    }

    #[test]
    fn chapters_pick_best_clarity() {
        let body = serde_json::json!({
            "data": {"episodes": [
                {"chapterId": "c1", "playOrder": 2, "name": "第二集", "clarityList": [
                    {"clarity": 720, "playUrl": "https://v.test/2-720.mp4"},
                    {"clarity": 1080, "playUrl": "https://v.test/2-1080.mp4"}
                ]},
                {"chapterId": "c2", "playOrder": 1, "clarityList": [
                    {"clarity": 480, "url": "//v.test/1-480.mp4"}
                ]},
                {"chapterId": "c3", "playOrder": 3}
            ]}
        });
        let chapters = JsonRuleExecutor::new(&rule(BEST_RULE))
            .parse_chapters(&body, &drama("besttest", "77"))
            .expect("分集");
        assert_eq!(chapters.len(), 3);
        assert_eq!(chapters[0].video_url, "https://v.test/1-480.mp4");
        assert_eq!(chapters[0].page_url, "https://v.test/ep/77/c2?n=1");
        assert_eq!(chapters[1].video_url, "https://v.test/2-1080.mp4");
        assert_eq!(chapters[1].title, "第二集");
        assert_eq!(chapters[2].title, "第3集");
        assert!(chapters[2].video_url.is_empty());
    }

    #[test]
    fn empty_chapters_report_rule_message() {
        let body = serde_json::json!({"data": {"episodes": []}});
        let err = JsonRuleExecutor::new(&rule(BEST_RULE))
            .parse_chapters(&body, &drama("besttest", "77"))
            .expect_err("空分集应报错");
        assert!(
            matches!(&err, SourceError::Parse { detail, .. } if detail == "暂无分集"),
            "{err:?}"
        );
    }

    #[test]
    fn views_divide_only_above_threshold() {
        let body = serde_json::json!({"data": {"list": [
            {"id": "1", "title": "热播", "viewCount": 25000},
            {"id": "2", "title": "冷门", "viewCount": 500}
        ]}});
        let page = JsonRuleExecutor::new(&rule(BEST_RULE))
            .parse_catalog(&body, 1)
            .expect("目录");
        assert_eq!(page.items[0].views, "2.5万次播放");
        assert_eq!(page.items[1].views, "500次播放");
        assert!(!page.has_more);
    }

    #[test]
    fn fill_drama_prefers_detail_values() {
        let document = rule(RULE);
        let mut target = drama("testjson", "11#src1");
        target.title = "列表已有标题".into();
        target.views = "123万播放".into();
        let body = serde_json::json!({
            "result": {
                "duanjuId": 11,
                "title": "详情标题",
                "total": 34,
                "updateStatus": "1"
            }
        });
        JsonRuleExecutor::new(&document).fill_drama(&body, &mut target);
        assert_eq!(target.title, "详情标题");
        assert_eq!(target.episodes, 34);
        assert_eq!(target.release_status, "ongoing");
        // 详情没有返回该字段时保留列表值。
        assert_eq!(target.views, "123万播放");

        let mut blank = drama("testjson", "11#src1");
        let finished =
            serde_json::json!({"result": {"title": "详情标题", "total": 8, "current": 8}});
        JsonRuleExecutor::new(&document).fill_drama(&finished, &mut blank);
        assert_eq!(blank.title, "详情标题");
        assert_eq!(blank.release_status, "finished");
    }

    #[test]
    fn media_url_uses_resolve_paths() {
        let root = serde_json::json!({"data": {"mp4": "https://v.test/x.mp4"}});
        assert_eq!(
            JsonRuleExecutor::new(&rule(BEST_RULE)).media_url(&root),
            Some("https://v.test/x.mp4".to_string())
        );
        assert_eq!(
            JsonRuleExecutor::new(&rule(BEST_RULE)).media_url(&serde_json::json!({"data": {}})),
            None
        );
        assert_eq!(JsonRuleExecutor::new(&rule(RULE)).media_url(&root), None);
    }

    #[test]
    fn json_rule_rejects_css_episode_selectors() {
        let text = r##"{
            "schema": "1.0",
            "id": "cssmix",
            "name": "混写测试源",
            "base": "https://a.test",
            "kind": "json",
            "catalog": {
                "url": "{base}/list",
                "items": ["data"],
                "fields": {"id": ["id"], "title": ["title"]}
            },
            "detail": {"url": "{base}/detail", "episodes": [".episode-item"]}
        }"##;
        let err = RuleDocument::from_json(text).expect_err("CSS 选择器不能用于 JSON 规格");
        assert!(
            matches!(&err, SourceError::Rule { detail, .. } if detail.contains("JSON 规格")),
            "{err:?}"
        );
    }
}
