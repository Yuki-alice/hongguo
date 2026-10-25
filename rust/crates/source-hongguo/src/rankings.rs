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

/// 从脚本属性里取 loader 的 `content`。
///
/// 站点换过三次承载形态，全部要认，否则榜单会退化成「数据尚未完整」：
///
/// 1. `data-fn-name="mergeLoaderData"` + `routerDataFnArgs` 里再套一层转义 JSON
///    （2026-10 起的旧形态）；
/// 2. `data-fn-name="r"` + `data-script-src="modern-run-router-data-fn"`，
///    args 直接是 `[loaderKey, "content", {...}]`（2026-10-24 实测形态）；
/// 3. `data-fn-name="s"`，args 是 `[loaderKey, [{key, routerDataFnArgs:[...]}]]`，
///    与 mergeLoaderData 结构相同、只是函数名不同。
///
/// `raw` 是整页 HTML；`loader_key` 形如 `rank_hot-drama/page`。
///
/// 同一页里**每段脚本都会命中同一个 loader key**，但只有最后一段带真实行数据：
/// 前面 `mergeLoaderData` 那段是占位（`[route, "content"]`，没有 payload），
/// 真正的 `rankList` 在 `modern-run-router-data-fn` 段里。因此不能命中即返回，
/// 要挑「有内容」的那一段。
pub fn merge_loader_content(raw: &str, loader_key: &str) -> Option<Value> {
    let mut best: Option<Value> = None;
    for marker in [
        "data-fn-name=\"mergeLoaderData\"",
        "data-fn-name=\"r\"",
        "data-fn-name=\"s\"",
    ] {
        let mut offset = 0;
        while let Some(found) = raw[offset..].find(marker) {
            let start = offset + found;
            offset = start + marker.len();
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
            let Some(value) = loader_content_from_args(&parsed, loader_key) else {
                continue;
            };
            // 占位内容（空对象，或只有 isSuccess 没有正文）先记下，
            // 后续若找到带正文的那段就替换。
            let richer = best
                .as_ref()
                .map(|current| {
                    value
                        .as_object()
                        .is_some_and(|map| map.len() > current.as_object().map_or(0, |m| m.len()))
                })
                .unwrap_or(true);
            if richer {
                best = Some(value);
            }
        }
    }
    best
}

/// 在已经解析的属性参数里按两种结构找 `content`。
fn loader_content_from_args(parsed: &Value, loader_key: &str) -> Option<Value> {
    let array = parsed.as_array()?;
    if array.first().and_then(Value::as_str) != Some(loader_key) {
        return None;
    }
    // 形态 2：`[loaderKey, "content", {...}]`
    if array.len() == 3 && array[1].as_str() == Some("content") {
        let content = array[2].clone();
        if content.is_object() {
            return Some(content);
        }
        // 少数页面把第三段再包成字符串。
        if let Some(text) = content.as_str() {
            if let Ok(value) = serde_json::from_str::<Value>(text) {
                return Some(value);
            }
        }
        return None;
    }
    // 形态 1 / 3：`[loaderKey, [{key: "content", routerDataFnArgs: [...]}]]`
    let entries = array.get(1)?.as_array()?;
    for entry in entries {
        if entry.get("key").and_then(Value::as_str) != Some("content") {
            continue;
        }
        let payload = entry
            .get("routerDataFnArgs")
            .and_then(Value::as_array)
            .and_then(|args| args.first());
        match payload {
            Some(Value::String(text)) => {
                if let Ok(value) = serde_json::from_str::<Value>(text) {
                    return Some(value);
                }
            }
            // 形态 3 的 s 函数把内容直接放在 args 里（不再套字符串）。
            Some(Value::Object(_)) => return payload.cloned(),
            _ => {}
        }
    }
    None
}

