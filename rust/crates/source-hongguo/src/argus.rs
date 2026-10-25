//! 弹幕 / App 详情接口的评论签名（X-Argus / X-Ladon / 评论版 X-Gorgon）。
//!
//! 与 Go 版 `native/core/provider_hongguo_comment_sign.go` 逐字节一致。
//! 2026-10-24 实测：红果把 App 接口的匿名门槛升级到了这一层——
//! 只有 Gorgon 时 `/novel/commentapi/...` 返回 `110001 未知异常`、
//! `/novel/player/video_detail/v1/` 返回空响应体；带上 Argus/Ladon 后
//! 两者都返回真实数据。签名本身不区分端点，弹幕额外要求
//! `Comment-Source: 601` / `Server-Channel: 1000` 两个头。
//!
//! 对拍方式见 `tests/hongguo_argus_parity.rs`：向量由 Go 参考实现生成
//! （`tests/hongguo_sign_vectors.json`），改动任一处都会失败。
//!
//! 依赖说明：`aes` 在 `source-huangguo` 已有先例（同样只用于站源协议），
//! `source-api` 的依赖铁律不受影响。

use aes::cipher::generic_array::GenericArray;
use aes::cipher::{BlockEncrypt, KeyInit};
use aes::Aes128;

use crate::sign::md5_bytes;

/// 评论签名的一次随机数。Go 版用 `crypto/rand`；这里只要「每次不同」，
/// 用时间与进程混合的 xorshift 就够（签名不要求不可预测）。
#[derive(Debug, Clone, Copy)]
pub struct CommentNonce(pub [u8; 11]);

impl CommentNonce {
    pub fn generate() -> Self {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|value| value.as_nanos() as u64)
            .unwrap_or(0);
        let mut state = nanos ^ ((std::process::id() as u64) << 32) ^ 0x9e37_79b9_7f4a_7c15;
        let mut out = [0u8; 11];
        for slot in out.iter_mut() {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            *slot = (state >> 24) as u8;
        }
        Self(out)
    }
}

/// 评论签名的完整请求头集合。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommentHeaders {
    pub x_gorgon: String,
    pub x_khronos: String,
    pub x_ss_req_ticket: String,
    pub x_argus: String,
    pub x_ladon: String,
}

/// 计算评论签名全套请求头。
///
/// `raw_query` 是不含 `?` 的查询串；`now_ms` 同时给出秒级时间戳与票据。
/// 注意：评论版 Gorgon **不**掺请求体摘要，且 `X-SS-STUB` 固定为空串
/// （这两个差异都与普通版 Gorgon 相反）。
pub fn comment_headers(raw_query: &str, nonce: CommentNonce, now_ms: u64) -> CommentHeaders {
    let stamp = (now_ms / 1000) as u32;
    let seed = comment_gorgon_seed(raw_query, stamp, &nonce);
    CommentHeaders {
        x_gorgon: to_hex(&comment_gorgon_bytes(seed, &nonce)),
        x_khronos: stamp.to_string(),
        x_ss_req_ticket: now_ms.to_string(),
        x_argus: argus(raw_query, stamp, &nonce),
        // aid 取查询串里的实际值（Go 版从 URL.Query() 读，缺省为空串）。
        // 生产请求恒带 aid=8662，但测试向量覆盖了无 aid 的形态。
        x_ladon: ladon(query_aid(raw_query), stamp, &nonce.0[2..6]),
    }
}

/// 从原始查询串里取 `aid` 参数值；不存在时返回空串。
fn query_aid(raw_query: &str) -> &str {
    for pair in raw_query.split('&') {
        if let Some(value) = pair.strip_prefix("aid=") {
            return value;
        }
    }
    ""
}

// ---------- 评论版 Gorgon ----------

fn comment_gorgon_seed(raw_query: &str, stamp: u32, nonce: &CommentNonce) -> [u8; 20] {
    let head2 = (nonce.0[0] % 7 + 1) << 5;
    let head3 = 0xe0 | (nonce.0[1] & 15);
    let mut seed = [0u8; 20];
    let query_digest = md5_bytes(raw_query.as_bytes());
    seed[..4].copy_from_slice(&query_digest[..4]);
    seed[12..16].copy_from_slice(&[0, 1, 7, 4]);
    seed[16..20].copy_from_slice(&stamp.to_be_bytes());

    let key = [0x4au8, 0, 0x16, head3, 0x47, 0x6c, 0, head2];
    let mut box_state = [0u8; 256];
    for (index, slot) in box_state.iter_mut().enumerate() {
        *slot = index as u8;
    }
    // 注意：这不是标准 RC4 的交换，而是**单向赋值** `box[i] = box[j]`。
    // 参考实现（Go）就是这么写的，服务端按这个退化形态校验；
    // 按「典型 RC4」脑补成 swap 会得到完全不同的 seed。
    let mut j = 0u8;
    for index in 0..256 {
        j = j
            .wrapping_add(box_state[index])
            .wrapping_add(key[index & 7]);
        let source = box_state[j as usize];
        box_state[index] = source;
    }
    let mut j = 0u8;
    for (offset, slot) in seed.iter_mut().enumerate() {
        let i = (offset as u8).wrapping_add(1);
        j = j.wrapping_add(box_state[i as usize]);
        let source = box_state[j as usize];
        box_state[i as usize] = source;
        *slot ^= box_state[box_state[i as usize].wrapping_add(box_state[j as usize]) as usize];
    }
    seed
}

