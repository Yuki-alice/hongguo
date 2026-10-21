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

/// 插件返回的 `Page` 转成契约层 `Page`。
pub fn page_from_wit(page: Page) -> guo_source_api::Page {
    guo_source_api::Page {
        items: page.items.into_iter().map(drama_from_wit).collect(),
        has_more: page.has_more,
        page: page.page,
        warning: String::new(),
    }
}

pub fn drama_from_wit(drama: types::Drama) -> guo_source_api::Drama {
    guo_source_api::Drama {
        id: drama.id.clone(),
        source: drama.source_id.clone(),
        source_id: drama.id,
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
        cookies: String::new(),
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
