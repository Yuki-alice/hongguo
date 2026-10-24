//! 红果的差异化能力：联想、推荐、弹幕、系列剧。
//!
//! 与 Go 版对应关系：
//! - 联想 → `provider_hongguo_suggestions.go`（网页 `/incent_resource/suggestion`）
//! - 推荐 → `provider_hongguo_recommendations.go`（App `/reading/distribution/category/landpage/v/`）
//! - 弹幕 → `ui_playback_danmaku.go`（App `/novel/commentapi/comment/list/<vid>/v1/`）
//! - 系列剧 → `provider_hongguo_search_seasons.go`（标题里的「第 N 季」识别）
//!
//! 所有解析都是纯函数，网络在 `source.rs` 里接。

use serde_json::Value;

use guo_source_api::{
    Danmaku, DanmakuPage, RecommendCursor, RecommendPage, SeriesSeason, SourceError, Suggestion,
};

/// 联想词上限。Go 版也是 10。
pub const SUGGESTION_LIMIT: usize = 10;
/// 弹幕每段上限。与 Go 版一致：90 条足够覆盖一小段，超出说明分段逻辑失效。
pub const DANMAKU_LIMIT: usize = 90;
/// 弹幕时间轴上限（24 小时，与 Go 版 danmakuMaxDurationMS 一致）。
pub const DANMAKU_MAX_WINDOW_MS: i64 = 24 * 60 * 60 * 1000;

/// 解析联想接口返回。
///
/// 结构是 `{"data": [{"name": "…", "word_type": "…"}]}`；`word_type` 只保留
/// Go 版认可的几种，其余清空而不是原样透传——UI 只对这几类做了图标。
pub fn parse_suggestions(body: &str) -> Result<Vec<Suggestion>, SourceError> {
    let root: Value = serde_json::from_str(body)
        .map_err(|err| SourceError::parse("hongguo", format!("联想返回不是 JSON：{err}")))?;
    // 外层键名随站点版本变过三次：`data` → `suggest_words` → `suggest_list`
    // （2026-10 起的形态）。行结构一直是 `name` + `word_type`，因此只补键名。
    let records = root
        .get("suggest_list")
        .and_then(Value::as_array)
        .or_else(|| root.get("data").and_then(Value::as_array))
        .or_else(|| root.get("suggest_words").and_then(Value::as_array))
        .cloned()
        .unwrap_or_default();
    let mut out = Vec::with_capacity(records.len().min(SUGGESTION_LIMIT));
    let mut seen = std::collections::HashSet::new();
    for record in records {
        let name = record
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim()
            .to_string();
        if name.is_empty() {
            continue;
        }
        let key = name.to_lowercase();
        if !seen.insert(key) {
            continue;
        }
        let kind = record
            .get("word_type")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let kind = match kind {
            "short_play_name"
            | "short_play_category"
            | "common_query"
            | "actor_name"
            | "short_play_actor" => kind.to_string(),
            _ => String::new(),
        };
        out.push(Suggestion { name, kind });
        if out.len() == SUGGESTION_LIMIT {
            break;
        }
    }
    Ok(out)
}

