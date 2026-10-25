use std::collections::{BTreeMap, BTreeSet};

use serde::Deserialize;
use serde_json::Value;

use guo_source_api::{ContentType, FetchRequest, SourceError};

/// 站源取数方式：`html` 走 CSS 选择器，`json` 走接口路径，`next` 先取页面内嵌 JSON，
/// `regex` 走正则切块（站点结构没有稳定 DOM 时用它，例如黄果）。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RuleKind {
    #[default]
    Html,
    Json,
    Next,
    Regex,
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
    /// 内容类型（`short-drama` / `movie` / `tv` / `anime` / `variety` / `documentary`）。
    ///
    /// 只用于商店筛选与发现页聚合，不影响解析逻辑；空表示未标注。
    #[serde(default)]
    pub content_types: Vec<ContentType>,
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
    /// 前置编排：主请求之前按顺序取一次会话 / 配置，把结果注入后续模板。
    #[serde(default)]
    pub preflight: Vec<PreflightStep>,
    /// 前置结果的复用秒数；缺省 300，`0` 表示每次操作都重跑。
    #[serde(default)]
    pub preflight_ttl: Option<u64>,
}

/// 前置编排的一步：发一个请求，再从响应里提取变量。
///
/// 典型形态（野果类站点）：
/// 1. 取首页拿站点配置；2. 用配置里的 `token` 请求搜索接口。
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PreflightStep {
    /// 步骤名，只用于错误定位与文档可读性。
    #[serde(default)]
    pub name: String,
    /// 地址模板，可用 `{base}` / `{ts}` 与**先前步骤**产出的 `{var:name}`。
    #[serde(default)]
    pub url: String,
    #[serde(default)]
    pub request: RequestRule,
    #[serde(default)]
    pub extract: ExtractRule,
}

/// 从响应里提取变量：变量名 → JSONPath / CSS 选择器 / 正则。
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExtractRule {
    /// 响应形态；缺省 `json`（多数前置接口返回 JSON）。
    #[serde(default)]
    pub kind: Option<RuleKind>,
    #[serde(default)]
    pub vars: BTreeMap<String, String>,
}

/// 收集一个动作段里所有可能含模板的字符串（地址候选、Referer、请求头值）。
fn collect_templates(
    label: &str,
    url: &str,
    urls: &[UrlRule],
    request: &RequestRule,
    out: &mut Vec<(String, String)>,
) {
    if !url.trim().is_empty() {
        out.push((label.to_string(), url.to_string()));
    }
    for candidate in urls {
        if !candidate.url.trim().is_empty() {
            out.push((label.to_string(), candidate.url.clone()));
        }
    }
    if let Some(referer) = &request.referer {
        out.push((label.to_string(), referer.clone()));
    }
    for value in request.headers.values() {
        out.push((label.to_string(), value.clone()));
    }
    if let Some(body) = &request.body {
        // 请求体里的字符串同样是模板（`{"$int":"{page}"}`），
        // 之前只渲染不校验，写错 token 会静默发出坏请求，这里一并收进来。
        push_json_templates(label, body, out);
    }
}

fn push_json_templates(label: &str, value: &Value, out: &mut Vec<(String, String)>) {
    match value {
        Value::String(text) => out.push((label.to_string(), text.clone())),
        Value::Array(items) => {
            for item in items {
                push_json_templates(label, item, out);
            }
        }
        Value::Object(map) => {
            for item in map.values() {
                push_json_templates(label, item, out);
            }
        }
        _ => {}
    }
}

/// 步骤在报错里的称呼：`#0 取配置`，无名时就是 `#0`。
fn preflight_label(index: usize, step: &PreflightStep) -> String {
    let name = step.name.trim();
    if name.is_empty() {
        format!("#{index}")
    } else {
        format!("#{index} {name}")
    }
}

