//! 红果搜索联想的离线对拍。
//!
//! 夹具取自 2026-10-21 的真实响应，只保留行字段。它覆盖一次真实的外层键
//! 变更：`data` / `suggest_words` → `suggest_list`。

use guo_source_hongguo::parse_suggestions;

const SUGGESTIONS: &str = include_str!("fixtures/suggestions.json");

#[test]
fn parses_suggest_list_rows() {
    let items = parse_suggestions(SUGGESTIONS).expect("联想应可解析");
    assert!(!items.is_empty(), "真实响应至少有若干条");
    assert!(items.iter().all(|item| !item.name.trim().is_empty()));
}

#[test]
fn keeps_declared_kind_and_drops_unknown() {
    let items = parse_suggestions(SUGGESTIONS).expect("解析");
    let known: Vec<&str> = items.iter().map(|item| item.kind.as_str()).collect();
    assert!(
        known.contains(&"short_play_name"),
        "应保留已知类型：{known:?}"
    );
    assert!(
        known.iter().all(|kind| !kind.contains("unknown")),
        "未知类型不应原样透传：{known:?}"
    );
}

#[test]
fn dedupes_repeated_names() {
    let body = r#"{"suggest_list":[
        {"name":"总裁","word_type":"short_play_name"},
        {"name":"总裁","word_type":"title"},
        {"name":"总裁夫人","word_type":"title"}
    ]}"#;
    let items = parse_suggestions(body).expect("解析");
    assert_eq!(items.len(), 2);
}

#[test]
fn legacy_keys_still_parse() {
    // 站点在键名上来回切；旧形态必须继续可用，否则一次回滚就会让联想全空。
    let legacy = r#"{"data":[{"name":"总裁","word_type":"short_play_name"}]}"#;
    assert_eq!(parse_suggestions(legacy).expect("解析").len(), 1);
    let older = r#"{"suggest_words":[{"name":"总裁","word_type":"title"}]}"#;
    assert_eq!(parse_suggestions(older).expect("解析").len(), 1);
}

#[test]
fn rejects_non_json() {
    assert!(parse_suggestions("<html>").is_err());
}

#[test]
fn empty_list_is_not_an_error() {
    let items = parse_suggestions(r#"{"suggest_list":[]}"#).expect("解析");
    assert!(items.is_empty());
}
