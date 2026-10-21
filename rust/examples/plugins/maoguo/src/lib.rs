//! 猫果（七猫）代码插件。
//!
//! 这是 Core-3 的打样源：验证一套**带签名**的站源能否完全跑在 Wasm 沙箱里。
//!
//! 与编译版（`crates/source-maoguo`）的关系：
//! - 站点知识（URL、签名串、字段名）与编译版逐项一致，改一处必须改两处；
//! - 传输、存储、提取全部走宿主注入的 `host` 接口，插件自身不碰网络与磁盘；
//! - MD5 与 Base64 由插件自带（PLAN.md Core-3：crypto 由插件自带，首版）。
//!
//! 迁移完成后（Core-3 验收）编译版会删除，届时以本文件为准。

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

const BASE: &str = "https://api-store.qmplaylet.com";
const READ_BASE: &str = "https://api-read.qmplaylet.com";
const KEY: &str = "d3dGiJc651gSQ8w1";
const TRACK_ID: &str = "ec1280db127955061754851657967";

struct Maoguo;

impl Guest for Maoguo {
    fn describe() -> Descriptor {
        Descriptor {
            id: "maoguo".into(),
            name: "猫果".into(),
            group: "duanju".into(),
            api_level: 1,
            capabilities: vec![
                "catalog".into(),
                "detail".into(),
                "search".into(),
            ],
        }
    }

    fn categories() -> Result<Vec<Category>, Error> {
        // 七猫的分类要额外一次请求；首版插件不做，返回空让宿主隐藏筛选。
        Ok(Vec::new())
    }

    fn catalog(query: Query) -> Result<Page, Error> {
        let tag = normalize_tag(&query.category);
        let url = catalog_url(tag, query.page);
        let body = fetch_json(&url)?;
        parse_page(&body, query.page)
    }

    fn fetch_detail(source_id: String) -> Result<Detail, Error> {
        let url = detail_url(&source_id);
        let body = fetch_json(&url)?;
        parse_detail(&body, &source_id)
    }

    fn search(query: Query) -> Result<Page, Error> {
        let keyword = query.keyword.trim();
        if keyword.is_empty() {
            return Err(Error::Unsupported("搜索关键词为空".into()));
        }
        let url = search_url(keyword);
        let body = fetch_json(&url)?;
        parse_page(&body, query.page)
    }

    fn resolve(request: ResolveRequest) -> Result<Media, Error> {
        // 七猫分集直接给 MP4，取流只做透传。
        let chapter = request.chapter;
        if chapter.video_url.is_empty() {
            return Err(Error::ParseChanged("分集缺少播放地址".into()));
        }
        Ok(Media {
            url: chapter.video_url,
            referer: format!("{BASE}/"),
            segments: Vec::new(),
            key_uri: String::new(),
            key_iv: String::new(),
            cookies: String::new(),
            origin: String::new(),
        })
    }

    fn suggestions(keyword: String) -> Result<Vec<String>, Error> {
        // 联想不是首发能力；返回空由宿主隐藏入口。
        let _ = keyword;
        Ok(Vec::new())
    }
}

export!(Maoguo);

// ---- 站点知识 ----

fn normalize_tag(category: &str) -> &str {
    let tag = category.trim();
    if !tag.is_empty() && tag.chars().all(|ch| ch.is_ascii_digit()) {
        tag
    } else {
        "0"
    }
}

fn catalog_url(tag: &str, page: u32) -> String {
    let sign = sign_catalog(tag, page);
    if page > 1 {
        format!(
            "{BASE}/api/v1/playlet/index?tag_id={tag}&playlet_privacy=1&operation=1&next_id={page}&sign={sign}"
        )
    } else {
        format!(
            "{BASE}/api/v1/playlet/index?tag_id={tag}&playlet_privacy=1&operation=1&sign={sign}"
        )
    }
}

fn detail_url(source_id: &str) -> String {
    format!(
        "{READ_BASE}/player/api/v1/playlet/info?playlet_id={}&sign={}",
        encode_component(source_id),
        sign_detail(source_id)
    )
}

