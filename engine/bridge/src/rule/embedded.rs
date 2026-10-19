use serde_json::Value;

const MARKER: &[u8] = b"__NEXT_DATA__";
const SCRIPT_OPEN: &[u8] = b"<script";
const SCRIPT_CLOSE: &[u8] = b"</script>";

/// 取页面内嵌 JSON（Next.js 的 `__NEXT_DATA__`），规则路径从文档根开始书写。
pub fn embedded_json(body: &str) -> Option<Value> {
    let bytes = body.as_bytes();
    let mut from = 0usize;
    while let Some(mark) = find(bytes, MARKER, from) {
        from = mark + MARKER.len();
        // 标记一般写在 `<script id="__NEXT_DATA__" …>` 的属性里，右尖括号在标记之后。
        if rfind(bytes, SCRIPT_OPEN, mark).is_none() {
            continue;
        }
        let Some(end) = find(bytes, SCRIPT_CLOSE, mark) else {
            break;
        };
        let Some(bracket) = bytes[mark..end].iter().position(|byte| *byte == b'>') else {
            continue;
        };
        // `>` 与 `<` 都是 ASCII，切片边界必然落在字符起始字节上。
        let start = mark + bracket + 1;
        if start >= end {
            continue;
        }
        let text = body[start..end].trim();
        if let Ok(parsed) = serde_json::from_str::<Value>(text) {
            return Some(parsed);
        }
    }
    None
}

fn find(haystack: &[u8], needle: &[u8], from: usize) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    (from..=haystack.len() - needle.len())
        .find(|start| haystack[*start..*start + needle.len()].eq_ignore_ascii_case(needle))
}

fn rfind(haystack: &[u8], needle: &[u8], before: usize) -> Option<usize> {
    if needle.is_empty() {
        return None;
    }
    let limit = before.min(haystack.len()).saturating_sub(needle.len());
    (0..=limit)
        .rev()
        .find(|start| haystack[*start..*start + needle.len()].eq_ignore_ascii_case(needle))
}

#[cfg(test)]
mod tests {
    use super::*;

    const PAGE: &str = r#"<html><head>
        <script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"bookList":[{"bookId":"9","bookName":"剧本"}],"pages":12,"page":3}}}</script>
        <script>var ignored = {"bookList":[]};</script>
    </head><body></body></html>"#;

    #[test]
    fn extracts_next_data_script_only() {
        let value = embedded_json(PAGE).expect("json");
        assert!(value.get("props").is_some());
        assert_eq!(value["props"]["pageProps"]["pages"], serde_json::json!(12));
        let list = value["props"]["pageProps"]["bookList"]
            .as_array()
            .expect("array");
        assert_eq!(list[0]["bookName"], serde_json::json!("剧本"));
    }

    #[test]
    fn tolerates_non_ascii_before_marker() {
        let body = "<title>短剧·标题</title><script id=\"__NEXT_DATA__\" type=\"application/json\">{\"a\":1}</script>";
        assert_eq!(
            embedded_json(body).expect("json")["a"],
            serde_json::json!(1)
        );
    }

    #[test]
    fn exposes_nested_nodes_for_rule_paths() {
        let value = embedded_json(PAGE).expect("json");
        let book = &value["props"]["pageProps"]["bookList"][0];
        assert_eq!(book["bookId"], serde_json::json!("9"));
        assert!(value.get("missing").is_none());
    }

    #[test]
    fn unparsable_payload_is_skipped() {
        let body = r#"<script id="__NEXT_DATA__" type="application/json">{not json}</script>"#;
        assert!(embedded_json(body).is_none());
        assert!(embedded_json("<html><body>no json</body></html>").is_none());
    }
}
