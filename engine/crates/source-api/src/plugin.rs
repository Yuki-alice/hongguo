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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SourceMeta {
    pub id: String,
    pub name: String,
    pub group: String,
    pub api_level: u32,
    pub capabilities: Vec<Capability>,
}

impl SourceMeta {
    pub fn supports(&self, capability: Capability) -> bool {
        self.capabilities.contains(&capability)
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
}
