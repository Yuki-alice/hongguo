//! WIT 绑定与宿主能力实现。
//!
//! 生成物来自 `wit/source-plugin.wit`；本文件只补上「宿主函数的行为」，
//! 不改生成的结构体，重新生成时不会冲突。

use guo_source_api::SourceError;

use crate::sandbox::{build_request, run_blocking, to_wit_error, HostState};

wasmtime::component::bindgen!({
    path: "wit/source-plugin.wit",
    world: "plugin",
});

use guo::source::host::Host;
pub use guo::source::types;
use types::{Descriptor, Error, Media, Page, Response};

impl guo::source::types::Host for HostState {}

impl Host for HostState {
    fn fetch(
        &mut self,
        method: String,
        url: String,
        headers: Vec<(String, String)>,
        body: Option<Vec<u8>>,
    ) -> Result<Response, Error> {
        let limits = self.capabilities.limits;
        if !self.capabilities.host_allowed(&url) {
            // 白名单外一律拒绝：这是插件唯一的出网口。
            return Err(Error::Unsupported(format!("域名不在白名单内：{url}")));
        }
        let mut request = build_request(&method, &url, headers, body);
        request.max_bytes = Some(limits.response_bytes);
        match run_blocking(self.capabilities.env.clone(), request) {
            Ok(response) => Ok(Response {
                status: response.status,
                url: response.final_url.clone(),
                body: response.body.clone(),
                content_type: response
                    .header("Content-Type")
                    .unwrap_or_default()
                    .to_string(),
                etag: response.validator(),
                // 全部头透传：插件需要 Set-Cookie 才能处理 CDN 签名源。
                headers: response
                    .headers
                    .iter()
                    .map(|(key, value)| (key.to_lowercase(), value.clone()))
                    .collect(),
            }),
            Err(err) => Err(to_wit_error(&err)),
        }
    }

    fn store_get(&mut self, namespace: String, key: String) -> Option<String> {
        if !self.capabilities.storage_allowed(&namespace) {
            return None;
        }
        let store = self.capabilities.env.store.clone();
        let full = format!("plugin/{namespace}/{key}");
        run_blocking_async(async move { store.get(&full).await })
            .ok()
            .flatten()
    }

    fn store_set(&mut self, namespace: String, key: String, value: String) -> Result<(), Error> {
        if !self.capabilities.storage_allowed(&namespace) {
            return Err(Error::Unsupported(format!(
                "存储命名空间未授权：{namespace}"
            )));
        }
        let store = self.capabilities.env.store.clone();
        let full = format!("plugin/{namespace}/{key}");
        run_blocking_async(async move { store.set(&full, &value).await })
            .map_err(|err| to_wit_error(&err))
    }

    fn log(&mut self, level: String, message: String) {
        let log = self.capabilities.env.log.clone();
        match level.as_str() {
            "warn" | "error" => log.warn(&message),
            _ => log.debug(&message),
        }
    }

    fn random(&mut self, len: u32) -> Vec<u8> {
        // 不引入 rand：xorshift 用时间做种子，足够插件生成 nonce。
        let mut seed = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|value| value.as_nanos() as u64)
            .unwrap_or(0x9e37_79b9_7f4a_7c15);
        let mut out = Vec::with_capacity(len as usize);
        for _ in 0..len {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            out.push((seed & 0xff) as u8);
        }
        out
    }

    fn now_ms(&mut self) -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|value| value.as_millis() as u64)
            .unwrap_or(0)
    }

    fn html_select(
        &mut self,
        _html: String,
        _selector: String,
        _attr: Option<String>,
    ) -> Vec<String> {
        // ADR-12 的提取原语已在 `guo-rule-engine` 实现；
        // 插件侧接上它需要把 scraper 拉进本 crate，P1 之后再按实际插件需求开。
        Vec::new()
    }

    fn json_path(&mut self, _json: String, _path: String) -> Vec<String> {
        Vec::new()
    }
}

fn run_blocking_async<F, T>(future: F) -> Result<T, SourceError>
where
    F: std::future::Future<Output = Result<T, SourceError>>,
{
    crate::sandbox::block_on(future)
}

/// 插件返回的 `Page` 转成契约层 `Page`，并给每个剧目补上源名。
pub fn page_from_wit_for(page: Page, source: &str) -> guo_source_api::Page {
    guo_source_api::Page {
        items: page
            .items
            .into_iter()
            .map(|item| drama_from_wit_for(item, source))
            .collect(),
        has_more: page.has_more,
        page: page.page,
        warning: String::new(),
    }
}

/// WIT → 宿主剧目，用给定源名填充 `source`。
///
/// WIT 的 `drama.source_id` 是**站点内 id**，不是源名；源名由调用方补上。
/// 插件只描述自己的站点知识，不该重复声明「我是哪个源」——那由清单决定。
///
/// `id` 缺失源前缀时补上，保证 `Drama::identity` 约定的
/// `<source>:<source_id>` 对所有源成立（UI 与旧数据都依赖这个格式）。
pub fn drama_from_wit_for(drama: types::Drama, source: &str) -> guo_source_api::Drama {
    let mut id = drama.id;
    let source_id = drama.source_id;
    if !source.is_empty() && !id.starts_with(&format!("{source}:")) {
        id = format!(
            "{source}:{}",
            if source_id.is_empty() {
                id.as_str()
            } else {
                source_id.as_str()
            }
        );
    }
    guo_source_api::Drama {
        id,
        source: source.to_string(),
        source_id,
        title: drama.title,
        description: drama.description,
        cover: drama.cover,
        episodes: drama.episodes,
        category: drama.category,
        tags: drama.tags,
        views: drama.views,
        heat: drama.heat,
        release_status: drama.release_status,
        ..Default::default()
    }
}

