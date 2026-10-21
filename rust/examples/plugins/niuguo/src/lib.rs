//! 牛果代码插件。
//!
//! Core-3 的第三个迁移源，验证的是**加密响应**：接口返回 Base64 密文，
//! 密钥由请求 URI 派生，AES-128-ECB 解密后才是 JSON。
//!
//! 这正是 ADR-12 / PLAN.md 里「crypto 由插件自带」的实践：宿主不提供 AES，
//! 插件自带一份最小实现。代价是包体变大，换来的是宿主不替任何站点做密码学。

use serde_json::Value;

wit_bindgen::generate!({
    path: "../../../crates/plugin-wasm/wit/source-plugin.wit",
    world: "plugin",
});

use exports::guo::source::source::Guest;
use guo::source::host;
use guo::source::types::{
    Category, Chapter, Descriptor, Detail, Drama, Error, Media, Page, Query, ResolveRequest,
};

struct Niuguo;

const BASE: &str = "https://ccc.chaojichaojichanga.com:35620";
/// 分集解析服务。主域名失效时按顺序回退。
const PARSE_BASES: &[&str] = &["http://ccs.jshh.gzbaoxian.com", "http://101.42.92.211:5560"];
const PARSE_SCRIPTS: &[&str] = &["qy.php", "dj.php"];

impl Guest for Niuguo {
    fn describe() -> Descriptor {
        Descriptor {
            id: "guo.niuguo".into(),
            name: "牛果".into(),
            group: "duanju".into(),
            api_level: 1,
            capabilities: vec!["catalog".into(), "detail".into(), "search".into()],
        }
    }

    fn categories() -> Result<Vec<Category>, Error> {
        Ok(Vec::new())
    }

    fn catalog(query: Query) -> Result<Page, Error> {
        let url = catalog_url(&query.category, query.page);
        let value = fetch_json(&url)?;
        let items = items_from(&value);
        let has_more = !items.is_empty();
        Ok(Page {
            items,
            has_more,
            page: query.page,
            cursor: String::new(),
        })
    }

    fn fetch_detail(source_id: String) -> Result<Detail, Error> {
        let value = fetch_json(&detail_url(&source_id))?;
        let node = value
            .get("data")
            .and_then(|data| {
                data.as_array()
                    .and_then(|list| list.first())
                    .or(Some(data))
            })
            .ok_or_else(|| Error::ParseChanged("详情缺少 data".into()))?;
        let mut drama = drama_from_node(node);
        if drama.source_id.is_empty() {
            drama.source_id = source_id.clone();
        }

        let mut chapters = Vec::new();
        if let Some(sources) = node.get("sources").and_then(Value::as_array) {
            for source in sources {
                let Some(episodes) = source.get("episodes").and_then(Value::as_array) else {
                    continue;
                };
                for (index, episode) in episodes.iter().enumerate() {
                    let id = pick(episode, &["url", "episode_id", "id"]);
                    if id.is_empty() {
                        continue;
                    }
                    let number = (index + 1) as u32;
                    let title = pick(episode, &["name", "title"]);
                    chapters.push(Chapter {
                        id: format!("{source_id}:{number}"),
                        title: if title.is_empty() {
                            format!("第{number}集")
                        } else {
                            title
                        },
                        // 内部分集 ID，取流时再解析为播放地址。
                        video_url: id,
                        page_url: String::new(),
                        referer: format!("{BASE}/"),
                        vip: false,
                    });
                }
            }
        }
        if chapters.is_empty() {
            return Err(Error::ParseChanged("未返回可播放分集".into()));
        }
        Ok(Detail { drama, chapters })
    }

    fn search(query: Query) -> Result<Page, Error> {
        let keyword = query.keyword.trim();
        if keyword.is_empty() {
            return Ok(Page {
                items: Vec::new(),
                has_more: false,
                page: query.page,
                cursor: String::new(),
            });
        }
        let value = fetch_json(&search_url(keyword, query.page))?;
        let items = items_from(&value);
        let has_more = !items.is_empty();
        Ok(Page {
            items,
            has_more,
            page: query.page,
            cursor: String::new(),
        })
    }

