use serde_json::Value;

/// 路径步骤：对象取键、数组下标、数组展开。
#[derive(Debug, Clone, PartialEq, Eq)]
enum Step {
    Field(String),
    Index(usize),
    Flatten,
}

fn parse_path(path: &str) -> Vec<Step> {
    let trimmed = path.trim();
    let body = match trimmed {
        "" | "$" | "." => "",
        _ => trimmed
            .strip_prefix("$.")
            .or_else(|| trimmed.strip_prefix('$'))
            .unwrap_or(trimmed),
    };
    let mut steps = Vec::new();
    for segment in body.split('.') {
        let segment = segment.trim();
        if segment.is_empty() || segment == "*" {
            if segment == "*" {
                steps.push(Step::Flatten);
            }
            continue;
        }
        let (name, bracket) = match segment.find('[') {
            Some(position) => {
                let head = &segment[..position];
                let tail = segment[position + 1..].trim_end_matches(']');
                (head, Some(tail.trim()))
            }
            None => (segment, None),
        };
        if !name.is_empty() {
            steps.push(Step::Field(name.to_string()));
        }
        if let Some(inner) = bracket {
            if inner.is_empty() || inner == "*" {
                steps.push(Step::Flatten);
            } else if let Ok(index) = inner.parse::<usize>() {
                steps.push(Step::Index(index));
            }
        }
    }
    steps
}

pub fn select<'a>(root: &'a Value, path: &str) -> Vec<&'a Value> {
    apply(root, &parse_path(path))
}

fn apply<'a>(root: &'a Value, steps: &[Step]) -> Vec<&'a Value> {
    let mut current = vec![root];
    for step in steps {
        let mut next = Vec::new();
        for value in &current {
            match step {
                Step::Field(name) => {
                    if let Some(found) = lookup(value, name) {
                        next.push(found);
                    }
                }
                Step::Index(index) => {
                    if let Value::Array(items) = value {
                        if let Some(found) = items.get(*index) {
                            next.push(found);
                        }
                    }
                }
                Step::Flatten => {
                    if let Value::Array(items) = value {
                        next.extend(items.iter());
                    }
                }
            }
        }
        current = next;
        if current.is_empty() {
            return current;
        }
    }
    current
}

fn lookup<'a>(value: &'a Value, name: &str) -> Option<&'a Value> {
    match value {
        Value::Object(map) => map.get(name),
        _ => None,
    }
}

/// 列表路径：命中数组时展开一层，便于 `data`、`bannerList`、`seoColumnVos[].bookInfos` 混写。
pub fn select_items<'a>(root: &'a Value, path: &str) -> Vec<&'a Value> {
    let mut out = Vec::new();
    for value in select(root, path) {
        match value {
            Value::Array(items) => out.extend(items.iter()),
            other => out.push(other),
        }
    }
    out
}

/// 依次尝试候选路径，返回第一个可取到文本的节点。
pub fn first_value<'a>(root: &'a Value, paths: &[String]) -> Option<&'a Value> {
    for path in paths {
        for candidate in select(root, path) {
            if !text_of(candidate).is_empty() {
                return Some(candidate);
            }
        }
    }
    None
}

/// 取第一个命中的对象节点，用于详情资料与内嵌 JSON 根节点。
pub fn first_object<'a>(root: &'a Value, paths: &[String]) -> Option<&'a Value> {
    for path in paths {
        for candidate in select(root, path) {
            if candidate.is_object() {
                return Some(candidate);
            }
        }
    }
    None
}

/// 取第一个非空列表路径，命中结果展开一层。
pub fn first_nodes<'a>(root: &'a Value, paths: &[String]) -> Vec<&'a Value> {
    for path in paths {
        let nodes = select_items(root, path);
        if !nodes.is_empty() {
            return nodes;
        }
    }
    Vec::new()
}

pub fn text_at(root: &Value, paths: &[String]) -> String {
    first_value(root, paths).map(text_of).unwrap_or_default()
}

