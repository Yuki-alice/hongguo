//! djapi 取流通道的向量对拍：v2 响应解密与 CENC 内容密钥。
//!
//! 向量由 `tests/tools/vectorgen` 从 Go 参考实现生成
//! （`hongguo_playback_vectors.json`）。任何一处算法偏差都在离线暴露，
//! 而不是等第三方服务恢复数据后才在线上炸。
//!
//! 生成方式（向量过期或算法调整后）：
//!
//! ```sh
//! cd rust/crates/source-hongguo/tests/tools/vectorgen && go run .
//! ```

use guo_source_hongguo::{content_key, decode_playback_response, parse_playback};

const VECTORS: &str = include_str!("hongguo_playback_vectors.json");

#[derive(serde::Deserialize)]
struct Vectors {
    response: Vec<ResponseCase>,
    key: Vec<KeyCase>,
}

#[derive(serde::Deserialize)]
struct ResponseCase {
    note: String,
    body: String,
    plain: String,
    #[serde(default)]
    is_error: bool,
}

#[derive(serde::Deserialize)]
struct KeyCase {
    note: String,
    spade_a: String,
    key_hex: String,
    #[serde(default)]
    is_error: bool,
}

#[test]
fn v2_responses_decode_to_the_pinned_plaintext() {
    let vectors: Vectors = serde_json::from_str(VECTORS).expect("向量文件");
    for case in &vectors.response {
        if case.is_error {
            continue;
        }
        let plain = decode_playback_response(&case.body)
            .unwrap_or_else(|err| panic!("{}：解密失败 {err}", case.note));
        assert_eq!(
            String::from_utf8_lossy(&plain),
            case.plain,
            "{}：明文不一致",
            case.note
        );
    }
}

#[test]
fn content_keys_match_the_pinned_goldens() {
    let vectors: Vectors = serde_json::from_str(VECTORS).expect("向量文件");
    for case in &vectors.key {
        let result = content_key(&case.spade_a);
        if case.is_error {
            let err = result.expect_err(&case.note);
            assert!(
                err.to_string().contains("版本暂不支持"),
                "{}：应拒绝版本，实际 {err}",
                case.note
            );
        } else {
            let key = result.unwrap_or_else(|err| panic!("{}：解密失败 {err}", case.note));
            assert_eq!(hex::encode(key), case.key_hex, "{}", case.note);
        }
    }
}

/// parse / jx 为真值时必须拒绝——Go 版字面清单的语义等价验证。
#[test]
fn reparse_flags_are_rejected() {
    for (flag, encoded) in [
        ("布尔真", r#"{"parse":true,"key_urls":[]}"#),
        ("字符串一", r#"{"parse":"1","key_urls":[]}"#),
        (
            "字符串假是合法 JSON 字符串，按 Go 字面清单算真值",
            r#"{"jx":"false"}"#,
        ),
    ] {
        let err = parse_playback(encoded).expect_err(flag);
        assert!(
            err.to_string().contains("二次跳转"),
            "{flag}：应报需要二次跳转，实际 {err}"
        );
    }
}

/// 无解析结果（2026-10-25 线上真实形态）必须落在 `NoResult`，
/// 调用方据此降级到下一通道而不是把用户挡在门外。
#[test]
fn parse_zero_maps_to_no_result() {
    let outcome = parse_playback(r#"{"parse":0,"url":""}"#).expect("解析");
    assert_eq!(outcome, guo_source_hongguo::PlaybackOutcome::NoResult);
}

/// key_urls 的候选选择：坏条目跳过、画质取 name 里的数字、密钥解出。
#[test]
fn key_urls_skip_broken_entries_and_pick_quality() {
    let spade_a = &serde_json::from_str::<Vectors>(VECTORS)
        .expect("向量文件")
        .key
        .into_iter()
        .find(|case| !case.is_error)
        .expect("至少一个正常密钥向量")
        .spade_a;
    let body = format!(
        r#"{{"parse":0,"key_urls":[
            {{"name":"","src":"","kid":"","spade_a":""}},
            {{"name":"480p","src":"https://cdn.example/low.m3u8","kid":"0f0e0d0c0b0a09080706050403020100","spade_a":"{spade_a}"}},
            {{"name":"720p","src":"https://cdn.example/broken.m3u8","kid":"zz","spade_a":"{spade_a}"}},
            {{"name":"1080p","src":"https://cdn.example/high.m3u8","kid":"000102030405060708090a0b0c0d0e0f","spade_a":"{spade_a}"}}
        ]}}"#
    );
    let outcome = parse_playback(&body).expect("解析");
    let guo_source_hongguo::PlaybackOutcome::Variants(variants) = outcome else {
        panic!("应有候选");
    };
    assert_eq!(variants.len(), 2, "空地址条目跳过、坏 kid 条目跳过");
    assert_eq!(variants[0].quality, 480);
    assert_eq!(variants[1].quality, 1080);
    assert_eq!(
        hex::encode(variants[1].key),
        "00112233445566778899aabbccddeeff"
    );
}
