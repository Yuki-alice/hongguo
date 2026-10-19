use guo_engine::{RuleDocument, RuleExecutor};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let (rule_path, html_path, category) = (
        &args[1],
        &args[2],
        args.get(3).map(String::as_str).unwrap_or("27"),
    );

    let rule = RuleDocument::from_json(&std::fs::read_to_string(rule_path).expect("rule"))
        .expect("parse rule");
    let html = std::fs::read_to_string(html_path).expect("html");
    let page = RuleExecutor::new(&rule)
        .parse_catalog(&html, 1)
        .expect("catalog");
    println!(
        "{}: {} items (category={})",
        rule.id,
        page.items.len(),
        category
    );
    for d in page.items.iter().take(5) {
        println!(
            "  {} | {} | cat={} | {}",
            d.source_id,
            d.title,
            d.category,
            d.cover.chars().take(40).collect::<String>()
        );
    }
}