/// 从联想接口的返回里提取**可点开的剧集**。
///
/// 联想结果比「联想词」多一层信息：`word_type == "short_play_name"` 的行带
/// 完整 `video_data`（`series_id` / 封面 / 集数 / 简介 / 分类）。网页搜索页
/// 在 2026-10 改为客户端渲染后不可解析，这条路是当前的搜索数据来源。
///
/// 过滤规则与 Go 版 `fetchHongguoSearchNames` 一致：
/// - 只要 `short_play_name`（其它类型是分类词 / 演员名，不可当剧集）；
/// - `video_data.series_id` 必须是纯数字；
/// - 标题不能等于 id（站点偶尔把 id 当标题回传）。
pub fn parse_suggestion_dramas(body: &str) -> Result<Vec<guo_source_api::Drama>, SourceError> {
    let root: Value = serde_json::from_str(body)
        .map_err(|err| SourceError::parse("hongguo", format!("联想返回不是 JSON：{err}")))?;
    let records = root
        .get("suggest_list")
        .and_then(Value::as_array)
        .or_else(|| root.get("data").and_then(Value::as_array))
        .or_else(|| root.get("suggest_words").and_then(Value::as_array))
        .cloned()
        .unwrap_or_default();
    let mut out = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for record in records {
        if record.get("word_type").and_then(Value::as_str) != Some("short_play_name") {
            continue;
        }
        let Some(video) = record.get("video_data").and_then(Value::as_object) else {
            continue;
        };
        let series_id = ["series_id_str", "series_id"]
            .iter()
            .find_map(|key| match video.get(*key) {
                Some(Value::String(text)) => Some(text.clone()),
                Some(Value::Number(number)) => Some(number.to_string()),
                _ => None,
            })
            .unwrap_or_default();
        if series_id.is_empty()
            || series_id.len() > 32
            || !series_id.chars().all(|c| c.is_ascii_digit())
        {
            continue;
        }
        let title = ["series_title", "name"]
            .iter()
            .find_map(|key| video.get(*key).and_then(Value::as_str))
            .unwrap_or_default()
            .trim()
            .to_string();
        let fallback_title = record
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim()
            .to_string();
        let title = if title.is_empty() { fallback_title } else { title };
        if title.is_empty() || title == series_id {
            continue;
        }
        if !seen.insert(series_id.clone()) {
            continue;
        }
        out.push(guo_source_api::Drama {
            id: guo_source_api::Drama::identity("hongguo", &series_id),
            source: "hongguo".into(),
            source_id: series_id,
            title,
            description: video
                .get("series_intro")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            cover: video
                .get("series_cover")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            episodes: video
                .get("episode_cnt")
                .and_then(|value| match value {
                    Value::Number(number) => number.as_u64(),
                    Value::String(text) => text.trim().parse().ok(),
                    _ => None,
                })
                .unwrap_or(0) as u32,
            category: "短剧".into(),
            heat: video
                .get("hot_score_data")
                .and_then(|value| value.get("text"))
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            ..Default::default()
        });
    }
    Ok(out)
}

/// 构造推荐请求体。抽成纯函数便于对拍字段名。
///
/// 关键点与 Go 一致：
/// - `client_req_type` 首屏是 3，翻页是 2（站点用这个区分「首次」与「继续」）；
/// - `select_items.genre` 决定频道；
/// - 翻页要原样回传 `session_id`，否则会退化成首屏。
pub fn recommend_payload(cursor: &RecommendCursor, genre: &str) -> Value {
    let genre = if cursor.genre.is_empty() {
        genre.to_string()
    } else {
        cursor.genre.clone()
    };
    let mut payload = serde_json::json!({
        "req_scene": scene_for(&genre),
        "offset": cursor.offset,
        "limit": 18,
        "req_type": "only_content",
        "need_selector_panel": false,
        "client_req_type": if cursor.offset > 0 { 2 } else { 3 },
        "session_id": cursor.session_id,
        "filter_ids": "",
        "select_items": {
            "genre": [genre],
            "sort": [],
            "gender": [],
            "category_dim_theme": [],
            "category_dim_role": [],
            "category_dim_epoch": [],
            "online_time": [],
            "creation_status": [],
        },
    });
    if cursor.offset == 0 {
        // 首屏不需要 session_id 字段；留空串会让部分网关判为非法。
        if let Some(map) = payload.as_object_mut() {
            map.remove("session_id");
        }
    }
    payload
}

fn scene_for(genre: &str) -> &'static str {
    match genre {
        "comic_series" => "comic_series",
        "ai_series" => "ai_series",
        _ => "default",
    }
}

