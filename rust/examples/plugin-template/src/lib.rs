//! 代码插件模板。
//!
//! 编译：
//! ```bash
//! cargo build --target wasm32-wasip2 --release
//! # 产物：target/wasm32-wasip2/release/guo_plugin_template.wasm
//! ```

wit_bindgen::generate!({
    path: "../../crates/plugin-wasm/wit/source-plugin.wit",
    world: "plugin",
});

use exports::guo::source::source::Guest;
use guo::source::types::{
    Category, Chapter, Descriptor, Detail, Drama, Error, Media, Page, Query, ResolveRequest,
};

struct Template;

impl Guest for Template {
    fn describe() -> Descriptor {
        Descriptor {
            id: "guo.template".into(),
            name: "模板站源".into(),
            group: "duanju".into(),
            api_level: 1,
            capabilities: vec!["catalog".into(), "detail".into(), "resolve".into()],
        }
    }

    fn categories() -> Result<Vec<Category>, Error> {
        Ok(vec![Category {
            id: "demo".into(),
            name: "示例".into(),
        }])
    }

    fn catalog(query: Query) -> Result<Page, Error> {
        // 真实插件在这里调用 host.fetch 取数，再用 host.html-select 提取。
        let drama = Drama {
            id: format!("demo-{}", query.page),
            source_id: format!("demo-{}", query.page),
            title: format!("第 {} 页示例", query.page),
            description: String::new(),
            cover: String::new(),
            episodes: 3,
            category: query.category.clone(),
            tags: vec!["示例".into()],
            views: "0".into(),
            heat: "0".into(),
            release_status: "已完结".into(),
        };
        Ok(Page {
            items: vec![drama],
            has_more: query.page < 3,
            page: query.page,
            cursor: String::new(),
        })
    }

    fn fetch_detail(source_id: String) -> Result<Detail, Error> {
        let drama = Drama {
            id: source_id.clone(),
            source_id: source_id.clone(),
            title: "示例".into(),
            description: String::new(),
            cover: String::new(),
            episodes: 1,
            category: String::new(),
            tags: Vec::new(),
            views: String::new(),
            heat: String::new(),
            release_status: String::new(),
        };
        let chapter = Chapter {
            id: "1".into(),
            title: "第 1 集".into(),
            video_url: "https://example.test/1.m3u8".into(),
            page_url: String::new(),
            referer: String::new(),
            vip: false,
        };
        Ok(Detail {
            drama,
            chapters: vec![chapter],
        })
    }

    fn search(query: Query) -> Result<Page, Error> {
        Self::catalog(query)
    }

    fn resolve(request: ResolveRequest) -> Result<Media, Error> {
        Ok(Media {
            url: request.chapter.video_url,
            referer: String::new(),
            segments: Vec::new(),
            key_uri: String::new(),
            key_iv: String::new(),
            // CDN 签名源才需要：从响应头 `set-cookie` 里取出并回填。
            // 模板固定返回一组值，让宿主侧的 ABI 穿透可以被断言。
            cookies: "k=v".to_string(),
            origin: "https://example.test".to_string(),
        })
    }

    fn suggestions(keyword: String) -> Result<Vec<String>, Error> {
        Ok(vec![keyword])
    }
}

export!(Template);
