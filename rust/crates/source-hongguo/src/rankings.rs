//! 红果榜单。
//!
//! 与 Go 版 `provider_rankings_hongguo.go` / `provider_rankings_parse.go` 对齐：
//! 页面数据同样藏在 `_ROUTER_DATA` 里，但榜单用的是 `rank_<path>/page` 这一类
//! **带前缀的 loader key**，并且额外校验 `rankKey` 与 `pageNum`——
//! 站点若把请求悄悄重定向到别的榜单，拿到的数据必须被拒绝，而不是当成目标榜单展示。

use serde_json::Value;

use guo_source_api::{RankingBoard, RankingItem, RankingPage, SourceError};

use crate::router::{parse_router_data, router_loader_map};

/// 红果的四个榜单看板。`upstream_key` 用于校验站点返回的是不是同一个榜单。
pub const BOARDS: [(&str, &str, &str, &str); 4] = [
    ("hongguo-hot", "总热播榜", "hot-drama", "hongguo"),
    ("hongguo-real", "真人剧榜", "hot-real-drama", "real"),
    ("hongguo-comic", "漫剧榜", "hot-comic-drama", "comic"),
    ("hongguo-ai", "AI剧榜", "hot-ai-drama", "ai"),
];

/// 每页条数固定为 20：站点用「名次落在 (page-1)*20+1 ..= page*20」来分页，
/// 换页大小会让名次校验失去意义。
pub const PAGE_SIZE: u32 = 20;

pub fn boards() -> Vec<RankingBoard> {
    BOARDS
        .iter()
        .map(|(id, name, _, _)| RankingBoard {
            id: (*id).to_string(),
            name: (*name).to_string(),
            group: "hongguo".to_string(),
        })
        .collect()
}

/// 按 id 找看板，返回 `(id, name, path, upstream_key)`。
pub fn find_board(id: &str) -> Option<(&'static str, &'static str, &'static str, &'static str)> {
    BOARDS.iter().copied().find(|board| board.0 == id)
}

/// 榜单页地址。第 1 页不带 `?page=`（真实站点即如此）。
pub fn board_path(path: &str, page: u32) -> String {
    if page <= 1 {
        format!("/rank/{path}")
    } else {
        format!("/rank/{path}?page={page}")
    }
}

