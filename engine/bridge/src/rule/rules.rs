use std::collections::BTreeMap;

use serde::Deserialize;
use serde_json::Value;

use crate::crypto::md5_hex;
use crate::env::FetchRequest;
use crate::SourceError;

/// 站源取数方式：`html` 走 CSS 选择器，`json` 走接口路径，`next` 先取页面内嵌 JSON。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RuleKind {
    #[default]
    Html,
    Json,
    Next,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuleDocument {
    pub schema: String,
    pub id: String,
    pub name: String,
    #[serde(default = "default_group")]
    pub group: String,
    pub base: String,
    #[serde(default)]
    pub kind: RuleKind,
    #[serde(default)]
    pub capabilities: Vec<String>,
    /// 每个请求都会带上的请求头，可被分段规格覆盖。
    #[serde(default)]
    pub headers: BTreeMap<String, String>,
    /// 站源把附加信息编码进主键时的分隔符，供 `{idFirst}`、`{idRest}` 使用。
    #[serde(default)]
    pub id_split: Option<String>,
    #[serde(default)]
    pub categories: Vec<CategoryRule>,
    #[serde(default)]
    pub catalog: Option<CatalogRule>,
    #[serde(default)]
    pub detail: Option<DetailRule>,
    #[serde(default)]
    pub search: Option<SearchRule>,
    #[serde(default)]
    pub resolve: Option<ResolveRule>,
}

