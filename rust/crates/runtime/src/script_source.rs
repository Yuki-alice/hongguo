//! 脚本型站源：把 `main.js` 包装成 `SourcePlugin`。
//!
//! 与 `ComponentSource`（Wasm）的关键差别：**这里不需要 IDL**。
//! 脚本实现哪几个函数，宿主就在运行时探到哪几个能力——
//! 新增一个方法不用改 WIT、不用重新生成绑定、不用改 7 个插件。
//! 这正是 Wasm 路线卡住的那一步（ADR-13）。
//!
//! 约定（写进文档，脚本作者只依赖这一层）：
//! - 脚本是普通 JS，顶层 `function catalog(input) { … }` 即为导出；
//! - `input` 是宿主给的 JSON 对象，返回值必须可 `JSON.stringify`；
//! - `ctx.fetch` / `ctx.store` / `ctx.log` / `ctx.now` 由宿主注入，全部同步。

use std::sync::Arc;

use async_trait::async_trait;
use guo_host::{JsPluginHost, ScriptLimits};
use guo_source_api::{
    Capability, Category, Chapter, ContentType, DanmakuPage, Detail, Drama, Media, Page,
    RankingBoard, RankingPage, RecommendCursor, RecommendPage, SeriesSeason, SourceEnv,
    SourceError, SourceMeta, SourcePlugin, Suggestion, CURRENT_API_LEVEL,
};

/// 脚本导出的函数清单。加载期探一次，之后每个方法据此决定「不支持」还是「调不到」。
#[derive(Debug, Clone, Default)]
struct Exports {
    categories: bool,
    catalog: bool,
    detail: bool,
    search: bool,
    resolve: bool,
    ranking_boards: bool,
    ranking: bool,
    recommend: bool,
    suggestions: bool,
    danmaku: bool,
    seasons: bool,
}

impl Exports {
    fn capabilities(&self) -> Vec<Capability> {
        let mut out = Vec::new();
        if self.categories {
            out.push(Capability::Categories);
        }
        if self.catalog {
            out.push(Capability::Catalog);
        }
        if self.detail {
            out.push(Capability::Detail);
        }
        if self.search {
            out.push(Capability::Search);
        }
        if self.resolve {
            out.push(Capability::Resolve);
        }
        if self.ranking_boards || self.ranking {
            out.push(Capability::Rankings);
        }
        if self.recommend {
            out.push(Capability::Recommend);
        }
        if self.suggestions {
            out.push(Capability::Suggestions);
        }
        if self.danmaku {
            out.push(Capability::Danmaku);
        }
        if self.seasons {
            out.push(Capability::Series);
        }
        out
    }
}

/// 脚本型站源。
#[derive(Debug)]
pub struct ScriptSource {
    meta: SourceMeta,
    source: String,
    exports: Exports,
    limits: ScriptLimits,
    /// 清单声明的域名白名单；`ctx.fetch` 只放行这些主机。
    network: Vec<String>,
}

impl ScriptSource {
    /// 加载脚本并读取它的 `describe()`。
    ///
    /// `env` 只用于 `describe` 阶段；描述符不该发请求，
    /// 因此调用方通常传一个不带传输能力的占位环境。
    pub fn load(
        env: &SourceEnv,
        source: impl Into<String>,
        limits: ScriptLimits,
        network: Vec<String>,
    ) -> Result<Self, SourceError> {
        let source = source.into();
        let host = JsPluginHost::new();

        let described: Descriptor = host
            .invoke_sync(env, &source, "describe", "{}", limits, &network)
            .and_then(|text| decode(&text, "describe"))?;
        let exports: Exports = host
            .invoke_sync(env, &source, "__probe_export_map", "{}", limits, &network)
            .and_then(|text| decode(&text, "__probe_export_map"))?;

        if described.id.trim().is_empty() {
            return Err(SourceError::parse("describe", "脚本必须返回 id"));
        }
        if described.api_level > CURRENT_API_LEVEL {
            return Err(SourceError::parse(
                "describe",
                format!(
                    "脚本要求 API level {}，宿主只支持到 {CURRENT_API_LEVEL}",
                    described.api_level
                ),
            ));
        }
        let meta = SourceMeta {
            id: described.id,
            name: described.name,
            group: described.group,
            api_level: described.api_level,
            capabilities: exports.capabilities(),
            content_types: described.content_types,
        };
        Ok(Self {
            meta,
            source,
            exports,
            limits,
            network,
        })
    }