/// 校验一段模板里的 `{var:…}` 引用都在已声明集合内。
fn check_var_scope(
    rule: &RuleDocument,
    label: &str,
    template: &str,
    declared: &BTreeSet<String>,
) -> Result<(), SourceError> {
    for token in crate::template::tokens_in(template) {
        if !token.starts_with("var:") {
            continue;
        }
        match crate::template::parse(token) {
            Some(crate::template::Token::Var(name)) if declared.contains(name) => {}
            Some(crate::template::Token::Var(_)) => {
                let known = if declared.is_empty() {
                    "无".to_string()
                } else {
                    declared.iter().cloned().collect::<Vec<_>>().join("、")
                };
                return Err(rule.rule_error(&format!(
                    "{label} 引用了未声明的 preflight 变量 {{{token}}}（已声明：{known}）"
                )));
            }
            _ => return Err(rule.rule_error(&format!("{label} 的变量名不合法：{{{token}}}"))),
        }
    }
    Ok(())
}

/// 校验单个变量的提取表达式：变量名合法、表达式能编译。
fn validate_extract(
    rule: &RuleDocument,
    label: &str,
    name: &str,
    expression: &str,
    kind: Option<RuleKind>,
) -> Result<(), SourceError> {
    if name.trim().is_empty() {
        return Err(rule.rule_error(&format!("preflight {label} 的变量名为空")));
    }
    let expression = expression.trim();
    if expression.is_empty() {
        return Err(rule.rule_error(&format!("preflight {label} 的变量 {name} 缺少提取表达式")));
    }
    match kind.unwrap_or(RuleKind::Json) {
        // JSONPath 的解析非常宽松（看不懂的段会被忽略），没有可靠的预校验，
        // 交给 `extract_vars` 在取不到值时带变量名报错。
        RuleKind::Json | RuleKind::Next => Ok(()),
        RuleKind::Regex => regex::Regex::new(expression).map(|_| ()).map_err(|err| {
            rule.rule_error(&format!("preflight {label} 的变量 {name} 正则无效：{err}"))
        }),
        RuleKind::Html => {
            let selector = expression.split('@').next().unwrap_or(expression).trim();
            scraper::Selector::parse(selector)
                .map(|_| ())
                .map_err(|err| {
                    rule.rule_error(&format!(
                        "preflight {label} 的变量 {name} 选择器无效：{err:?}"
                    ))
                })
        }
    }
}

/// 把一组正则候选收进待校验清单。
fn push_list<'a>(out: &mut Vec<(&'static str, &'a str)>, label: &'static str, items: &'a [String]) {
    for item in items {
        out.push((label, item));
    }
}

/// 收集一个字段规格里用到的全部正则（空串由调用方统一判空，这里照收）。
fn push_fields<'a>(
    out: &mut Vec<(&'static str, &'a str)>,
    label: &'static str,
    fields: &'a RuleFields,
) {
    push_list(out, label, &fields.id.0);
    push_list(out, label, &fields.title.0);
    push_list(out, label, &fields.cover.0);
    push_list(out, label, &fields.episodes.0);
    push_list(out, label, &fields.category.0);
    push_list(out, label, &fields.description.0);
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

/// 分集列表：HTML 用 CSS 选择器，JSON 用路径与字段规格，正则型站源用 [`EpisodesRegex`]。
///
/// `Regex` 必须排在 `Json` 前面：`EpisodesRule` 的字段全带 `#[serde(default)]`，
/// 换成任意顺序会让 `{"pattern": …}` 静默落进 `Json` 变体并得到空分集。
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(untagged)]
pub enum EpisodesSpec {
    Selectors(SelectorList),
    Regex(Box<EpisodesRegex>),
    Json(Box<EpisodesRule>),
}

impl EpisodesSpec {
    pub fn regex(&self) -> Option<&EpisodesRegex> {
        match self {
            Self::Regex(spec) => Some(spec),
            _ => None,
        }
    }
}

