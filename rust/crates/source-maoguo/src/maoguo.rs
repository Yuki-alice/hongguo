use async_trait::async_trait;
use serde_json::Value;

use guo_source_api::{
    md5_hash, Chapter, Detail, Drama, FetchRequest, Media, Page, SourceEnv, SourceError,
};
use guo_source_api::{Capability, SourceMeta, SourcePlugin, CURRENT_API_LEVEL};

/// 猫果（七猫）签名接口。
///
/// 目录、详情、搜索各自使用不同签名串，签名由脚本层计算，
/// 宿主只负责拼接 URL 和解析 JSON。
pub struct MaoguoSource {
    meta: SourceMeta,
}

const BASE: &str = "https://api-store.qmplaylet.com";
const READ_BASE: &str = "https://api-read.qmplaylet.com";
const KEY: &str = "d3dGiJc651gSQ8w1";
const TRACK_ID: &str = "ec1280db127955061754851657967";

/// 七猫的 `qm-params` 字符映射表：Base64 结果整体替换后才参与签名。
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

impl Default for MaoguoSource {
    fn default() -> Self {
        Self::new()
    }
}

impl MaoguoSource {
    pub fn new() -> Self {
        Self {
            meta: SourceMeta {
                id: "maoguo".into(),
                name: "猫果".into(),
                group: "duanju".into(),
                api_level: CURRENT_API_LEVEL,
                capabilities: vec![Capability::Catalog, Capability::Detail, Capability::Search],
            },
        }
    }

    pub fn sign_catalog(tag_id: &str, page: u32) -> String {
        let mut text = String::from("operation=1playlet_privacy=1tag_id=");
        text.push_str(tag_id);
        if page > 1 {
            text.push_str(&format!("next_id={page}"));
        }
        text.push_str(KEY);
        format!("{:032x}", md5_hash(text.as_bytes()))
    }

    pub fn sign_detail(source_id: &str) -> String {
        let text = format!("playlet_id={source_id}{KEY}");
        format!("{:032x}", md5_hash(text.as_bytes()))
    }

    pub fn sign_search(query: &str) -> String {
        let text = format!("extend=page=1read_preference=0track_id={TRACK_ID}wd={query}{KEY}");
        format!("{:032x}", md5_hash(text.as_bytes()))
    }

    pub fn sign_tags() -> String {
        format!("{:032x}", md5_hash(format!("operation=1{KEY}").as_bytes()))
    }

    pub fn catalog_url(tag_id: &str, page: u32) -> String {
        let sign = Self::sign_catalog(tag_id, page);
        if page > 1 {
            format!(
                "{BASE}/api/v1/playlet/index?tag_id={tag_id}&playlet_privacy=1&operation=1&next_id={page}&sign={sign}"
            )
        } else {
            format!(
                "{BASE}/api/v1/playlet/index?tag_id={tag_id}&playlet_privacy=1&operation=1&sign={sign}"
            )
        }
    }

    pub fn detail_url(source_id: &str) -> String {
        let sign = Self::sign_detail(source_id);
        let encoded = encode_component(source_id);
        format!("{READ_BASE}/player/api/v1/playlet/info?playlet_id={encoded}&sign={sign}")
    }

    pub fn search_url(query: &str) -> String {
        let sign = Self::sign_search(query);
        let encoded = encode_component(query);
        format!(
            "{BASE}/api/v1/playlet/search?extend=&page=1&wd={encoded}&read_preference=0&track_id={TRACK_ID}&sign={sign}"
        )
    }

    pub fn tags_url() -> String {
        format!(
            "{BASE}/api/v1/playlet/tag/list?operation=1&sign={}",
            Self::sign_tags()
        )
    }