/// 取标签里某个属性的原始值（未解码实体）。
///
/// 站点对同一个属性会混用双引号与单引号：`mergeLoaderData` 那段用
/// `data-fn-args="..."`，`modern-run-router-data-fn` 那段用
/// `data-fn-args='...'`（属性值里全是 `&quot;`，所以单引号不会冲突）。
/// 只认双引号会让后者整段被跳过，表现为「榜单数据尚未完整」。
fn attribute<'a>(tag: &'a str, name: &str) -> Option<&'a str> {
    for quote in ['"', '\''] {
        let needle = format!("{name}={quote}");
        if let Some(start) = tag.find(&needle) {
            let start = start + needle.len();
            if let Some(end) = tag[start..].find(quote) {
                return Some(&tag[start..start + end]);
            }
        }
    }
    None
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
    fn parses_rows_from_modern_router_data_fn_script() {
        // 2026-10-24 实测形态：行数据由 `data-fn-name="r"` +
        // `data-script-src="modern-run-router-data-fn"` 注入，属性用单引号，
        // 且同一页里 `mergeLoaderData` 只有占位内容（没有 rankList）。
        use serde_json::json;
        let rows: Vec<Value> = [(1, "111"), (2, "222")]
            .iter()
            .map(|(rank, id)| {
                json!({
                    "id": id,
                    "seriesId": id,
                    "rank": rank,
                    "title": format!("剧 {rank}"),
                    "heatText": format!("{rank}万热度"),
                })
            })
            .collect();
        let content = json!({
            "isSuccess": true,
            "rankList": rows,
            "pagination": { "pageNum": 1, "totalPages": 2 },
        });
        let router = json!({
            "loaderData": {
                "rank_hot-drama/page": {
                    "rankKey": "hongguo",
                    "pageNum": 1,
                    "content": {},
                }
            }
        });
        let placeholder = json!(["rank_hot-drama/page", [
            {"key": "content", "routerDataFnName": "s", "routerDataFnArgs": []}
        ]]);
        let modern = json!(["rank_hot-drama/page", "content", content]);
        let escape = |value: &Value| {
            serde_json::to_string(value)
                .expect("serialize")
                .replace('"', "&quot;")
        };
        let body = format!(
            "<script>window._ROUTER_DATA = {};</script>\
             <script async data-fn-name=\"mergeLoaderData\" data-fn-args=\"{}\"></script>\
             <script async data-fn-name=\"r\" data-script-src=\"modern-run-router-data-fn\" data-fn-args='{}'></script>",
            serde_json::to_string(&router).expect("serialize"),
            escape(&placeholder),
            escape(&modern),
        );
        let page = parse_ranking_page(&body, "hongguo-hot", 1).expect("解析成功");
        assert_eq!(page.items.len(), 2);
        assert_eq!(page.items[0].rank, 1);
        assert_eq!(page.items[1].drama.id, "hongguo:222");
    }

    #[test]
    fn prefers_script_with_rows_over_placeholder() {
        // 占位段为空对象时不能被当成「已完整」，否则会退化成缺少 rankList。
        use serde_json::json;
        let content = json!({
            "isSuccess": true,
            "rankList": [{"id": "1", "seriesId": "1", "rank": 1, "title": "剧 1"}],
            "pagination": { "pageNum": 1, "totalPages": 1 },
        });
        let escape = |value: &Value| {
            serde_json::to_string(value)
                .expect("serialize")
                .replace('"', "&quot;")
        };
        let body = format!(
            "<script>window._ROUTER_DATA = {{\"loaderData\":{{\"rank_hot-drama/page\":{{\"rankKey\":\"hongguo\",\"pageNum\":1,\"content\":{{}}}}}}}};</script>\
             <script data-fn-name=\"mergeLoaderData\" data-fn-args=\"{}\"></script>\
             <script data-fn-name=\"r\" data-fn-args='{}'></script>",
            escape(&json!(["rank_hot-drama/page", [{"key": "content", "routerDataFnArgs": []}]])),
            escape(&json!(["rank_hot-drama/page", "content", content])),
        );
        let page = parse_ranking_page(&body, "hongguo-hot", 1).expect("解析成功");
        assert_eq!(page.items.len(), 1);
    }

    #[test]
    fn boards_cover_four_boards() {
        assert_eq!(boards().len(), 4);
        assert!(find_board("hongguo-ai").is_some());
        assert!(find_board("unknown").is_none());
    }
}