/// 对齐 Go `nativeText`：对象取常见地址键，数组取第一个非空。
pub fn text_of(value: &Value) -> String {
    match value {
        Value::String(text) => text.trim().to_string(),
        Value::Number(number) => number.to_string(),
        Value::Object(map) => {
            for key in ["url", "src", "cover", "image", "pic"] {
                if let Some(found) = map.get(key) {
                    let text = text_of(found);
                    if !text.is_empty() {
                        return text;
                    }
                }
            }
            String::new()
        }
        Value::Array(items) => {
            for entry in items {
                let text = text_of(entry);
                if !text.is_empty() {
                    return text;
                }
            }
            String::new()
        }
        _ => String::new(),
    }
}

pub fn int_of(value: &Value) -> i64 {
    match value {
        Value::Number(number) => number
            .as_i64()
            .or_else(|| number.as_f64().map(|float| float as i64))
            .unwrap_or(0),
        Value::String(text) => parse_number(text),
        Value::Array(items) => items
            .iter()
            .map(int_of)
            .find(|value| *value != 0)
            .unwrap_or(0),
        _ => 0,
    }
}

pub fn int_at(root: &Value, paths: &[String]) -> i64 {
    first_value(root, paths).map(int_of).unwrap_or(0)
}

/// 支持 `34集`、`共34集` 这类带单位文本。
pub fn parse_number(raw: &str) -> i64 {
    let trimmed = raw.trim();
    if let Ok(parsed) = trimmed.parse::<i64>() {
        return parsed;
    }
    let stripped = trimmed
        .trim_end_matches('集')
        .trim_end_matches("全集")
        .replace("共", "")
        .replace([',', ' '], "");
    stripped.parse::<i64>().unwrap_or(0)
}

/// 对齐 Go `duanjuStringList`：字符串数组或 `{name|title|class_name}` 对象数组。
pub fn string_list_of(value: &Value) -> Vec<String> {
    match value {
        Value::Array(items) => {
            let mut out = Vec::new();
            for entry in items {
                match entry {
                    Value::String(text) => {
                        let text = text.trim();
                        if !text.is_empty() {
                            out.push(text.to_string());
                        }
                    }
                    Value::Object(_) => {
                        let text =
                            text_at(entry, &["name".into(), "title".into(), "class_name".into()]);
                        if !text.is_empty() {
                            out.push(text);
                        }
                    }
                    _ => {}
                }
            }
            out
        }
        Value::String(text) => text
            .split(',')
            .map(str::trim)
            .filter(|item| !item.is_empty())
            .map(ToString::to_string)
            .collect(),
        _ => Vec::new(),
    }
}

pub fn string_list_at(root: &Value, paths: &[String]) -> Vec<String> {
    for path in paths {
        for candidate in select(root, path) {
            let values = string_list_of(candidate);
            if !values.is_empty() {
                return values;
            }
        }
    }
    Vec::new()
}

/// 在对象树里找第一个命中的地址键，用于星果把播放地址藏在子列表里的情况。
pub fn find_url(node: &Value, keys: &[String], depth: u32) -> String {
    for key in keys {
        if let Some(found) = lookup(node, key) {
            let text = text_of(found);
            if !text.is_empty() {
                return text;
            }
        }
    }
    if depth >= 3 {
        return String::new();
    }
    match node {
        Value::Object(map) => {
            for child in map.values() {
                let found = find_url(child, keys, depth + 1);
                if !found.is_empty() {
                    return found;
                }
            }
            String::new()
        }
        Value::Array(items) => {
            for child in items {
                let found = find_url(child, keys, depth + 1);
                if !found.is_empty() {
                    return found;
                }
            }
            String::new()
        }
        _ => String::new(),
    }
}