    /// 构造 `qm-params`：设备信息 JSON → Base64 → 字符映射。
    pub fn qm_params(session_id: &str) -> String {
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

    /// 授权头签名：`md5("AUTHORIZATION=app-version=...qm-params=<件>reg=<key>")`
    pub fn sign_authorization(qm_params: &str) -> String {
        let text = format!(
            "AUTHORIZATION=app-version=10001application-id=com.duoduo.readchannel=unknownis-white=net-env=5platform=androidqm-params={qm_params}reg={KEY}"
        );
        format!("{:032x}", md5_hash(text.as_bytes()))
    }

    /// 带一次重试的请求。
    ///
    /// 七猫接口对并发请求较敏感，偶发返回空或错误；重试前会刷新会话时间戳，
    /// 因此第二次请求带的是新的 `qm-params`。
    async fn fetch_with_retry(
        &self,
        env: &SourceEnv,
        url: &str,
        _kind: RequestKind,
    ) -> Result<String, SourceError> {
        let mut last = SourceError::NoResult;
        for attempt in 0..2 {
            let session_id = current_millis();
            match env
                .text(Self::headers(FetchRequest::get(url), &session_id))
                .await
            {
                Ok(body) if !body.trim().is_empty() => return Ok(body),
                Ok(_) => last = SourceError::NoResult,
                Err(err) => last = err,
            }
            if attempt == 0 {
                tokio::time::sleep(std::time::Duration::from_millis(120)).await;
            }
        }
        Err(last)
    }

    /// 用当前时间戳构造完整请求头，供示例与测试复用。
    pub fn signed_request(url: &str) -> FetchRequest {
        Self::headers(FetchRequest::get(url), &current_millis())
    }

    fn headers(request: FetchRequest, session_id: &str) -> FetchRequest {
        let qm_params = Self::qm_params(session_id);
        let sign = Self::sign_authorization(&qm_params);
        request
            .header("Referer", format!("{BASE}/"))
            .header("platform", "android")
            .header("application-id", "com.duoduo.read")
            .header("app-version", "10001")
            .header("channel", "unknown")
            .header("net-env", "5")
            .header("is-white", "")
            .header("reg", "")
            .header("authorization", "")
            .header("qm-params", qm_params)
            .header("sign", sign)
            .header("Accept", "application/json")
            .header("X-Requested-With", "com.duoduo.read")
            .header("user-agent", "webviewversion/0")
    }
}

fn drama_from_node(node: &Value, base: &str) -> Drama {
    let id = pick(node, &["playlet_id", "playletId", "id"]);
    if id.is_empty() {
        return Drama::default();
    }
    let cover = pick(node, &["image_link", "imageLink", "cover", "cover_url"]);
    Drama {
        id: Drama::identity("maoguo", &id),
        source: "maoguo".into(),
        source_id: id.clone(),
        title: pick(node, &["playlet_name", "title", "name"]),
        description: pick(node, &["description", "intro", "summary"]),
        cover: absolute(base, &cover),
        episodes: pick(node, &["total_episode_num", "totalEpisodeNum", "total"])
            .parse()
            .unwrap_or_default(),
        category: tag_names(node),
        ..Default::default()
    }
}

/// 分类优先取 `tags` / `tag_list` 数组，其次退回单个标签字段。
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
            if let Some(number) = value.as_f64() {
                return format!("{number}");
            }
        }
    }
    String::new()
}