/// 解析榜单页。
///
/// 失败语义分两类，与 Go 一致：
/// - **数据尚未完整**（`content` 为空）：可重试；
/// - **格式或分页不符**：不可重试，说明站点改版或返回了别的榜单。
pub fn parse_ranking_page(body: &str, board: &str, page: u32) -> Result<RankingPage, SourceError> {
    let (_, _, path, upstream_key) = find_board(board)
        .ok_or_else(|| SourceError::parse("hongguo", format!("未知榜单 {board}")))?;
    if page == 0 || page > 500 {
        return Err(SourceError::parse(
            "hongguo",
            format!("榜单页码越界：{page}"),
        ));
    }

    let data = parse_router_data(body)
        .ok_or_else(|| SourceError::parse("hongguo", "榜单页里没有 _ROUTER_DATA"))?;
    let loader_key = format!("rank_{path}/page");
    let loader = router_loader_map(&data, &[loader_key.as_str(), "rank_"]);
    // 校验站点返回的是同一个榜单、同一页；不一致说明被重定向或被改写。
    if let Some(loader) = loader {
        let returned_key = text(loader, &["rankKey"]);
        let returned_page = text(loader, &["pageNum"]);
        if !returned_key.is_empty() && returned_key != upstream_key {
            return Err(SourceError::parse(
                "hongguo",
                format!("返回了其它榜单（{returned_key}），不是 {upstream_key}"),
            ));
        }
        if !returned_page.is_empty() && returned_page != page.to_string() {
            return Err(SourceError::parse(
                "hongguo",
                format!("返回了第 {returned_page} 页，不是第 {page} 页"),
            ));
        }
    }

    // 三种承载形态，按顺序尝试：
    // 1. `loader.content` 直接给结构（服务端渲染完整时）；
    // 2. `_ROUTER_DATA.fnArgs`（旧形态）；
    // 3. `mergeLoaderData` 脚本属性（2026-10 起的形态）。
    let owned;
    let content = match loader
        .and_then(|loader| loader.get("content"))
        .filter(|value| value.as_object().is_some_and(|map| !map.is_empty()))
    {
        Some(content) => Some(content),
        None => {
            if let Some(content) = inline_args(&data, &loader_key) {
                Some(content)
            } else {
                owned = merge_loader_content(body, &loader_key);
                owned.as_ref()
            }
        }
    };
    let content =
        content.ok_or_else(|| SourceError::parse("hongguo", "榜单数据尚未完整返回，请稍后重试"))?;

    if content.get("isSuccess").and_then(Value::as_bool) == Some(false) {
        return Err(SourceError::parse(
            "hongguo",
            "榜单接口返回 isSuccess=false",
        ));
    }
    let Some(rows) = content.get("rankList").and_then(Value::as_array) else {
        return Err(SourceError::parse("hongguo", "榜单缺少 rankList"));
    };
    let total_pages = content
        .get("pagination")
        .and_then(|value| value.get("totalPages"))
        .and_then(number)
        .unwrap_or(1)
        .clamp(1, 500);
    let returned_page = content
        .get("pagination")
        .and_then(|value| value.get("pageNum"))
        .and_then(number)
        .unwrap_or(page);
    if returned_page != page || total_pages < page {
        return Err(SourceError::parse("hongguo", "榜单分页与请求不一致"));
    }

    let mut items = Vec::with_capacity(rows.len());
    let mut previous = (page - 1) * PAGE_SIZE;
    let mut seen = std::collections::HashSet::new();
    for row in rows {
        let id = first_text(row, &["seriesId", "id"]);
        let rank = row.get("rank").and_then(number).unwrap_or(0);
        let title = text(row, &["title"]);
        let invalid = !is_numeric_id(&id)
            || title.trim().is_empty()
            || rank == 0
            || rank <= previous
            || rank > page * PAGE_SIZE
            || !seen.insert(id.clone());
        if invalid {
            return Err(SourceError::parse(
                "hongguo",
                "榜单条目名次或主键不合法（站点结构可能已变化）",
            ));
        }
        previous = rank;
        let mut drama = crate::router::HongguoDrama::from_value(row, "")
            .map(|drama| drama.into_drama())
            .unwrap_or_else(|| guo_source_api::Drama {
                id: guo_source_api::Drama::identity("hongguo", &id),
                source: "hongguo".into(),
                source_id: id.clone(),
                title: title.clone(),
                ..Default::default()
            });
        // 榜单行自带的信息比通用映射更权威。
        drama.title = title;
        if let Some(heat) = row.get("heatText").and_then(Value::as_str) {
            drama.heat = heat.to_string();
        }
        items.push(RankingItem {
            rank,
            drama,
            metric: text(row, &["heatText", "scoreText"]),
        });
    }
    if items.is_empty() && page < total_pages {
        return Err(SourceError::parse(
            "hongguo",
            "榜单数据尚未完整返回，请稍后重试",
        ));
    }

    Ok(RankingPage {
        items,
        has_more: page < total_pages,
        page,
        updated_text: loader
            .map(|loader| text(loader, &["updatedText"]))
            .unwrap_or_default(),
        stale: false,
        warning: String::new(),
    })
}

/// 从 `data-fn-args` 脚本里取 `content`。
///
/// 页面把 loader 数据拆成两段：结构在 `_ROUTER_DATA`，行数据由一段
/// `data-script-src='modern-run-router-data-fn'` 的脚本注入。有两种承载形态：
///
/// 1. `_ROUTER_DATA.fnArgs = [route, "content", {...}]`（旧形态）；
/// 2. `<script data-fn-name="mergeLoaderData" data-fn-args="[route, [{key,
///    routerDataFnName, routerDataFnArgs}]]">`，真正的 JSON 在
///    `routerDataFnArgs[0]` 里，且被 HTML 实体转义（新形态，2026-10 起）。
///
/// 站点会在两者之间来回切，两种都要认，否则榜单会退化成「数据尚未完整」。
fn inline_args<'a>(data: &'a Value, loader_key: &str) -> Option<&'a Value> {
    if let Some(array) = data.get("fnArgs").and_then(Value::as_array) {
        if array.len() == 3 {
            let route = array[0].as_str().unwrap_or_default();
            let field = array[1].as_str().unwrap_or_default();
            if route == loader_key && field == "content" {
                return Some(&array[2]);
            }
        }
    }
    None
}