    /// 缺省实现：脚本没导出就报 `Unsupported`，UI 按能力位隐藏入口。
    fn require(&self, present: bool, what: &'static str) -> Result<(), SourceError> {
        if present {
            Ok(())
        } else {
            Err(SourceError::Unsupported(what))
        }
    }

    async fn call<T: serde::de::DeserializeOwned>(
        &self,
        env: &SourceEnv,
        entry: &str,
        input: serde_json::Value,
        what: &'static str,
    ) -> Result<T, SourceError> {
        let text = JsPluginHost::new()
            .invoke(
                env,
                &self.source,
                entry,
                &input.to_string(),
                self.limits,
                &self.network,
            )
            .await?;
        let mut value: T = decode(&text, what)?;
        let _ = &mut value;
        Ok(value)
    }
}

/// `describe()` 的返回结构。未知字段忽略，脚本可以多带信息。
#[derive(Debug, Clone, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct Descriptor {
    #[serde(default)]
    id: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    group: String,
    #[serde(default)]
    api_level: u32,
    /// 内容类型；脚本没写时按未标注处理。
    #[serde(default)]
    content_types: Vec<ContentType>,
}

impl<'de> serde::Deserialize<'de> for Exports {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(serde::Deserialize, Default)]
        #[serde(rename_all = "camelCase")]
        struct Raw {
            #[serde(default)]
            categories: bool,
            #[serde(default)]
            catalog: bool,
            #[serde(default)]
            detail: bool,
            #[serde(default)]
            search: bool,
            #[serde(default)]
            resolve: bool,
            #[serde(default)]
            ranking_boards: bool,
            #[serde(default)]
            ranking: bool,
            #[serde(default)]
            recommend: bool,
            #[serde(default)]
            suggestions: bool,
            #[serde(default)]
            danmaku: bool,
            #[serde(default)]
            seasons: bool,
        }
        let raw = Raw::deserialize(deserializer)?;
        Ok(Self {
            categories: raw.categories,
            catalog: raw.catalog,
            detail: raw.detail,
            search: raw.search,
            resolve: raw.resolve,
            ranking_boards: raw.ranking_boards,
            ranking: raw.ranking,
            recommend: raw.recommend,
            suggestions: raw.suggestions,
            danmaku: raw.danmaku,
            seasons: raw.seasons,
        })
    }
}

fn decode<T: serde::de::DeserializeOwned>(
    text: &str,
    what: &'static str,
) -> Result<T, SourceError> {
    serde_json::from_str(text)
        .map_err(|err| SourceError::parse(what, format!("脚本返回结构无法解析：{err}")))
}

/// 脚本返回的条目结构：字段全可选。
///
/// 作者不该被迫知道宿主的 id 规则（`maoguo:21277`），所以这里宽松接收，
/// 由宿主补齐归属字段。
#[derive(Debug, Clone, Default, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawDrama {
    #[serde(default)]
    id: String,
    #[serde(default)]
    source_id: String,
    #[serde(default)]
    title: String,
    #[serde(default)]
    cover: String,
    #[serde(default)]
    description: String,
    #[serde(default)]
    category: String,
    #[serde(default)]
    episodes: u32,
    #[serde(default)]
    tags: Vec<String>,
    #[serde(default)]
    heat: String,
    #[serde(default)]
    views: String,
    #[serde(default)]
    online_date: String,
    #[serde(default)]
    release_status: String,
}

impl RawDrama {
    fn into_drama(self, source: &str) -> Drama {
        let source_id = if self.source_id.is_empty() {
            self.id.clone()
        } else {
            self.source_id
        };
        Drama {
            id: Drama::identity(source, &source_id),
            source: source.to_string(),
            source_id,
            title: self.title,
            cover: self.cover,
            description: self.description,
            category: self.category,
            episodes: self.episodes,
            tags: self.tags,
            heat: self.heat,
            views: self.views,
            online_date: self.online_date,
            release_status: self.release_status,
            vip: None,
        }
    }
}

#[derive(Debug, Clone, Default, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawChapter {
    #[serde(default)]
    id: String,
    #[serde(default)]
    title: String,
    #[serde(default)]
    video_url: String,
    #[serde(default)]
    referer: String,
    #[serde(default)]
    page_url: String,
    #[serde(default)]
    vip: bool,
}

#[derive(Debug, Clone, Default, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawPage {
    #[serde(default)]
    items: Vec<RawDrama>,
    #[serde(default)]
    has_more: bool,
    #[serde(default)]
    page: u32,
    #[serde(default)]
    warning: String,
}