pub fn chapter_from_wit(chapter: types::Chapter) -> guo_source_api::Chapter {
    guo_source_api::Chapter {
        id: chapter.id,
        title: chapter.title,
        video_url: chapter.video_url,
        page_url: chapter.page_url,
        referer: chapter.referer,
        vip: chapter.vip,
        ..Default::default()
    }
}

pub fn category_from_wit(category: types::Category) -> guo_source_api::Category {
    guo_source_api::Category {
        id: category.id,
        name: category.name,
    }
}

pub fn media_from_wit(media: Media) -> guo_source_api::Media {
    guo_source_api::Media {
        url: media.url,
        referer: media.referer,
        playlist: if media.segments.is_empty() {
            None
        } else {
            Some(media.segments)
        },
        key_uri: media.key_uri,
        key_iv: media.key_iv,
        cookies: media.cookies,
        origin: media.origin,
    }
}

/// 插件在 `descriptor.capabilities` 里声明的能力位。
pub fn descriptor_capabilities(descriptor: &Descriptor) -> Vec<guo_source_api::Capability> {
    descriptor
        .capabilities
        .iter()
        .filter_map(|name| match name.as_str() {
            "catalog" => Some(guo_source_api::Capability::Catalog),
            "detail" => Some(guo_source_api::Capability::Detail),
            "search" => Some(guo_source_api::Capability::Search),
            "resolve" => Some(guo_source_api::Capability::Resolve),
            "categories" => Some(guo_source_api::Capability::Categories),
            _ => None,
        })
        .collect()
}

pub fn plugin_error(err: Error) -> SourceError {
    crate::sandbox::from_wit_error(err)
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use async_trait::async_trait;
    use guo_source_api::{FetchRequest, FetchResponse, LogSink, SourceEnv, SourceStore, Transport};

    use super::*;
    use crate::sandbox::Capabilities;

    /// 返回带 `set-cookie` 的响应，用来验证 v2 的响应头透传。
    struct CookieTransport {
        seen: Mutex<Vec<String>>,
    }

    #[async_trait]
    impl Transport for CookieTransport {
        async fn fetch(&self, request: FetchRequest) -> Result<FetchResponse, SourceError> {
            self.seen.lock().expect("lock").push(request.url.clone());
            let mut response = FetchResponse::new(200, b"ok".to_vec(), request.url);
            response.headers.insert(
                "set-cookie".to_string(),
                "sid=abc; Path=/; HttpOnly".to_string(),
            );
            Ok(response)
        }
    }

    struct NoStore;
    #[async_trait]
    impl SourceStore for NoStore {
        async fn get(&self, _: &str) -> Result<Option<String>, SourceError> {
            Ok(None)
        }
        async fn set(&self, _: &str, _: &str) -> Result<(), SourceError> {
            Ok(())
        }
    }

    struct NoLog;
    impl LogSink for NoLog {
        fn debug(&self, _: &str) {}
        fn warn(&self, _: &str) {}
    }

    fn state() -> HostState {
        HostState::new(
            Capabilities::new(SourceEnv {
                source_id: "test".into(),
                transport: Arc::new(CookieTransport {
                    seen: Mutex::new(Vec::new()),
                }),
                store: Arc::new(NoStore),
                scripts: None,
                log: Arc::new(NoLog),
            })
            .allow_network(["cdn.test"]),
        )
    }

    #[test]
    fn response_exposes_set_cookie_headers() {
        let mut host = state();
        let response = host
            .fetch("get".into(), "https://cdn.test/a".into(), Vec::new(), None)
            .expect("请求应成功");
        // 快捷字段仍在，保持向后兼容。
        assert_eq!(response.status, 200);
        // v2：全部头都在 `headers` 里，键名统一小写。
        let cookie = response
            .headers
            .iter()
            .find(|(key, _)| key == "set-cookie")
            .map(|(_, value)| value.clone())
            .unwrap_or_default();
        assert!(
            cookie.contains("sid=abc"),
            "实际响应头：{:?}",
            response.headers
        );
        assert!(response
            .headers
            .iter()
            .all(|(key, _)| key == &key.to_lowercase()));
    }

    #[test]
    fn whitelist_rejection_happens_before_the_request() {
        let mut host = state();
        let error = host
            .fetch("get".into(), "https://evil.test/a".into(), Vec::new(), None)
            .expect_err("白名单外必须拒绝");
        assert!(matches!(error, Error::Unsupported(_)), "{error:?}");
    }

    #[test]
    fn media_conversion_keeps_cookies_and_origin() {
        let media = Media {
            url: "https://cdn.test/v.m3u8".into(),
            referer: "https://cdn.test/".into(),
            segments: vec!["https://cdn.test/1.ts".into()],
            key_uri: "https://cdn.test/k".into(),
            key_iv: "00ff".into(),
            cookies: "sid=abc".into(),
            origin: "https://cdn.test".into(),
        };
        let converted = media_from_wit(media);
        assert_eq!(converted.cookies, "sid=abc");
        assert_eq!(converted.origin, "https://cdn.test");
        assert_eq!(
            converted.playlist.as_deref(),
            Some(["https://cdn.test/1.ts".to_string()].as_slice())
        );
    }
}