/// 从 `mergeLoaderData` 脚本属性里取 `content`。
///
/// `raw` 是整页 HTML；`loader_key` 形如 `rank_hot-drama/page`。返回解析后的
/// JSON 值（生命周期与调用方相同）。
pub fn merge_loader_content(raw: &str, loader_key: &str) -> Option<Value> {
    const MARKER: &str = "data-fn-name=\"mergeLoaderData\"";
    let mut offset = 0;
    while let Some(found) = raw[offset..].find(MARKER) {
        let start = offset + found;
        offset = start + MARKER.len();
        // 属性都在同一个开始标签内，取到 `>` 为止即可。
        let Some(tag_end) = raw[offset..].find('>') else {
            continue;
        };
        let tag = &raw[start..offset + tag_end];
        let Some(args) = attribute(tag, "data-fn-args") else {
            continue;
        };
        let decoded = decode_entities(args);
        let Ok(parsed) = serde_json::from_str::<Value>(&decoded) else {
            continue;
        };
        let Some(array) = parsed.as_array() else {
            continue;
        };
        if array.len() != 2 || array[0].as_str() != Some(loader_key) {
            continue;
        }
        let Some(entries) = array[1].as_array() else {
            continue;
        };
        for entry in entries {
            if entry.get("key").and_then(Value::as_str) != Some("content") {
                continue;
            }
            let Some(payload) = entry
                .get("routerDataFnArgs")
                .and_then(Value::as_array)
                .and_then(|args| args.first())
                .and_then(Value::as_str)
            else {
                continue;
            };
            if let Ok(value) = serde_json::from_str::<Value>(payload) {
                return Some(value);
            }
        }
    }
    None
}

/// 取标签里某个属性的原始值（未解码实体）。
fn attribute<'a>(tag: &'a str, name: &str) -> Option<&'a str> {
    let needle = format!("{name}=\"");
    let start = tag.find(&needle)? + needle.len();
    let end = tag[start..].find('"')? + start;
    Some(&tag[start..end])
}

/// 只处理 JSON 里会出现的几个实体。
///
/// 属性值里的 JSON 被转义成 `&quot;`，少数文本还会带 `&amp;` / `&#39;`；
/// 用完整的 HTML 解析器会拖进 `scraper`，这里手写足够且更可控。
fn decode_entities(text: &str) -> String {
    text.replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&amp;", "&")
}

fn text(value: &Value, keys: &[&str]) -> String {
    for key in keys {
        match value.get(*key) {
            Some(Value::String(text)) => return text.trim().to_string(),
            Some(Value::Number(number)) => return number.to_string(),
            _ => {}
        }
    }
    String::new()
}

fn first_text(value: &Value, keys: &[&str]) -> String {
    text(value, keys)
}

fn number(value: &Value) -> Option<u32> {
    match value {
        Value::Number(number) => number.as_u64().map(|value| value as u32),
        Value::String(text) => text.trim().parse().ok(),
        _ => None,
    }
}

