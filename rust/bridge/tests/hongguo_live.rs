//! 红果实网金丝雀测试。
//!
//! 红果是主源，却是唯一没有实网测试的源（以前只有夹具回放）。站点改版时
//! 「离线测试全绿、生产端到端全坏」的事故必须被 CI 拦住，所以这些用例
//! **不加 `#[ignore]`**：断网即红，这是金丝雀的意义。
//!
//! ```sh
//! cargo test -p guo_engine --test hongguo_live -- --nocapture
//! ```

use std::sync::Arc;
use std::time::Duration;

use guo_engine::{
    Capability, Chapter, HttpTransport, LogSink, SourceEnv, SourcePlugin, SourceStore,
};

const USER_AGENT: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 \
(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// 单步实网调用的上限。站点正常时目录 / 详情都在数秒内，
/// 30 秒足够区分「慢」和「坏」；不设上限会让 CI 卡在挂起的连接上。
const STEP_TIMEOUT: Duration = Duration::from_secs(30);

/// 站点对并发请求敏感：实测并行跑 5 条链路时出现过「缺分段游标」的退化
/// 响应，但单独跑稳定通过。金丝雀必须可重复，这里把同文件内的用例串行化。
static LIVE_SERIAL: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

struct NoopStore;
#[async_trait::async_trait]
impl SourceStore for NoopStore {
    async fn get(&self, _: &str) -> Result<Option<String>, guo_engine::SourceError> {
        Ok(None)
    }
    async fn set(&self, _: &str, _: &str) -> Result<(), guo_engine::SourceError> {
        Ok(())
    }
}

struct NoopLog;
impl LogSink for NoopLog {
    fn debug(&self, _: &str) {}
    fn warn(&self, _: &str) {}
}

fn env() -> SourceEnv {
    SourceEnv {
        source_id: "hongguo".into(),
        transport: Arc::new(HttpTransport::new(USER_AGENT).expect("transport")),
        store: Arc::new(NoopStore),
        scripts: None,
        log: Arc::new(NoopLog),
    }
}

fn source() -> guo_engine::HongguoSource {
    let source = guo_engine::HongguoSource::new();
    assert!(
        source.meta().supports(Capability::Danmaku),
        "红果应声明弹幕能力"
    );
    source
}

/// 取目录第一部**可解析**的剧。目录里偶有占位条目（source_id 为空），
/// 直接取 `items[0]` 会让用例因数据脏而不是站点坏而失败。
async fn first_drama(source: &guo_engine::HongguoSource, env: &SourceEnv) -> guo_engine::Drama {
    let page = tokio::time::timeout(STEP_TIMEOUT, source.catalog(env, 1, ""))
        .await
        .expect("目录请求超时")
        .expect("在线目录");
    assert!(
        page.items.len() >= 10,
        "目录第一页应有至少 10 条，实际 {}",
        page.items.len()
    );
    page.items
        .into_iter()
        .find(|item| !item.source_id.trim().is_empty())
        .expect("目录应有可解析的条目")
}

#[tokio::test]
async fn catalog_and_detail_live() {
    let _permit = LIVE_SERIAL.lock().await;
    let source = source();
    let env = env();
    let drama = first_drama(&source, &env).await;

    let detail = tokio::time::timeout(STEP_TIMEOUT, source.detail(&env, &drama.source_id))
        .await
        .expect("详情请求超时")
        .expect("在线详情");
    assert!(!detail.chapters.is_empty(), "详情应有分集");
    let chapter = &detail.chapters[0];
    assert!(
        chapter.video_url.starts_with("hongguo-cenc://"),
        "分集 video_url 应是 hongguo-cenc:// 协议：{}",
        chapter.video_url
    );
    assert!(
        chapter.source.chars().all(|c| c.is_ascii_digit()) && !chapter.source.is_empty(),
        "分集 source 应是纯数字 series_id：{}",
        chapter.source
    );
}

#[tokio::test]
async fn danmaku_live_returns_a_server_cursor() {
    let _permit = LIVE_SERIAL.lock().await;
    let source = source();
    let env = env();
    let drama = first_drama(&source, &env).await;
    let detail = tokio::time::timeout(STEP_TIMEOUT, source.detail(&env, &drama.source_id))
        .await
        .expect("详情请求超时")
        .expect("在线详情");
    let chapter = detail.chapters.first().expect("详情应有分集");

    let page = tokio::time::timeout(STEP_TIMEOUT, source.danmaku(&env, chapter, 0))
        .await
        .expect("弹幕请求超时")
        .expect("弹幕接口应可用（评论签名已通）");
    // 冷门剧可能一条弹幕都没有，所以**不**断言条目数；真正必须存在的是
    // 服务端游标：没有它，Dart 侧无法推进 30s 窗口，会整段跳过弹幕。
    assert!(
        page.end_ms > 0,
        "响应必须带服务端窗口游标，实际 end_ms={}",
        page.end_ms
    );
}

#[tokio::test]
async fn ranking_live_has_twenty_ranked_rows_per_board() {
    let _permit = LIVE_SERIAL.lock().await;
    let source = source();
    let env = env();
    let boards = tokio::time::timeout(STEP_TIMEOUT, source.ranking_boards(&env))
        .await
        .expect("榜单看板超时")
        .expect("在线榜单看板");
    assert_eq!(boards.len(), 4, "红果应有四个榜单：{boards:?}");

    for board in boards {
        let page = tokio::time::timeout(STEP_TIMEOUT, source.ranking(&env, &board.id, 1))
            .await
            .unwrap_or_else(|_| panic!("榜单 {} 请求超时", board.id))
            .unwrap_or_else(|error| panic!("榜单 {} 在线失败：{error}", board.id));
        assert_eq!(
            page.items.len(),
            20,
            "榜单 {} 第一页固定 20 条，实际 {}",
            board.id,
            page.items.len()
        );
        // 站点用名次区间做分页校验：名次必须从 1 起严格递增。
        let ranks: Vec<u32> = page.items.iter().map(|entry| entry.rank).collect();
        assert_eq!(ranks[0], 1, "榜单 {} 第一页应从第 1 名开始", board.id);
        assert!(
            ranks.windows(2).all(|pair| pair[0] < pair[1]),
            "榜单 {} 名次必须严格递增：{ranks:?}",
            board.id
        );
    }
}

#[tokio::test]
async fn suggestions_live_finds_series() {
    let _permit = LIVE_SERIAL.lock().await;
    let source = source();
    let env = env();
    let items = tokio::time::timeout(STEP_TIMEOUT, source.suggestions(&env, "总裁"))
        .await
        .expect("联想接口超时")
        .expect("联想接口应可用");
    assert!(
        items.iter().any(|item| !item.name.trim().is_empty()),
        "联想「总裁」应有结果"
    );
}

/// 弹幕必须能跨窗口推进：服务端按 30s 分段，`start_ms = end_ms` 取下一段。
#[tokio::test]
async fn danmaku_live_advances_to_the_next_window() {
    let _permit = LIVE_SERIAL.lock().await;
    let source = source();
    let env = env();
    let drama = first_drama(&source, &env).await;
    let detail = tokio::time::timeout(STEP_TIMEOUT, source.detail(&env, &drama.source_id))
        .await
        .expect("详情请求超时")
        .expect("在线详情");
    let chapter: &Chapter = detail.chapters.first().expect("详情应有分集");

    let first = tokio::time::timeout(STEP_TIMEOUT, source.danmaku(&env, chapter, 0))
        .await
        .expect("弹幕请求超时")
        .expect("第一段弹幕");
    assert!(first.end_ms > 0, "第一段必须有游标");
    let second = tokio::time::timeout(STEP_TIMEOUT, source.danmaku(&env, chapter, first.end_ms))
        .await
        .expect("第二段请求超时")
        .expect("第二段弹幕");
    assert!(
        second.end_ms > first.end_ms,
        "第二段游标必须继续前进：{} -> {}",
        first.end_ms,
        second.end_ms
    );
}

/// 取流降级链：第一集必须能拿到可播地址（djapi 或公开试看通道）。
///
/// 2026-10-25 起取流链路为「djapi 解析 → 网页试看」两级；djapi 当前
/// 返回 parse=0，本用例实际压在试看通道上。djapi 恢复数据后这里会
/// 拿到全画质 CENC 流，断言依然成立。
#[tokio::test]
async fn resolve_live_returns_playable_media_for_the_first_episode() {
    let _permit = LIVE_SERIAL.lock().await;
    let source = source();
    let env = env();
    let drama = first_drama(&source, &env).await;
    let detail = tokio::time::timeout(STEP_TIMEOUT, source.detail(&env, &drama.source_id))
        .await
        .expect("详情请求超时")
        .expect("在线详情");
    let chapter = detail.chapters.first().expect("详情应有分集");

    let media = tokio::time::timeout(STEP_TIMEOUT, source.resolve(&env, &detail.drama, chapter))
        .await
        .expect("取流请求超时")
        .expect("第一集应能取到播放地址");
    assert!(
        media.url.starts_with("http"),
        "播放地址应是 HTTP(S)：{}",
        media.url
    );
}
