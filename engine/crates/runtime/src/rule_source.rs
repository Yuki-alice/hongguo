use async_trait::async_trait;

use guo_media::{extract_media_url, parse_playlist};
use guo_rule_engine::{RequestRule, RuleDocument, RuleExecutor, TemplateCtx};
use guo_source_api::{
    Capability, Category, Chapter, Detail, Drama, FetchRequest, Media, Page, SourceEnv,
    SourceError, SourceMeta, SourcePlugin, CURRENT_API_LEVEL,
};

/// 把声明式规则包装成 `SourcePlugin`，让规则源与代码插件走同一条调度路径。
pub struct RuleSource {
    rule: RuleDocument,
    meta: SourceMeta,
}

impl RuleSource {
    pub fn new(rule: RuleDocument) -> Self {
        let mut capabilities = Vec::new();
        if rule.catalog.is_some() {
            capabilities.push(Capability::Catalog);
        }
        if rule.detail.is_some() {
            capabilities.push(Capability::Detail);
        }
        if rule.search.is_some() {
            capabilities.push(Capability::Search);
        }
        if rule.resolve.is_some() {
            capabilities.push(Capability::Resolve);
        }
        if !rule.categories.is_empty() {
            capabilities.push(Capability::Categories);
        }
        let meta = SourceMeta {
            id: rule.id.clone(),
            name: rule.name.clone(),
            group: rule.group.clone(),
            api_level: CURRENT_API_LEVEL,
            capabilities,
        };
        Self { rule, meta }
    }

    pub fn from_json(text: &str) -> Result<Self, SourceError> {
        Ok(Self::new(RuleDocument::from_json(text)?))
    }

    pub fn rule(&self) -> &RuleDocument {
        &self.rule
    }

    fn join(&self, path: &str) -> String {
        if path.starts_with("http") {
            return path.to_string();
        }
        format!(
            "{}/{}",
            self.rule.base.trim_end_matches('/'),
            path.trim_start_matches('/')
        )
    }

    fn build(&self, spec: &RequestRule, url: String, ctx: &TemplateCtx<'_>) -> FetchRequest {
        self.rule.build_request(spec, url, ctx)
    }

    fn absolute_address(&self, address: &str) -> String {
        if address.starts_with("http") {
            return address.to_string();
        }
        self.join(address)
    }
}

#[async_trait]
impl SourcePlugin for RuleSource {
    fn meta(&self) -> SourceMeta {
        self.meta.clone()
    }

    async fn categories(&self, _env: &SourceEnv) -> Result<Vec<Category>, SourceError> {
        Ok(self
            .rule
            .categories
            .iter()
            .map(|entry| Category {
                id: entry.id.clone(),
                name: entry.name.clone(),
            })
            .collect())
    }

    async fn catalog(
        &self,
        env: &SourceEnv,
        page: u32,
        category: &str,
    ) -> Result<Page, SourceError> {
        let catalog = self
            .rule
            .catalog
            .as_ref()
            .ok_or(SourceError::Unsupported("目录"))?;
        let category = catalog.category_for(category);
        let ctx = TemplateCtx {
            page,
            category,
            keyword: "",
            id: "",
        };
        let template = catalog
            .url_candidates(&self.rule, &ctx)
            .ok_or_else(|| self.rule_error("catalog 缺少可用地址"))?;
        let url = self.join(&template);
        let body = env.text(self.build(&catalog.request, url, &ctx)).await?;
        RuleExecutor::new(&self.rule).parse_catalog(&body, page)
    }

    async fn detail(&self, env: &SourceEnv, source_id: &str) -> Result<Detail, SourceError> {
        // 详情页地址优先用规则模板；没有模板时退回站源常见的候选路径。
        let ctx = TemplateCtx {
            page: 1,
            category: "",
            keyword: "",
            id: source_id,
        };
        let spec = self
            .rule
            .detail
            .as_ref()
            .ok_or(SourceError::Unsupported("详情"))?;
        let candidates = match spec.url_candidates(&self.rule, &ctx) {
            Some(template) => vec![self.join(&template)],
            None => detail_candidates(&self.rule.base, source_id),
        };
        let mut last = SourceError::NoResult;
        for url in candidates {
            let request = self.build(&spec.request, url, &ctx);
            match env.text(request).await {
                Ok(body) => {
                    let mut drama = Drama {
                        id: Drama::identity(&self.rule.id, source_id),
                        source: self.rule.id.clone(),
                        source_id: source_id.to_string(),
                        ..Default::default()
                    };
                    let executor = RuleExecutor::new(&self.rule);
                    executor.fill_drama(&body, &mut drama);
                    match executor.parse_chapters(&body, &drama) {
                        Ok(chapters) => {
                            if drama.episodes == 0 {
                                drama.episodes = chapters.len() as u32;
                            }
                            return Ok(Detail { drama, chapters });
                        }
                        Err(err) => last = err,
                    }
                }
                Err(err) => last = err,
            }
        }
        Err(last)
    }

