//! 发果（P2 第二个迁移源）的离线夹具对拍。
//!
//! 夹具取自 2026-10-21 的真实响应并裁剪：目录页保留 3 张卡片、详情页保留
//! 完整分集列表与标题、播放页保留 `player_aaaa` 变量。站点类名带随机后缀，
//! 夹具保留了原始随机类名，规则只能依赖 `stui-vodlist__*` 这类稳定钩子——
//! 这正是本次要守住的不变量。

use guo_engine::{extract_media_url, Drama, RuleDocument, RuleExecutor, TemplateCtx};

const RULE: &str = include_str!("../../rules/faguo.json");
const CATALOG: &str = include_str!("fixtures/faguo_catalog.html");
const DETAIL: &str = include_str!("fixtures/faguo_detail.html");
const PLAY: &str = include_str!("fixtures/faguo_play.html");

fn rule() -> RuleDocument {
    RuleDocument::from_json(RULE).expect("发果规则应可加载")
}

#[test]
fn rule_loads_with_expected_metadata() {
    let rule = rule();
    assert_eq!(rule.id, "faguo");
    assert_eq!(rule.name, "发果");
    assert_eq!(rule.base, "https://www.xzyx168.com");
}

#[test]
fn catalog_parses_cards_from_stable_class_hooks() {
    let page = RuleExecutor::new(&rule())
        .parse_catalog(CATALOG, 1)
        .expect("目录解析成功");
    assert_eq!(page.items.len(), 3, "夹具里的三张卡片都要命中");

    let first = &page.items[0];
    assert_eq!(first.source, "faguo");
    assert_eq!(first.source_id, "431290", "id 只取路径里的数字");
    assert_eq!(first.id, "faguo:431290");
    assert_eq!(first.title, "权掌新生，捍卫属于我的一切");
    assert!(
        first.cover.starts_with("https://"),
        "封面要转成绝对地址：{}",
        first.cover
    );
    assert!(
        !first.source_id.contains(".html"),
        "主键不能带上 .html 后缀"
    );
}

#[test]
fn catalog_url_uses_category_slug_and_query_page() {
    let rule = rule();
    let catalog = rule.catalog.as_ref().expect("catalog");
    let ctx = |page, category| TemplateCtx {
        page,
        category,
        keyword: "",
        id: "",

        vars: None,
    };
    let url = rule
        .pick_url(&catalog.urls, &ctx(2, "duanju"))
        .expect("有分类时选中条件地址");
    assert_eq!(url, "xzyxvt/duanjun.html?page=2");

    // 没有分类时选中不带 `when` 的回退地址，落到短剧首页。
    let fallback = rule
        .pick_url(&catalog.urls, &ctx(1, ""))
        .expect("无分类时选中回退地址");
    assert_eq!(fallback, "xzyxvt/duanjun.html?page=1");
}

#[test]
fn detail_parses_episodes() {
    let rule = rule();
    let executor = RuleExecutor::new(&rule);
    let drama = Drama {
        id: "faguo:429996".into(),
        source: "faguo".into(),
        source_id: "429996".into(),
        title: String::new(),
        ..Drama::default()
    };
    let chapters = executor
        .parse_chapters(DETAIL, &drama)
        .expect("分集解析成功");
    assert!(
        chapters.len() >= 8,
        "应解析出完整分集，实际 {}",
        chapters.len()
    );
    let first = &chapters[0];
    assert!(first.id.ends_with(":1"), "分集按 1 起编号：{}", first.id);
    assert!(
        first.page_url.contains("/xzyxvp/"),
        "分集地址要保留播放页路径：{}",
        first.page_url
    );
}

#[test]
fn search_url_encodes_keyword() {
    let rule = rule();
    let search = rule.search.as_ref().expect("search");
    let url = rule.expand(&search.url, 1, "", "都市");
    assert!(url.starts_with("xzyxvc/"), "{url}");
    assert!(!url.contains("都市"), "关键词必须编码：{url}");
    assert!(url.contains("%E9%83%BD%E5%B8%82"), "{url}");
}

#[test]
fn resolve_reads_player_variable() {
    let media = extract_media_url(PLAY, "https://www.xzyx168.com/").expect("应解析出播放地址");
    assert!(
        media.starts_with("https://") && media.contains(".m3u8"),
        "取到直链 m3u8：{media}"
    );
}

#[test]
fn detail_url_template_renders_numeric_id() {
    let rule = rule();
    let detail = rule.detail.as_ref().expect("detail");
    let url = detail.url.as_deref().expect("detail url");
    let rendered = rule.render(
        url,
        &TemplateCtx {
            page: 1,
            category: "",
            keyword: "",
            id: "431290",

            vars: None,
        },
    );
    assert_eq!(rendered, "xzyxvd/431290.html");
}