#[derive(Debug, Clone, Default, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawDetail {
    #[serde(default)]
    drama: RawDrama,
    #[serde(default)]
    chapters: Vec<RawChapter>,
}

/// 把脚本返回的一页转成领域模型，并补上宿主侧的归属字段。
fn into_page(raw: RawPage, source: &str) -> Page {
    Page {
        items: raw
            .items
            .into_iter()
            .map(|item| item.into_drama(source))
            .collect(),
        has_more: raw.has_more,
        page: raw.page,
        warning: raw.warning,
    }
}

fn into_detail(raw: RawDetail, source: &str, fallback_id: &str) -> Detail {
    let mut drama = raw.drama.into_drama(source);
    if drama.source_id.is_empty() {
        drama.source_id = fallback_id.to_string();
        drama.id = Drama::identity(source, fallback_id);
    }
    let chapters = raw
        .chapters
        .into_iter()
        .enumerate()
        .map(|(index, chapter)| {
            let id = if chapter.id.is_empty() {
                format!("{}:{}", drama.source_id, index + 1)
            } else {
                chapter.id
            };
            Chapter {
                id,
                title: chapter.title,
                source: source.to_string(),
                video_url: chapter.video_url,
                page_url: chapter.page_url,
                referer: chapter.referer,
                vip: chapter.vip,
            }
        })
        .collect();
    Detail { drama, chapters }
}

#[async_trait]
impl SourcePlugin for ScriptSource {
    fn meta(&self) -> SourceMeta {
        self.meta.clone()
    }

    async fn categories(&self, env: &SourceEnv) -> Result<Vec<Category>, SourceError> {
        if !self.exports.categories {
            return Ok(Vec::new());
        }
        self.call(env, "categories", serde_json::json!({}), "categories")
            .await
    }

    async fn catalog(
        &self,
        env: &SourceEnv,
        page: u32,
        category: &str,
    ) -> Result<Page, SourceError> {
        self.require(self.exports.catalog, "目录")?;
        let raw: RawPage = self
            .call(
                env,
                "catalog",
                serde_json::json!({ "page": page, "category": category }),
                "catalog",
            )
            .await?;
        Ok(into_page(raw, &self.meta.id))
    }

    async fn detail(&self, env: &SourceEnv, source_id: &str) -> Result<Detail, SourceError> {
        self.require(self.exports.detail, "详情")?;
        let raw: RawDetail = self
            .call(
                env,
                "detail",
                serde_json::json!({ "id": source_id }),
                "detail",
            )
            .await?;
        Ok(into_detail(raw, &self.meta.id, source_id))
    }

    async fn search(&self, env: &SourceEnv, query: &str, page: u32) -> Result<Page, SourceError> {
        self.require(self.exports.search, "搜索")?;
        let raw: RawPage = self
            .call(
                env,
                "search",
                serde_json::json!({ "query": query, "page": page }),
                "search",
            )
            .await?;
        Ok(into_page(raw, &self.meta.id))
    }

    async fn resolve(
        &self,
        env: &SourceEnv,
        drama: &Drama,
        chapter: &Chapter,
    ) -> Result<Media, SourceError> {
        self.require(self.exports.resolve, "取流")?;
        self.call(
            env,
            "resolve",
            serde_json::json!({ "drama": drama, "chapter": chapter }),
            "resolve",
        )
        .await
    }

    async fn ranking_boards(&self, env: &SourceEnv) -> Result<Vec<RankingBoard>, SourceError> {
        if !self.exports.ranking_boards {
            return Ok(Vec::new());
        }
        self.call(env, "rankingBoards", serde_json::json!({}), "rankingBoards")
            .await
    }

    async fn ranking(
        &self,
        env: &SourceEnv,
        board: &str,
        page: u32,
    ) -> Result<RankingPage, SourceError> {
        self.require(self.exports.ranking, "榜单")?;
        self.call(
            env,
            "ranking",
            serde_json::json!({ "board": board, "page": page }),
            "ranking",
        )
        .await
    }

    async fn recommend(
        &self,
        env: &SourceEnv,
        cursor: &RecommendCursor,
    ) -> Result<RecommendPage, SourceError> {
        self.require(self.exports.recommend, "推荐")?;
        self.call(
            env,
            "recommend",
            serde_json::json!({ "cursor": cursor }),
            "recommend",
        )
        .await
    }

