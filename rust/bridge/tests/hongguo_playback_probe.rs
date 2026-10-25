//! 红果取流通道存活探针（默认忽略）。
//!
//! ```sh
//! cargo test -p guo_engine --test hongguo_playback_probe -- --ignored --nocapture
//! ```
//!
//! 逐个探测当前全部取流通道，给「实现哪条链路」提供实据：
//! 1. 播放页：`video_player_info` 是否回归、`publicVideoSeo` 对 ep1/ep2 的开放情况；
//! 2. 公开试看地址 `/video/public/<vid>/360p.mp4` 的 HTTP 状态；
//! 3. 第三方解析 `djapi.999888456.xyz/api/hongguo/play`（Go 版主通道，
//!    v2. 加密响应；10-24 记录为「恒 {"parse":0,"url":""}」）；
//! 4. App 接口 `video_model/v1/`（10-24 记录为 200 + 空响应体）。

use std::sync::Arc;

use guo_engine::{HongguoSource, LogSink, SourceEnv, SourceError, SourcePlugin, SourceStore};
use guo_host::DEFAULT_USER_AGENT;

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
impl LogSink for NoopLog {
    fn debug(&self, _: &str) {}
    fn warn(&self, _: &str) {}
}

fn env() -> SourceEnv {
    SourceEnv {
        source_id: "hongguo".into(),
        transport: Arc::new(guo_engine::HttpTransport::new(DEFAULT_USER_AGENT).expect("transport")),
        store: Arc::new(NoopStore),
        scripts: None,
        log: Arc::new(NoopLog),
    }
}

const WEB_BASE: &str = "https://hongguoduanju.com";

#[tokio::test]
#[ignore = "需要外网，手动执行：cargo test -p guo_engine --test hongguo_playback_probe -- --ignored --nocapture"]
async fn probe_playback_channels() {
    let source = HongguoSource::new();
    let env = env();

    // 1. 拿真实剧集与前两集 vid。
    let page = source.catalog(&env, 1, "").await.expect("在线目录");
    let drama = page.items.first().expect("目录非空");
    let detail = source
        .detail(&env, &drama.source_id)
        .await
        .expect("在线详情");
    let vids: Vec<String> = detail
        .chapters
        .iter()
        .take(2)
        .map(|chapter| {
            chapter
                .video_url
                .strip_prefix("hongguo-cenc://")
                .unwrap_or(&chapter.video_url)
                .to_string()
        })
        .collect();
    println!(
        "剧「{}」({})，探测分集 vid：{:?}",
        detail.drama.title, drama.source_id, vids
    );

    // 2. 播放页字段 + 3. 公开试看地址。
    for (index, vid) in vids.iter().enumerate() {
        let player_url = format!("{WEB_BASE}/player/{}/{}", drama.source_id, vid);
        let body = fetch_with_referer(&env, &player_url, &format!("{WEB_BASE}/"))
            .await
            .unwrap_or_default();
        let has_player_info = body.contains("video_player_info");
        let seo = extract_seo(&body);
        println!(
            "[播放页 ep{}] video_player_info={} publicVideoSeo={}",
            index + 1,
            has_player_info,
            seo.as_deref().unwrap_or("(无)")
        );
        let public_url = format!("{WEB_BASE}/video/public/{vid}/360p.mp4");
        let status = head_status(&env, &public_url).await;
        println!("[试看 ep{}] {} → {}", index + 1, public_url, status);
    }

    // 4. 第三方解析接口（Go 版主通道）。
    let reference = format!(
        r#"{{"content_type":1004,"from_video_id":"","series_id":"{}","vid":"{}","video_platform":3}}"#,
        drama.source_id,
        vids.first().map(String::as_str).unwrap_or("")
    );
    let encoded = base64_std(reference.as_bytes());
    let djapi = format!(
        "https://djapi.999888456.xyz/api/hongguo/play?id={}",
        urlencode(&encoded)
    );
    match fetch_with_referer(&env, &djapi, "https://hongguoduanju.com/").await {
        Ok(body) => println!(
            "[djapi] {} 字节：{}",
            body.len(),
            &body[..body.len().min(300)]
        ),
        Err(err) => println!("[djapi] ❌ {err}"),
    }

    // 5. App 接口 video_model（无签名裸探：10-24 已证签名也不给数据）。
    let model_url = "https://api5-normal-sinfonlineb.fqnovel.com/novel/player/video_model/v1/";
    match fetch_with_referer(&env, model_url, "https://hongguoduanju.com/").await {
        Ok(body) => println!(
            "[video_model 裸 GET] {} 字节：{}",
            body.len(),
            &body[..body.len().min(120)]
        ),
        Err(err) => println!("[video_model 裸 GET] ❌ {err}"),
    }
}

fn extract_seo(body: &str) -> Option<String> {
    let marker = "\"publicVideoSeo\":";
    let start = body.find(marker)? + marker.len();
    let rest = &body[start..];
    let end = rest.find('}').map(|index| index + 1)?;
    Some(rest[..end.min(rest.len())].to_string())
}

async fn head_status(env: &SourceEnv, url: &str) -> String {
    match env
        .transport
        .fetch(
            guo_engine::FetchRequest::get(url.to_string())
                .header("Referer", format!("{WEB_BASE}/")),
        )
        .await
    {
        Ok(response) => format!("HTTP {} ({} 字节)", response.status, response.body.len()),
        Err(err) => format!("❌ {err}"),
    }
}

async fn fetch_with_referer(
    env: &SourceEnv,
    url: &str,
    referer: &str,
) -> Result<String, SourceError> {
    let response = env
        .transport
        .fetch(guo_engine::FetchRequest::get(url.to_string()).header("Referer", referer))
        .await?;
    response.ensure_success()?;
    Ok(String::from_utf8_lossy(&response.body).into_owned())
}

/// 标准带填充的 Base64（探针自用，避免为一次性探测加依赖）。
fn base64_std(input: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(input.len().div_ceil(3) * 4);
    for chunk in input.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = *chunk.get(1).unwrap_or(&0) as u32;
        let b2 = *chunk.get(2).unwrap_or(&0) as u32;
        let triple = (b0 << 16) | (b1 << 8) | b2;
        out.push(TABLE[(triple >> 18) as usize & 63] as char);
        out.push(TABLE[(triple >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 {
            TABLE[(triple >> 6) as usize & 63] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            TABLE[triple as usize & 63] as char
        } else {
            '='
        });
    }
    out
}

fn urlencode(value: &str) -> String {
    let mut out = String::new();
    for byte in value.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*byte as char)
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}