fn is_numeric_id(value: &str) -> bool {
    !value.is_empty() && value.len() <= 32 && value.chars().all(|c| c.is_ascii_digit())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(path: &str, page: u32, upstream: &str, ranks: &[(u32, &str)]) -> String {
        // 手写转义太容易错，直接由 serde_json 构造结构再拼成页面。
        use serde_json::json;
        let rows: Vec<serde_json::Value> = ranks
            .iter()
            .map(|(rank, id)| {
                json!({
                    "id": id,
                    "seriesId": id,
                    "rank": rank,
                    "title": format!("剧 {rank}"),
                    "heatText": format!("{rank}万热度"),
                    "episodeVids": ["111"],
                })
            })
            .collect();
        let loader = json!({
            "loaderData": {
                format!("rank_{path}/page"): {
                    "rankKey": upstream,
                    "pageNum": page,
                    "updatedText": "9月13日已更新",
                    "content": {
                        "isSuccess": true,
                        "rankList": rows,
                        "pagination": { "pageNum": page, "totalPages": 2 },
                    },
                }
            }
        });
        format!(
            "<script>window._ROUTER_DATA = {};</script>",
            serde_json::to_string(&loader).expect("serialize")
        )
    }

    #[test]
    fn parses_first_page() {
        let body = fixture("hot-drama", 1, "hongguo", &[(1, "111"), (2, "222")]);
        let page = parse_ranking_page(&body, "hongguo-hot", 1).expect("解析成功");
        assert_eq!(page.items.len(), 2);
        assert_eq!(page.items[0].rank, 1);
        assert_eq!(page.items[0].drama.id, "hongguo:111");
        assert_eq!(page.items[0].metric, "1万热度");
        assert!(page.has_more, "totalPages=2 时第 1 页应还有下一页");
        assert_eq!(page.updated_text, "9月13日已更新");
    }

    #[test]
    fn parses_second_page_with_shifted_ranks() {
        let body = fixture("hot-drama", 2, "hongguo", &[(21, "333"), (22, "444")]);
        let page = parse_ranking_page(&body, "hongguo-hot", 2).expect("解析成功");
        assert_eq!(page.items[0].rank, 21);
        assert!(!page.has_more);
    }

    #[test]
    fn rejects_other_board() {
        // 请求总榜，站点却返回真人剧榜：必须拒绝，不能当总榜展示。
        let body = fixture("hot-drama", 1, "real", &[(1, "111")]);
        let err = parse_ranking_page(&body, "hongguo-hot", 1).expect_err("必须失败");
        assert!(err.to_string().contains("其它榜单"), "{err}");
    }

    #[test]
    fn rejects_wrong_page() {
        let body = fixture("hot-drama", 3, "hongguo", &[(1, "111")]);
        let err = parse_ranking_page(&body, "hongguo-hot", 1).expect_err("必须失败");
        assert!(err.to_string().contains("第 3 页"), "{err}");
    }

    #[test]
    fn rejects_rank_outside_page_window() {
        // 第 1 页出现第 21 名：分页错乱，必须拒绝。
        let body = fixture("hot-drama", 1, "hongguo", &[(21, "111")]);
        let err = parse_ranking_page(&body, "hongguo-hot", 1).expect_err("必须失败");
        assert!(err.to_string().contains("名次"), "{err}");
    }

    #[test]
    fn rejects_duplicate_ids() {
        let body = fixture("hot-drama", 1, "hongguo", &[(1, "111"), (2, "111")]);
        let err = parse_ranking_page(&body, "hongguo-hot", 1).expect_err("必须失败");
        assert!(err.to_string().contains("名次"), "{err}");
    }

    #[test]
    fn rejects_missing_router_data() {
        let err = parse_ranking_page("<html></html>", "hongguo-hot", 1).expect_err("必须失败");
        assert!(err.to_string().contains("_ROUTER_DATA"), "{err}");
    }

    #[test]
    fn missing_content_is_retryable_kind() {
        // loader 存在但没有 content：属于「数据未完整」，错误文案提示稍后重试。
        let body = r#"<script>window._ROUTER_DATA = {"loaderData":{"rank_hot-drama/page":{"rankKey":"hongguo","pageNum":1}}};</script>"#;
        let err = parse_ranking_page(body, "hongguo-hot", 1).expect_err("必须失败");
        assert!(err.to_string().contains("稍后重试"), "{err}");
    }

    #[test]
    fn board_path_omits_page_for_first_page() {
        assert_eq!(board_path("hot-drama", 1), "/rank/hot-drama");
        assert_eq!(board_path("hot-drama", 2), "/rank/hot-drama?page=2");
    }

    #[test]
    fn boards_cover_four_boards() {
        assert_eq!(boards().len(), 4);
        assert!(find_board("hongguo-ai").is_some());
        assert!(find_board("unknown").is_none());
    }
}