fn absolute(base: &str, url: &str) -> String {
    if url.is_empty() || url.starts_with("http") {
        return url.to_string();
    }
    format!(
        "{}/{}",
        base.trim_end_matches('/'),
        url.trim_start_matches('/')
    )
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

#[async_trait]
impl SourcePlugin for MaoguoSource {
    fn meta(&self) -> SourceMeta {
        self.meta.clone()
    }

    async fn catalog(
        &self,
        env: &SourceEnv,
        page: u32,
        category: &str,
    ) -> Result<Page, SourceError> {
        let tag = category.trim();
        let tag = if tag.chars().all(|c| c.is_ascii_digit()) && !tag.is_empty() {
            tag
        } else {
            "0"
        };
        let url = Self::catalog_url(tag, page);
        let body = self
            .fetch_with_retry(env, &url, RequestKind::Catalog)
            .await?;
        let value: Value = serde_json::from_str(&body)
            .map_err(|err| SourceError::parse("maoguo.catalog", format!("{err}: {body:.120}")))?;
        let data = value.get("data").unwrap_or(&Value::Null);
        let mut items = Vec::new();
        let mut seen = std::collections::HashSet::new();
        if let Some(list) = data.get("list").and_then(Value::as_array) {
            for node in list {
                let drama = drama_from_node(node, BASE);
                if drama.source_id.is_empty() || !seen.insert(drama.source_id.clone()) {
                    continue;
                }
                items.push(drama);
            }
        }
        let has_more = !items.is_empty();
        Ok(Page {
            items,
            has_more,
            page,
            warning: String::new(),
        })
    }

    async fn detail(&self, env: &SourceEnv, source_id: &str) -> Result<Detail, SourceError> {
        let url = Self::detail_url(source_id);
        let body = self
            .fetch_with_retry(env, &url, RequestKind::Detail)
            .await?;
        let value: Value = serde_json::from_str(&body)
            .map_err(|err| SourceError::parse("maoguo.detail", format!("{err}")))?;
        let data = value
            .get("data")
            .ok_or_else(|| SourceError::parse("maoguo.detail", "缺少 data 字段"))?;
        let mut drama = drama_from_node(data, BASE);
        drama.id = Drama::identity("maoguo", source_id);
        drama.source = "maoguo".into();
        drama.source_id = source_id.to_string();

        let mut chapters = Vec::new();
        if let Some(list) = data.get("play_list").and_then(Value::as_array) {
            for (index, node) in list.iter().enumerate() {
                let url = pick(node, &["video_url", "videoUrl", "url"]);
                if url.is_empty() {
                    continue;
                }
                let number = pick(node, &["sort", "episode", "index"])
                    .parse::<u32>()
                    .unwrap_or(index as u32 + 1)
                    .max(1);
                chapters.push(Chapter {
                    id: format!("{source_id}:{number}"),
                    title: chapter_title(node, number),
                    source: "maoguo".into(),
                    video_url: url,
                    referer: format!("{BASE}/"),
                    ..Default::default()
                });
            }
        }
        if chapters.is_empty() {
            return Err(SourceError::parse("maoguo.detail", "未返回可播放分集"));
        }
        chapters.sort_by_key(|chapter| {
            chapter
                .id
                .rsplit(':')
                .next()
                .and_then(|tail| tail.parse::<u32>().ok())
                .unwrap_or(u32::MAX)
        });
        Ok(Detail { drama, chapters })
    }

    async fn search(&self, env: &SourceEnv, query: &str, page: u32) -> Result<Page, SourceError> {
        if page > 1 {
            return Ok(Page {
                items: Vec::new(),
                has_more: false,
                page,
                warning: String::new(),
            });
        }
        let url = Self::search_url(query);
        let body = self
            .fetch_with_retry(env, &url, RequestKind::Search)
            .await?;
        let value: Value = serde_json::from_str(&body)
            .map_err(|err| SourceError::parse("maoguo.search", format!("{err}")))?;
        let data = value.get("data").unwrap_or(&Value::Null);
        let mut items = Vec::new();
        if let Some(list) = data.get("list").and_then(Value::as_array) {
            for node in list {
                let drama = drama_from_node(node, BASE);
                if !drama.source_id.is_empty() {
                    items.push(drama);
                }
            }
        }
        Ok(Page {
            items,
            has_more: false,
            page,
            warning: String::new(),
        })
    }

    async fn resolve(
        &self,
        env: &SourceEnv,
        _drama: &Drama,
        chapter: &Chapter,
    ) -> Result<Media, SourceError> {
        if chapter.video_url.is_empty() {
            return Err(SourceError::parse("maoguo.resolve", "分集缺少播放地址"));
        }
        let referer = format!("{BASE}/");
        // 七猫的 CDN 地址不带扩展名，但内容可能是 HLS，需要探测。
        let body = env
            .text(FetchRequest::get(&chapter.video_url).header("Referer", &referer))
            .await?;
        let playlist = guo_media::parse_playlist(&body, &chapter.video_url);
        if !playlist.is_hls {
            return Ok(Media {
                url: chapter.video_url.clone(),
                referer,
                playlist: None,
                key_uri: String::new(),
                key_iv: String::new(),
                cookies: String::new(),
                origin: String::new(),
            });
        }
        if playlist.segments.is_empty() {
            if let Some(variant) = playlist.variants.first() {
                let nested = env
                    .text(FetchRequest::get(variant).header("Referer", &referer))
                    .await?;
                let inner = guo_media::parse_playlist(&nested, variant);
                if inner.is_hls {
                    return Ok(Media {
                        url: variant.clone(),
                        referer,
                        playlist: Some(inner.segments),
                        key_uri: inner.key_uri.clone().unwrap_or_default(),
                        key_iv: inner.key_iv.clone().unwrap_or_default(),
                        cookies: String::new(),
                        origin: String::new(),
                    });
                }
            }
        }
        Ok(Media {
            url: chapter.video_url.clone(),
            referer,
            playlist: Some(playlist.segments),
            key_uri: playlist.key_uri.clone().unwrap_or_default(),
            key_iv: playlist.key_iv.clone().unwrap_or_default(),
            cookies: String::new(),
            origin: String::new(),
        })
    }
}

fn chapter_title(node: &Value, number: u32) -> String {
    let title = pick(node, &["title", "name"]);
    if title.is_empty() {
        format!("第{number}集")
    } else {
        title
    }
}

/// 请求类型，仅用于诊断与未来差异化重试策略。
#[derive(Debug, Clone, Copy)]
enum RequestKind {
    Catalog,
    Detail,
    Search,
}

fn current_millis() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis().to_string())
        .unwrap_or_else(|_| "0".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn md5_matches_rfc_vectors() {
        assert_eq!(
            format!("{:032x}", md5_hash(b"")),
            "d41d8cd98f00b204e9800998ecf8427e"
        );
        assert_eq!(
            format!("{:032x}", md5_hash(b"abc")),
            "900150983cd24fb0d6963f7d28e17f72"
        );
        assert_eq!(
            format!(
                "{:032x}",
                md5_hash(b"The quick brown fox jumps over the lazy dog")
            ),
            "9e107d9d372bb6826bd81d3542a419d6"
        );
    }

    #[test]
    fn catalog_signature_follows_upstream_order() {
        let first = MaoguoSource::sign_catalog("0", 1);
        let expected = format!(
            "{:032x}",
            md5_hash(format!("operation=1playlet_privacy=1tag_id=0{KEY}").as_bytes())
        );
        assert_eq!(first, expected);

        let second = MaoguoSource::sign_catalog("0", 3);
        let expected = format!(
            "{:032x}",
            md5_hash(format!("operation=1playlet_privacy=1tag_id=0next_id=3{KEY}").as_bytes())
        );
        assert_eq!(second, expected);
        assert_ne!(first, second);
    }

    #[test]
    fn search_signature_places_key_after_keyword() {
        let sign = MaoguoSource::sign_search("都市");
        let expected = format!(
            "{:032x}",
            md5_hash(
                format!("extend=page=1read_preference=0track_id={TRACK_ID}wd=都市{KEY}").as_bytes()
            )
        );
        assert_eq!(sign, expected);
    }

    #[test]
    fn catalog_url_encodes_paging() {
        let first = MaoguoSource::catalog_url("0", 1);
        assert!(!first.contains("next_id"));
        let second = MaoguoSource::catalog_url("0", 2);
        assert!(second.contains("next_id=2"));
    }

    #[test]
    fn detail_url_escapes_source_id() {
        let url = MaoguoSource::detail_url("a b/c");
        assert!(url.contains("playlet_id=a%20b%2Fc"), "{url}");
    }

    #[test]
    fn metadata_declares_capabilities() {
        let source = MaoguoSource::new();
        let meta = source.meta();
        assert_eq!(meta.id, "maoguo");
        assert!(meta.supports(Capability::Catalog));
        assert!(meta.supports(Capability::Detail));
        assert!(meta.supports(Capability::Search));
        assert!(!meta.supports(Capability::Categories));
    }
}
