//! `_ROUTER_DATA` 内嵌 JSON 的提取与字段映射。
//!
//! 红果的网页把数据塞在 `window._ROUTER_DATA = {...}` 里；app 接口则是纯 JSON。
//! 两边的字段名并不统一（`series_id` / `series_id_str`，`series_title` / `series_name`），
//! 这里集中处理候选字段，避免调用方到处写 `or_else`。

use serde_json::Value;

/// 网页里承载数据的标记。前面可能带 `window.` 前缀。
const ROUTER_MARKERS: [&str; 2] = ["window._ROUTER_DATA", "_ROUTER_DATA"];

/// 从页面文本里解析 `_ROUTER_DATA`。找不到或解析失败返回 `None`。
pub fn parse_router_data(raw: &str) -> Option<Value> {
    let start = ROUTER_MARKERS
        .iter()
        .filter_map(|marker| raw.find(marker))
        .min()?;
    // 跳过 `=` 与空白，从第一个 `{` 开始按 JSON 解码；尾部可能还有别的脚本。
    let rest = &raw[start..];
    let brace = rest.find('{')?;
    let mut stream = serde_json::Deserializer::from_str(&rest[brace..]).into_iter::<Value>();
    stream.next()?.ok()
}

/// 取 `loaderData[<name>…]`。`names` 支持前缀写法（去掉结尾的 `$` 后按前缀匹配）。
pub fn router_loader_map<'a>(data: &'a Value, names: &[&str]) -> Option<&'a Value> {
    let loader = data.get("loaderData")?.as_object()?;
    for name in names {
        if let Some(page) = loader.get(*name) {
            if page.as_object().is_some_and(|map| !map.is_empty()) {
                return Some(page);
            }
        }
    }
    for name in names {
        let prefix = name.trim_end_matches('$');
        if prefix.is_empty() {
            continue;
        }
        for (key, value) in loader {
            if key.starts_with(prefix) && value.as_object().is_some_and(|map| !map.is_empty()) {
                return Some(value);
            }
        }
    }
    None
}

/// 红果剧目。字段与 Go 版 `Drama` 的映射结果一致，只保留迁移需要的那部分。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct HongguoDrama {
    pub series_id: String,
    pub title: String,
    pub description: String,
    pub cover: String,
    pub category: String,
    pub episodes: u32,
    pub tags: Vec<String>,
    pub views: String,
    pub heat: String,
    pub release_status: String,
    pub online_date: String,
}

impl HongguoDrama {
    /// 从 `video_data` 或直接字段构造。`series_id` 必须是纯数字，否则视为无效条目。
    pub fn from_value(value: &Value, category: &str) -> Option<Self> {
        let map = value.as_object()?;
        // `video_data` 存在时优先用它，字段更全。
        let data = map
            .get("video_data")
            .and_then(Value::as_object)
            .unwrap_or(map);
        let series_id = first_text(data, &["series_id_str", "series_id"])
            .or_else(|| first_text(map, &["series_id_str", "series_id"]))
            .or_else(|| first_text(data, &["keyword"]))
            .or_else(|| first_text(map, &["keyword"]))?;
        if !series_id.chars().all(|c| c.is_ascii_digit()) {
            return None;
        }
        let title = first_text(data, &["series_title", "series_name", "title"])
            .or_else(|| first_text(map, &["series_name", "name"]))
            .unwrap_or_else(|| series_id.clone());
        let description = first_text(data, &["series_intro", "video_desc"])
            .or_else(|| first_text(map, &["series_intro"]))
            .unwrap_or_default();
        let cover = first_text(data, &["series_cover", "cover"])
            .or_else(|| first_text(map, &["series_cover"]))
            .unwrap_or_default();
        let episode_text = first_text(data, &["episode_cnt"])
            .or_else(|| first_text(map, &["episode_cnt"]))
            .unwrap_or_default();
        let episodes = episode_text.parse().unwrap_or(0);
        let remark = first_text(data, &["episode_right_text"])
            .or_else(|| first_text(map, &["episode_right_text"]))
            .unwrap_or_default();
        let release_status = release_status_from(data, &remark);
        let mut tags = string_list(data.get("tags"));
        for value in list(data.get("category_list")) {
            if let Some(name) = value.get("name").and_then(Value::as_str) {
                push_unique(&mut tags, name);
            }
        }
        if let Some(schema) = first_text(data, &["category_schema"]) {
            if let Ok(parsed) = serde_json::from_str::<Vec<Value>>(&schema) {
                for item in parsed {
                    if let Some(name) = item.get("name").and_then(Value::as_str) {
                        push_unique(&mut tags, name);
                    }
                }
            }
        }
        let category = first_text(data, &["category_name", "categoryName", "category"])
            .or_else(|| tags.first().cloned())
            .unwrap_or_else(|| category.to_string());
        Some(Self {
            series_id,
            title,
            description,
            cover,
            category,
            episodes,
            tags,
            views: first_text(data, &["series_play_cnt", "play_cnt"]).unwrap_or_default(),
            heat: heat_from(data),
            release_status,
            online_date: online_date_from(data),
        })
    }
}

/// 完结状态：`series_status` 优先，其次看 `episode_right_text` 的文案。
fn release_status_from(data: &serde_json::Map<String, Value>, remark: &str) -> String {
    match first_text(data, &["series_status"]).as_deref() {
        Some("1") => return "finished".to_string(),
        Some("0") => return "ongoing".to_string(),
        _ => {}
    }
    if remark.contains("完结") || remark.contains("全") {
        "finished".to_string()
    } else if remark.contains("更新") {
        "ongoing".to_string()
    } else {
        String::new()
    }
}

