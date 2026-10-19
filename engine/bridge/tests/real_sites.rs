use guo_engine::{RuleDocument, RuleExecutor};

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
