//! 红果榜单解析的离线对拍。
//!
//! 夹具取自 2026-10-21 的真实榜单页（已裁掉无关脚本，只保留
//! `_ROUTER_DATA` 与 `mergeLoaderData` 两段）。它覆盖一个真实的站点结构变化：
//! 行数据不再放在 `_ROUTER_DATA.fnArgs`，而是由 `mergeLoaderData` 脚本属性注入。

use guo_source_hongguo::{boards, parse_ranking_page};

const RANKING: &str = include_str!("fixtures/hongguo_ranking.html");

#[test]
fn boards_cover_the_four_main_channels() {
    let ids: Vec<String> = boards().into_iter().map(|board| board.id).collect();
    assert_eq!(
        ids,
        vec!["hongguo-hot", "hongguo-real", "hongguo-comic", "hongguo-ai",]
    );
}

#[test]
fn parses_rows_injected_by_merge_loader_data() {
    let page = parse_ranking_page(RANKING, "hongguo-hot", 1).expect("榜单应可解析");
    assert_eq!(page.items.len(), 20, "第一页固定 20 条");
    assert_eq!(page.items[0].rank, 1);
    assert!(!page.items[0].drama.title.is_empty());
    assert!(
        page.items[0].drama.id.starts_with("hongguo:"),
        "{}",
        page.items[0].drama.id
    );
    // 名次必须严格递增：站点用名次区间做分页校验，乱序说明解析错了字段。
    let ranks: Vec<u32> = page.items.iter().map(|item| item.rank).collect();
    assert!(ranks.windows(2).all(|pair| pair[0] < pair[1]), "{ranks:?}");
}

#[test]
fn rejects_unknown_board() {
    assert!(parse_ranking_page(RANKING, "hongguo-nope", 1).is_err());
}

#[test]
fn rejects_page_out_of_range() {
    assert!(parse_ranking_page(RANKING, "hongguo-hot", 0).is_err());
    assert!(parse_ranking_page(RANKING, "hongguo-hot", 501).is_err());
}

#[test]
fn rejects_mismatched_page() {
    // 夹具是第 1 页；请求第 2 页必须被拒绝，而不是把第 1 页当成第 2 页。
    assert!(parse_ranking_page(RANKING, "hongguo-hot", 2).is_err());
}

/// 站点偶发返回半截页面时必须**重新请求**，而不是把同一份 body 解析两次。
///
/// 这条用例锁住一个真实修过的缺陷：原来的「重试」只是重复解析同一份
/// 响应，遇到半截数据必然再失败一次。
#[tokio::test]
async fn incomplete_page_is_refetched_not_reparsed() {
    use std::sync::{Arc, Mutex};

    use guo_engine::{
        Capability, FetchRequest, FetchResponse, LogSink, SourceEnv, SourceError, SourcePlugin,
        SourceStore, Transport,
    };

    /// 第一次返回半截页面（无 rankList），第二次返回完整夹具。
    struct TwiceTransport {
        calls: Mutex<usize>,
    }

    #[async_trait::async_trait]
    impl Transport for TwiceTransport {
        async fn fetch(&self, request: FetchRequest) -> Result<FetchResponse, SourceError> {
            let mut calls = self.calls.lock().expect("calls");
            *calls += 1;
            let first = *calls == 1;
            let body = if first {
                // 结构与真实半截页面一致：loader.content 为空、没有 merge 脚本。
                r#"<html><script>_ROUTER_DATA = {"loaderData":{"rank_hot-drama/page":{"rankKey":"hongguo","pageNum":"1","content":{}}}}</script></html>"#
            } else {
                RANKING
            };
            Ok(FetchResponse::new(
                200,
                body.as_bytes().to_vec(),
                request.url,
            ))
        }
    }

    struct NoStore;
    #[async_trait::async_trait]
    impl SourceStore for NoStore {
        async fn get(&self, _: &str) -> Result<Option<String>, SourceError> {
            Ok(None)
        }
        async fn set(&self, _: &str, _: &str) -> Result<(), SourceError> {
            Ok(())
        }
    }

    struct NoLog;
    impl LogSink for NoLog {
        fn debug(&self, _: &str) {}
        fn warn(&self, _: &str) {}
    }

    let transport = Arc::new(TwiceTransport {
        calls: Mutex::new(0),
    });
    let env = SourceEnv {
        source_id: "hongguo".into(),
        transport: transport.clone(),
        store: Arc::new(NoStore),
        scripts: None,
        log: Arc::new(NoLog),
    };
    let source =
        guo_source_hongguo::HongguoSource::with_base("https://rank.test", "https://api.test");
    assert!(source.meta().supports(Capability::Rankings));
    let page = source
        .ranking(&env, "hongguo-hot", 1)
        .await
        .expect("第二次应成功");
    assert_eq!(page.items.len(), 20);
    assert_eq!(
        *transport.calls.lock().expect("calls"),
        2,
        "必须重新请求一次"
    );
}

#[test]
fn missing_router_data_is_a_clear_error() {
    let err = parse_ranking_page("<html></html>", "hongguo-hot", 1).expect_err("必须失败");
    assert!(err.to_string().contains("_ROUTER_DATA"), "{err}");
}