fn search_url(keyword: &str) -> String {
    format!(
        "{BASE}/api/v1/playlet/search?extend=&page=1&wd={}&read_preference=0&track_id={TRACK_ID}&sign={}",
        encode_component(keyword),
        sign_search(keyword)
    )
}

fn sign_catalog(tag_id: &str, page: u32) -> String {
    let mut text = String::from("operation=1playlet_privacy=1tag_id=");
    text.push_str(tag_id);
    if page > 1 {
        text.push_str(&format!("next_id={page}"));
    }
    text.push_str(KEY);
    md5_hex(text.as_bytes())
}

fn sign_detail(source_id: &str) -> String {
    md5_hex(format!("playlet_id={source_id}{KEY}").as_bytes())
}

fn sign_search(query: &str) -> String {
    md5_hex(
        format!("extend=page=1read_preference=0track_id={TRACK_ID}wd={query}{KEY}").as_bytes(),
    )
}

/// 授权头 `qm-params`：设备信息 JSON → Base64 → 字符映射。
fn qm_params(session_id: &str) -> String {
    let payload = serde_json::json!({
        "static_score": "0.8",
        "uuid": "00000000-7fc7-08dc-0000-000000000000",
        "device-id": "20250220125449b9b8cac84c2dd3d035c9052a2572f7dd0122edde3cc42a70",
        "mac": "",
        "sourceuid": "aa7de295aad621a6",
        "refresh-type": "0",
        "model": "22021211RC",
        "wlb-imei": "",
        "client-id": "aa7de295aad621a6",
        "brand": "Redmi",
        "oaid": "",
        "oaid-no-cache": "",
        "sys-ver": "12",
        "trusted-id": "",
        "phone-level": "H",
        "imei": "",
        "wlb-uid": "aa7de295aad621a6",
        "session-id": session_id,
    });
    let text = serde_json::to_string(&payload).unwrap_or_default();
    map_chars(&base64_encode(text.as_bytes()))
}

fn sign_authorization(qm: &str) -> String {
    md5_hex(
        format!(
            "AUTHORIZATION=app-version=10001application-id=com.duoduo.readchannel=unknownis-white=net-env=5platform=androidqm-params={qm}reg={KEY}"
        )
        .as_bytes(),
    )
}

fn headers(session_id: &str) -> Vec<(String, String)> {
    let qm = qm_params(session_id);
    let sign = sign_authorization(&qm);
    [
        ("Referer", format!("{BASE}/")),
        ("platform", "android".into()),
        ("application-id", "com.duoduo.read".into()),
        ("app-version", "10001".into()),
        ("channel", "unknown".into()),
        ("net-env", "5".into()),
        ("is-white", String::new()),
        ("reg", String::new()),
        ("authorization", String::new()),
        ("qm-params", qm),
        ("sign", sign),
        ("Accept", "application/json".into()),
        ("X-Requested-With", "com.duoduo.read".into()),
        ("user-agent", "webviewversion/0".into()),
    ]
    .into_iter()
    .map(|(key, value)| (key.to_string(), value))
    .collect()
}

// ---- 传输 ----

fn fetch_json(url: &str) -> Result<Value, Error> {
    let mut last = Error::Empty;
    // 七猫对并发请求敏感，偶发返回空体；重试一次，并刷新会话时间戳。
    for attempt in 0..2 {
        let session = host::now_ms().to_string();
        let request_headers = headers(&session);
        let response = host::fetch("get", url, &request_headers, None)?;
        if response.status != 200 {
            return Err(Error::Http(response.status));
        }
        let body = String::from_utf8_lossy(&response.body).into_owned();
        if body.trim().is_empty() {
            last = Error::Empty;
            if attempt == 0 {
                continue;
            }
            return Err(last);
        }
        return serde_json::from_str(&body)
            .map_err(|err| Error::ParseChanged(format!("返回不是 JSON：{err}")));
    }
    Err(last)
}

// ---- 解析 ----