/// 正则型站源的分集规格。
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EpisodesRegex {
    /// 全局匹配分集条目。**第 1 个捕获组是分集地址**。
    pub pattern: String,
    /// 分集标题所在的捕获组；省略时用第 2 组（没有则留空，由序号补标题）。
    #[serde(default)]
    pub title_group: Option<usize>,
    /// 分集标题为空时的兜底模板，支持 `{n}`。
    #[serde(default)]
    pub title_template: Option<String>,
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
    /// 正则型站源的播放地址正则候选：取第一个命中的第 1 个捕获组，
    /// 没有捕获组则取整段匹配。
    #[serde(default)]
    pub url_regex: Vec<String>,
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
    /// 从 `id` 的原始值里用正则抽出主键。
    ///
    /// 站点常把 id 藏在路径里（`/vod/play/id/456/sid/1.html`）：直接拿整段
    /// URL 当主键会让同一部剧在目录与详情里得到两个不同 id。
    /// 写了 `idPattern` 就必须能匹配，匹配不到视为该条目无效。
    #[serde(default)]
    pub id_pattern: Option<String>,
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
    /// `preflight` 提取出来的变量；没有前置编排时为 `None`。
    pub vars: Option<&'a BTreeMap<String, String>>,
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
            // 逗号分隔的选择器会被当成一个整体：`"a@href, b@href"` 里
            // `@` 之后的部分全变成属性名，取到的永远是空串。这种写法必须拒绝。
            for selector in &selectors.0 {
                if selector.contains(',') {
                    return Err(self.rule_error(&format!(
                        "{field} 里的 \"{selector}\" 含逗号：候选选择器请写成数组，\
                         否则整串会被当成一个选择器"
                    )));
                }
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
        if self.id.trim().is_empty() {
            return Err(self.rule_error("id 不能为空"));
        }
        if !self
            .id
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
        {
            return Err(self.rule_error(&format!(
                "id 只能包含小写字母、数字、`_` 与 `-`：{}",
                self.id
            )));
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
            RuleKind::Regex => self.validate_regexes()?,
        }
        self.validate_templates()?;
        self.validate_preflight()?;
        Ok(())
    }

    /// 加载期编译全部正则。
    ///
    /// 与选择器同理：正则写错时静默返回空列表，看起来像站点改版，
    /// 排查成本远高于在加载时就报错。
    pub fn validate_regexes(&self) -> Result<(), SourceError> {
        let mut patterns: Vec<(&'static str, &str)> = Vec::new();
        if let Some(catalog) = &self.catalog {
            push_list(&mut patterns, "catalog.item", &catalog.item.0);
            push_fields(&mut patterns, "catalog", &catalog.fields);
            if let Some(next) = &catalog.next {
                patterns.push(("catalog.next", next));
            }
            if let Some(pattern) = &catalog.fields.id_pattern {
                patterns.push(("catalog.fields.idPattern", pattern));
            }
        }
        if let Some(search) = &self.search {
            push_list(&mut patterns, "search.item", &search.item.0);
            push_fields(&mut patterns, "search", &search.fields);
        }
        if let Some(detail) = &self.detail {
            if let Some(spec) = detail.episodes.regex() {
                patterns.push(("detail.episodes.pattern", &spec.pattern));
            }
            push_fields(&mut patterns, "detail", &detail.fields);
        }
        if let Some(resolve) = &self.resolve {
            for (index, pattern) in resolve.url_regex.iter().enumerate() {
                patterns.push(("resolve.urlRegex", pattern));
                let _ = index;
            }
        }
        for (label, pattern) in patterns {
            if pattern.trim().is_empty() {
                return Err(self.rule_error(&format!("{label} 的正则不能为空")));
            }
            regex::Regex::new(pattern)
                .map_err(|err| self.rule_error(&format!("{label} 的正则无效 {pattern}：{err}")))?;
        }
        Ok(())
    }

    /// 校验所有模板里的 token：未知 token 一律拒绝。
    ///
    /// 否则 `{foo}` 会被原样发到站点，返回 200 + 空列表，看起来像源站改版。
    pub fn validate_templates(&self) -> Result<(), SourceError> {
        // base 是常量前缀，出现占位符说明写错了段（`{base}` 只应出现在请求模板里）。
        if let Some(token) = crate::template::tokens_in(&self.base).first() {
            return Err(self.rule_error(&format!("base 不应包含模板占位符 {{{token}}}")));
        }

        let mut templates: Vec<(String, String)> = Vec::new();
        self.collect_action_templates(&mut templates);
        for (index, step) in self.preflight.iter().enumerate() {
            let label = preflight_label(index, step);
            collect_templates(&label, &step.url, &[], &step.request, &mut templates);
        }

        for (label, template) in &templates {
            for token in crate::template::tokens_in(template) {
                if crate::template::parse(token).is_none() {
                    return Err(self.rule_error(&format!(
                        "{label} 里的模板 token 不受支持：{{{token}}}（{template}）"
                    )));
                }
            }
        }
        Ok(())
    }

    /// 主动作段（目录 / 搜索 / 详情 / 取流）里所有可能含模板的字符串。
    fn collect_action_templates(&self, out: &mut Vec<(String, String)>) {
        if let Some(catalog) = &self.catalog {
            collect_templates(
                "catalog",
                &catalog.url,
                &catalog.urls,
                &catalog.request,
                out,
            );
        }
        if let Some(search) = &self.search {
            collect_templates("search", &search.url, &search.urls, &search.request, out);
        }
        if let Some(detail) = &self.detail {
            if let Some(url) = &detail.url {
                out.push(("detail".to_string(), url.clone()));
            }
            collect_templates("detail", "", &detail.urls, &detail.request, out);
        }
        if let Some(resolve) = &self.resolve {
            collect_templates("resolve", "", &[], &resolve.request, out);
        }
    }

    /// 校验前置编排：步骤自身合法，变量引用不越界。
    ///
    /// 变量作用域按顺序收窄：第 N 步只能引用第 1..N-1 步产出的变量，
    /// 主动作段可以引用全部。写错名字在加载期就报错——否则运行时渲染出
    /// 空串，请求会带着「看起来正常」的坏地址发出去。
    fn validate_preflight(&self) -> Result<(), SourceError> {
        // 即使没有任何步骤也要往下走：主动作段引用 `{var:x}` 时必须报错，
        // 否则运行时渲染成空串，请求带着缺参地址发出去。
        let mut declared: BTreeSet<String> = BTreeSet::new();
        for (index, step) in self.preflight.iter().enumerate() {
            let label = preflight_label(index, step);
            if step.url.trim().is_empty() {
                return Err(self.rule_error(&format!("preflight {label} 缺少 url")));
            }
            check_var_scope(
                self,
                &format!("preflight {label}.url"),
                &step.url,
                &declared,
            )?;
            let mut step_templates: Vec<(String, String)> = Vec::new();
            collect_templates(
                &format!("preflight {label}"),
                "",
                &[],
                &step.request,
                &mut step_templates,
            );
            for (template_label, template) in &step_templates {
                check_var_scope(self, template_label, template, &declared)?;
            }
            if step.extract.vars.is_empty() {
                return Err(self.rule_error(&format!(
                    "preflight {label} 的 extract.vars 为空：至少声明一个变量"
                )));
            }
            for (name, expression) in &step.extract.vars {
                validate_extract(self, &label, name, expression, step.extract.kind)?;
                if !declared.insert(name.clone()) {
                    return Err(
                        self.rule_error(&format!("preflight 变量 {name} 重复声明（{label}）"))
                    );
                }
            }
        }
        // 主动作段只能引用声明过的变量。
        let mut templates: Vec<(String, String)> = Vec::new();
        self.collect_action_templates(&mut templates);
        for (label, template) in &templates {
            check_var_scope(self, label, template, &declared)?;
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

                vars: None,
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
        use crate::template::{digest_hex, hmac_sha256_hex, Token, Transform};
        Some(match crate::template::parse(token)? {
            Token::Page => ctx.page.to_string(),
            Token::Category => ctx.category.to_string(),
            Token::Keyword => {
                if encode_keyword {
                    encode_component(ctx.keyword)
                } else {
                    ctx.keyword.to_string()
                }
            }
            Token::Id => ctx.id.to_string(),
            Token::Base => self.base.clone(),
            Token::TimestampMillis => unix_millis(),
            Token::TimestampSeconds => {
                let text = unix_millis();
                let keep = text.chars().count().saturating_sub(10);
                text.chars().skip(keep).collect()
            }
            Token::IdPart { head } => self.id_part(ctx.id, head),
            Token::Digest { algorithm, inner } => {
                let rendered = self.render_with(inner, ctx, encode_keyword);
                digest_hex(algorithm, &rendered)
            }
            Token::Transform { kind, inner } => {
                let rendered = self.render_with(inner, ctx, encode_keyword);
                match kind {
                    Transform::Upper => rendered.to_uppercase(),
                    Transform::Lower => rendered.to_lowercase(),
                    Transform::Trim => rendered.trim().to_string(),
                }
            }
            Token::Hmac { key, inner } => {
                let rendered = self.render_with(inner, ctx, encode_keyword);
                hmac_sha256_hex(key.as_bytes(), rendered.as_bytes())
            }
            Token::Var(name) => ctx
                .vars
                .and_then(|vars| vars.get(name))
                .cloned()
                // 变量缺失只可能发生在 preflight 失败后——调用方在这种情况下
                // 会中止操作，不会走到渲染。留空串而非字面量，避免把 `{var:x}`
                // 原样拼进地址发出一个"看起来正常"的坏请求。
                .unwrap_or_default(),
        })
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
            Self::Regex(_) | Self::Json(_) => None,
        }
    }

    pub fn json(&self) -> Option<&EpisodesRule> {
        match self {
            Self::Json(spec) => Some(spec.as_ref()),
            Self::Selectors(_) | Self::Regex(_) => None,
        }
    }
}

impl RuleFields {
    /// 主键：`idTemplate` 里的 `{id}` 取 id 路径的值，其余 token 按节点路径取值；
    /// 取到空值的 token 连同紧邻的分隔符一起省略。
    /// 取主键原值，并按 `idPattern` 抽取。
    ///
    /// 抽不到时返回空串：调用方据此丢弃该条目，而不是把整段 URL 当 id。
    pub fn raw_identity(&self, node: &Value) -> String {
        let raw = crate::jsonpath::text_at(node, &self.id.as_paths());
        match self.id_pattern.as_deref() {
            Some(pattern) if !pattern.is_empty() => {
                extract_pattern(&raw, pattern).unwrap_or_default()
            }
            _ => raw,
        }
    }

    pub fn identity(&self, node: &Value) -> String {
        let raw = self.raw_identity(node);
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
                crate::jsonpath::text_at(node, &[token.to_string()])
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

/// 用极简正则从 `raw` 里抽取主键。
///
/// 只支持规则文件里真正用得到的两种写法：
/// - `(\d+)`：取第一段连续数字；
/// - 其余字符按字面量匹配。
///
/// 之所以不引入 `regex` crate：规则引擎只需要「从 URL 里拿数字 id」这一个能力，
/// 为它加一个几百 KB 的依赖不划算，而复杂正则本就应该由代码插件承担。
pub(crate) fn extract_pattern(raw: &str, pattern: &str) -> Option<String> {
    const DIGITS: &str = "(\\d+)";
    let Some((prefix, _suffix)) = pattern.split_once(DIGITS) else {
        return raw.contains(pattern).then(|| raw.to_string());
    };
    // 只在**路径段**里找数字：域名与查询串里的数字（`dsd.com.se`、`?id=1`）
    // 会先命中，拿它们当主键会让所有条目撞成同一个 id。
    let path = raw
        .split_once("://")
        .map(|(_, rest)| rest.split_once('/').map(|(_, path)| path).unwrap_or(""))
        .unwrap_or(raw);
    let path = path.split(['?', '#']).next().unwrap_or(path);
    let segments: Vec<&str> = path.split('/').filter(|part| !part.is_empty()).collect();

    // 前缀里的最后一段（如 `play`）用来定位「紧接着的那段就是 id」。
    // `play` 与 `detail` 这类路由在同一规则里都会出现，因此先按标记找，
    // 找不到再退回「路径里第一段纯数字」——`/vod/detail/id/457.html` 属于后者。
    let anchor = prefix
        .rsplit('/')
        .find(|part| !part.is_empty())
        .unwrap_or(prefix);
    if !anchor.is_empty() {
        for window in segments.windows(2) {
            if let [marker, next] = window {
                if marker.eq_ignore_ascii_case(anchor) && next.chars().all(|c| c.is_ascii_digit()) {
                    return Some((*next).to_string());
                }
            }
        }
    }
    // 退路一：`id` 标记后面紧跟的纯数字段（`/vod/detail/id/457.html`）。
    // 注意 `457.html` 带扩展名，必须先去扩展名再判断。
    for window in segments.windows(2) {
        if let [marker, next] = window {
            let stem = next.rsplit_once('.').map(|(head, _)| head).unwrap_or(next);
            if marker.eq_ignore_ascii_case("id")
                && !stem.is_empty()
                && stem.chars().all(|c| c.is_ascii_digit())
            {
                return Some(stem.to_string());
            }
        }
    }
    // 退路二：路径里第一段纯数字（同样允许带扩展名）。
    segments
        .iter()
        .map(|part| part.rsplit_once('.').map(|(head, _)| head).unwrap_or(part))
        .find(|part| !part.is_empty() && part.chars().all(|c| c.is_ascii_digit()))
        .map(str::to_string)
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
    fn parses_content_types() {
        let text = SAMPLE.replace(
            r#""capabilities": ["catalog", "detail", "search"],"#,
            r#""capabilities": ["catalog", "detail", "search"],
        "contentTypes": ["short-drama", "movie"],"#,
        );
        let rule = RuleDocument::from_json(&text).expect("parse");
        assert_eq!(rule.content_types.len(), 2);
        assert_eq!(rule.content_types[0], ContentType::ShortDrama);
        assert_eq!(rule.content_types[1], ContentType::Movie);
    }

    #[test]
    fn rejects_unknown_content_type() {
        let text = SAMPLE.replace(
            r#""capabilities": ["catalog", "detail", "search"],"#,
            r#""capabilities": ["catalog", "detail", "search"],
        "contentTypes": ["短剧"],"#,
        );
        let err = RuleDocument::from_json(&text).expect_err("must fail");
        assert!(err.to_string().contains("未知内容类型"), "{err}");
    }

    #[test]
    fn missing_content_types_is_allowed() {
        // 老规则包没有这个字段：必须仍能加载，只是商店里显示「未标注」。
        let rule = RuleDocument::from_json(SAMPLE).expect("parse");
        assert!(rule.content_types.is_empty());
    }

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

            vars: None,
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

            vars: None,
        };
        let request = rule.build_request(&catalog.request, "https://x.test/a".into(), &ctx);
        assert_eq!(request.method, guo_source_api::Method::Post);
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

            vars: None,
        };
        let without = TemplateCtx {
            page: 3,
            category: "",
            keyword: "",
            id: "",

            vars: None,
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
    #[test]
    fn id_pattern_extracts_from_path_not_domain() {
        // 域名与查询串里的数字不能当主键：否则所有条目会撞成同一个 id。
        assert_eq!(
            extract_pattern(
                "https://www.dsd.com.se/index.php/vod/play/id/456/sid/1/nid/1.html",
                "(\\d+)"
            ),
            Some("456".to_string())
        );
        assert_eq!(
            extract_pattern(
                "https://www.dsd.com.se/index.php/vod/detail/id/457.html",
                "(\\d+)"
            ),
            Some("457".to_string())
        );
        assert_eq!(
            extract_pattern("https://a.test/x/9.html", "(\\d+)"),
            Some("9".to_string())
        );
        assert_eq!(extract_pattern("https://a.test/no-digits", "(\\d+)"), None);
    }

    #[test]
    fn html_executor_uses_id_pattern() {
        // 同一份 HTML，写了 idPattern 才取到正确的 id。
        let text = include_str!("../../../rules/dsd.json");
        let rule = RuleDocument::from_json(text).expect("规则应可加载");
        let html = include_str!("../../../bridge/tests/fixtures/dsd_catalog.html");
        let page = crate::RuleExecutor::new(&rule)
            .parse_catalog(html, 1)
            .expect("解析");
        assert_eq!(page.items.len(), 2);
        assert_eq!(page.items[0].source_id, "456");
        assert_eq!(page.items[1].source_id, "457");
        assert_eq!(page.items[1].title, "帝果榜二");
    }

    #[test]
    fn rejects_unknown_template_token() {
        let text = include_str!("../../../rules/wuguo.json").replace("{page}", "{page}&x={nope}");
        let err = RuleDocument::from_json(&text).expect_err("必须拒绝未知 token");
        assert!(err.to_string().contains("nope"), "{err}");
    }

    #[test]
    fn accepts_hmac_and_transform_tokens() {
        let text = include_str!("../../../rules/wuguo.json").replace(
            "index.php/vod/search/page/{page}/wd/{keyword}.html",
            "index.php/vod/search/page/{hmac:sha256:secret:{page}}/wd/{upper:{keyword}}.html",
        );
        let document = RuleDocument::from_json(&text).expect("hmac / transform token 应被接受");
        assert_eq!(document.id, "wuguo");
    }

    #[test]
    fn renders_hmac_sha256_matching_reference() {
        let rule = RuleDocument::from_json(include_str!("../../../rules/wuguo.json"))
            .expect("规则应可加载");
        // RFC 4231 Case 2 的 key/data，用模板语法拼出来。
        let rendered = rule.render(
            "{hmac:sha256:Jefe:what do ya want for nothing?}",
            &TemplateCtx::default(),
        );
        assert_eq!(
            rendered,
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        );
    }

    #[test]
    fn renders_sha256_and_transforms() {
        let rule = RuleDocument::from_json(include_str!("../../../rules/wuguo.json"))
            .expect("规则应可加载");
        assert_eq!(
            rule.render("{sha256:abc}", &TemplateCtx::default()),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(
            rule.render(
                "{upper:{id}}",
                &TemplateCtx {
                    id: "ab",
                    ..TemplateCtx::default()
                }
            ),
            "AB"
        );
        assert_eq!(rule.render("{trim:  x  }", &TemplateCtx::default()), "x");
    }

    #[test]
    fn base_must_not_contain_tokens() {
        let text = include_str!("../../../rules/wuguo.json").replace(
            "https://www.duanju55.com",
            "https://www.duanju55.com/{page}",
        );
        let err = RuleDocument::from_json(&text).expect_err("base 不应有 token");
        assert!(err.to_string().contains("base"), "{err}");
    }

    #[test]
    fn rejects_invalid_rule_id() {
        let text = include_str!("../../../rules/wuguo.json")
            .replace("\"id\": \"wuguo\"", "\"id\": \"Wu Guo\"");
        let err = RuleDocument::from_json(&text).expect_err("id 必须是小写");
        assert!(err.to_string().contains("id"), "{err}");
    }
}

#[cfg(test)]
mod preflight_tests {
    use super::*;

    fn document(preflight: &str, catalog_url: &str) -> String {
        format!(
            r#"{{
                "schema": "1.0",
                "id": "yeguo",
                "name": "野果",
                "base": "https://x.test",
                "kind": "json",
                "catalog": {{ "url": "{catalog_url}", "items": ["data.list"], "fields": {{ "id": ["$.id"] }} }},
                "detail": {{ "episodes": {{ "paths": ["data.eps"], "videoUrl": ["$.url"] }} }},
                "preflight": {preflight}
            }}"#
        )
    }

    #[test]
    fn renders_declared_variables() {
        let json = document(
            r#"[
                { "name": "配置", "url": "{base}/cfg", "extract": { "vars": { "token": "$.data.token" } } }
            ]"#,
            "list?page={page}&t={var:token}",
        );
        let rule = RuleDocument::from_json(&json).expect("rule");
        let mut vars = BTreeMap::new();
        vars.insert("token".to_string(), "tk-1".to_string());
        let ctx = TemplateCtx {
            page: 2,
            category: "",
            keyword: "",
            id: "",
            vars: Some(&vars),
        };
        assert_eq!(
            rule.render("list?page={page}&t={var:token}", &ctx),
            "list?page=2&t=tk-1"
        );
        // 没传 vars 时渲染为空串而不是字面量：调用方在 preflight 失败时
        // 会中止操作，走到这里说明变量确实为空。
        assert_eq!(rule.render("t={var:token}", &TemplateCtx::default()), "t=");
    }

    #[test]
    fn rejects_undeclared_variable() {
        let json = document("[]", "list?t={var:missing}");
        let err = RuleDocument::from_json(&json).expect_err("must fail");
        assert!(err.to_string().contains("missing"), "{err}");
        assert!(err.to_string().contains("未声明"), "{err}");
    }

    #[test]
    fn step_cannot_reference_a_later_step() {
        let json = document(
            r#"[
                { "name": "取站点", "url": "{base}/site?t={var:token}",
                  "extract": { "vars": { "site": "$.site" } } },
                { "name": "取配置", "url": "{base}/cfg",
                  "extract": { "vars": { "token": "$.token" } } }
            ]"#,
            "list",
        );
        let err = RuleDocument::from_json(&json).expect_err("must fail");
        assert!(err.to_string().contains("token"), "{err}");
    }

    #[test]
    fn rejects_duplicate_variable_names() {
        let json = document(
            r#"[
                { "url": "{base}/a", "extract": { "vars": { "t": "$.t" } } },
                { "url": "{base}/b", "extract": { "vars": { "t": "$.t" } } }
            ]"#,
            "list",
        );
        let err = RuleDocument::from_json(&json).expect_err("must fail");
        assert!(err.to_string().contains("重复"), "{err}");
    }

    #[test]
    fn rejects_invalid_extract_expressions() {
        let bad_regex = document(
            r#"[{ "url": "{base}/a", "extract": { "kind": "regex", "vars": { "t": "(" } } }]"#,
            "list",
        );
        let err = RuleDocument::from_json(&bad_regex).expect_err("must fail");
        assert!(err.to_string().contains("正则"), "{err}");

        let bad_selector = document(
            r#"[{ "url": "{base}/a", "extract": { "kind": "html", "vars": { "t": "div[[" } } }]"#,
            "list",
        );
        let err = RuleDocument::from_json(&bad_selector).expect_err("must fail");
        assert!(err.to_string().contains("选择器"), "{err}");
    }

    #[test]
    fn requires_url_and_extract_vars() {
        let missing_url = document(
            r#"[{ "name": "空", "extract": { "vars": { "t": "$.t" } } }]"#,
            "list",
        );
        let err = RuleDocument::from_json(&missing_url).expect_err("must fail");
        assert!(err.to_string().contains("url"), "{err}");

        let missing_vars = document(r#"[{ "url": "{base}/a" }]"#, "list");
        let err = RuleDocument::from_json(&missing_vars).expect_err("must fail");
        assert!(err.to_string().contains("extract.vars"), "{err}");
    }

    #[test]
    fn variables_work_in_headers_and_bodies() {
        let json = document(
            r#"[
                { "url": "{base}/cfg", "extract": { "vars": { "token": "$.token" } } }
            ]"#,
            "list",
        )
        .replace(
            r#""catalog": { "url": "list", "items": ["data.list"], "fields": { "id": ["$.id"] } }"#,
            r#""catalog": { "url": "list", "items": ["data.list"], "fields": { "id": ["$.id"] },
                "request": { "method": "POST", "headers": { "X-Token": "{var:token}" },
                             "body": { "t": "{var:token}" } } }"#,
        );
        let rule = RuleDocument::from_json(&json).expect("rule");
        let mut vars = BTreeMap::new();
        vars.insert("token".to_string(), "tk".to_string());
        let ctx = TemplateCtx {
            page: 1,
            category: "",
            keyword: "",
            id: "",
            vars: Some(&vars),
        };
        let catalog = rule.catalog.as_ref().expect("catalog");
        let request = rule.build_request(&catalog.request, "https://x.test/list".into(), &ctx);
        assert_eq!(
            request.headers.get("X-Token").map(String::as_str),
            Some("tk")
        );
        assert_eq!(request.body.as_deref(), Some(r#"{"t":"tk"}"#.as_bytes()));
    }
}