    async fn search(&self, env: &SourceEnv, query: &str, page: u32) -> Result<Page, SourceError> {
        let search = self
            .rule
            .search
            .as_ref()
            .ok_or(SourceError::Unsupported("搜索"))?;
        let ctx = TemplateCtx {
            page,
            category: "",
            keyword: query,
            id: "",
        };
        let template = search
            .url_candidates(&self.rule, &ctx)
            .ok_or_else(|| self.rule_error("search 缺少可用地址"))?;
        let url = self.join(&template);
        let body = env.text(self.build(&search.request, url, &ctx)).await?;
        RuleExecutor::new(&self.rule).parse_search(&body, page)
    }

    async fn resolve(
        &self,
        env: &SourceEnv,
        drama: &Drama,
        chapter: &Chapter,
    ) -> Result<Media, SourceError> {
        // 取流不强制要求 resolve 段：HTML 规则靠页面扫描也能拿到地址。
        let fallback = RequestRule::default();
        let resolve = self.rule.resolve.as_ref();
        let referer = if chapter.referer.is_empty() {
            format!("{}/", self.rule.base)
        } else {
            chapter.referer.clone()
        };

        // 直链可直接返回，但 HLS 仍需取播放列表以判断有效性与时长。
        if looks_like_media(&chapter.video_url) {
            return self
                .finish_media(env, chapter.video_url.clone(), referer)
                .await;
        }

        // 否则按播放页处理：抓页面后先按规则路径取，再退回页面文本扫描。
        let page = if chapter.page_url.is_empty() {
            chapter.video_url.clone()
        } else {
            chapter.page_url.clone()
        };
        if page.is_empty() {
            return Err(SourceError::parse("resolve", "分集缺少地址"));
        }
        let ctx = TemplateCtx {
            page: 1,
            category: "",
            keyword: "",
            id: &drama.source_id,
        };
        let request = self.build(
            resolve.map(|spec| &spec.request).unwrap_or(&fallback),
            page.clone(),
            &ctx,
        );
        let body = env.text(request).await?;
        let address = RuleExecutor::new(&self.rule)
            .media_url(&body)
            .or_else(|| extract_media_url(&body, &page))
            .ok_or_else(|| SourceError::parse("resolve", "播放页未找到媒体地址"))?;
        self.finish_media(env, self.absolute_address(&address), page)
            .await
    }
}

impl RuleSource {
    /// 若目标是 HLS，拉取播放列表并校验；否则直接返回。
    async fn finish_media(
        &self,
        env: &SourceEnv,
        address: String,
        referer: String,
    ) -> Result<Media, SourceError> {
        // 地址可能不带 `.m3u8` 后缀却返回 HLS（猫果的 CDN 即如此），
        // 因此必须先探测内容。直链 MP4 不能整段读入内存：只取前缀判断，
        // 确认是播放列表后再拉完整内容。
        let likely_hls = address.to_lowercase().contains(".m3u8");
        let probe = FetchRequest::get(&address)
            .header("Referer", &referer)
            .limit_bytes(PLAYLIST_PROBE_BYTES);
        let head = env.text(probe).await?;
        if !head.trim_start().starts_with("#EXTM3U") {
            if likely_hls {
                return Err(SourceError::parse(
                    "resolve",
                    "站点未返回有效 M3U8，可能需要登录或链接已失效",
                ));
            }
            // 不是 HLS，说明是直链媒体，原样返回。
            return Ok(Media {
                url: address,
                referer,
                playlist: None,
                key_uri: String::new(),
                key_iv: String::new(),
            });
        }
        // 已确认是播放列表：再拉完整内容（主列表与分片清单都在这一步拿到）。
        let body = env
            .text(FetchRequest::get(&address).header("Referer", &referer))
            .await?;
        let playlist = parse_playlist(&body, &address);
        // 主列表需要再取一层变体。
        if playlist.segments.is_empty() {
            if let Some(variant) = playlist.variants.first() {
                return Box::pin(self.finish_media(env, variant.clone(), referer)).await;
            }
        }
        Ok(Media {
            url: address,
            referer,
            playlist: Some(playlist.segments),
            key_uri: playlist.key_uri.clone().unwrap_or_default(),
            key_iv: playlist.key_iv.clone().unwrap_or_default(),
        })
    }

