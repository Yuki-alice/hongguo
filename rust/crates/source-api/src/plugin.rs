//! 站源插件契约：能力位、元信息、`SourcePlugin` trait 与注册表。
//!
//! 规则源与代码插件实现同一个 trait，宿主只认这个接口（ARCHITECTURE.md §6.3）。

use std::sync::Arc;

use async_trait::async_trait;

use crate::env::SourceEnv;
use crate::error::SourceError;
use crate::model::{
    Category, Chapter, DanmakuPage, Detail, Drama, Media, Page, RankingBoard, RankingPage,
    RecommendCursor, RecommendPage, SeriesSeason, Suggestion,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Capability {
    Catalog,
    Detail,
    Search,
    Resolve,
    Categories,
    /// 榜单。
    Rankings,
    /// 推荐流。
    Recommend,
    /// 搜索联想。
    Suggestions,
    /// 弹幕。
    Danmaku,
    /// 系列剧（同一部剧的多季）。
    Series,
}

/// 内容类型：只做粗分类（商店筛选、发现页聚合），**不改变数据模型**。
///
/// 电影 = `episodes` 为 1 的 `Drama`，剧集/动漫 = 多 `Chapter`，
/// 类型特有的元信息先由 `tags` 承载（EXTENSION-ECOSYSTEM.md §1.3）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum ContentType {
    /// 短剧。
    ShortDrama,
    /// 电影。
    Movie,
    /// 电视剧 / 网剧。
    Tv,
    /// 动漫。
    Anime,
    /// 综艺。
    Variety,
    /// 纪录片。
    Documentary,
}

impl ContentType {
    /// 全部类型，顺序即商店筛选片的展示顺序。
    pub const ALL: [Self; 6] = [
        Self::ShortDrama,
        Self::Movie,
        Self::Tv,
        Self::Anime,
        Self::Variety,
        Self::Documentary,
    ];

    /// 规范写法（也是规则 JSON / 索引 JSON 里的取值）。
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::ShortDrama => "short-drama",
            Self::Movie => "movie",
            Self::Tv => "tv",
            Self::Anime => "anime",
            Self::Variety => "variety",
            Self::Documentary => "documentary",
        }
    }

    /// 解析。宽容三种常见写法：`short-drama` / `short_drama` / `shortdrama`，
    /// 作者写错分隔符不应该让整包加载失败。
    pub fn parse(text: &str) -> Option<Self> {
        let normalized: String = text
            .chars()
            .filter(|c| *c != '-' && *c != '_' && !c.is_whitespace())
            .flat_map(char::to_lowercase)
            .collect();
        Self::ALL
            .into_iter()
            .find(|kind| kind.as_str().replace('-', "") == normalized)
    }
}

impl std::fmt::Display for ContentType {
    fn fmt(&self, out: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        out.write_str(self.as_str())
    }
}

impl serde::Serialize for ContentType {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.as_str())
    }
}