/// 解析推荐页。
pub fn parse_recommend_page(root: &Value) -> Result<RecommendPage, SourceError> {
    let data = root
        .get("data")
        .ok_or_else(|| SourceError::parse("hongguo", "推荐接口缺少 data"))?;
    let rows = data
        .get("video_data")
        .and_then(Value::as_array)
        .ok_or_else(|| SourceError::parse("hongguo", "推荐接口缺少 video_data"))?;
    let has_more = data
        .get("has_more")
        .and_then(Value::as_bool)
        .ok_or_else(|| SourceError::parse("hongguo", "推荐接口缺少 has_more"))?;
    let next_offset = data
        .get("next_offset")
        .and_then(|value| match value {
            Value::Number(number) => number.as_u64().map(|value| value as u32),
            Value::String(text) => text.trim().parse().ok(),
            _ => None,
        })
        .ok_or_else(|| SourceError::parse("hongguo", "推荐接口缺少 next_offset"))?;
    let session_id = data
        .get("session_id")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();

    let mut items = Vec::with_capacity(rows.len());
    let mut recognized = 0usize;
    let mut seen = std::collections::HashSet::new();
    for row in rows {
        let Some(drama) = crate::router::HongguoDrama::from_value(row, "") else {
            continue;
        };
        recognized += 1;
        let drama = drama.into_drama();
        if seen.insert(drama.id.clone()) {
            items.push(drama);
        }
    }
    if !rows.is_empty() && recognized == 0 {
        return Err(SourceError::parse("hongguo", "推荐未返回可识别的剧集"));
    }
    Ok(RecommendPage {
        items,
        cursor: RecommendCursor {
            offset: next_offset,
            session_id,
            genre: String::new(),
        },
        has_more,
    })
}

/// 解析弹幕接口返回（2026-10-24 实测形态）。
///
/// 结构是 `{"data": {"data_list": [{"comment": {"common": {...}, "expand":
/// {"offset_time": ms}}}], "extra": {"next_query_danmaku_list_time": ms}}}`。
/// 过滤规则与 Go 版 `parseHongguoDanmaku` 一致：
/// - `common.group_id` 必须等于请求的 `video_id`；
/// - `common.status` 必须是 1（运营插入的活动行 status 为 0，借此排除）；
/// - `offset_time` 落在 `[start_ms, next)`；
/// - `comment_id` 非空、去重；正文去控制字符、超长截断。
///
/// 返回的 `end_ms` 是服务端给的真实窗口结束（`next_query_danmaku_list_time`），
/// 调用方必须用它推进游标——自己按 60s 估算会跳过服务端切成 30s 的段。
pub fn parse_danmaku(
    body: &str,
    video_id: &str,
    start_ms: i64,
) -> Result<DanmakuPage, SourceError> {
    let root: Value = serde_json::from_str(body)
        .map_err(|err| SourceError::parse("hongguo", format!("弹幕返回不是 JSON：{err}")))?;
    let code = root
        .get("code")
        .or_else(|| root.get("BaseResp").and_then(|base| base.get("StatusCode")))
        .map(|value| match value {
            Value::Number(number) => number.to_string(),
            Value::String(text) => text.clone(),
            _ => String::new(),
        })
        .unwrap_or_default();
    if !code.is_empty() && code != "0" {
        return Err(SourceError::parse(
            "hongguo",
            format!("弹幕接口返回 {code}"),
        ));
    }
    let data = root
        .get("data")
        .ok_or_else(|| SourceError::parse("hongguo", "弹幕接口缺少 data"))?;
    let rows = data
        .get("data_list")
        .and_then(Value::as_array)
        .ok_or_else(|| SourceError::parse("hongguo", "弹幕接口缺少 data_list"))?;
    let next = data
        .get("extra")
        .and_then(|extra| extra.get("next_query_danmaku_list_time"))
        .and_then(value_to_i64)
        .ok_or_else(|| SourceError::parse("hongguo", "弹幕接口缺少分段游标"))?;
    if next <= start_ms || next > DANMAKU_MAX_WINDOW_MS {
        return Err(SourceError::parse("hongguo", "弹幕时间段格式无效"));
    }

    let mut items = Vec::with_capacity(rows.len().min(DANMAKU_LIMIT));
    let mut seen = std::collections::HashSet::new();
    for row in rows {
        let Some(comment) = row.get("comment") else {
            continue;
        };
        let Some(common) = comment.get("common") else {
            continue;
        };
        if text_field(common, &["group_id"]) != video_id {
            continue;
        }
        // 活动插入行（「参与弹幕活动」）的 status 是 0；真实弹幕是 1。
        let status = text_field(common, &["status"]);
        if !status.is_empty() && status != "1" {
            continue;
        }
        let Some(position) = comment
            .get("expand")
            .and_then(|expand| expand.get("offset_time"))
            .and_then(value_to_i64)
        else {
            continue;
        };
        let text = common
            .get("content")
            .and_then(|content| content.get("text"))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .chars()
            .map(|c| if c.is_control() || c == '\u{2028}' || c == '\u{2029}' { ' ' } else { c })
            .collect::<String>()
            .trim()
            .to_string();
        let id = text_field(comment, &["comment_id"]);
        if position < start_ms
            || position >= next
            || text.is_empty()
            || id.is_empty()
            || id.len() > 120
            || !seen.insert(id.clone())
        {
            continue;
        }
        let text = if text.chars().count() > 180 {
            let cut: String = text.chars().take(180).collect();
            format!("{cut}…")
        } else {
            text
        };
        items.push(Danmaku {
            time_ms: position,
            text,
            color: String::new(),
        });
        if items.len() == DANMAKU_LIMIT {
            break;
        }
    }
    items.sort_by_key(|item| item.time_ms);
    Ok(DanmakuPage {
        items,
        end_ms: next,
        has_more: next < DANMAKU_MAX_WINDOW_MS,
    })
}