fn parse_page(body: &Value, page: u32) -> Result<Page, Error> {
    let rows = body
        .pointer("/data/list")
        .or_else(|| body.pointer("/data/playlets"))
        .or_else(|| body.pointer("/data/data"))
        .and_then(Value::as_array)
        .or_else(|| body.get("list").and_then(Value::as_array))
        .ok_or_else(|| Error::ParseChanged("目录缺少 list".into()))?;
    let items: Vec<Drama> = rows
        .iter()
        .filter_map(|row| {
            let drama = drama_from_node(row);
            if drama.id.is_empty() {
                None
            } else {
                Some(drama)
            }
        })
        .collect();
    let has_more = body
        .pointer("/data/has_more")
        .and_then(Value::as_bool)
        .unwrap_or_else(|| items.len() >= 10);
    Ok(Page {
        items,
        has_more,
        page,
        cursor: String::new(),
    })
}

fn parse_detail(body: &Value, source_id: &str) -> Result<Detail, Error> {
    let node = body
        .pointer("/data/playlet_info")
        .or_else(|| body.pointer("/data"))
        .or_else(|| body.get("data"))
        .ok_or_else(|| Error::ParseChanged("详情缺少 data".into()))?;
    let mut drama = drama_from_node(node);
    if drama.id.is_empty() {
        drama = empty_drama();
        drama.id = format!("maoguo:{source_id}");
        drama.source_id = source_id.to_string();
    }
    // 七猫分集在 `play_list`；`sort` 是集号，用作分集 id 的后半段，
    // 与编译版 `MaoguoSource` 的 `{source_id}:{number}` 保持一致。
    let rows = node
        .get("play_list")
        .and_then(Value::as_array)
        .ok_or_else(|| Error::ParseChanged("详情缺少 play_list".into()))?;
    let mut chapters: Vec<Chapter> = rows
        .iter()
        .enumerate()
        .filter_map(|(index, row)| {
            let video = pick(row, &["video_url", "videoUrl", "play_url", "url"]);
            if video.is_empty() {
                return None;
            }
            let number: u32 = pick(row, &["sort", "episode", "index"])
                .parse()
                .unwrap_or(index as u32 + 1)
                .max(1);
            Some(Chapter {
                id: format!("{source_id}:{number}"),
                title: {
                    let title = pick(row, &["episode_name", "title", "name"]);
                    if title.is_empty() {
                        format!("第{number}集")
                    } else {
                        title
                    }
                },
                video_url: video,
                page_url: String::new(),
                referer: format!("{BASE}/"),
                vip: false,
            })
        })
        .collect();
    if chapters.is_empty() {
        return Err(Error::ParseChanged("未返回可播放分集".into()));
    }
    chapters.sort_by_key(|chapter| {
        chapter
            .id
            .rsplit_once(':')
            .and_then(|(_, number)| number.parse::<u32>().ok())
            .unwrap_or(0)
    });
    Ok(Detail { drama, chapters })
}

fn drama_from_node(node: &Value) -> Drama {
    let id = pick(node, &["playlet_id", "playletId", "id"]);
    if id.is_empty() {
        return empty_drama();
    }
    Drama {
        id: format!("maoguo:{id}"),
        source_id: id,
        title: pick(node, &["playlet_name", "title", "name"]),
        description: pick(node, &["description", "intro", "summary"]),
        cover: absolute(pick(node, &["image_link", "imageLink", "cover", "cover_url"])),
        episodes: pick(node, &["total_episode_num", "totalEpisodeNum", "total"])
            .parse()
            .unwrap_or_default(),
        category: tag_names(node),
        tags: Vec::new(),
        views: pick(node, &["play_count", "view_count"]),
        heat: String::new(),
        release_status: String::new(),
    }
}

/// WIT 生成的 `Drama` 没有 `Default`，这里给一个空值。
fn empty_drama() -> Drama {
    Drama {
        id: String::new(),
        source_id: String::new(),
        title: String::new(),
        description: String::new(),
        cover: String::new(),
        episodes: 0,
        category: String::new(),
        tags: Vec::new(),
        views: String::new(),
        heat: String::new(),
        release_status: String::new(),
    }
}

fn tag_names(node: &Value) -> String {
    for key in ["tags", "tag_list"] {
        if let Some(list) = node.get(key).and_then(Value::as_array) {
            let names: Vec<String> = list
                .iter()
                .filter_map(|entry| {
                    entry.as_str().map(str::to_string).or_else(|| {
                        entry
                            .get("tag_name")
                            .and_then(Value::as_str)
                            .map(str::to_string)
                    })
                })
                .filter(|name| !name.trim().is_empty())
                .collect();
            if !names.is_empty() {
                return names.join(",");
            }
        }
    }
    pick(node, &["tag_name", "category", "category_name"])
}

