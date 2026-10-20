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

    // 两种承载形态：`loader.content` 直接给结构，或由 `data-fn-args` 脚本注入。
    let content = loader
        .and_then(|loader| loader.get("content"))
        .filter(|value| value.as_object().is_some_and(|map| !map.is_empty()))
        .or_else(|| inline_args(&data, &loader_key));
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
/// `data-script-src='modern-run-router-data-fn'` 的脚本注入。
fn inline_args<'a>(data: &'a Value, loader_key: &str) -> Option<&'a Value> {
    let args = data.get("fnArgs")?;
    let array = args.as_array()?;
    if array.len() != 3 {
        return None;
    }
    let route = array[0].as_str()?;
    let field = array[1].as_str()?;
    if route != loader_key || field != "content" {
        return None;
    }
    Some(&array[2])
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