    fn resolve(request: ResolveRequest) -> Result<Media, Error> {
        let source_id = request.chapter.video_url.trim().to_string();
        if source_id.is_empty() {
            return Err(Error::ParseChanged("分集缺少解析 ID".into()));
        }
        let mut last = Error::Empty;
        for base in PARSE_BASES {
            let referer = format!("{}/", base.trim_end_matches('/'));
            for script in PARSE_SCRIPTS {
                let address = format!(
                    "{}/jx/{script}?url={}",
                    base.trim_end_matches('/'),
                    encode_component(&source_id)
                );
                let headers = vec![("Referer".to_string(), referer.clone())];
                let Ok(response) = host::fetch("get", &address, &headers, None) else {
                    last = Error::Network("解析服务不可达".into());
                    continue;
                };
                if response.status != 200 {
                    last = Error::Http(response.status);
                    continue;
                }
                let body = String::from_utf8_lossy(&response.body).into_owned();
                let Ok(value) = serde_json::from_str::<Value>(&body) else {
                    last = Error::ParseChanged("解析服务返回格式无法识别".into());
                    continue;
                };
                let url = pick(&value, &["url"]);
                if url.is_empty() {
                    last = Error::ParseChanged("解析服务未返回播放地址".into());
                    continue;
                }
                return Ok(Media {
                    url,
                    referer,
                    segments: Vec::new(),
                    key_uri: String::new(),
                    key_iv: String::new(),
                    cookies: String::new(),
                    origin: String::new(),
                });
            }
        }
        Err(last)
    }

    fn suggestions(keyword: String) -> Result<Vec<String>, Error> {
        let _ = keyword;
        Ok(Vec::new())
    }
}

export!(Niuguo);

// ---- 站点地址 ----

fn catalog_url(category: &str, page: u32) -> String {
    format!(
        "{BASE}/list?class={}&order={}&type_id=5&area=&year=&state=&wd=&page={page}",
        encode_component(category.trim()),
        encode_component("最新")
    )
}

fn detail_url(source_id: &str) -> String {
    format!(
        "{BASE}/detail?vod_id={}",
        encode_component(source_id)
    )
}

fn search_url(query: &str, page: u32) -> String {
    format!(
        "{BASE}/list?class=&order={}&type_id=5&area=&year=&state=&wd={}&page={page}",
        encode_component("最新"),
        encode_component(query.trim())
    )
}

/// 拉取并解密接口响应。
///
/// 密钥用**请求实际使用的 URI**（路径 + 查询串）计算，与站点口径一致。
fn fetch_json(url: &str) -> Result<Value, Error> {
    let headers = vec![("Referer".to_string(), format!("{BASE}/"))];
    let response = host::fetch("get", url, &headers, None)?;
    if response.status != 200 {
        return Err(Error::Http(response.status));
    }
    let body = String::from_utf8_lossy(&response.body).into_owned();
    let key = uri_key(url);
    decrypt_payload(&body, &key)
}

/// 取 URI 的路径 + 查询串，左对齐填进 16 字节。
fn uri_key(address: &str) -> [u8; 16] {
    let after_scheme = address
        .find("://")
        .map(|index| &address[index + 3..])
        .unwrap_or(address);
    let uri = after_scheme
        .find('/')
        .map(|index| &after_scheme[index..])
        .unwrap_or(after_scheme);
    let mut key = [0u8; 16];
    for (slot, byte) in key.iter_mut().zip(uri.bytes()) {
        *slot = byte;
    }
    key
}

fn decrypt_payload(body: &str, key: &[u8; 16]) -> Result<Value, Error> {
    let encoded = body.trim();
    if encoded.is_empty() {
        return Err(Error::Empty);
    }
    let raw = base64_decode(encoded)
        .or_else(|| base64_decode(encoded.trim_end_matches('=')))
        .ok_or_else(|| Error::ParseChanged("响应不是有效的 Base64".into()))?;
    if raw.is_empty() || raw.len() % 16 != 0 {
        return Err(Error::ParseChanged("响应长度不符合加密块要求".into()));
    }
    let mut plain = raw;
    for block in plain.chunks_exact_mut(16) {
        let mut chunk = [0u8; 16];
        chunk.copy_from_slice(block);
        block.copy_from_slice(&aes128_ecb_decrypt_block(&chunk, key));
    }
    let unpadded = unpad(&plain)?;
    serde_json::from_slice(unpadded)
        .map_err(|_| Error::ParseChanged("解密后不是有效数据".into()))
}

/// 严格校验 PKCS#7 填充。
fn unpad(data: &[u8]) -> Result<&[u8], Error> {
    let Some(&pad) = data.last() else {
        return Err(Error::ParseChanged("解密结果为空".into()));
    };
    let pad = pad as usize;
    if pad == 0 || pad > 16 || pad > data.len() {
        return Err(Error::ParseChanged("响应解密失败".into()));
    }
    if !data[data.len() - pad..].iter().all(|byte| *byte as usize == pad) {
        return Err(Error::ParseChanged("响应填充无效".into()));
    }
    Ok(&data[..data.len() - pad])
}