fn pick(node: &Value, keys: &[&str]) -> String {
    for key in keys {
        if let Some(value) = node.get(*key) {
            if let Some(text) = value.as_str() {
                if !text.trim().is_empty() {
                    return text.trim().to_string();
                }
            }
            if let Some(number) = value.as_i64() {
                return number.to_string();
            }
        }
    }
    String::new()
}

fn absolute(url: String) -> String {
    if url.is_empty() || url.starts_with("http") {
        return url;
    }
    format!("{}/{}", BASE.trim_end_matches('/'), url.trim_start_matches('/'))
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

// ---- 自带的 crypto（ADR-12：宿主只提供提取原语，crypto 由插件自带） ----

/// Base64 字符映射表：编码结果整体替换后才参与签名。
const CHAR_MAP: &[(char, char)] = &[
    ('+', 'P'),
    ('/', 'X'),
    ('0', 'M'),
    ('1', 'U'),
    ('2', 'l'),
    ('3', 'E'),
    ('4', 'r'),
    ('5', 'Y'),
    ('6', 'W'),
    ('7', 'b'),
    ('8', 'd'),
    ('9', 'J'),
    ('A', '9'),
    ('B', 's'),
    ('C', 'a'),
    ('D', 'I'),
    ('E', '0'),
    ('F', 'o'),
    ('G', 'y'),
    ('H', '_'),
    ('I', 'H'),
    ('J', 'G'),
    ('K', 'i'),
    ('L', 't'),
    ('M', 'g'),
    ('N', 'N'),
    ('O', 'A'),
    ('P', '8'),
    ('Q', 'F'),
    ('R', 'k'),
    ('S', '3'),
    ('T', 'h'),
    ('U', 'f'),
    ('V', 'R'),
    ('W', 'q'),
    ('X', 'C'),
    ('Y', '4'),
    ('Z', 'p'),
    ('a', 'm'),
    ('b', 'B'),
    ('c', 'O'),
    ('d', 'u'),
    ('e', 'c'),
    ('f', '6'),
    ('g', 'K'),
    ('h', 'x'),
    ('i', '5'),
    ('j', 'T'),
    ('k', '-'),
    ('l', '2'),
    ('m', 'z'),
    ('n', 'S'),
    ('o', 'Z'),
    ('p', '1'),
    ('q', 'V'),
    ('r', 'v'),
    ('s', 'j'),
    ('t', 'Q'),
    ('u', '7'),
    ('v', 'D'),
    ('w', 'w'),
    ('x', 'n'),
    ('y', 'L'),
    ('z', 'e'),
];

fn map_chars(base64: &str) -> String {
    base64
        .chars()
        .map(|ch| {
            CHAR_MAP
                .iter()
                .find(|(from, _)| *from == ch)
                .map(|(_, to)| *to)
                .unwrap_or(ch)
        })
        .collect()
}

fn base64_encode(input: &[u8]) -> String {
    const TABLE: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
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

/// 最小 MD5。插件不能依赖宿主的 `md5` 原语（WIT 没有暴露），
/// 也不该把 `md-5` crate 拖进来增加包体，因此这里自带实现。
fn md5_hex(input: &[u8]) -> String {
    let digest = md5(input);
    let mut out = String::with_capacity(32);
    for byte in digest {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

fn md5(input: &[u8]) -> [u8; 16] {
    const S: [u32; 64] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 5, 9, 14, 20, 5, 9, 14, 20, 5,
        9, 14, 20, 5, 9, 14, 20, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 6,
        10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
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

    let mut message = input.to_vec();
    let bit_len = (input.len() as u64).wrapping_mul(8);
    message.push(0x80);
    while message.len() % 64 != 56 {
        message.push(0);
    }
    message.extend_from_slice(&bit_len.to_le_bytes());

    let mut a0: u32 = 0x67452301;
    let mut b0: u32 = 0xefcdab89;
    let mut c0: u32 = 0x98badcfe;
    let mut d0: u32 = 0x10325476;

    for chunk in message.chunks(64) {
        let mut m = [0u32; 16];
        for (index, word) in m.iter_mut().enumerate() {
            let start = index * 4;
            *word = u32::from_le_bytes([
                chunk[start],
                chunk[start + 1],
                chunk[start + 2],
                chunk[start + 3],
            ]);
        }
        let (mut a, mut b, mut c, mut d) = (a0, b0, c0, d0);
        for step in 0..64 {
            let (f, g) = match step {
                0..=15 => ((b & c) | (!b & d), step),
                16..=31 => ((d & b) | (!d & c), (5 * step + 1) % 16),
                32..=47 => (b ^ c ^ d, (3 * step + 5) % 16),
                _ => (c ^ (b | !d), (7 * step) % 16),
            };
            let temp = d;
            d = c;
            c = b;
            b = b.wrapping_add(
                a.wrapping_add(f)
                    .wrapping_add(K[step])
                    .wrapping_add(m[g])
                    .rotate_left(S[step]),
            );
            a = temp;
        }
        a0 = a0.wrapping_add(a);
        b0 = b0.wrapping_add(b);
        c0 = c0.wrapping_add(c);
        d0 = d0.wrapping_add(d);
    }

    let mut out = [0u8; 16];
    out[0..4].copy_from_slice(&a0.to_le_bytes());
    out[4..8].copy_from_slice(&b0.to_le_bytes());
    out[8..12].copy_from_slice(&c0.to_le_bytes());
    out[12..16].copy_from_slice(&d0.to_le_bytes());
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn md5_matches_known_vectors() {
        assert_eq!(md5_hex(b""), "d41d8cd98f00b204e9800998ecf8427e");
        assert_eq!(md5_hex(b"abc"), "900150983cd24fb0d6963f7d28e17f72");
        assert_eq!(
            md5_hex(b"The quick brown fox jumps over the lazy dog"),
            "9e107d9d372bb6826bd81d3542a419d6"
        );
    }

    #[test]
    fn base64_matches_expected_output() {
        assert_eq!(base64_encode(b""), "");
        assert_eq!(base64_encode(b"f"), "Zg==");
        assert_eq!(base64_encode(b"fo"), "Zm8=");
        assert_eq!(base64_encode(b"foo"), "Zm9v");
        assert_eq!(base64_encode(b"foobar"), "Zm9vYmFy");
    }

    #[test]
    fn catalog_signature_matches_compiled_source() {
        // 与编译版 `MaoguoSource::sign_catalog` 逐字一致；两边改一处必须改两处。
        assert_eq!(
            sign_catalog("0", 1),
            md5_hex(b"operation=1playlet_privacy=1tag_id=0d3dGiJc651gSQ8w1")
        );
        assert_eq!(
            sign_catalog("0", 3),
            md5_hex(b"operation=1playlet_privacy=1tag_id=0next_id=3d3dGiJc651gSQ8w1")
        );
    }

    #[test]
    fn detail_and_search_signatures_are_stable() {
        assert_eq!(
            sign_detail("123"),
            md5_hex(format!("playlet_id=123{KEY}").as_bytes())
        );
        assert_eq!(
            sign_search("总裁"),
            md5_hex(
                format!("extend=page=1read_preference=0track_id={TRACK_ID}wd=总裁{KEY}").as_bytes()
            )
        );
    }

    #[test]
    fn qm_params_is_remapped() {
        let params = qm_params("123");
        // 字符映射之后不应再出现原始 Base64 的 `+` / `/`。
        assert!(!params.contains('+'));
        assert!(!params.contains('/'));
        assert!(!params.is_empty());
    }

    #[test]
    fn encode_component_escapes_non_ascii() {
        assert_eq!(encode_component("abc"), "abc");
        assert_eq!(encode_component("总裁"), "%E6%80%BB%E8%A3%81");
    }

    #[test]
    fn catalog_url_includes_paging_only_after_first_page() {
        let first = catalog_url("0", 1);
        assert!(!first.contains("next_id="));
        let third = catalog_url("0", 3);
        assert!(third.contains("next_id=3"));
    }
}
