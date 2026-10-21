//! 红果请求签名。
//!
//! 与 Go 版 `native/core/provider_hongguo_sign.go` 逐字节一致：
//! 先用 MD5 的前 4 字节填 query/body 摘要，再与固定密钥异或、位旋转、按位取反。
//!
//! 对拍方式见 `tests/sign_parity.rs`：向量由 Go 实现生成，改动任一处都会失败。

use guo_source_api::{md5_hash, md5_hex};

/// 参与签名的输入。抽成结构体而不是直接接收 `reqwest::Request`，
/// 是为了让签名可以在没有 HTTP 对象的情况下被测试与复用。
#[derive(Debug, Clone, Copy)]
pub struct SignInputs<'a> {
    /// URL 的原始查询串（不含 `?`）。
    pub raw_query: &'a str,
    /// 请求体；`None` 与 `Some(&[])` 语义不同：前者不写 `X-SS-STUB`。
    pub body: Option<&'a [u8]>,
    /// Unix 秒。
    pub timestamp: u32,
    /// Unix 毫秒，用于 `X-SS-Req-Ticket`。
    pub ticket_ms: u64,
}

/// 一次签名的完整产物。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GorgonHeaders {
    pub x_gorgon: String,
    pub x_khronos: String,
    pub x_ss_req_ticket: String,
    /// 请求体的 MD5（大写），仅在带请求体时出现。
    pub x_ss_stub: Option<String>,
}

/// 固定密钥，与 Go 版一致。
const KEY: [u8; 20] = [
    0x44, 0xb9, 0xb9, 0xd9, 0xa4, 0xae, 0xf9, 0xfc, 0xa4, 0x93, 0xaa, 0x75, 0x7c, 0xa3, 0xc2, 0xc4,
    0xa4, 0x96, 0x93, 0x8f,
];

/// 计算 X-Gorgon 系列请求头。
pub fn gorgon(inputs: &SignInputs<'_>) -> GorgonHeaders {
    let mut payload = [0u8; 20];

    // query 的 MD5 前 4 字节进 payload[0..4]
    let query_digest = md5_bytes(inputs.raw_query.as_bytes());
    payload[..4].copy_from_slice(&query_digest[..4]);

    // body 的 MD5 前 4 字节进 payload[4..8]，并额外写 X-SS-STUB
    let mut stub = None;
    if let Some(body) = inputs.body {
        let digest = md5_bytes(body);
        payload[4..8].copy_from_slice(&digest[..4]);
        stub = Some(md5_hex(body).to_uppercase());
    }

    // 固定的魔数片段与时间戳
    payload[12..16].copy_from_slice(&[0, 6, 11, 28]);
    payload[16..20].copy_from_slice(&inputs.timestamp.to_be_bytes());

    for (index, byte) in payload.iter_mut().enumerate() {
        *byte ^= KEY[index];
    }
    let len = payload.len() as u8;
    for index in 0..payload.len() {
        let mixed = payload[index].rotate_left(4) ^ payload[(index + 1) % payload.len()];
        payload[index] = mixed.reverse_bits() ^ 0xff ^ len;
    }

    let mut signature = Vec::with_capacity(26);
    signature.extend_from_slice(&[0x84, 0x04, 0x40, 0x1c, 0, 0]);
    signature.extend_from_slice(&payload);

    GorgonHeaders {
        x_gorgon: to_hex(&signature),
        x_khronos: inputs.timestamp.to_string(),
        x_ss_req_ticket: inputs.ticket_ms.to_string(),
        x_ss_stub: stub,
    }
}

/// MD5 的原始 16 字节。契约层的 `md5_hash` 返回 `u128`（小端拼装），
/// 这里转回字节序，避免签名实现再写一份 MD5。
fn md5_bytes(input: &[u8]) -> [u8; 16] {
    md5_hash(input).to_be_bytes()
}

fn to_hex(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_query_matches_go_vector() {
        // 向量来自 Go 版 `signHongguoRequest("", nil, 1700000000)`。
        let headers = gorgon(&SignInputs {
            raw_query: "",
            body: None,
            timestamp: 1_700_000_000,
            ticket_ms: 1_700_000_000_000,
        });
        assert_eq!(
            headers.x_gorgon,
            "8404401c00005e1521cecc232d3d7022103fad22c9d970977e8e"
        );
        assert_eq!(headers.x_khronos, "1700000000");
        assert_eq!(headers.x_ss_req_ticket, "1700000000000");
        assert!(headers.x_ss_stub.is_none());
    }

    #[test]
    fn query_with_page_matches_go_vector() {
        let headers = gorgon(&SignInputs {
            raw_query: "page=1",
            body: None,
            timestamp: 1_700_000_000,
            ticket_ms: 1_700_000_000_000,
        });
        assert_eq!(
            headers.x_gorgon,
            "8404401c00008ca34eeccc232d3d7022103fad22c9d970977ec5"
        );
    }

    #[test]
    fn non_ascii_query_matches_go_vector() {
        // 中文分类走 URL 编码后的原始查询串，签名必须按字节一致。
        let headers = gorgon(&SignInputs {
            raw_query: "page=2&category=都市",
            body: None,
            timestamp: 1_735_689_600,
            ticket_ms: 1_735_689_600_000,
        });
        assert_eq!(
            headers.x_gorgon,
            "8404401c0000fe85a102cc232d3d7022103fad22c99990f79d9b"
        );
    }

    #[test]
    fn body_contributes_both_gorgon_and_stub() {
        let headers = gorgon(&SignInputs {
            raw_query: "series_id=123&vid=456",
            body: Some(br#"{"a":1}"#),
            timestamp: 1_767_225_600,
            ticket_ms: 1_767_225_600_000,
        });
        assert_eq!(
            headers.x_gorgon,
            "8404401c0000ebcb1ed227ed940b7022103fad22c9e913835f23"
        );
        assert_eq!(
            headers.x_ss_stub.as_deref(),
            Some("BB6CB5C68DF4652941CAF652A366F2D8")
        );
    }

    #[test]
    fn empty_body_still_produces_stub() {
        // Go 版里 `body != nil` 才写 stub：空切片也会写。
        let headers = gorgon(&SignInputs {
            raw_query: "aid=3019&tab=5",
            body: Some(b""),
            timestamp: 1_600_000_000,
            ticket_ms: 1_600_000_000_000,
        });
        assert_eq!(
            headers.x_gorgon,
            "8404401c0000ac84b9dbc699a5847022103fad22c985051b06c1"
        );
        assert_eq!(
            headers.x_ss_stub.as_deref(),
            Some("D41D8CD98F00B204E9800998ECF8427E")
        );
    }

    #[test]
    fn signature_shape_is_stable() {
        let headers = gorgon(&SignInputs {
            raw_query: "x=1",
            body: None,
            timestamp: 1,
            ticket_ms: 1000,
        });
        assert!(headers.x_gorgon.starts_with("8404401c0000"), "{headers:?}");
        assert_eq!(headers.x_gorgon.len(), 52, "26 字节十六进制");
        assert!(headers
            .x_gorgon
            .chars()
            .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
    }
}
