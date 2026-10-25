//! 猫果的真实网络验证（默认忽略）。
//!
//! ```sh
//! cargo test -p guo_engine --test maoguo_live -- --ignored --nocapture
//! ```
//!
//! 存在的理由：离线金标准（`script_maoguo_parity.rs`）只能证明脚本解析行为
//! 没变，证明不了「站点还认这套请求」。签名/请求头失效是最常见的站源故障，
//! 所以必须有一条发真请求的用例——把结论写进文档前先让它跑一遍。
//!
//! 历史教训（EXTENSION-ECOSYSTEM §3.4）：`44010120 验签失败` 要先怀疑请求头
//! 再怀疑签名串——七猫鉴权是两层，缺 `qm-params` / `authorization` 的表现
//! 与「签名算错」完全一样。

use std::sync::Arc;

use guo_engine::{
    placeholder_env, ScriptLimits, ScriptSource, SourceEnv, SourceError, SourcePlugin, SourceStore,
};
use guo_host::{HttpTransport, DEFAULT_USER_AGENT};

const SCRIPT: &str = include_str!("../../examples/extensions/maoguo/main.js");

struct NoopStore;
#[async_trait::async_trait]
impl SourceStore for NoopStore {
    async fn get(&self, _: &str) -> Result<Option<String>, SourceError> {
        Ok(None)
    }
    async fn set(&self, _: &str, _: &str) -> Result<(), SourceError> {
        Ok(())
    }
}

struct NoopLog;
impl guo_engine::LogSink for NoopLog {
    fn debug(&self, _: &str) {}
    fn warn(&self, _: &str) {}
}

fn env() -> SourceEnv {
    SourceEnv {
        source_id: "maoguo".into(),
        transport: Arc::new(HttpTransport::new(DEFAULT_USER_AGENT).expect("transport")),
        store: Arc::new(NoopStore),
        scripts: None,
        log: Arc::new(NoopLog),
    }
}

/// 清单 `[permissions] network` 的白名单；脚本请求白名单之外会被宿主拒绝。
fn network() -> Vec<String> {
    vec![
        "api-store.qmplaylet.com".to_string(),
        "api-read.qmplaylet.com".to_string(),
    ]
}

/// 目录 → 详情 → 搜索串起来跑：三者各有独立签名串，坏一个就够看出是哪条。
#[tokio::test]
#[ignore = "需要外网，手动执行：cargo test -p guo_engine --test maoguo_live -- --ignored"]
async fn catalog_detail_and_search_accept_current_signature() {
    let source = ScriptSource::load(
        &placeholder_env(),
        SCRIPT,
        ScriptLimits::default(),
        network(),
    )
    .expect("脚本加载");
    let env = env();

    let page = source
        .catalog(&env, 1, "")
        .await
        .expect("在线目录（签名或请求头失效时会拿到 44010120 验签失败）");
    assert!(!page.items.is_empty(), "在线目录不应为空");
    let first = page.items.first().expect("first").clone();
    assert!(!first.title.trim().is_empty(), "条目缺标题：{first:?}");

    let detail = source
        .detail(&env, &first.source_id)
        .await
        .expect("在线详情");
    assert!(!detail.chapters.is_empty(), "详情不应没有分集");
    assert!(
        detail
            .chapters
            .iter()
            .all(|chapter| !chapter.video_url.is_empty()),
        "分集缺播放地址"
    );

    let found = source.search(&env, "都市", 1).await.expect("在线搜索");
    assert!(!found.items.is_empty(), "搜索「都市」应有结果");
}