    async fn suggestions(
        &self,
        env: &SourceEnv,
        keyword: &str,
    ) -> Result<Vec<Suggestion>, SourceError> {
        self.require(self.exports.suggestions, "搜索联想")?;
        self.call(
            env,
            "suggestions",
            serde_json::json!({ "keyword": keyword }),
            "suggestions",
        )
        .await
    }

    async fn danmaku(
        &self,
        env: &SourceEnv,
        chapter: &Chapter,
        start_ms: i64,
    ) -> Result<DanmakuPage, SourceError> {
        self.require(self.exports.danmaku, "弹幕")?;
        self.call(
            env,
            "danmaku",
            serde_json::json!({ "chapter": chapter, "startMs": start_ms }),
            "danmaku",
        )
        .await
    }

    async fn seasons(
        &self,
        env: &SourceEnv,
        drama: &Drama,
    ) -> Result<Vec<SeriesSeason>, SourceError> {
        if !self.exports.seasons {
            return Ok(Vec::new());
        }
        self.call(
            env,
            "seasons",
            serde_json::json!({ "drama": drama }),
            "seasons",
        )
        .await
    }
}

/// 加载期的占位环境：描述符阶段不该发请求。
pub fn placeholder_env() -> SourceEnv {
    SourceEnv {
        source_id: "script".into(),
        transport: Arc::new(NoTransport),
        store: Arc::new(NoStore),
        scripts: None,
        log: Arc::new(NoLog),
    }
}

struct NoTransport;
#[async_trait]
impl guo_source_api::Transport for NoTransport {
    async fn fetch(
        &self,
        request: guo_source_api::FetchRequest,
    ) -> Result<guo_source_api::FetchResponse, SourceError> {
        Err(SourceError::network(
            request.url,
            "描述符阶段不应发起网络请求",
        ))
    }
}

struct NoStore;
#[async_trait]
impl guo_source_api::SourceStore for NoStore {
    async fn get(&self, _key: &str) -> Result<Option<String>, SourceError> {
        Ok(None)
    }
    async fn set(&self, _key: &str, _value: &str) -> Result<(), SourceError> {
        Ok(())
    }
}

struct NoLog;
impl guo_source_api::LogSink for NoLog {
    fn debug(&self, _message: &str) {}
    fn warn(&self, _message: &str) {}
}

#[cfg(test)]
mod tests {
    use super::*;

    const SCRIPT: &str = r#"
        function describe() {
            return { id: 'guo.script', name: '脚本源', group: 'duanju', apiLevel: 1 };
        }
        function catalog(input) {
            const res = ctx.fetch({ url: 'https://x.test/list?page=' + input.page });
            const data = JSON.parse(res.body);
            return {
                items: data.list.map(function (row) {
                    return { sourceId: row.id, title: row.title, cover: row.cover };
                }),
                hasMore: false,
                page: input.page,
            };
        }
    "#;

    /// 只有 describe 的脚本：其余能力应当报 Unsupported 而不是 panic。
    const MINIMAL: &str = r#"
        function describe() {
            return { id: 'guo.min', name: '最小脚本', group: 'test', apiLevel: 1 };
        }
    "#;

    #[test]
    fn loads_descriptor_and_probes_exports() {
        let env = placeholder_env();
        let source = ScriptSource::load(
            &env,
            SCRIPT,
            ScriptLimits::default(),
            vec!["x.test".to_string()],
        )
        .expect("load");
        assert_eq!(source.meta().id, "guo.script");
        assert!(source.meta().supports(Capability::Catalog));
        assert!(!source.meta().supports(Capability::Danmaku));
    }

    #[tokio::test]
    async fn missing_capability_reports_unsupported() {
        let env = placeholder_env();
        let source = Arc::new(
            ScriptSource::load(&env, MINIMAL, ScriptLimits::default(), Vec::new()).expect("load"),
        );
        let err = source.catalog(&env, 1, "").await.expect_err("must fail");
        assert!(matches!(err, SourceError::Unsupported(_)), "{err:?}");
        // 榜单是「可以没有」的能力，应返回空而不是报错。
        assert!(source
            .ranking_boards(&env)
            .await
            .expect("boards")
            .is_empty());
    }

    #[test]
    fn script_missing_id_is_rejected() {
        let env = placeholder_env();
        let err = ScriptSource::load(
            &env,
            "function describe(){ return { name: '无名' }; }",
            ScriptLimits::default(),
            Vec::new(),
        )
        .expect_err("must fail");
        assert!(err.to_string().contains("id"), "{err}");
    }
}