fn comment_gorgon_bytes(mut seed: [u8; 20], nonce: &CommentNonce) -> Vec<u8> {
    let head2 = (nonce.0[0] % 7 + 1) << 5;
    let head3 = 0xe0 | (nonce.0[1] & 15);
    // Go：seed[i] = rev(rotl(seed[i],4) ^ seed[(i+1)%20]) ^ 0xeb。
    // 原地改写是有意的：最后一轮（i=19）读到的 seed[0] 已是本轮改写后的值，
    // 与普通版 Gorgon 的收尾行为一致，不能先存副本再算。
    for index in 0..20 {
        seed[index] = (seed[index].rotate_left(4) ^ seed[(index + 1) % 20]).reverse_bits() ^ 0xeb;
    }
    let mut out = Vec::with_capacity(26);
    out.extend_from_slice(&[0x84, 0x04, head2, head3, 0, 0]);
    out.extend_from_slice(&seed);
    out
}

// ---------- Ladon ----------

fn ladon(aid: &str, timestamp: u32, prefix: &[u8]) -> String {
    let digest_input = [prefix, aid.as_bytes()].concat();
    let digest_hex = md5_bytes(&digest_input)
        .map(|byte| format!("{byte:02x}"))
        .concat();
    // Go：digest := []byte(hex)；再按 LittleEndian u64 切四段。
    let digest = digest_hex.as_bytes();
    let mut words = [0u64; 4];
    for (index, word) in words.iter_mut().enumerate() {
        let start = index * 8;
        *word = u64::from_le_bytes(digest[start..start + 8].try_into().expect("8 字节"));
    }
    let (mut left, mut right) = (words[0], words[1]);
    let mut queue = std::collections::VecDeque::from([words[2], words[3]]);
    let mut keys = [0u64; 34];
    for (index, key) in keys.iter_mut().enumerate() {
        *key = left;
        let mixed = right.rotate_left(64 - 8).wrapping_add(left) ^ index as u64;
        queue.push_back(mixed);
        left = mixed ^ left.rotate_left(3);
        right = queue.pop_front().expect("队列恒有元素");
    }

    let mut data = pkcs7_pad(format!("{timestamp}-1611921764-3019").as_bytes());
    for chunk in data.as_chunks_mut::<16>().0 {
        let (mut l, mut r) = (
            u64::from_le_bytes(chunk[..8].try_into().expect("8 字节")),
            u64::from_le_bytes(chunk[8..].try_into().expect("8 字节")),
        );
        for key in keys {
            r = key ^ l.wrapping_add(r.rotate_left(64 - 8));
            l = r ^ l.rotate_left(3);
        }
        chunk[..8].copy_from_slice(&l.to_le_bytes());
        chunk[8..].copy_from_slice(&r.to_le_bytes());
    }
    to_base64(&[prefix, &data].concat())
}

// ---------- Argus ----------

/// Argus 的固定密钥（客户端版本绑定，与 Go 版一致）。
const ARGUS_KEY: [u8; 32] = [
    0xac, 0x1a, 0xda, 0xae, 0x95, 0xa7, 0xaf, 0x94, 0xa5, 0x11, 0x4a, 0xb3, 0xb3, 0xa9, 0x7d, 0xd8,
    0x00, 0x50, 0xaa, 0x0a, 0x39, 0x31, 0x4c, 0x40, 0x52, 0x8c, 0xae, 0xc9, 0x52, 0x56, 0xc2, 0x8c,
];