    fn rule_error(&self, detail: &str) -> SourceError {
        SourceError::Rule {
            rule_id: self.rule.id.clone(),
            detail: detail.to_string(),
        }
    }
}

/// 判断是否为 HLS 只需读取开头；`#EXTM3U` 与首个标签都在这段范围内。
const PLAYLIST_PROBE_BYTES: u64 = 1024;

fn looks_like_media(address: &str) -> bool {
    let lower = address.to_lowercase();
    lower.contains(".m3u8") || lower.contains(".mp4") || lower.contains(".flv")
}

/// 常见网页站源的详情地址候选，按命中概率排序。
fn detail_candidates(base: &str, source_id: &str) -> Vec<String> {
    let base = base.trim_end_matches('/');
    vec![
        format!("{base}/index.php/vod/detail/id/{source_id}.html"),
        format!("{base}/detail/{source_id}.html"),
        format!("{base}/show/{source_id}.html"),
        format!("{base}/vod/{source_id}.html"),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    const RULE: &str = r#"{
        "schema": "1.0",
        "id": "wuguo",
        "name": "伍果",
        "base": "https://www.duanju55.com",
        "catalog": { "url": "index.php/vod/type/id/{category}.html", "item": "a.x" },
        "detail": { "episodes": "a" },
        "search": { "url": "search/{keyword}.html", "item": "a.x" }
    }"#;

    #[test]
    fn capabilities_follow_rule_sections() {
        let source = RuleSource::from_json(RULE).expect("source");
        let meta = source.meta();
        assert!(meta.supports(Capability::Catalog));
        assert!(meta.supports(Capability::Detail));
        assert!(meta.supports(Capability::Search));
        assert!(!meta.supports(Capability::Resolve));
        assert!(!meta.supports(Capability::Categories));
    }

    #[test]
    fn static_categories_declare_their_own_capability() {
        let rule = RULE.replace(
            "\"detail\": { \"episodes\": \"a\" },",
            "\"detail\": { \"episodes\": \"a\" }, \"categories\": [ { \"id\": \"7\", \"name\": \"都市\" } ],",
        );
        let source = RuleSource::from_json(&rule).expect("source");
        assert!(source.meta().supports(Capability::Categories));
    }

    #[test]
    fn urls_are_absolute() {
        let source = RuleSource::from_json(RULE).expect("source");
        let ctx = TemplateCtx {
            page: 2,
            category: "7",
            keyword: "",
            id: "",
        };
        let catalog = source.rule().catalog.as_ref().expect("catalog");
        let template = catalog
            .url_candidates(source.rule(), &ctx)
            .expect("catalog url");
        assert_eq!(
            source.join(&template),
            "https://www.duanju55.com/index.php/vod/type/id/7.html"
        );
    }

    #[test]
    fn html_requests_carry_referer_only() {
        let source = RuleSource::from_json(RULE).expect("source");
        let catalog = source.rule().catalog.as_ref().expect("catalog");
        let ctx = TemplateCtx {
            page: 1,
            category: "",
            keyword: "",
            id: "",
        };
        let request = source.build(&catalog.request, "https://www.duanju55.com/x".into(), &ctx);
        assert_eq!(
            request.headers.get("Referer").map(String::as_str),
            Some("https://www.duanju55.com/")
        );
        assert!(request.body.is_none());
    }

    #[test]
    fn detail_candidates_cover_common_layouts() {
        let candidates = detail_candidates("https://a.test/", "42");
        assert_eq!(candidates.len(), 4);
        assert!(candidates[0].contains("/index.php/vod/detail/id/42.html"));
        assert!(candidates.iter().all(|url| !url.contains("//detail")));
    }
}
