use guo_engine::MaoguoSource;
use guo_engine::QuickJsHost;

/// Rust 与 JS 两套 MD5 实现必须给出相同结果，
/// 否则脚本层与原生层的签名会不一致，站源会拒绝请求。
#[test]
fn rust_and_script_md5_agree() {
    let host = QuickJsHost::new();
    let cases = [
        "",
        "abc",
        "The quick brown fox jumps over the lazy dog",
        "operation=1playlet_privacy=1tag_id=0d3dGiJc651gSQ8w1",
        "都市无上仙尊",
        "a",
    ];
    for case in cases {
        let script = host
            .run(&format!("return crypto.md5({});", js_string(case)), "")
            .expect("script md5");
        let native = format!("{:032x}", md5_reference(case));
        assert_eq!(script, native, "mismatch for {case:?}");
    }
}

#[test]
fn catalog_signature_matches_script_implementation() {
    let host = QuickJsHost::new();
    for (tag, page) in [("0", 1u32), ("0", 3), ("12", 1), ("12", 2)] {
        let mut text = String::from("operation=1playlet_privacy=1tag_id=");
        text.push_str(tag);
        if page > 1 {
            text.push_str(&format!("next_id={page}"));
        }
        text.push_str("d3dGiJc651gSQ8w1");
        let from_script = host
            .run(&format!("return crypto.md5({});", js_string(&text)), "")
            .expect("script");
        assert_eq!(
            MaoguoSource::sign_catalog(tag, page),
            from_script,
            "catalog signature mismatch for tag={tag} page={page}"
        );
    }
}

#[test]
fn search_signature_matches_script_implementation() {
    let host = QuickJsHost::new();
    for query in ["都市", "abc", "甜宠 复仇"] {
        let text = format!(
            "extend=page=1read_preference=0track_id=ec1280db127955061754851657967wd={query}d3dGiJc651gSQ8w1"
        );
        let from_script = host
            .run(&format!("return crypto.md5({});", js_string(&text)), "")
            .expect("script");
        assert_eq!(MaoguoSource::sign_search(query), from_script);
    }
}

#[test]
fn malformed_url_encoding_is_stable() {
    let url = MaoguoSource::detail_url("6991");
    assert!(url.starts_with("https://api-read.qmplaylet.com/player/api/v1/playlet/info"));
    assert!(url.contains("playlet_id=6991"));
    assert!(url.contains("sign="));
    let sign = url.rsplit("sign=").next().expect("sign");
    assert_eq!(sign.len(), 32);
    assert!(sign.chars().all(|c| c.is_ascii_hexdigit()));
}

fn js_string(value: &str) -> String {
    serde_json::to_string(value).expect("encode")
}

/// 独立参考实现，故意与 `MaoguoSource` 内部实现分开，避免自证。
fn md5_reference(input: &str) -> u128 {
    const S: [u32; 64] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 5, 9, 14, 20, 5, 9, 14, 20, 5,
        9, 14, 20, 5, 9, 14, 20, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 6, 10,
        15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ];
    const K: [u32; 64] = [
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613,
        0xfd469501, 0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193,
        0xa679438e, 0x49b40821, 0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d,
        0x02441453, 0xd8a1e681, 0xe7d3fbc8, 0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
        0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a, 0xfffa3942, 0x8771f681, 0x6d9d6122,
        0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70, 0x289b7ec6, 0xeaa127fa,
        0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665, 0xf4292244,
        0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb,
        0xeb86d391,
    ];
    let mut message = input.as_bytes().to_vec();
    let bit_len = (input.len() as u64) * 8;
    message.push(0x80);
    while message.len() % 64 != 56 {
        message.push(0);
    }
    message.extend_from_slice(&bit_len.to_le_bytes());
    let (mut a0, mut b0, mut c0, mut d0) = (0x67452301u32, 0xefcdab89u32, 0x98badcfe, 0x10325476);
    for chunk in message.chunks(64) {
        let mut m = [0u32; 16];
        for (index, word) in m.iter_mut().enumerate() {
            *word = u32::from_le_bytes([
                chunk[index * 4],
                chunk[index * 4 + 1],
                chunk[index * 4 + 2],
                chunk[index * 4 + 3],
            ]);
        }
        let (mut a, mut b, mut c, mut d) = (a0, b0, c0, d0);
        for i in 0..64 {
            let (f, g) = match i / 16 {
                0 => ((b & c) | (!b & d), i),
                1 => ((d & b) | (!d & c), (5 * i + 1) % 16),
                2 => (b ^ c ^ d, (3 * i + 5) % 16),
                _ => (c ^ (b | !d), (7 * i) % 16),
            };
            let f = f.wrapping_add(a).wrapping_add(K[i]).wrapping_add(m[g]);
            a = d;
            d = c;
            c = b;
            b = b.wrapping_add(f.rotate_left(S[i]));
        }
        a0 = a0.wrapping_add(a);
        b0 = b0.wrapping_add(b);
        c0 = c0.wrapping_add(c);
        d0 = d0.wrapping_add(d);
    }
    let mut out = 0u128;
    for (index, word) in [a0, b0, c0, d0].iter().enumerate() {
        out |= (u128::from(*word)) << (index * 32);
    }
    out.swap_bytes()
}
