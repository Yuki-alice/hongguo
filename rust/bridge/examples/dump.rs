use guo_engine::{RuleDocument, RuleExecutor};

fn main() {
    let rule = RuleDocument::from_json(include_str!("../../rules/wuguo.json")).expect("rule");
    let html = include_str!("../tests/fixtures/wuguo_home.html");
    let page = RuleExecutor::new(&rule)
        .parse_catalog(html, 1)
        .expect("catalog");
    println!("items: {}", page.items.len());
    for drama in page.items.iter().take(5) {
        let cover: String = drama.cover.chars().take(40).collect();
        println!(
            "  id={} | {} | cat={} | {}",
            drama.source_id, drama.title, drama.category, cover
        );
    }
}