/// 热度：优先 `heat`，其次 `series_play_cnt` 换算成带单位的展示值。
fn heat_from(data: &serde_json::Map<String, Value>) -> String {
    if let Some(text) = first_text(data, &["heat"]) {
        return text;
    }
    let Some(raw) = first_text(data, &["series_play_cnt", "play_cnt"]) else {
        return String::new();
    };
    let Ok(value) = raw.parse::<u64>() else {
        return String::new();
    };
    if value >= 100_000_000 {
        format!("{:.1}亿", value as f64 / 100_000_000.0)
    } else if value >= 10_000 {
        format!("{:.1}万", value as f64 / 10_000.0)
    } else {
        value.to_string()
    }
}

fn online_date_from(data: &serde_json::Map<String, Value>) -> String {
    for key in ["online_date", "publish_time", "create_time"] {
        if let Some(text) = first_text(data, &[key]) {
            // 时间戳的情况下只保留日期部分，前端按 `YYYY-MM-DD` 展示。
            if text.chars().all(|c| c.is_ascii_digit()) && text.len() >= 10 {
                if let Ok(seconds) = text[..10].parse::<i64>() {
                    return format_date(seconds);
                }
            }
            return text;
        }
    }
    String::new()
}

/// 把 Unix 秒转成 `YYYY-MM-DD`（UTC）。实现保持极简，不引入 chrono。
fn format_date(seconds: i64) -> String {
    let days = seconds.div_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    format!("{year:04}-{month:02}-{day:02}")
}

/// Howard Hinnant 的 `civil_from_days` 算法。
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

fn first_text(map: &serde_json::Map<String, Value>, keys: &[&str]) -> Option<String> {
    for key in keys {
        match map.get(*key) {
            Some(Value::String(text)) if !text.trim().is_empty() => {
                return Some(text.trim().to_string())
            }
            Some(Value::Number(number)) => return Some(number.to_string()),
            _ => {}
        }
    }
    None
}

fn list(value: Option<&Value>) -> &[Value] {
    match value {
        Some(Value::Array(items)) => items,
        _ => &[],
    }
}

fn string_list(value: Option<&Value>) -> Vec<String> {
    list(value)
        .iter()
        .filter_map(|item| item.as_str().map(str::to_string))
        .collect()
}

fn push_unique(target: &mut Vec<String>, value: &str) {
    if !value.trim().is_empty() && !target.iter().any(|item| item == value) {
        target.push(value.trim().to_string());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_router_data_with_window_prefix() {
        let raw = r#"<script>window._ROUTER_DATA = {"loaderData":{"category_page":{"isSuccess":true}}};</script>"#;
        let data = parse_router_data(raw).expect("router data");
        assert_eq!(data["loaderData"]["category_page"]["isSuccess"], true);
    }

    #[test]
    fn tolerates_missing_marker() {
        assert!(parse_router_data("<html>no data</html>").is_none());
    }

    #[test]
    fn loader_map_prefers_exact_name_then_prefix() {
        let data: Value =
            serde_json::from_str(r#"{"loaderData":{"detail_$id":{"hit":true},"other":{}}}"#)
                .expect("json");
        let page = router_loader_map(&data, &["detail_page", "detail_"]).expect("page");
        assert_eq!(page["hit"], true);
    }

    #[test]
    fn drama_maps_go_fields() {
        let value: Value = serde_json::from_str(
            r#"{
                "video_data": {
                    "series_id": 12345,
                    "series_title": "示例剧",
                    "series_intro": "简介",
                    "series_cover": "https://cdn.test/c.jpg",
                    "episode_cnt": "24",
                    "episode_right_text": "全24集",
                    "series_status": "1",
                    "tags": ["都市", "逆袭"],
                    "category_schema": "[{\"name\":\"甜宠\"}]",
                    "series_play_cnt": "123456789",
                    "online_date": "1700000000"
                }
            }"#,
        )
        .expect("json");
        let drama = HongguoDrama::from_value(&value, "真人剧").expect("drama");
        assert_eq!(drama.series_id, "12345");
        assert_eq!(drama.title, "示例剧");
        assert_eq!(drama.episodes, 24);
        assert_eq!(drama.category, "都市");
        assert_eq!(drama.tags, vec!["都市", "逆袭", "甜宠"]);
        assert_eq!(drama.release_status, "finished");
        assert_eq!(drama.heat, "1.2亿");
        assert_eq!(drama.online_date, "2023-11-14");
    }

    #[test]
    fn rejects_non_numeric_series_id() {
        let value: Value = serde_json::from_str(r#"{"series_id": "abc"}"#).expect("json");
        assert!(HongguoDrama::from_value(&value, "真人剧").is_none());
    }

    #[test]
    fn falls_back_to_top_level_fields() {
        let value: Value =
            serde_json::from_str(r#"{"series_id":"7","series_name":"顶层","episode_cnt":"3"}"#)
                .expect("json");
        let drama = HongguoDrama::from_value(&value, "漫剧").expect("drama");
        assert_eq!(drama.title, "顶层");
        assert_eq!(drama.category, "漫剧");
        assert_eq!(drama.episodes, 3);
    }

    #[test]
    fn date_conversion_matches_civil_algorithm() {
        assert_eq!(format_date(0), "1970-01-01");
        assert_eq!(format_date(86_399), "1970-01-01");
        assert_eq!(format_date(86_400), "1970-01-02");
        assert_eq!(format_date(1_700_000_000), "2023-11-14");
    }

    #[test]
    fn heat_uses_units_above_ten_thousand() {
        let value: Value =
            serde_json::from_str(r#"{"series_id":"1","play_cnt":"23456"}"#).expect("json");
        assert_eq!(
            HongguoDrama::from_value(&value, "").expect("drama").heat,
            "2.3万"
        );
    }
}