// ---- 自带的 crypto ----

fn base64_decode(input: &str) -> Option<Vec<u8>> {
    let table = |byte: u8| -> Option<u8> {
        match byte {
            b'A'..=b'Z' => Some(byte - b'A'),
            b'a'..=b'z' => Some(byte - b'a' + 26),
            b'0'..=b'9' => Some(byte - b'0' + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    };
    let bytes: Vec<u8> = input
        .bytes()
        .filter(|byte| !byte.is_ascii_whitespace())
        .collect();
    let mut out = Vec::with_capacity(bytes.len() / 4 * 3);
    for chunk in bytes.chunks(4) {
        let mut values = [0u8; 4];
        let mut count = 0;
        for (index, byte) in chunk.iter().enumerate() {
            if *byte == b'=' {
                break;
            }
            values[index] = table(*byte)?;
            count += 1;
        }
        if count == 0 {
            continue;
        }
        let triple = ((values[0] as u32) << 18)
            | ((values[1] as u32) << 12)
            | ((values[2] as u32) << 6)
            | values[3] as u32;
        out.push((triple >> 16) as u8);
        if count > 2 {
            out.push((triple >> 8) as u8);
        }
        if count > 3 {
            out.push(triple as u8);
        }
    }
    Some(out)
}

/// AES-128 的 S 盒。
const SBOX: [u8; 256] = [
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
];

/// 逆 S 盒。
const INV_SBOX: [u8; 256] = [
    0x52, 0x09, 0x6a, 0xd5, 0x30, 0x36, 0xa5, 0x38, 0xbf, 0x40, 0xa3, 0x9e, 0x81, 0xf3, 0xd7, 0xfb,
    0x7c, 0xe3, 0x39, 0x82, 0x9b, 0x2f, 0xff, 0x87, 0x34, 0x8e, 0x43, 0x44, 0xc4, 0xde, 0xe9, 0xcb,
    0x54, 0x7b, 0x94, 0x32, 0xa6, 0xc2, 0x23, 0x3d, 0xee, 0x4c, 0x95, 0x0b, 0x42, 0xfa, 0xc3, 0x4e,
    0x08, 0x2e, 0xa1, 0x66, 0x28, 0xd9, 0x24, 0xb2, 0x76, 0x5b, 0xa2, 0x49, 0x6d, 0x8b, 0xd1, 0x25,
    0x72, 0xf8, 0xf6, 0x64, 0x86, 0x68, 0x98, 0x16, 0xd4, 0xa4, 0x5c, 0xcc, 0x5d, 0x65, 0xb6, 0x92,
    0x6c, 0x70, 0x48, 0x50, 0xfd, 0xed, 0xb9, 0xda, 0x5e, 0x15, 0x46, 0x57, 0xa7, 0x8d, 0x9d, 0x84,
    0x90, 0xd8, 0xab, 0x00, 0x8c, 0xbc, 0xd3, 0x0a, 0xf7, 0xe4, 0x58, 0x05, 0xb8, 0xb3, 0x45, 0x06,
    0xd0, 0x2c, 0x1e, 0x8f, 0xca, 0x3f, 0x0f, 0x02, 0xc1, 0xaf, 0xbd, 0x03, 0x01, 0x13, 0x8a, 0x6b,
    0x3a, 0x91, 0x11, 0x41, 0x4f, 0x67, 0xdc, 0xea, 0x97, 0xf2, 0xcf, 0xce, 0xf0, 0xb4, 0xe6, 0x73,
    0x96, 0xac, 0x74, 0x22, 0xe7, 0xad, 0x35, 0x85, 0xe2, 0xf9, 0x37, 0xe8, 0x1c, 0x75, 0xdf, 0x6e,
    0x47, 0xf1, 0x1a, 0x71, 0x1d, 0x29, 0xc5, 0x89, 0x6f, 0xb7, 0x62, 0x0e, 0xaa, 0x18, 0xbe, 0x1b,
    0xfc, 0x56, 0x3e, 0x4b, 0xc6, 0xd2, 0x79, 0x20, 0x9a, 0xdb, 0xc0, 0xfe, 0x78, 0xcd, 0x5a, 0xf4,
    0x1f, 0xdd, 0xa8, 0x33, 0x88, 0x07, 0xc7, 0x31, 0xb1, 0x12, 0x10, 0x59, 0x27, 0x80, 0xec, 0x5f,
    0x60, 0x51, 0x7f, 0xa9, 0x19, 0xb5, 0x4a, 0x0d, 0x2d, 0xe5, 0x7a, 0x9f, 0x93, 0xc9, 0x9c, 0xef,
    0xa0, 0xe0, 0x3b, 0x4d, 0xae, 0x2a, 0xf5, 0xb0, 0xc8, 0xeb, 0xbb, 0x3c, 0x83, 0x53, 0x99, 0x61,
    0x17, 0x2b, 0x04, 0x7e, 0xba, 0x77, 0xd6, 0x26, 0xe1, 0x69, 0x14, 0x63, 0x55, 0x21, 0x0c, 0x7d,
];

const RCON: [u8; 10] = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36];

fn xtime(byte: u8) -> u8 {
    if byte & 0x80 != 0 {
        (byte << 1) ^ 0x1b
    } else {
        byte << 1
    }
}

fn gmul(mut a: u8, mut b: u8) -> u8 {
    let mut out = 0u8;
    for _ in 0..8 {
        if b & 1 != 0 {
            out ^= a;
        }
        let high = a & 0x80 != 0;
        a <<= 1;
        if high {
            a ^= 0x1b;
        }
        b >>= 1;
    }
    out
}

/// 128 位密钥扩展：11 轮密钥，每轮 16 字节。
fn expand_key(key: &[u8; 16]) -> [[u8; 16]; 11] {
    let mut words = [[0u8; 4]; 44];
    for index in 0..4 {
        words[index].copy_from_slice(&key[index * 4..index * 4 + 4]);
    }
    for index in 4..44 {
        let mut temp = words[index - 1];
        if index % 4 == 0 {
            temp = [
                SBOX[temp[1] as usize] ^ RCON[index / 4 - 1],
                SBOX[temp[2] as usize],
                SBOX[temp[3] as usize],
                SBOX[temp[0] as usize],
            ];
        }
        for byte in 0..4 {
            words[index][byte] = words[index - 4][byte] ^ temp[byte];
        }
    }
    let mut rounds = [[0u8; 16]; 11];
    for (round, chunk) in rounds.iter_mut().enumerate() {
        for word in 0..4 {
            chunk[word * 4..word * 4 + 4].copy_from_slice(&words[round * 4 + word]);
        }
    }
    rounds
}

fn add_round_key(state: &mut [u8; 16], key: &[u8; 16]) {
    for index in 0..16 {
        state[index] ^= key[index];
    }
}

fn inv_shift_rows(state: &mut [u8; 16]) {
    // 状态按列存储：`s[row + 4 * column]`。解密时第 r 行右移 r 位，
    // 即 `result[r + 4c] = state[r + 4((c - r) mod 4)]`。
    let copy = *state;
    for row in 0..4 {
        for column in 0..4 {
            state[row + 4 * column] = copy[row + 4 * ((column + 4 - row) % 4)];
        }
    }
}

fn inv_sub_bytes(state: &mut [u8; 16]) {
    for byte in state.iter_mut() {
        *byte = INV_SBOX[*byte as usize];
    }
}

fn inv_mix_columns(state: &mut [u8; 16]) {
    for column in 0..4 {
        let base = column * 4;
        let (a0, a1, a2, a3) = (
            state[base],
            state[base + 1],
            state[base + 2],
            state[base + 3],
        );
        state[base] = gmul(a0, 14) ^ gmul(a1, 11) ^ gmul(a2, 13) ^ gmul(a3, 9);
        state[base + 1] = gmul(a0, 9) ^ gmul(a1, 14) ^ gmul(a2, 11) ^ gmul(a3, 13);
        state[base + 2] = gmul(a0, 13) ^ gmul(a1, 9) ^ gmul(a2, 14) ^ gmul(a3, 11);
        state[base + 3] = gmul(a0, 11) ^ gmul(a1, 13) ^ gmul(a2, 9) ^ gmul(a3, 14);
    }
}

/// 单块 AES-128 解密（ECB）。
fn aes128_ecb_decrypt_block(block: &[u8; 16], key: &[u8; 16]) -> [u8; 16] {
    let rounds = expand_key(key);
    let mut state = *block;
    add_round_key(&mut state, &rounds[10]);
    for round in (1..10).rev() {
        inv_shift_rows(&mut state);
        inv_sub_bytes(&mut state);
        add_round_key(&mut state, &rounds[round]);
        inv_mix_columns(&mut state);
    }
    inv_shift_rows(&mut state);
    inv_sub_bytes(&mut state);
    add_round_key(&mut state, &rounds[0]);
    let _ = xtime; // 保留给未来的加密路径，避免死代码告警
    state
}

// ---- 解析 ----

fn items_from(value: &Value) -> Vec<Drama> {
    let mut seen = std::collections::HashSet::new();
    let mut items = Vec::new();
    let rows = value
        .get("data")
        .and_then(|data| {
            data.as_array()
                .or_else(|| data.get("list").and_then(Value::as_array))
        })
        .or_else(|| value.get("list").and_then(Value::as_array));
    for row in rows.into_iter().flatten() {
        let drama = drama_from_node(row);
        if drama.source_id.is_empty() || !seen.insert(drama.source_id.clone()) {
            continue;
        }
        items.push(drama);
    }
    items
}

fn drama_from_node(node: &Value) -> Drama {
    let source_id = pick(node, &["vod_id", "vodId", "id"]);
    Drama {
        // 源前缀由宿主按清单补上。
        id: source_id.clone(),
        source_id,
        title: pick(node, &["vod_name", "vodName", "title"]),
        description: pick(node, &["vod_content", "vod_blurb", "vodContent", "desc"]),
        cover: pick(node, &["vod_pic", "vodPic", "cover"]),
        category: pick(node, &["type_name", "typeName"]),
        episodes: 0,
        tags: Vec::new(),
        views: String::new(),
        heat: String::new(),
        release_status: String::new(),
    }
}

fn pick(node: &Value, keys: &[&str]) -> String {
    for key in keys {
        let Some(value) = node.get(*key) else {
            continue;
        };
        if let Some(text) = value.as_str() {
            let text = text.trim();
            if !text.is_empty() {
                return text.to_string();
            }
        }
        if let Some(number) = value.as_i64() {
            return number.to_string();
        }
    }
    String::new()
}

fn encode_component(value: &str) -> String {
    value
        .bytes()
        .map(|byte| match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (byte as char).to_string()
            }
            _ => format!("%{byte:02X}"),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uri_key_uses_path_and_query_only() {
        let key = uri_key("https://host/list?class=&order=x&page=1");
        assert_eq!(&key[..7], b"/list?c");
        let short = uri_key("http://host/a");
        assert_eq!(short[0], b'/');
        assert_eq!(short[1], b'a');
        assert_eq!(&short[2..], &[0u8; 14]);
    }

    #[test]
    fn aes128_decrypts_a_known_vector() {
        // FIPS-197 附录 C.1 的 AES-128 向量（加密方向），这里验证解密方向。
        let key: [u8; 16] = [
            0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d,
            0x0e, 0x0f,
        ];
        let ciphertext: [u8; 16] = [
            0x69, 0xc4, 0xe0, 0xd8, 0x6a, 0x7b, 0x04, 0x30, 0xd8, 0xcd, 0xb7, 0x80, 0x70, 0xb4,
            0xc5, 0x5a,
        ];
        let plaintext: [u8; 16] = [
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd,
            0xee, 0xff,
        ];
        assert_eq!(aes128_ecb_decrypt_block(&ciphertext, &key), plaintext);
    }

    #[test]
    fn base64_round_trips_common_padding() {
        assert_eq!(base64_decode("").unwrap(), b"");
        assert_eq!(base64_decode("Zg==").unwrap(), b"f");
        assert_eq!(base64_decode("Zm8=").unwrap(), b"fo");
        assert_eq!(base64_decode("Zm9v").unwrap(), b"foo");
        assert_eq!(base64_decode("Zm9vYmFy").unwrap(), b"foobar");
        assert!(base64_decode("!!!").is_none());
    }

    #[test]
    fn unpad_rejects_malformed_padding() {
        assert!(unpad(&[0x01]).unwrap().is_empty());
        assert!(unpad(&[0x41, 0x02]).is_err(), "填充字节不一致必须拒绝");
        assert!(unpad(&[0x41, 0x11]).is_err(), "填充长度越界必须拒绝");
        assert!(unpad(&[]).is_err());
    }

    #[test]
    fn catalog_url_matches_the_compiled_source() {
        assert_eq!(
            catalog_url("", 2),
            "https://ccc.chaojichaojichanga.com:35620/list?class=&order=%E6%9C%80%E6%96%B0&type_id=5&area=&year=&state=&wd=&page=2"
        );
    }

    #[test]
    fn encode_component_escapes_non_ascii() {
        assert_eq!(encode_component("abc"), "abc");
        assert_eq!(encode_component("最新"), "%E6%9C%80%E6%96%B0");
    }
}