impl<'de> serde::Deserialize<'de> for ContentType {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let raw = <String as serde::Deserialize>::deserialize(deserializer)?;
        Self::parse(&raw).ok_or_else(|| {
            serde::de::Error::custom(format!(
                "未知内容类型 {raw}（可用：short-drama / movie / tv / anime / variety / documentary）"
            ))
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SourceMeta {
    pub id: String,
    pub name: String,
    pub group: String,
    pub api_level: u32,
    pub capabilities: Vec<Capability>,
    /// 内容类型标注；空表示未标注（不参与类型筛选，但照常可用）。
    pub content_types: Vec<ContentType>,
}

impl SourceMeta {
    pub fn supports(&self, capability: Capability) -> bool {
        self.capabilities.contains(&capability)
    }

    /// 是否覆盖某内容类型。未标注时返回 `false`。
    pub fn covers(&self, content_type: ContentType) -> bool {
        self.content_types.contains(&content_type)
    }
}

#[async_trait]
pub trait SourcePlugin: Send + Sync {
    fn meta(&self) -> SourceMeta;

    async fn categories(&self, _env: &SourceEnv) -> Result<Vec<Category>, SourceError> {
        Ok(Vec::new())
    }

    async fn catalog(
        &self,
        _env: &SourceEnv,
        _page: u32,
        _category: &str,
    ) -> Result<Page, SourceError> {
        Err(SourceError::Unsupported("目录"))
    }

    async fn detail(&self, _env: &SourceEnv, _source_id: &str) -> Result<Detail, SourceError> {
        Err(SourceError::Unsupported("详情"))
    }

    async fn search(
        &self,
        _env: &SourceEnv,
        _query: &str,
        _page: u32,
    ) -> Result<Page, SourceError> {
        Err(SourceError::Unsupported("搜索"))
    }

    async fn resolve(
        &self,
        _env: &SourceEnv,
        _drama: &Drama,
        _chapter: &Chapter,
    ) -> Result<Media, SourceError> {
        Err(SourceError::Unsupported("取流"))
    }

    /// 站点提供的榜单看板。返回空表示该源没有榜单。
    async fn ranking_boards(&self, _env: &SourceEnv) -> Result<Vec<RankingBoard>, SourceError> {
        Ok(Vec::new())
    }

    /// 某一榜单的一页。
    async fn ranking(
        &self,
        _env: &SourceEnv,
        _board: &str,
        _page: u32,
    ) -> Result<RankingPage, SourceError> {
        Err(SourceError::Unsupported("榜单"))
    }

    /// 推荐流的一页。游标由调用方持有并原样回传。
    async fn recommend(
        &self,
        _env: &SourceEnv,
        _cursor: &RecommendCursor,
    ) -> Result<RecommendPage, SourceError> {
        Err(SourceError::Unsupported("推荐"))
    }

    /// 搜索联想词。
    async fn suggestions(
        &self,
        _env: &SourceEnv,
        _keyword: &str,
    ) -> Result<Vec<Suggestion>, SourceError> {
        Err(SourceError::Unsupported("搜索联想"))
    }

    /// 一集的分段弹幕。`start_ms` 是分段起点。
    async fn danmaku(
        &self,
        _env: &SourceEnv,
        _chapter: &Chapter,
        _start_ms: i64,
    ) -> Result<DanmakuPage, SourceError> {
        Err(SourceError::Unsupported("弹幕"))
    }

    /// 找出同一部剧的其它季。返回空表示无系列信息。
    async fn seasons(
        &self,
        _env: &SourceEnv,
        _drama: &Drama,
    ) -> Result<Vec<SeriesSeason>, SourceError> {
        Ok(Vec::new())
    }
}

#[derive(Default)]
pub struct SourceRegistry {
    plugins: Vec<Arc<dyn SourcePlugin>>,
}

impl SourceRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn register(&mut self, plugin: Arc<dyn SourcePlugin>) -> &mut Self {
        self.plugins.push(plugin);
        self
    }

    pub fn len(&self) -> usize {
        self.plugins.len()
    }

    pub fn is_empty(&self) -> bool {
        self.plugins.is_empty()
    }

    pub fn get(&self, id: &str) -> Option<Arc<dyn SourcePlugin>> {
        self.plugins
            .iter()
            .find(|plugin| plugin.meta().id == id)
            .cloned()
    }

    pub fn metas(&self) -> Vec<SourceMeta> {
        self.plugins.iter().map(|plugin| plugin.meta()).collect()
    }
}

pub const CURRENT_API_LEVEL: u32 = 1;

#[cfg(test)]
mod tests {
    use super::*;

    struct Stub {
        meta: SourceMeta,
    }

    #[async_trait]
    impl SourcePlugin for Stub {
        fn meta(&self) -> SourceMeta {
            self.meta.clone()
        }
    }

    fn stub(id: &str) -> Arc<dyn SourcePlugin> {
        Arc::new(Stub {
            meta: SourceMeta {
                id: id.into(),
                name: id.into(),
                group: "test".into(),
                api_level: CURRENT_API_LEVEL,
                capabilities: vec![Capability::Catalog],
                content_types: vec![ContentType::ShortDrama],
            },
        })
    }

    #[test]
    fn registry_resolves_registered_sources() {
        let mut registry = SourceRegistry::new();
        registry.register(stub("wuguo")).register(stub("maoguo"));
        assert_eq!(registry.len(), 2);
        assert!(registry.get("wuguo").is_some());
        assert!(registry.get("unknown").is_none());
    }

    #[test]
    fn unimplemented_capabilities_return_unsupported() {
        let plugin = stub("wuguo");
        assert!(plugin.meta().supports(Capability::Catalog));
        assert!(!plugin.meta().supports(Capability::Search));
    }

    #[test]
    fn content_type_parsing_is_forgiving() {
        for text in ["short-drama", "short_drama", "ShortDrama", "shortdrama"] {
            assert_eq!(
                ContentType::parse(text),
                Some(ContentType::ShortDrama),
                "{text}"
            );
        }
        assert_eq!(ContentType::parse("tv"), Some(ContentType::Tv));
        assert_eq!(ContentType::parse("动漫"), None);
        assert_eq!(ContentType::ShortDrama.to_string(), "short-drama");
    }

    #[test]
    fn content_type_round_trips_through_json() {
        let text =
            serde_json::to_string(&vec![ContentType::Movie, ContentType::Anime]).expect("ser");
        assert_eq!(text, r#"["movie","anime"]"#);
        let back: Vec<ContentType> = serde_json::from_str(&text).expect("de");
        assert_eq!(back, vec![ContentType::Movie, ContentType::Anime]);
        // 未知类型必须报错而不是静默丢弃：商店分类依赖这个值。
        let err = serde_json::from_str::<Vec<ContentType>>(r#"["短剧"]"#).expect_err("must fail");
        assert!(err.to_string().contains("未知内容类型"), "{err}");
    }

    #[test]
    fn covers_reports_membership_only() {
        let meta = stub("wuguo").meta();
        assert!(meta.covers(ContentType::ShortDrama));
        assert!(!meta.covers(ContentType::Movie));
    }
}