fn value_to_i64(value: &Value) -> Option<i64> {
    match value {
        Value::Number(number) => number.as_i64(),
        Value::String(text) => text.trim().parse().ok(),
        _ => None,
    }
}

fn text_field(value: &Value, keys: &[&str]) -> String {
    for key in keys {
        match value.get(*key) {
            Some(Value::String(text)) => return text.clone(),
            Some(Value::Number(number)) => return number.to_string(),
            _ => {}
        }
    }
    String::new()
}

/// 从标题里识别「第 N 季」。
///
/// 支持 `第2季`、`第二季`、`Season 2`、`S2` 四种写法；识别不到返回 `None`
/// （调用方据此认为该剧没有分季，而不是当成第 1 季）。
pub fn season_of(title: &str) -> Option<u32> {
    let title = title.trim();
    if title.is_empty() {
        return None;
    }
    // `第2季` / `第二季`
    if let Some(index) = title.find('第') {
        let rest = &title[index + '第'.len_utf8()..];
        let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
        if let Ok(number) = digits.parse::<u32>() {
            if rest[digits.len()..].starts_with('季') {
                return valid_season(number);
            }
        }
        let chinese: String = rest.chars().take_while(|c| is_chinese_digit(*c)).collect();
        if !chinese.is_empty() && rest[chinese.len()..].starts_with('季') {
            return chinese_number(&chinese).and_then(valid_season);
        }
    }
    // `Season 2` / `season2` / `S2`
    let lower = title.to_lowercase();
    for marker in ["season", "s"] {
        if let Some(index) = lower.find(marker) {
            let rest = &lower[index + marker.len()..];
            let rest = rest.trim_start_matches([' ', '-', '_', ':']);
            let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
            if !digits.is_empty() {
                // 单独的 `s` 太容易误判（如 `sweet`），要求后面紧跟数字且前面是边界。
                if marker == "s" && index > 0 {
                    let previous = lower[..index].chars().next_back().unwrap_or(' ');
                    if previous.is_alphanumeric() {
                        continue;
                    }
                }
                return digits.parse::<u32>().ok().and_then(valid_season);
            }
        }
    }
    None
}