pub fn absolute(base: &str, href: &str) -> String {
    let href = href.trim();
    if href.is_empty() {
        return String::new();
    }
    if href.starts_with("http://") || href.starts_with("https://") {
        return href.to_string();
    }
    if href.starts_with("//") {
        return format!("https:{href}");
    }
    if href.starts_with("data:") {
        return href.to_string();
    }
    let base = base.trim_end_matches('/');
    format!("{base}/{}", href.trim_start_matches('/'))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn reads_nested_object_and_array_paths() {
        let value = json!({
            "result": {
                "elements": [
                    { "contents": [ { "duanjuVo": { "title": "剧名" } } ] }
                ]
            }
        });
        let items = select_items(&value, "result.elements[].contents[].duanjuVo");
        assert_eq!(items.len(), 1);
        assert_eq!(text_of(items[0]), "");
        assert_eq!(text_at(items[0], &["title".to_string()]), "剧名");
    }

    #[test]
    fn flattens_plain_array_paths() {
        let value = json!({ "data": [ { "id": 1 }, { "id": 2 } ] });
        let items = select_items(&value, "data");
        assert_eq!(items.len(), 2);
        assert_eq!(text_at(items[1], &["id".to_string()]), "2");
    }

    #[test]
    fn supports_indexed_step() {
        let value = json!({ "list": [ { "n": 7 }, { "n": 9 } ] });
        assert_eq!(int_at(&value, &["list[0].n".to_string()]), 7);
        assert_eq!(int_at(&value, &["list[1].n".to_string()]), 9);
        assert_eq!(int_at(&value, &["list[9].n".to_string()]), 0);
    }

    #[test]
    fn aliases_take_first_non_empty() {
        let value = json!({ "bookName": "", "name": "名称" });
        assert_eq!(
            text_at(
                &value,
                &[
                    "bookName".to_string(),
                    "name".to_string(),
                    "title".to_string()
                ]
            ),
            "名称"
        );
    }

    #[test]
    fn coerces_numbers_and_episode_text() {
        let value = json!({ "total": 34, "episodes": "共34集", "ratio": 12.9 });
        assert_eq!(int_at(&value, &["total".to_string()]), 34);
        assert_eq!(int_at(&value, &["episodes".to_string()]), 34);
        assert_eq!(int_of(&value["ratio"]), 12);
        assert_eq!(text_of(&value["total"]), "34");
    }

    #[test]
    fn string_lists_accept_objects() {
        let value = json!({
            "categories": [ { "name": "都市" }, { "title": "甜宠" }, { "class_name": "逆袭" } ],
            "tags": ["A", " B "]
        });
        assert_eq!(
            string_list_at(&value, &["categories".to_string()]),
            vec!["都市", "甜宠", "逆袭"]
        );
        assert_eq!(
            string_list_at(&value, &["tags".to_string()]),
            vec!["A", "B"]
        );
    }

    #[test]
    fn cover_addresses_unwrap_objects() {
        let value = json!({ "cover": { "url": "https://cdn.test/1.jpg" } });
        assert_eq!(
            text_at(&value, &["cover".to_string()]),
            "https://cdn.test/1.jpg"
        );
        assert_eq!(
            absolute("https://a.test/", "/b.jpg"),
            "https://a.test/b.jpg"
        );
        assert_eq!(
            absolute("https://a.test", "//cdn.test/b.jpg"),
            "https://cdn.test/b.jpg"
        );
    }

    #[test]
    fn find_url_recurses_into_nested_lists() {
        let value = json!({
            "chapterNum": 3,
            "shortPlayList": [ { "shortPlayUrl": "https://cdn.test/1.mp4" } ]
        });
        let keys = ["shortPlayUrl".to_string(), "playUrl".to_string()];
        assert_eq!(find_url(&value, &keys, 0), "https://cdn.test/1.mp4");
        assert_eq!(find_url(&json!({"a": 1}), &keys, 0), "");
    }

    #[test]
    fn missing_paths_yield_empty() {
        let value = json!({ "data": null });
        assert_eq!(text_at(&value, &["data.title".to_string()]), "");
        assert!(select_items(&value, "data.list").is_empty());
    }
}