fn default_group() -> String {
    "duanju".to_string()
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CategoryRule {
    pub id: String,
    pub name: String,
}

/// 地址模板与生效条件。`when` 取值：`category`（分类非空）、
/// `keyword`（关键词非空）、省略或 `default`（始终）。
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UrlRule {
    #[serde(default)]
    pub url: String,
    #[serde(default)]
    pub when: Option<String>,
}

impl UrlRule {
    fn applies(&self, ctx: &TemplateCtx<'_>) -> bool {
        match self.when.as_deref().map(str::trim) {
            None | Some("") | Some("default") => true,
            Some("category") => !ctx.category.is_empty(),
            Some("keyword") => !ctx.keyword.is_empty(),
            Some(_) => false,
        }
    }
}

/// 请求规格：接口站源需要 POST、自定义请求头与 JSON 请求体。
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RequestRule {
    #[serde(default)]
    pub method: Option<String>,
    #[serde(default)]
    pub headers: BTreeMap<String, String>,
    /// JSON 请求体模板，字符串内的占位符会先展开；`{"$int": "{page}"}` 输出数字。
    #[serde(default)]
    pub body: Option<Value>,
    #[serde(default)]
    pub referer: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HasMoreRule {
    /// 本页条目数达到该值则认为还有下一页。
    #[serde(default)]
    pub min_items: u32,
    #[serde(default)]
    pub total: Option<String>,
    #[serde(default)]
    pub current: Option<String>,
}

/// 数值字段的展示换算，用于播放量一类需要带单位的字段。
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NumberFieldRule {
    #[serde(default)]
    pub paths: Vec<String>,
    /// 低于 `divideFrom` 时直接拼接的单位。
    #[serde(default)]
    pub suffix: Option<String>,
    /// 不低于 `divideFrom` 时使用的单位。
    #[serde(default)]
    pub high_suffix: Option<String>,
    #[serde(default)]
    pub divide: Option<u64>,
    #[serde(default)]
    pub divide_from: Option<u64>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReleaseStatusRule {
    #[serde(default)]
    pub paths: Vec<String>,
    #[serde(default)]
    pub total: Option<String>,
    #[serde(default)]
    pub current: Option<String>,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct CatalogRule {
    #[serde(default)]
    pub url: String,
    #[serde(default)]
    pub urls: Vec<UrlRule>,
    #[serde(default)]
    pub request: RequestRule,
    #[serde(default)]
    pub item: SelectorList,
    /// JSON 站源的列表路径候选，命中结果按顺序拼接后按主键去重。
    #[serde(default)]
    pub items: Vec<String>,
    #[serde(default)]
    pub fields: RuleFields,
    #[serde(default)]
    pub next: Option<String>,
    #[serde(default)]
    pub has_more: Option<HasMoreRule>,
    /// 分类为空时使用的默认分类。
    #[serde(default)]
    pub category_default: Option<String>,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct DetailRule {
    /// 详情页地址模板，支持 `{id}` 占位符；为空时退回内置候选。
    #[serde(default)]
    pub url: Option<String>,
    #[serde(default)]
    pub urls: Vec<UrlRule>,
    #[serde(default)]
    pub request: RequestRule,
    pub episodes: EpisodesSpec,
    /// JSON 站源：剧集资料所在节点路径候选。
    #[serde(default)]
    pub meta: Vec<String>,
    #[serde(default)]
    pub fields: RuleFields,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub cover: Option<String>,
    #[serde(default)]
    pub description: Option<String>,
}

/// 分集列表：HTML 用 CSS 选择器，JSON 用路径与字段规格。
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(untagged)]
pub enum EpisodesSpec {
    Selectors(SelectorList),
    Json(Box<EpisodesRule>),
}

impl Default for EpisodesSpec {
    fn default() -> Self {
        Self::Selectors(SelectorList::default())
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EpisodesRule {
    /// 分集数组路径候选，取第一个命中。
    #[serde(default)]
    pub paths: Vec<String>,
    #[serde(default)]
    pub video_url: Vec<String>,
    /// 直取不到时，在子结构里递归查找同样的键。
    #[serde(default)]
    pub recurse: bool,
    /// 多清晰度列表：取 `rank` 最大的一条。
    #[serde(default)]
    pub best: Option<BestUrlRule>,
    #[serde(default)]
    pub page_url: Vec<String>,
    #[serde(default)]
    pub page_url_template: Option<String>,
    #[serde(default)]
    pub chapter_id: Vec<String>,
    #[serde(default)]
    pub number: Vec<String>,
    #[serde(default)]
    pub title: Vec<String>,
    #[serde(default)]
    pub empty_message: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BestUrlRule {
    #[serde(default)]
    pub paths: Vec<String>,
    #[serde(default)]
    pub url: Vec<String>,
    #[serde(default)]
    pub rank: Vec<String>,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SearchRule {
    #[serde(default)]
    pub url: String,
    #[serde(default)]
    pub urls: Vec<UrlRule>,
    #[serde(default)]
    pub request: RequestRule,
    #[serde(default)]
    pub item: SelectorList,
    #[serde(default)]
    pub items: Vec<String>,
    #[serde(default)]
    pub fields: RuleFields,
    #[serde(default)]
    pub has_more: Option<HasMoreRule>,
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ResolveRule {
    #[serde(default)]
    pub player_var: Option<String>,
    #[serde(default)]
    pub url_selector: Option<String>,
    /// JSON/内嵌 JSON 站源的播放地址路径候选。
    #[serde(default)]
    pub url_paths: Vec<String>,
    #[serde(default)]
    pub request: RequestRule,
}

/// 选择器可以是单条字符串，也可以是按优先级排列的候选列表，
/// 用于同一站源不同页面结构（例如首页与分类页类名不同）。
/// JSON 站源里同一结构表示路径候选。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SelectorList(pub Vec<String>);

impl SelectorList {
    pub fn single(value: impl Into<String>) -> Self {
        Self(vec![value.into()])
    }

    pub fn is_empty(&self) -> bool {
        self.0.iter().all(|item| item.trim().is_empty())
    }

    pub fn first_non_empty(&self) -> Option<&str> {
        self.0
            .iter()
            .map(String::as_str)
            .find(|item| !item.trim().is_empty())
    }

    pub fn as_paths(&self) -> Vec<String> {
        self.0
            .iter()
            .map(|item| item.trim())
            .filter(|item| !item.is_empty())
            .map(ToString::to_string)
            .collect()
    }
}

impl<'de> Deserialize<'de> for SelectorList {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum Raw {
            One(String),
            Many(Vec<String>),
        }
        Ok(match Raw::deserialize(deserializer)? {
            Raw::One(value) => SelectorList::single(value),
            Raw::Many(values) => SelectorList(values),
        })
    }
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RuleFields {
    #[serde(default = "default_id_field")]
    pub id: SelectorList,
    #[serde(default = "default_title_field")]
    pub title: SelectorList,
    #[serde(default)]
    pub cover: SelectorList,
    #[serde(default)]
    pub episodes: SelectorList,
    #[serde(default)]
    pub category: SelectorList,
    #[serde(default)]
    pub description: SelectorList,
    /// 主键模板，例如 `{id}#{source}`；省略时直接用 `id` 路径的值。
    #[serde(default)]
    pub id_template: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub views: Option<NumberFieldRule>,
    #[serde(default)]
    pub release_status: Option<ReleaseStatusRule>,
}

fn default_id_field() -> SelectorList {
    SelectorList::single("a@href")
}

fn default_title_field() -> SelectorList {
    SelectorList::single(".title")
}

impl RuleFields {
    pub fn normalized(self) -> Self {
        Self {
            id: if self.id.is_empty() {
                default_id_field()
            } else {
                self.id
            },
            title: if self.title.is_empty() {
                default_title_field()
            } else {
                self.title
            },
            ..self
        }
    }
}

/// 地址模板的渲染上下文。
#[derive(Debug, Clone, Copy, Default)]
pub struct TemplateCtx<'a> {
    pub page: u32,
    pub category: &'a str,
    pub keyword: &'a str,
    pub id: &'a str,
}

impl RuleDocument {
    pub fn from_json(text: &str) -> Result<Self, SourceError> {
        let document: Self = serde_json::from_str(text)
            .map_err(|err| SourceError::parse("rule", format!("{err}")))?;
        document.validate()?;
        Ok(document)
    }

    /// 提前校验所有选择器，避免运行时静默空结果。
    pub fn validate_selectors(&self) -> Result<(), SourceError> {
        let mut checks: Vec<(&'static str, &SelectorList)> = Vec::new();
        let next_selector;
        if let Some(catalog) = &self.catalog {
            checks.push(("catalog.item", &catalog.item));
            if let Some(next) = &catalog.next {
                next_selector = SelectorList::single(next.clone());
                checks.push(("catalog.next", &next_selector));
            }
            if catalog.url.is_empty() && catalog.urls.is_empty() {
                return Err(self.rule_error("catalog 缺少 url"));
            }
        }
        if let Some(detail) = &self.detail {
            if let Some(selectors) = detail.episodes.selectors() {
                checks.push(("detail.episodes", selectors));
            }
        }
        if let Some(search) = &self.search {
            checks.push(("search.item", &search.item));
            if search.url.is_empty() && search.urls.is_empty() {
                return Err(self.rule_error("search 缺少 url"));
            }
        }
        for (field, selectors) in checks {
            if selectors.is_empty() {
                return Err(self.rule_error(&format!("{field} 不能为空")));
            }
            for selector in &selectors.0 {
                let selector = selector.trim();
                if selector.is_empty() {
                    continue;
                }
                if !selector_balanced(selector) {
                    return Err(self.rule_error(&format!("{field} 选择器括号不配对：{selector}")));
                }
            }
        }
        Ok(())
    }

    /// JSON 与内嵌 JSON 站源校验路径与请求规格，不检查 CSS 选择器。
    pub fn validate_paths(&self) -> Result<(), SourceError> {
        if let Some(catalog) = &self.catalog {
            require_paths(self, "catalog.items", &catalog.items)?;
            if catalog.url.is_empty() && catalog.urls.is_empty() {
                return Err(self.rule_error("catalog 缺少 url"));
            }
            self.validate_field_paths("catalog.fields", &catalog.fields)?;
        }
        if let Some(detail) = &self.detail {
            let spec = detail
                .episodes
                .json()
                .ok_or_else(|| self.rule_error("detail.episodes 需要 JSON 规格"))?;
            require_paths(self, "detail.episodes.paths", &spec.paths)?;
            if spec.video_url.is_empty()
                && spec.page_url.is_empty()
                && spec.page_url_template.is_none()
            {
                return Err(self.rule_error("detail.episodes 缺少分集地址来源"));
            }
            self.validate_field_paths("detail.fields", &detail.fields)?;
        }
        if let Some(search) = &self.search {
            require_paths(self, "search.items", &search.items)?;
            if search.url.is_empty() && search.urls.is_empty() {
                return Err(self.rule_error("search 缺少 url"));
            }
            self.validate_field_paths("search.fields", &search.fields)?;
        }
        Ok(())
    }

    fn validate_field_paths(&self, field: &str, fields: &RuleFields) -> Result<(), SourceError> {
        for (name, list) in [
            ("id", &fields.id),
            ("title", &fields.title),
            ("cover", &fields.cover),
            ("episodes", &fields.episodes),
            ("category", &fields.category),
            ("description", &fields.description),
        ] {
            for path in &list.0 {
                if path.contains('@') {
                    return Err(self.rule_error(&format!("{field}.{name} 使用了 CSS 写法：{path}")));
                }
            }
        }
        Ok(())
    }

    fn rule_error(&self, detail: &str) -> SourceError {
        SourceError::Rule {
            rule_id: self.id.clone(),
            detail: detail.to_string(),
        }
    }

    pub fn validate(&self) -> Result<(), SourceError> {
        if self.schema.split('.').next() != Some("1") {
            return Err(self.rule_error(&format!("不支持的 schema：{}", self.schema)));
        }
        if !self.base.starts_with("http") {
            return Err(self.rule_error("base 必须是 http(s) 地址"));
        }
        for (name, present) in [
            ("catalog", self.catalog.is_some()),
            ("detail", self.detail.is_some()),
        ] {
            if !present {
                return Err(self.rule_error(&format!("缺少 {name} 段")));
            }
        }
        match self.kind {
            RuleKind::Html => self.validate_selectors()?,
            RuleKind::Json | RuleKind::Next => self.validate_paths()?,
        }
        Ok(())
    }

    pub fn expand(&self, template: &str, page: u32, category: &str, query: &str) -> String {
        self.render(
            template,
            &TemplateCtx {
                page,
                category,
                keyword: query,
                id: "",
            },
        )
    }

    /// 渲染模板：`{page}` `{category}` `{keyword}` `{id}` `{idFirst}` `{idRest}` `{base}`
    /// `{ts}` `{ts10}`，以及 `{md5:inner}`（inner 先渲染再取摘要）。
    ///
    /// URL 里的关键词按百分号编码；JSON 请求体保留原文，交由传输层编码。
    pub fn render(&self, template: &str, ctx: &TemplateCtx<'_>) -> String {
        self.render_with(template, ctx, true)
    }

    fn render_with(&self, template: &str, ctx: &TemplateCtx<'_>, encode_keyword: bool) -> String {
        let chars: Vec<char> = template.chars().collect();
        let mut out = String::with_capacity(template.len());
        let mut index = 0usize;
        while index < chars.len() {
            if chars[index] != '{' {
                out.push(chars[index]);
                index += 1;
                continue;
            }
            match find_close(&chars, index) {
                Some(end) => {
                    let token: String = chars[index + 1..end].iter().collect();
                    match self.token_value(&token, ctx, encode_keyword) {
                        Some(value) => out.push_str(&value),
                        None => {
                            out.push('{');
                            out.push_str(&token);
                            out.push('}');
                        }
                    }
                    index = end + 1;
                }
                None => {
                    out.push('{');
                    index += 1;
                }
            }
        }
        out
    }

    fn token_value(
        &self,
        token: &str,
        ctx: &TemplateCtx<'_>,
        encode_keyword: bool,
    ) -> Option<String> {
        if let Some(inner) = token.strip_prefix("md5:") {
            let rendered = self.render_with(inner, ctx, encode_keyword);
            return Some(md5_hex(rendered.as_bytes()));
        }
        match token {
            "page" => Some(ctx.page.to_string()),
            "category" => Some(ctx.category.to_string()),
            "keyword" => Some(if encode_keyword {
                encode_component(ctx.keyword)
            } else {
                ctx.keyword.to_string()
            }),
            "id" => Some(ctx.id.to_string()),
            "base" => Some(self.base.clone()),
            "ts" => Some(unix_millis()),
            "ts10" => {
                let text = unix_millis();
                let keep = text.chars().count().saturating_sub(10);
                Some(text.chars().skip(keep).collect())
            }
            "idFirst" => Some(self.id_part(ctx.id, true)),
            "idRest" => Some(self.id_part(ctx.id, false)),
            _ => None,
        }
    }

    fn id_part(&self, id: &str, head: bool) -> String {
        let separator = self.id_split.as_deref().unwrap_or("#");
        let separator = separator.chars().next().unwrap_or('#');
        match id.split_once(separator) {
            Some((first, rest)) => {
                if head {
                    first.to_string()
                } else {
                    rest.to_string()
                }
            }
            None => {
                if head {
                    id.to_string()
                } else {
                    String::new()
                }
            }
        }
    }

    /// 在候选模板中选出第一个满足条件并渲染出非空地址的规则项。
    pub fn pick_url(&self, candidates: &[UrlRule], ctx: &TemplateCtx<'_>) -> Option<String> {
        candidates
            .iter()
            .filter(|candidate| !candidate.url.trim().is_empty() && candidate.applies(ctx))
            .map(|candidate| self.render(&candidate.url, ctx))
            .find(|url| !url.trim().is_empty())
    }

    /// 用分段请求规格构造请求：默认 GET，带模板化请求头与可选 JSON 请求体。
    pub fn build_request(
        &self,
        spec: &RequestRule,
        url: String,
        ctx: &TemplateCtx<'_>,
    ) -> FetchRequest {
        let body = spec
            .body
            .as_ref()
            .map(|template| render_json(template, self, ctx))
            .map(|rendered| rendered.to_string().into_bytes());
        let wants_post = spec
            .method
            .as_deref()
            .map(|method| method.eq_ignore_ascii_case("POST"))
            .unwrap_or(false)
            || body.is_some();
        let mut request = if wants_post {
            FetchRequest::post(url, body.clone().unwrap_or_default())
        } else {
            FetchRequest::get(url)
        };
        let referer = spec
            .referer
            .as_deref()
            .map(|template| self.render(template, ctx))
            .unwrap_or_else(|| format!("{}/", self.base.trim_end_matches('/')));
        request = request.header("Referer", referer);
        for (key, value) in self.headers.iter().chain(spec.headers.iter()) {
            request = request.header(key.clone(), self.render(value, ctx));
        }
        if wants_post && !has_content_type(&request.headers) {
            request = request.header("Content-Type", "application/json");
        }
        request
    }
}

fn has_content_type(headers: &BTreeMap<String, String>) -> bool {
    headers
        .keys()
        .any(|key| key.eq_ignore_ascii_case("content-type"))
}

fn require_paths(rule: &RuleDocument, field: &str, paths: &[String]) -> Result<(), SourceError> {
    if paths.iter().all(|path| path.trim().is_empty()) {
        return Err(rule.rule_error(&format!("{field} 不能为空")));
    }
    for path in paths {
        let path = path.trim();
        if !path.is_empty() && !brackets_balanced(path) {
            return Err(rule.rule_error(&format!("{field} 路径括号不配对：{path}")));
        }
    }
    Ok(())
}

fn render_json(template: &Value, rule: &RuleDocument, ctx: &TemplateCtx<'_>) -> Value {
    match template {
        Value::String(text) => Value::String(rule.render_with(text, ctx, false)),
        Value::Array(items) => Value::Array(
            items
                .iter()
                .map(|item| render_json(item, rule, ctx))
                .collect(),
        ),
        Value::Object(map) => {
            if map.len() == 1 {
                if let Some(inner) = map.get("$int") {
                    let text = render_json(inner, rule, ctx);
                    let raw = text.as_str().unwrap_or_default().trim().to_string();
                    if let Ok(integer) = raw.parse::<i64>() {
                        return Value::from(integer);
                    }
                    if let Ok(float) = raw.parse::<f64>() {
                        return Value::from(float);
                    }
                    return Value::Null;
                }
            }
            let mut out = serde_json::Map::with_capacity(map.len());
            for (key, value) in map {
                out.insert(key.clone(), render_json(value, rule, ctx));
            }
            Value::Object(out)
        }
        other => other.clone(),
    }
}

fn unix_millis() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis().to_string())
        .unwrap_or_else(|_| "0".into())
}

fn find_close(chars: &[char], open: usize) -> Option<usize> {
    let mut depth = 0usize;
    for (offset, ch) in chars.iter().enumerate().skip(open) {
        match ch {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    return Some(offset);
                }
            }
            _ => {}
        }
    }
    None
}

impl CatalogRule {
    pub fn url_candidates(&self, rule: &RuleDocument, ctx: &TemplateCtx<'_>) -> Option<String> {
        if let Some(url) = rule.pick_url(&self.urls, ctx) {
            return Some(url);
        }
        if self.url.trim().is_empty() {
            return None;
        }
        Some(rule.render(&self.url, ctx))
    }

    pub fn category_for<'a>(&'a self, category: &'a str) -> &'a str {
        if category.trim().is_empty() {
            self.category_default.as_deref().unwrap_or(category)
        } else {
            category
        }
    }
}

impl SearchRule {
    pub fn url_candidates(&self, rule: &RuleDocument, ctx: &TemplateCtx<'_>) -> Option<String> {
        if let Some(url) = rule.pick_url(&self.urls, ctx) {
            return Some(url);
        }
        if self.url.trim().is_empty() {
            return None;
        }
        Some(rule.render(&self.url, ctx))
    }
}

impl DetailRule {
    pub fn url_candidates(&self, rule: &RuleDocument, ctx: &TemplateCtx<'_>) -> Option<String> {
        if let Some(url) = rule.pick_url(&self.urls, ctx) {
            return Some(url);
        }
        self.url
            .as_deref()
            .map(|template| rule.render(template, ctx))
    }

    pub fn json_episodes(&self) -> Option<&EpisodesRule> {
        self.episodes.json()
    }
}

impl EpisodesSpec {
    pub fn selectors(&self) -> Option<&SelectorList> {
        match self {
            Self::Selectors(list) => Some(list),
            Self::Json(_) => None,
        }
    }

    pub fn json(&self) -> Option<&EpisodesRule> {
        match self {
            Self::Json(spec) => Some(spec.as_ref()),
            Self::Selectors(_) => None,
        }
    }
}

impl RuleFields {
    /// 主键：`idTemplate` 里的 `{id}` 取 id 路径的值，其余 token 按节点路径取值；
    /// 取到空值的 token 连同紧邻的分隔符一起省略。
    pub fn identity(&self, node: &Value) -> String {
        let raw = crate::rule::jsonpath::text_at(node, &self.id.as_paths());
        let Some(template) = self.id_template.as_deref() else {
            return raw;
        };
        let mut out = String::with_capacity(template.len());
        let mut pending = String::new();
        let mut rest = template;
        while let Some(start) = rest.find('{') {
            pending.push_str(&rest[..start]);
            let tail = &rest[start + 1..];
            let Some(end) = tail.find('}') else {
                out.push_str(&pending);
                out.push_str(tail);
                return out;
            };
            let token = tail[..end].trim();
            let value = if token == "id" {
                raw.clone()
            } else {
                crate::rule::jsonpath::text_at(node, &[token.to_string()])
            };
            if value.is_empty() {
                pending.clear();
            } else {
                out.push_str(&pending);
                out.push_str(&value);
                pending.clear();
            }
            rest = &tail[end + 1..];
        }
        out.push_str(rest);
        out
    }
}

fn selector_balanced(selector: &str) -> bool {
    let mut depth = 0i32;
    let mut quote: Option<char> = None;
    for ch in selector.chars() {
        match (ch, quote) {
            (_, Some(q)) => {
                if ch == q {
                    quote = None;
                }
            }
            ('"' | '\'', None) => quote = Some(ch),
            ('[' | '(', None) => depth += 1,
            (']' | ')', None) => {
                depth -= 1;
                if depth < 0 {
                    return false;
                }
            }
            _ => {}
        }
    }
    depth == 0 && quote.is_none()
}

fn brackets_balanced(path: &str) -> bool {
    let mut depth = 0i32;
    for ch in path.chars() {
        match ch {
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if depth < 0 {
                    return false;
                }
            }
            _ => {}
        }
    }
    depth == 0
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

    const SAMPLE: &str = r#"{
        "schema": "1.0",
        "id": "wuguo",
        "name": "伍果",
        "base": "https://www.duanju55.com",
        "capabilities": ["catalog", "detail", "search"],
        "catalog": {
            "url": "index.php/vod/type/id/{category}/page/{page}.html",
            "item": "a.module-item",
            "fields": { "id": "a@href", "title": ".title" }
        },
        "detail": { "episodes": "a[href*=play]" },
        "search": {
            "url": "index.php/vod/search/page/{page}/wd/{keyword}.html",
            "item": "a.module-item"
        }
    }"#;

    #[test]
    fn parses_and_validates_rule_document() {
        let rule = RuleDocument::from_json(SAMPLE).expect("parse");
        assert_eq!(rule.id, "wuguo");
        assert_eq!(rule.group, "duanju");
        assert_eq!(rule.kind, RuleKind::Html);
        assert!(rule.catalog.is_some());
    }

    #[test]
    fn expands_template_placeholders() {
        let rule = RuleDocument::from_json(SAMPLE).expect("parse");
        let catalog = rule.catalog.as_ref().expect("catalog");
        let url = rule.expand(&catalog.url, 3, "7", "");
        assert_eq!(url, "index.php/vod/type/id/7/page/3.html");
        let search = rule.search.as_ref().expect("search");
        let encoded = rule.expand(&search.url, 1, "", "韩剧 现代");
        assert!(encoded.contains("%E9%9F%A9%E5%89%A7"), "{encoded}");
        assert!(encoded.contains("%20"), "{encoded}");
    }

    #[test]
    fn rejects_wrong_schema_version() {
        let broken = SAMPLE.replace("\"1.0\"", "\"2.0\"");
        let err = RuleDocument::from_json(&broken).expect_err("must fail");
        assert!(matches!(err, SourceError::Rule { .. }));
    }

    #[test]
    fn rejects_missing_detail_section() {
        let broken = SAMPLE.replace("\"detail\": { \"episodes\": \"a[href*=play]\" },", "");
        let err = RuleDocument::from_json(&broken).expect_err("must fail");
        assert!(err.to_string().contains("detail"));
    }

    const JSON_RULE: &str = r##"{
        "schema": "1.0",
        "id": "guanguo",
        "name": "观果",
        "kind": "json",
        "base": "https://api.drama.9ddm.com",
        "idSplit": "#",
        "headers": { "User-Agent": "okhttp/5.1.0" },
        "categories": [ { "id": "1", "name": "都市" } ],
        "catalog": {
            "url": "/drama/home/search?a={md5:{ts10}}&page={page}",
            "request": { "method": "POST", "body": { "page": {"$int": "{page}"}, "pageSize": 30, "subject": "{category}" } },
            "items": ["data"],
            "fields": { "id": ["oneId"], "title": ["title"] },
            "hasMore": { "minItems": 30 }
        },
        "detail": { "url": "/drama/home/shortVideoDetail?oneId={id}", "episodes": { "paths": ["data"], "videoUrl": ["playUrl"] } }
    }"##;

    fn json_rule() -> RuleDocument {
        RuleDocument::from_json(JSON_RULE).expect("rule")
    }

    #[test]
    fn json_rule_rejects_css_field_paths() {
        let broken = JSON_RULE.replace("\"id\": [\"oneId\"]", "\"id\": [\"a@href\"]");
        let err = RuleDocument::from_json(&broken).expect_err("must fail");
        assert!(err.to_string().contains("CSS 写法"), "{err}");
    }

    #[test]
    fn json_rule_requires_episode_paths() {
        let broken = JSON_RULE.replace("\"paths\": [\"data\"]", "\"paths\": []");
        let err = RuleDocument::from_json(&broken).expect_err("must fail");
        assert!(err.to_string().contains("detail.episodes.paths"), "{err}");
    }

    #[test]
    fn renders_md5_and_timestamp_tokens() {
        let rule = json_rule();
        let ctx = TemplateCtx {
            page: 4,
            category: "",
            keyword: "",
            id: "9#extra",
        };
        let url = rule.render("/x?p={md5:abc}&t={ts10}&page={page}", &ctx);
        assert!(url.contains("p=900150983cd24fb0d6963f7d28e17f72"), "{url}");
        assert!(url.contains("page=4"), "{url}");
        let digits: String = url
            .split("&t=")
            .nth(1)
            .unwrap_or_default()
            .split('&')
            .next()
            .unwrap_or_default()
            .chars()
            .collect();
        assert_eq!(digits.len(), 10, "{digits}");
        assert_eq!(rule.render("{idFirst}/{idRest}", &ctx), "9/extra");
    }

    #[test]
    fn builds_post_request_from_json_body_template() {
        let rule = json_rule();
        let catalog = rule.catalog.as_ref().expect("catalog");
        let ctx = TemplateCtx {
            page: 2,
            category: "都市",
            keyword: "",
            id: "",
        };
        let request = rule.build_request(&catalog.request, "https://x.test/a".into(), &ctx);
        assert_eq!(request.method, crate::env::Method::Post);
        assert_eq!(
            request.headers.get("User-Agent").map(String::as_str),
            Some("okhttp/5.1.0")
        );
        assert_eq!(
            request.headers.get("Content-Type").map(String::as_str),
            Some("application/json")
        );
        let body: Value =
            serde_json::from_slice(&request.body.clone().expect("body")).expect("json");
        assert_eq!(body["page"], serde_json::json!(2));
        assert_eq!(body["subject"], "都市");
    }

    #[test]
    fn conditional_urls_pick_first_matching_candidate() {
        let rule = json_rule();
        let with_category = TemplateCtx {
            page: 3,
            category: "462",
            keyword: "",
            id: "",
        };
        let without = TemplateCtx {
            page: 3,
            category: "",
            keyword: "",
            id: "",
        };
        let candidates = vec![
            UrlRule {
                url: "{base}/browse/{category}/{page}".into(),
                when: Some("category".into()),
            },
            UrlRule {
                url: "{base}/".into(),
                when: None,
            },
        ];
        assert_eq!(
            rule.pick_url(&candidates, &with_category).as_deref(),
            Some("https://api.drama.9ddm.com/browse/462/3")
        );
        assert_eq!(
            rule.pick_url(&candidates, &without).as_deref(),
            Some("https://api.drama.9ddm.com/")
        );
    }

    #[test]
    fn id_template_composes_source_key() {
        let rule = json_rule();
        let catalog = rule.catalog.as_ref().expect("catalog");
        let node = serde_json::json!({ "oneId": "42", "source": "drama" });
        let mut fields = catalog.fields.clone();
        fields.id_template = Some("{id}#{source}".into());
        assert_eq!(fields.identity(&node), "42#drama");
        // 附加段为空时分隔符一起省略，与 Go 的条件拼接一致。
        assert_eq!(fields.identity(&serde_json::json!({ "oneId": "42" })), "42");
        assert_eq!(catalog.fields.identity(&node), "42");
    }
}