fn valid_season(number: u32) -> Option<u32> {
    // 200 季明显是标题里的其它数字，不是季号。
    (1..=200).contains(&number).then_some(number)
}

fn is_chinese_digit(c: char) -> bool {
    matches!(
        c,
        '零' | '一' | '二' | '三' | '四' | '五' | '六' | '七' | '八' | '九' | '十'
    )
}

/// 只支持 1..=99 的中文数字（季号不会有更大值）。
fn chinese_number(text: &str) -> Option<u32> {
    let value = match text {
        "零" => 0,
        "一" => 1,
        "二" => 2,
        "三" => 3,
        "四" => 4,
        "五" => 5,
        "六" => 6,
        "七" => 7,
        "八" => 8,
        "九" => 9,
        "十" => 10,
        "十一" => 11,
        "十二" => 12,
        _ => {
            // `二十`、`二十一` 这类两位数。
            if let Some(rest) = text.strip_prefix('十') {
                return chinese_number(rest).map(|value| 10 + value);
            }
            let (tens, ones) = text.split_once('十')?;
            let tens = chinese_number(tens)?;
            let ones = if ones.is_empty() {
                0
            } else {
                chinese_number(ones)?
            };
            return Some(tens * 10 + ones);
        }
    };
    Some(value)
}

/// 搜索系列剧时用的关键词：去掉季号后的主标题。
///
/// 直接拿「总裁的第2季」去搜只会命中第 2 季，拿「总裁」才能搜到全部分季。
pub fn base_title_for_search(title: &str) -> String {
    let trimmed = title.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    // `base_title` 会转小写用于比对，搜索要保留原始大小写，因此这里单独裁剪。
    let mut base = trimmed.to_string();
    for marker in ["第", "Season", "season"] {
        if let Some(index) = base.find(marker) {
            let tail = &base[index..];
            if tail.contains('季') || tail.to_lowercase().contains("season") {
                base.truncate(index);
                break;
            }
        }
    }
    base.trim()
        .trim_end_matches([' ', '-', '_', '·', '：', ':'])
        .to_string()
}

/// 把同一部剧的不同季聚合成 `SeriesSeason` 列表。
///
/// 入参是「候选剧目」（通常来自搜索），返回按季号排序的结果。
/// 只有季号识别得到、且主标题（去掉季号后）一致时才归入同一系列。
pub fn group_seasons(
    reference_title: &str,
    candidates: &[guo_source_api::Drama],
) -> Vec<SeriesSeason> {
    let reference = base_title(reference_title);
    if reference.is_empty() {
        return Vec::new();
    }
    let mut out: Vec<SeriesSeason> = Vec::new();
    for drama in candidates {
        let Some(season) = season_of(&drama.title) else {
            continue;
        };
        if base_title(&drama.title) != reference {
            continue;
        }
        if out.iter().any(|item| item.source_id == drama.source_id) {
            continue;
        }
        out.push(SeriesSeason {
            season,
            title: drama.title.clone(),
            source_id: drama.source_id.clone(),
        });
    }
    out.sort_by_key(|item| item.season);
    out
}

