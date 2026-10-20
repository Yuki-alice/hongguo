//! 帝果（P2 首个迁移源）的离线夹具对拍。
//!
//! 夹具 HTML 取自 Go 测试里的真实结构（`provider_sources_parity_test.go`），
//! 路径前缀 `/index.php/vod/...` 与站点一致。

use guo_engine::{RuleDocument, RuleExecutor};

const RULE: &str = include_str!("../../rules/diguo.json");
const CATALOG: &str = include_str!("fixtures/diguo_catalog.html");

fn rule() -> RuleDocument {
    RuleDocument::from_json(RULE).expect("帝果规则应可加载")
}

#[test]
fn rule_loads_with_expected_metadata() {
    let rule = rule();
    assert_eq!(rule.id, "diguo");
    assert_eq!(rule.name, "帝果");
    assert_eq!(rule.base, "https://www.dsd.com.se");
}

#[test]
fn catalog_parses_play_and_detail_links() {
    let page = RuleExecutor::new(&rule())
        .parse_catalog(CATALOG, 1)
        .expect("目录解析成功");
    assert_eq!(page.items.len(), 2, "两种卡片 class 都要命中");

    let first = &page.items[0];
    assert_eq!(first.source, "diguo");
    assert_eq!(first.source_id, "456");
    assert_eq!(first.id, "diguo:456");
    assert_eq!(first.title, "帝果榜一");
    assert!(first.cover.ends_with("456.jpg"), "{}", first.cover);

    let second = &page.items[1];
    assert_eq!(second.source_id, "457", "detail 链接也要取对 id");
    assert_eq!(second.title, "帝果榜二");
    assert!(second.cover.ends_with("457.jpg"), "{}", second.cover);
}

#[test]
fn catalog_url_uses_site_route_shape() {
    let rule = rule();
    let catalog = rule.catalog.as_ref().expect("catalog");
    let url = rule.expand(&catalog.url, 1, "9", "");
    assert_eq!(url, "index.php/vod/type/id/9/page/1.html");
}

#[test]
fn search_url_encodes_keyword() {
    let rule = rule();
    let search = rule.search.as_ref().expect("search");
    let url = rule.expand(&search.url, 1, "", "都市");
    assert!(url.contains("/wd/"), "{url}");
    assert!(!url.contains("都市"), "关键词必须编码：{url}");
    assert!(url.contains("%E9%83%BD%E5%B8%82"), "{url}");
}

#[test]
fn detail_uses_id_template() {
    let rule = rule();
    let detail = rule.detail.as_ref().expect("detail");
    let url = detail.url.as_deref().expect("detail url");
    // 空 id 会被折叠掉（模板渲染遇到空值时不留空段），因此不在这里断言；
    // 真正要保证的是渲染出正确的地址。
    let rendered = rule.render(
        url,
        &guo_engine::TemplateCtx {
            page: 1,
            category: "",
            keyword: "",
            id: "456",
        },
    );
    assert_eq!(rendered, "index.php/vod/detail/id/456.html");
}
