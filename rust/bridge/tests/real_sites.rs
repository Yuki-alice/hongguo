use guo_engine::{extract_media_url, Drama, RuleDocument, RuleExecutor, TemplateCtx};

#[test]
fn wuguo_rule_parses_real_catalog_fixture() {
    let rule_text = include_str!("../../rules/wuguo.json");
    let rule = RuleDocument::from_json(rule_text).expect("rule must load");
    let html = include_str!("fixtures/wuguo_home.html");
    let executor = RuleExecutor::new(&rule);
    let page = executor.parse_catalog(html, 1).expect("catalog");

    assert!(
        page.items.len() >= 10,
        "expected real catalog items, got {}",
        page.items.len()
    );

    let first = &page.items[0];
    assert_eq!(first.source, "wuguo");
    assert!(!first.source_id.is_empty(), "source id must be extracted");
    assert!(!first.title.is_empty(), "title must be extracted");
    assert!(
        first.cover.starts_with("http"),
        "cover must be absolute, got {}",
        first.cover
    );
    assert!(first.id.starts_with("wuguo:"));
    assert!(!page.items.iter().any(|d| d.source_id.contains(".html")));
}

#[test]
fn piguo_structure_is_parseable_by_a_rule() {
    let rule_text = r#"{
        "schema": "1.0",
        "id": "piguo",
        "name": "皮果",
        "base": "https://ptt.red",
        "catalog": {
            "url": "p/66/c/{category}",
            "item": "div.item",
            "fields": { "id": "a@href", "title": "a" }
        },
        "detail": { "episodes": "a[href*=/p/]" }
    }"#;
    let rule = RuleDocument::from_json(rule_text).expect("rule");
    let html = include_str!("fixtures/piguo_catalog.html");
    let executor = RuleExecutor::new(&rule);
    let parsed = executor.parse_catalog(html, 1).expect("catalog runs");
    assert_eq!(parsed.page, 1);
}

#[test]
fn wuguo_rule_handles_real_category_page() {
    let rule = RuleDocument::from_json(include_str!("../../rules/wuguo.json")).expect("rule");
    let html = include_str!("fixtures/wuguo_catalog.html");
    let page = RuleExecutor::new(&rule)
        .parse_catalog(html, 1)
        .expect("catalog");

    assert!(page.items.len() >= 20, "got {} items", page.items.len());
    let first = &page.items[0];
    assert_eq!(first.source, "wuguo");
    assert!(
        !first.title.contains("人在追"),
        "title leaked rating: {}",
        first.title
    );
    assert!(
        !first.title.contains('\n'),
        "title not normalized: {:?}",
        first.title
    );
    assert!(!first.source_id.contains(".html"));
    assert!(first.source_id.chars().all(|c| c.is_ascii_digit()));
}

#[test]
fn wuguo_rule_supports_both_page_layouts() {
    let rule = RuleDocument::from_json(include_str!("../../rules/wuguo.json")).expect("rule");
    let executor = RuleExecutor::new(&rule);
    let home = executor
        .parse_catalog(include_str!("fixtures/wuguo_home.html"), 1)
        .expect("home");
    let category = executor
        .parse_catalog(include_str!("fixtures/wuguo_catalog.html"), 1)
        .expect("category");
    assert!(home.items.len() >= 10, "home: {}", home.items.len());
    assert!(
        category.items.len() >= 20,
        "category: {}",
        category.items.len()
    );
}

#[test]
fn huaguo_rule_parses_real_catalog() {
    let rule = RuleDocument::from_json(include_str!("../../rules/huaguo.json")).expect("rule");
    let html = include_str!("fixtures/huaguo_catalog.html");
    let page = RuleExecutor::new(&rule)
        .parse_catalog(html, 1)
        .expect("catalog");

    assert!(page.items.len() >= 30, "got {}", page.items.len());
    let first = &page.items[0];
    assert_eq!(first.source, "huaguo");
    assert!(first.source_id.chars().all(|c| c.is_ascii_digit()));
    assert!(!first.title.is_empty());
    assert!(first.cover.starts_with("http"));
}

#[test]
fn wangguo_rule_parses_real_catalog() {
    let rule = RuleDocument::from_json(include_str!("../../rules/wangguo.json")).expect("rule");
    let page = RuleExecutor::new(&rule)
        .parse_catalog(include_str!("fixtures/wangguo_catalog.html"), 1)
        .expect("catalog");

    assert!(page.items.len() >= 20, "got {}", page.items.len());
    let first = &page.items[0];
    assert_eq!(first.source, "wangguo");
    assert_eq!(first.source_id, "49540");
    assert!(!first.title.contains('\n'), "title not normalized");
    assert!(!first.title.is_empty());
    assert!(
        first.cover.starts_with("https://pic."),
        "cover must be absolute, got {}",
        first.cover
    );
    assert!(
        first.cover.starts_with("http") && !first.cover.starts_with("data:"),
        "lazy placeholder must not leak into cover"
    );
    assert!(page.has_more, "24 条满页应判定还有下一页");
}

#[test]
fn wangguo_catalog_url_switches_on_category() {
    let rule = RuleDocument::from_json(include_str!("../../rules/wangguo.json")).expect("rule");
    let catalog = rule.catalog.as_ref().expect("catalog");
    let all_ctx = TemplateCtx {
        page: 1,
        category: "",
        keyword: "",
        id: "",

        vars: None,
    };
    let all = catalog.url_candidates(&rule, &all_ctx).expect("全部地址");
    assert_eq!(all, "show/duanju--------1---.html");

    let category = TemplateCtx {
        page: 2,
        category: "女频恋爱",
        keyword: "",
        id: "",

        vars: None,
    };
    let scoped = catalog.url_candidates(&rule, &category).expect("分类地址");
    assert_eq!(scoped, "show/duanju---女频恋爱-----2---.html");
}

#[test]
fn wangguo_detail_reads_real_episode_links() {
    let rule = RuleDocument::from_json(include_str!("../../rules/wangguo.json")).expect("rule");
    let drama = Drama {
        id: Drama::identity("wangguo", "49540"),
        source: "wangguo".to_string(),
        source_id: "49540".to_string(),
        ..Default::default()
    };
    let chapters = RuleExecutor::new(&rule)
        .parse_chapters(include_str!("fixtures/wangguo_detail.html"), &drama)
        .expect("chapters");
    assert!(!chapters.is_empty(), "未解析到分集");
    assert!(
        chapters[0]
            .page_url
            .contains("https://www.duanju2.com/play/49540-1-1.html"),
        "got {}",
        chapters[0].page_url
    );
}

#[test]
fn wangguo_resolve_scans_play_page() {
    let rule = RuleDocument::from_json(include_str!("../../rules/wangguo.json")).expect("rule");
    let play = include_str!("fixtures/wangguo_play.html");
    let media = extract_media_url(play, &rule.base).expect("play 页没有解析到地址");
    assert!(media.contains("/video/index.m3u8"), "got {media}");
}