fn argus(query: &str, timestamp: u32, nonce: &CommentNonce) -> String {
    let nonce = &nonce.0;
    let mut message = Vec::new();
    fn varint(message: &mut Vec<u8>, field: u64, value: u64) {
        put_uvarint(message, field * 8);
        put_uvarint(message, value);
    }
    varint(&mut message, 1, 0x2020_0929u64 * 2);
    varint(&mut message, 2, 2);
    varint(
        &mut message,
        3,
        u32::from_le_bytes(nonce[6..10].try_into().expect("4 字节")) as u64,
    );
    bytes_field(&mut message, 4, b"3019");
    bytes_field(&mut message, 6, b"1611921764");
    bytes_field(&mut message, 7, b"6.8.1.32");
    bytes_field(&mut message, 8, b"v04.07.01-ml-android");
    varint(&mut message, 9, 135_135_744);
    bytes_field(&mut message, 10, &[0u8; 8]);
    varint(&mut message, 12, timestamp as u64 * 2);
    let body_hash = sm3(&[0u8; 16]);
    let query_hash = sm3(query.as_bytes());
    bytes_field(&mut message, 13, &body_hash[..6]);
    bytes_field(&mut message, 14, &query_hash[..6]);
    let mut nested = vec![8u8, 2 + (nonce[10] % 49) * 2];
    for field in [2u64, 3, 4] {
        put_uvarint(&mut nested, field * 8);
        put_uvarint(&mut nested, 1_388_734);
    }
    bytes_field(&mut message, 15, &nested);
    bytes_field(&mut message, 20, b"none");
    varint(&mut message, 21, 738);

    let mut data = pkcs7_pad(&message);
    let seed = [
        ARGUS_KEY.as_slice(),
        &[0x3c, 0xcc, 0x56, 0x7b],
        ARGUS_KEY.as_slice(),
    ]
    .concat();
    let derived = sm3(&seed);
    let mut rounds = [0u64; 72];
    for (index, round) in rounds.iter_mut().enumerate().take(4) {
        *round = u64::from_le_bytes(
            derived[index * 8..index * 8 + 8]
                .try_into()
                .expect("8 字节"),
        );
    }
    for index in 4..rounds.len() {
        let mut mixed = rounds[index - 1].rotate_left(64 - 3) ^ rounds[index - 3];
        mixed ^= mixed.rotate_left(64 - 1);
        let mask = (0x3dc9_4c3a_046d_678bu64 >> ((index - 4) % 62)) & 1;
        rounds[index] = !rounds[index - 4] ^ mixed ^ mask ^ 3;
    }
    for chunk in data.as_chunks_mut::<16>().0 {
        let (mut l, mut r) = (
            u64::from_le_bytes(chunk[..8].try_into().expect("8 字节")),
            u64::from_le_bytes(chunk[8..].try_into().expect("8 字节")),
        );
        for round in rounds {
            // Go：left, right = right, left^(rotl(right,1)&rotl(right,8))^rotl(right,2)^round。
            // 右侧全部用**旧的** left/right 求值，再同时落盘；先交换会让
            // rotate 作用到错误的操作数上。
            let next_left = r;
            let next_right = l ^ ((r.rotate_left(1) & r.rotate_left(8)) ^ r.rotate_left(2) ^ round);
            l = next_left;
            r = next_right;
        }
        chunk[..8].copy_from_slice(&l.to_le_bytes());
        chunk[8..].copy_from_slice(&r.to_le_bytes());
    }
    let xor = [0xd0u8, 0x4f, 0xfd, 0xff, 0xd0, 0x4f, 0xfd, 0xff];
    for (index, byte) in data.iter_mut().enumerate() {
        *byte ^= xor[index % 8];
    }
    let mut payload = xor.to_vec();
    payload.extend_from_slice(&data);
    payload.reverse();
    let mut container = vec![0xa6, 0xe7, 0x83, 0xee, 0x70, 0x01, 0x10, 0x09, 0x18];
    container.extend_from_slice(&payload);
    container.extend_from_slice(&[0x56, 0x7b]);
    let container = pkcs7_pad(&container);

    let aes_key = md5_bytes(&ARGUS_KEY[..16]);
    let iv = md5_bytes(&ARGUS_KEY[16..]);
    let cipher = Aes128::new(GenericArray::from_slice(&aes_key));
    let mut encrypted = Vec::with_capacity(container.len());
    let mut previous = iv;
    for chunk in container.as_chunks::<16>().0 {
        let mixed: Vec<u8> = chunk
            .iter()
            .zip(previous.iter())
            .map(|(left, right)| left ^ right)
            .collect();
        let mut block: [u8; 16] = mixed.try_into().expect("16 字节");
        cipher.encrypt_block(GenericArray::from_mut_slice(&mut block));
        encrypted.extend_from_slice(&block);
        previous = block;
    }
    let mut out = vec![0x3c, 0xcc];
    out.extend_from_slice(&encrypted);
    to_base64(&out)
}

