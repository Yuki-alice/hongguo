//! 前置编排（`preflight`）的响应提取。
//!
//! 与其它执行器的区别只有一处：提取目标是**变量表**而不是剧目模型。
//! 这里保持纯函数、零 IO —— 请求由 runtime 层驱动，规则引擎只负责
//! 「给定响应文本与提取规格，算出变量」。

use std::collections::BTreeMap;

use scraper::{Html, Selector};
use serde_json::Value;

use guo_source_api::SourceError;

use super::{embedded, jsonpath, ExtractRule, RuleKind};

/// 按提取规格把响应文本变成变量表。
///
/// 任何变量取不到值都算失败：把空串注入地址会发出一个「看起来正常」的坏请求，
/// 这正是规则体系最怕的静默失败。
pub fn extract_vars(
    body: &str,
    spec: &ExtractRule,
) -> Result<BTreeMap<String, String>, SourceError> {
    let kind = spec.kind.unwrap_or(RuleKind::Json);
    if spec.vars.is_empty() {
        return Err(SourceError::parse("preflight", "extract.vars 为空"));
    }
    let root = match kind {
        RuleKind::Json | RuleKind::Next => Some(read_root(body, kind)?),
        RuleKind::Html | RuleKind::Regex => None,
    };
    let document = (kind == RuleKind::Html).then(|| Html::parse_document(body));

    let mut out = BTreeMap::new();
    for (name, expression) in &spec.vars {
        let value = extract_one(kind, body, root.as_ref(), document.as_ref(), expression)?;
        if value.trim().is_empty() {
            return Err(SourceError::parse(
                "preflight",
                format!("变量 {name} 提取为空（{expression}）"),
            ));
        }
        out.insert(name.clone(), value);
    }
    Ok(out)
}

fn read_root(body: &str, kind: RuleKind) -> Result<Value, SourceError> {
    match kind {
        RuleKind::Json => serde_json::from_str(body)
            .map_err(|err| SourceError::parse("preflight", format!("响应不是 JSON：{err}"))),
        // 内嵌 JSON 页面与直接返回 JSON 的接口共用 `next`。
        RuleKind::Next => embedded::embedded_json(body)
            .or_else(|| serde_json::from_str(body).ok())
            .ok_or_else(|| SourceError::parse("preflight", "页面未返回可解析的数据")),
        RuleKind::Html | RuleKind::Regex => Err(SourceError::parse(
            "preflight",
            "该提取方式不需要 JSON 解析",
        )),
    }
}

fn extract_one(
    kind: RuleKind,
    body: &str,
    root: Option<&Value>,
    document: Option<&Html>,
    expression: &str,
) -> Result<String, SourceError> {
    let expression = expression.trim();
    if expression.is_empty() {
        return Err(SourceError::parse("preflight", "提取表达式为空"));
    }
    match kind {
        RuleKind::Json | RuleKind::Next => {
            let root = root.ok_or_else(|| SourceError::parse("preflight", "缺少 JSON 根"))?;
            Ok(jsonpath::select(root, expression)
                .first()
                .map(|value| jsonpath::text_of(value))
                .unwrap_or_default())
        }
        RuleKind::Regex => {
            Ok(super::regex_executor::first_capture(body, expression).unwrap_or_default())
        }
        RuleKind::Html => {
            let document =
                document.ok_or_else(|| SourceError::parse("preflight", "缺少 HTML 文档"))?;
            let (selector_text, attribute) = match expression.split_once('@') {
                Some((selector, attribute)) => (selector, Some(attribute)),
                None => (expression, None),
            };
            let selector = Selector::parse(selector_text.trim()).map_err(|err| {
                SourceError::parse(
                    "preflight",
                    format!("选择器无效（{selector_text}）：{err:?}"),
                )
            })?;
            let Some(element) = document.select(&selector).next() else {
                return Ok(String::new());
            };
            Ok(match attribute {
                Some(attribute) => super::executor::decode_entities(
                    element.value().attr(attribute).unwrap_or_default(),
                ),
                None => super::executor::decode_entities(&super::executor::first_text(element)),
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec(kind: RuleKind, vars: &[(&str, &str)]) -> ExtractRule {
        ExtractRule {
            kind: Some(kind),
            vars: vars
                .iter()
                .map(|(name, path)| (name.to_string(), path.to_string()))
                .collect(),
        }
    }

    #[test]
    fn reads_json_values() {
        let body = r#"{"data":{"token":"tk-1","host":"cdn.x","n":42}}"#;
        let vars = extract_vars(
            body,
            &spec(
                RuleKind::Json,
                &[
                    ("token", "$.data.token"),
                    ("host", "data.host"),
                    ("n", "$.data.n"),
                ],
            ),
        )
        .expect("extract");
        assert_eq!(vars["token"], "tk-1");
        assert_eq!(vars["host"], "cdn.x");
        assert_eq!(vars["n"], "42");
    }

    #[test]
    fn reads_embedded_json() {
        let body = r#"<html><script id="__NEXT_DATA__" type="application/json">{"cfg":{"v":"9"}}</script></html>"#;
        let vars = extract_vars(body, &spec(RuleKind::Next, &[("v", "$.cfg.v")])).expect("extract");
        assert_eq!(vars["v"], "9");
    }

    #[test]
    fn reads_html_text_and_attribute() {
        let body = r#"<html><body><meta name="csrf" content="c-7"><h1> 标题 &amp; 更多 </h1></body></html>"#;
        let vars = extract_vars(
            body,
            &spec(
                RuleKind::Html,
                &[("csrf", "meta[name=csrf]@content"), ("title", "h1")],
            ),
        )
        .expect("extract");
        assert_eq!(vars["csrf"], "c-7");
        assert_eq!(vars["title"], "标题 & 更多");
    }

    #[test]
    fn reads_regex_capture_group() {
        let body = r#"<script>window.__CFG__={"token":"abc123"}</script>"#;
        let vars = extract_vars(
            body,
            &spec(RuleKind::Regex, &[("token", r#""token":"([^"]+)""#)]),
        )
        .expect("extract");
        assert_eq!(vars["token"], "abc123");
    }

    #[test]
    fn missing_value_is_an_error_not_an_empty_string() {
        let body = r#"{"data":{}}"#;
        let err = extract_vars(body, &spec(RuleKind::Json, &[("token", "$.data.token")]))
            .expect_err("must fail");
        assert!(err.to_string().contains("token"), "{err}");
    }

    #[test]
    fn non_json_body_reports_a_locatable_error() {
        let err = extract_vars("<html></html>", &spec(RuleKind::Json, &[("a", "$.a")]))
            .expect_err("must fail");
        assert!(err.to_string().contains("不是 JSON"), "{err}");
    }
}
