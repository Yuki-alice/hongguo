//! 发果站点的真实网络验证（默认忽略）。
//!
//! 离线夹具只能证明「规则匹配这份 HTML」，证明不了「站点仍然这样返回」。
//! 站点改版是站源最常见失效原因，因此保留一条需要手动开启的在线用例：
//!
//! ```sh
//! cargo test -p guo_engine --test faguo_live -- --ignored --nocapture
//! ```
//!
//! 只在规则或站点结构变更时跑；CI 依赖它会让构建在海外网络下随机失败。

use guo_engine::{
    Drama, FetchRequest, HttpTransport, RuleDocument, RuleExecutor, Transport, DEFAULT_USER_AGENT,
};

const RULE: &str = include_str!("../../rules/faguo.json");

fn rule() -> RuleDocument {
    RuleDocument::from_json(RULE).expect("发果规则应可加载")
}

async fn get(transport: &HttpTransport, url: &str) -> String {
    let response = transport
        .fetch(FetchRequest::get(url))
        .await
        .expect("请求应成功");
    String::from_utf8_lossy(&response.body).into_owned()
}

#[tokio::test]
#[ignore = "需要外网，手动执行：cargo test --test faguo_live -- --ignored"]
async fn catalog_live_returns_playable_items() {
    let rule = rule();
    let transport = HttpTransport::new(DEFAULT_USER_AGENT).expect("transport");
    let executor = RuleExecutor::new(&rule);
    let url = rule
        .pick_url(
            &rule.catalog.as_ref().expect("catalog").urls,
            &guo_engine::TemplateCtx {
                page: 1,
                category: "duanju",
                keyword: "",
                id: "",

                vars: None,
            },
        )
        .expect("目录地址");
    let body = get(&transport, &format!("{}/{}", rule.base, url)).await;
    let page = executor.parse_catalog(&body, 1).expect("目录解析");
    assert!(
        page.items.len() >= 10,
        "真实目录应返回至少 10 条，实际 {}",
        page.items.len()
    );
    assert!(page.items.iter().all(|item| !item.title.trim().is_empty()));
    assert!(page
        .items
        .iter()
        .all(|item| item.source_id.parse::<u32>().is_ok()));
}

#[tokio::test]
#[ignore = "需要外网，手动执行：cargo test --test faguo_live -- --ignored"]
async fn detail_and_resolve_live_produce_a_media_url() {
    let rule = rule();
    let transport = HttpTransport::new(DEFAULT_USER_AGENT).expect("transport");
    let executor = RuleExecutor::new(&rule);
    let detail_url = format!("{}/xzyxvd/429996.html", rule.base);
    let body = get(&transport, &detail_url).await;
    let drama = Drama {
        id: "faguo:429996".into(),
        source: "faguo".into(),
        source_id: "429996".into(),
        title: String::new(),
        ..Drama::default()
    };
    let chapters = executor.parse_chapters(&body, &drama).expect("分集解析");
    assert!(!chapters.is_empty(), "真实详情页应有分集");

    // `page_url` 已被规则转成绝对地址，不能再拼一次 base。
    let play = get(&transport, &chapters[0].page_url).await;
    let media = guo_engine::extract_media_url(&play, &format!("{}/", rule.base))
        .expect("播放页应能取到媒体地址");
    assert!(
        media.contains(".m3u8") || media.contains(".mp4"),
        "取到的应是可播放地址：{media}"
    );
}