fn put_uvarint(out: &mut Vec<u8>, mut value: u64) {
    loop {
        let byte = (value & 0x7f) as u8;
        value >>= 7;
        if value == 0 {
            out.push(byte);
            return;
        }
        out.push(byte | 0x80);
    }
}

fn bytes_field(out: &mut Vec<u8>, field: u64, value: &[u8]) {
    put_uvarint(out, field * 8 + 2);
    put_uvarint(out, value.len() as u64);
    out.extend_from_slice(value);
}

// ---------- SM3 ----------

/// 国密 SM3 摘要（32 字节）。Go 版为 Argus 内嵌实现，逐语句对齐。
pub fn sm3(input: &[u8]) -> [u8; 32] {
    let bit_length = (input.len() as u64) * 8;
    let mut padded = input.to_vec();
    padded.push(0x80);
    while padded.len() % 64 != 56 {
        padded.push(0);
    }
    padded.extend_from_slice(&bit_length.to_be_bytes());

    let mut state: [u32; 8] = [
        0x7380_166f,
        0x4914_b2b9,
        0x1724_42d7,
        0xda8a_0600,
        0xa96f_30bc,
        0x1631_38aa,
        0xe38d_ee4d,
        0xb0fb_0e4e,
    ];
    for chunk in padded.as_chunks::<64>().0 {
        let mut words = [0u32; 68];
        for (index, word) in words.iter_mut().enumerate().take(16) {
            *word = u32::from_be_bytes(chunk[index * 4..index * 4 + 4].try_into().expect("4 字节"));
        }
        for index in 16..68 {
            let value = words[index - 16] ^ words[index - 9] ^ words[index - 3].rotate_left(15);
            words[index] = value
                ^ value.rotate_left(15)
                ^ value.rotate_left(23)
                ^ words[index - 13].rotate_left(7)
                ^ words[index - 6];
        }
        let mut working = state;
        let (mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut h) = (
            working[0], working[1], working[2], working[3], working[4], working[5], working[6],
            working[7],
        );
        for index in 0..64 {
            let (t, ff, gg) = if index < 16 {
                (0x79cc_4519u32, a ^ b ^ c, e ^ f ^ g)
            } else {
                (
                    0x7a87_9d8au32,
                    (a & b) | (a & c) | (b & c),
                    (e & f) | (!e & g),
                )
            };
            let ss1 = a
                .rotate_left(12)
                .wrapping_add(e)
                .wrapping_add(t.rotate_left(index % 32))
                .rotate_left(7);
            let tt1 = ff
                .wrapping_add(d)
                .wrapping_add(ss1 ^ a.rotate_left(12))
                .wrapping_add(words[index as usize] ^ words[index as usize + 4]);
            let tt2 = gg
                .wrapping_add(h)
                .wrapping_add(ss1)
                .wrapping_add(words[index as usize]);
            let next = [
                tt1,
                a,
                b.rotate_left(9),
                c,
                tt2 ^ tt2.rotate_left(9) ^ tt2.rotate_left(17),
                e,
                f.rotate_left(19),
                g,
            ];
            a = next[0];
            b = next[1];
            c = next[2];
            d = next[3];
            e = next[4];
            f = next[5];
            g = next[6];
            h = next[7];
        }
        for (index, word) in [a, b, c, d, e, f, g, h].into_iter().enumerate() {
            working[index] = state[index] ^ word;
        }
        state = working;
    }

    let mut out = [0u8; 32];
    for (index, word) in state.iter().enumerate() {
        out[index * 4..index * 4 + 4].copy_from_slice(&word.to_be_bytes());
    }
    out
}

// ---------- 基础工具 ----------

fn pkcs7_pad(data: &[u8]) -> Vec<u8> {
    let padding = 16 - data.len() % 16;
    let mut out = Vec::with_capacity(data.len() + padding);
    out.extend_from_slice(data);
    out.extend(std::iter::repeat_n(padding as u8, padding));
    out
}

fn to_hex(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

fn to_base64(data: &[u8]) -> String {
    const TABLE: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in data.chunks(3) {
        let bytes = [
            chunk[0],
            *chunk.get(1).unwrap_or(&0),
            *chunk.get(2).unwrap_or(&0),
        ];
        let value = ((bytes[0] as u32) << 16) | ((bytes[1] as u32) << 8) | bytes[2] as u32;
        out.push(TABLE[(value >> 18) as usize & 63] as char);
        out.push(TABLE[(value >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 {
            TABLE[(value >> 6) as usize & 63] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            TABLE[value as usize & 63] as char
        } else {
            '='
        });
    }
    out
}
