//! 评论签名（Argus / Ladon / 评论版 Gorgon / SM3）与 Go 参考实现的对拍。
//!
//! 向量来自 `hongguo_sign_vectors.json`，由参考项目
//! `native/core/provider_hongguo_comment_sign.go` 生成（固定 nonce 与时间戳）。
//! 任何一处与 Go 不一致都会在这里失败。

use guo_source_hongguo::{comment_headers, sm3, CommentNonce};

#[derive(serde::Deserialize)]
struct SignVector {
    query: String,
    timestamp: u32,
    nonce: String,
    khronos: String,
    gorgon: String,
    ladon: String,
    argus: String,
}

#[derive(serde::Deserialize)]
struct Sm3Vector {
    input_hex: String,
    digest: String,
}

#[derive(serde::Deserialize)]
struct Vectors {
    sign: Vec<SignVector>,
    sm3: Vec<Sm3Vector>,
}

fn vectors() -> Vectors {
    serde_json::from_str(include_str!("hongguo_sign_vectors.json")).expect("向量文件合法")
}

#[test]
fn comment_signing_matches_go_vectors() {
    let all = vectors();
    assert!(!all.sign.is_empty(), "向量文件不能为空");
    for vector in &all.sign {
        let mut nonce_bytes = [0u8; 11];
        let hex = hex_decode(&vector.nonce);
        nonce_bytes.copy_from_slice(&hex);
        let headers = comment_headers(
            &vector.query,
            CommentNonce(nonce_bytes),
            // 与生成器一致：毫秒 = 秒 * 1000 + 固定尾数。
            vector.timestamp as u64 * 1000 + 123,
        );
        assert_eq!(headers.x_khronos, vector.khronos, "query={}", vector.query);
        assert_eq!(headers.x_gorgon, vector.gorgon, "query={}", vector.query);
        assert_eq!(headers.x_ladon, vector.ladon, "query={}", vector.query);
        assert_eq!(headers.x_argus, vector.argus, "query={}", vector.query);
    }
}

#[test]
fn sm3_matches_go_vectors() {
    let all = vectors();
    // 已知 SM3 标准向量兜底：空串与 "abc" 的摘要是公开的规范值。
    assert_eq!(
        hex_string(&sm3(b"")),
        "1ab21d8355cfa17f8e61194831e81a8f22bec8c728fefb747ed035eb5082aa2b"
    );
    assert_eq!(
        hex_string(&sm3(b"abc")),
        "66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0"
    );
    for vector in &all.sm3 {
        let input = hex_decode(&vector.input_hex);
        assert_eq!(hex_string(&sm3(&input)), vector.digest);
    }
}

#[test]
fn nonce_generator_changes_between_calls() {
    let first = CommentNonce::generate();
    let second = CommentNonce::generate();
    assert_ne!(first.0, second.0, "连续两次生成的 nonce 不应相同");
}

fn hex_decode(text: &str) -> Vec<u8> {
    (0..text.len())
        .step_by(2)
        .map(|index| u8::from_str_radix(&text[index..index + 2], 16).expect("合法十六进制"))
        .collect()
}

fn hex_string(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}