/// 去掉标题里的季号与修饰，得到用于比对的主标题。
fn base_title(title: &str) -> String {
    let mut base = title.trim().to_string();
    for marker in ["第", "Season", "season", "S"] {
        if let Some(index) = base.find(marker) {
            // 只在「标记 + 数字/中文数字 + 季」或「Season N」形态下裁剪。
            let tail = &base[index..];
            if tail.contains('季') || tail.to_lowercase().contains("season") {
                base.truncate(index);
                break;
            }
        }
    }
    base.trim()
        .trim_end_matches([' ', '-', '_', '·', '：', ':'])
        .to_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn suggestions_parse_and_dedupe() {
        let body = r#"{"data":[
            {"name":"总裁","word_type":"short_play_name"},
            {"name":"总裁","word_type":"common_query"},
            {"name":"  ","word_type":"short_play_name"},
            {"name":"演员甲","word_type":"actor_name"},
            {"name":"未知类型","word_type":"weird"}
        ]}"#;
        let items = parse_suggestions(body).expect("解析成功");
        assert_eq!(items.len(), 3);
        assert_eq!(items[0].name, "总裁");
        assert_eq!(items[1].kind, "actor_name");
        assert_eq!(items[2].kind, "", "未知类型应清空而不是透传");
    }

    #[test]
    fn suggestions_reject_non_json() {
        assert!(parse_suggestions("<html>").is_err());
    }

    #[test]
    fn recommend_payload_marks_first_page() {
        let cursor = RecommendCursor::default();
        let payload = recommend_payload(&cursor, "short_play");
        assert_eq!(payload["client_req_type"], 3);
        assert!(payload.get("session_id").is_none(), "首屏不应带 session_id");
        assert_eq!(payload["select_items"]["genre"][0], "short_play");
        assert_eq!(payload["limit"], 18);
    }

    #[test]
    fn recommend_payload_keeps_session_on_paging() {
        let cursor = RecommendCursor {
            offset: 18,
            session_id: "abc".into(),
            genre: "comic_series".into(),
        };
        let payload = recommend_payload(&cursor, "short_play");
        assert_eq!(payload["client_req_type"], 2);
        assert_eq!(payload["session_id"], "abc");
        // 游标里的 genre 优先于调用方传入的。
        assert_eq!(payload["select_items"]["genre"][0], "comic_series");
        assert_eq!(payload["req_scene"], "comic_series");
    }

    #[test]
    fn recommend_page_parses_and_dedupes() {
        let root: Value = serde_json::from_str(
            r#"{"data":{"video_data":[
                {"series_id":111,"series_title":"甲"},
                {"series_id":111,"series_title":"甲"},
                {"series_id":222,"series_title":"乙"}
            ],"has_more":true,"next_offset":"18","session_id":"s1"}}"#,
        )
        .expect("json");
        let page = parse_recommend_page(&root).expect("解析成功");
        assert_eq!(page.items.len(), 2);
        assert_eq!(page.cursor.offset, 18);
        assert_eq!(page.cursor.session_id, "s1");
        assert!(page.has_more);
    }

    #[test]
    fn recommend_page_rejects_missing_fields() {
        let root: Value = serde_json::from_str(r#"{"data":{"video_data":[]}}"#).expect("json");
        assert!(parse_recommend_page(&root).is_err());
    }

    /// 构造 2026-10-24 实测形态的弹幕夹具（用 json! 拼装，避免转义错误）。
    fn danmaku_body(rows: &str, next: i64) -> String {
        // rows 是多行 JSON 对象用逗号拼接的串，包上方括号才是合法数组。
        let rows: Value = serde_json::from_str(&format!("[{rows}]")).expect("行数组");
        serde_json::json!({
            "code": 0,
            "data": {"data_list": rows, "extra": {"next_query_danmaku_list_time": next}}
        })
        .to_string()
    }

    fn danmaku_row(id: &str, offset: i64, text: &str, status: i64) -> String {
        serde_json::json!({
            "data_type": 4,
            "comment": {
                "comment_id": id,
                "common": {"group_id": "vid1", "status": status, "content": {"text": text}},
                "expand": {"offset_time": offset},
            }
        })
        .to_string()
    }

    #[test]
    fn danmaku_filters_window_and_sorts() {
        let body = danmaku_body(
            &[
                danmaku_row("b", 5000, "后", 1),
                danmaku_row("a", 1000, "前", 1),
                danmaku_row("c", 99, "窗口外", 1),
                danmaku_row("d", 1200, "", 1),
                danmaku_row("e", 1500, "活动插入", 0),
                danmaku_row("a", 1000, "重复 id", 1),
            ]
            .join(","),
            6000,
        );
        // 窗口从 500 开始：99 在窗口外、空文本丢弃、status=0 的活动行丢弃、
        // 重复 comment_id 只留第一条；剩下的按时间排序。
        let page = parse_danmaku(&body, "vid1", 500).expect("解析成功");
        assert_eq!(page.items.len(), 2);
        assert_eq!(page.items[0].time_ms, 1000, "必须按时间排序");
        assert_eq!(page.items[0].text, "前");
        assert_eq!(page.items[1].text, "后");
        assert_eq!(page.end_ms, 6000, "窗口结束取服务端游标");
    }

    #[test]
    fn danmaku_rejects_missing_or_invalid_windows() {
        // 缺 data_list / 缺游标 / 游标不在 (start, 24h] 内，都要报错。
        assert!(parse_danmaku(r#"{"data":{}}"#, "vid1", 0).is_err());
        assert!(parse_danmaku(
            &danmaku_body(&danmaku_row("a", 1, "x", 1), 0),
            "vid1",
            0
        )
        .is_err());
        let too_far = DANMAKU_MAX_WINDOW_MS + 1;
        assert!(parse_danmaku(
            &danmaku_body(&danmaku_row("a", 1, "x", 1), too_far),
            "vid1",
            0
        )
        .is_err());
    }

    #[test]
    fn danmaku_rejects_business_error_code() {
        let body = r#"{"Code":110001,"Message":"未知异常","BaseResp":{"StatusCode":110001}}"#;
        assert!(parse_danmaku(body, "vid1", 0).is_err());
    }

    #[test]
    fn danmaku_truncates_overlong_text() {
        let long = "长".repeat(200);
        let body = danmaku_body(&danmaku_row("a", 100, &long, 1), 1000);
        let page = parse_danmaku(&body, "vid1", 0).expect("解析成功");
        assert_eq!(page.items[0].text.chars().count(), 181, "180 字 + 省略号");
    }

    #[test]
    fn season_detection_covers_common_forms() {
        assert_eq!(season_of("总裁的第2季"), Some(2));
        assert_eq!(season_of("总裁的第二季"), Some(2));
        assert_eq!(season_of("总裁 Season 3"), Some(3));
        assert_eq!(season_of("总裁 season4"), Some(4));
        assert_eq!(season_of("总裁 S2"), Some(2));
        assert_eq!(season_of("总裁"), None);
        assert_eq!(season_of(""), None);
        // 标题里的其它数字不应被当成季号。
        assert_eq!(season_of("80集全"), None);
        assert_eq!(season_of("Sweet Home"), None);
    }

    #[test]
    fn chinese_numbers_cover_two_digits() {
        assert_eq!(chinese_number("十"), Some(10));
        assert_eq!(chinese_number("十二"), Some(12));
        assert_eq!(chinese_number("二十"), Some(20));
        assert_eq!(chinese_number("二十一"), Some(21));
        assert_eq!(chinese_number("x"), None);
    }

    #[test]
    fn seasons_group_only_matching_titles() {
        let dramas = vec![
            guo_source_api::Drama {
                title: "总裁的第1季".into(),
                source_id: "1".into(),
                ..Default::default()
            },
            guo_source_api::Drama {
                title: "总裁的第2季".into(),
                source_id: "2".into(),
                ..Default::default()
            },
            guo_source_api::Drama {
                title: "别的剧第3季".into(),
                source_id: "3".into(),
                ..Default::default()
            },
        ];
        let seasons = group_seasons("总裁的第1季", &dramas);
        assert_eq!(seasons.len(), 2);
        assert_eq!(seasons[0].season, 1);
        assert_eq!(seasons[1].source_id, "2");
    }

    #[test]
    fn seasons_empty_for_unknown_title() {
        assert!(group_seasons("总裁", &[]).is_empty());
        assert!(group_seasons("", &[]).is_empty());
    }
}
