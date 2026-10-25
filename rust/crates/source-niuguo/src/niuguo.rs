use aes::cipher::{BlockDecrypt, KeyInit};
use aes::Aes128;
use async_trait::async_trait;
use base64::Engine;
use serde_json::Value;

use guo_source_api::{Capability, ContentType, SourceMeta, SourcePlugin, CURRENT_API_LEVEL};
use guo_source_api::{Chapter, Detail, Drama, FetchRequest, Media, Page, SourceEnv, SourceError};

/// 牛果（牛牛短剧）接口站源。
///
/// 与其他 JSON 站源不同，这里的响应体不是明文 JSON，而是 Base64 包裹的
/// AES-ECB 密文；密钥是**实际发出的请求 URI 前 16 字节**。参数顺序一变
/// 密钥就变，因此解密必须紧贴「真正发出去的那个地址」，不能用规则里的
/// 模板重新拼一次。
pub struct NiuguoSource {
    meta: SourceMeta,
}

const BASE: &str = "https://ccc.chaojichaojichanga.com:35620";
/// 分集解析服务。主域名失效时按顺序回退。
const PARSE_BASES: &[&str] = &["http://ccs.jshh.gzbaoxian.com", "http://101.42.92.211:5560"];
const PARSE_SCRIPTS: &[&str] = &["qy.php", "dj.php"];

impl Default for NiuguoSource {
    fn default() -> Self {
        Self::new()
    }
}

impl NiuguoSource {
    pub fn new() -> Self {
        Self {
            meta: SourceMeta {
                id: "niuguo".into(),
                name: "牛果".into(),
                group: "duanju".into(),
                api_level: CURRENT_API_LEVEL,
                content_types: vec![ContentType::ShortDrama],
                capabilities: vec![Capability::Catalog, Capability::Detail, Capability::Search],
            },
        }
    }

    /// 目录地址。`page` 从 1 开始，直接作为 `page` 参数。
    fn catalog_url(category: &str, page: u32) -> String {
        let class = encode_component(category.trim());
        format!(
            "{BASE}/list?class={class}&order={}&type_id=5&area=&year=&state=&wd=&page={page}",
            encode_component("最新")
        )
    }

    fn detail_url(source_id: &str) -> String {
        format!("{BASE}/detail?vod_id={}", encode_component(source_id))
    }

    fn search_url(query: &str, page: u32) -> String {
        format!(
            "{BASE}/list?class=&order={}&type_id=5&area=&year=&state=&wd={}&page={page}",
            encode_component("最新"),
            encode_component(query.trim())
        )
    }

    /// 拉取并解密一个接口响应。
    ///
    /// 密钥用**请求实际使用的 URI**（路径 + 查询串）计算，与站点口径一致。
    async fn fetch_json(&self, env: &SourceEnv, url: &str) -> Result<Value, SourceError> {
        let body = env
            .text(FetchRequest::get(url).header("Referer", format!("{BASE}/")))
            .await?;
        let key = uri_key(url);
        decrypt_payload(&body, &key)
    }
}

#[async_trait]
impl SourcePlugin for NiuguoSource {
    fn meta(&self) -> SourceMeta {
        self.meta.clone()
    }

    async fn catalog(
        &self,
        env: &SourceEnv,
        page: u32,
        category: &str,
    ) -> Result<Page, SourceError> {
        let url = Self::catalog_url(category, page);
        let value = self.fetch_json(env, &url).await?;
        let items = items_from(&value);
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
        let value = self.fetch_json(env, &url).await?;
        let node = value
            .get("data")
            .and_then(|data| data.as_array().and_then(|list| list.first()).or(Some(data)))
            .ok_or_else(|| SourceError::parse("niuguo.detail", "缺少 data 字段"))?;
        let mut drama = drama_from_node(node);
        drama.id = Drama::identity("niuguo", source_id);
        drama.source = "niuguo".into();
        drama.source_id = source_id.to_string();

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
                        source: "niuguo".into(),
                        // 这里是内部分集 ID，不是播放地址；取流时再解析。
                        video_url: id,
                        referer: format!("{BASE}/"),
                        ..Default::default()
                    });
                }
            }
        }
        if chapters.is_empty() {
            return Err(SourceError::parse("niuguo.detail", "未返回可播放分集"));
        }
        Ok(Detail { drama, chapters })
    }

    async fn search(&self, env: &SourceEnv, query: &str, page: u32) -> Result<Page, SourceError> {
        if query.trim().is_empty() {
            return Ok(Page {
                items: Vec::new(),
                has_more: false,
                page,
                warning: String::new(),
            });
        }
        let url = Self::search_url(query, page);
        let value = self.fetch_json(env, &url).await?;
        let items = items_from(&value);
        let has_more = !items.is_empty();
        Ok(Page {
            items,
            has_more,
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
        let source_id = chapter.video_url.trim();
        if source_id.is_empty() {
            return Err(SourceError::parse(
                "niuguo.resolve",
                "分集缺少解析 ID，请刷新详情后重试",
            ));
        }
        let mut last = SourceError::NoResult;
        for base in PARSE_BASES {
            let referer = format!("{}/", base.trim_end_matches('/'));
            for script in PARSE_SCRIPTS {
                let address = format!(
                    "{}/jx/{script}?url={}",
                    base.trim_end_matches('/'),
                    encode_component(source_id)
                );
                let body = match env
                    .text(FetchRequest::get(&address).header("Referer", &referer))
                    .await
                {
                    Ok(body) => body,
                    Err(err) => {
                        last = err;
                        continue;
                    }
                };
                let Ok(value) = serde_json::from_str::<Value>(&body) else {
                    last = SourceError::parse("niuguo.resolve", "解析服务返回的数据格式无法识别");
                    continue;
                };
                let url = pick(&value, &["url"]);
                if url.is_empty() {
                    last = SourceError::parse("niuguo.resolve", "解析服务未返回播放地址");
                    continue;
                }
                return Ok(Media {
                    url,
                    referer,
                    playlist: None,
                    key_uri: String::new(),
                    key_iv: String::new(),
                    cookies: String::new(),
                    origin: String::new(),
                    cenc_key: String::new(),
                    quality: 0,
                    qualities: Vec::new(),
                });
            }
        }
        Err(last)
    }
}

/// 目录与搜索共用的响应结构：`data` 是数组，个别接口把它包在 `list` 里。
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
    if source_id.is_empty() {
        return Drama::default();
    }
    Drama {
        id: Drama::identity("niuguo", &source_id),
        source: "niuguo".into(),
        source_id,
        title: pick(node, &["vod_name", "vodName", "title"]),
        description: pick(node, &["vod_content", "vod_blurb", "vodContent", "desc"]),
        cover: pick(node, &["vod_pic", "vodPic", "cover"]),
        category: pick(node, &["type_name", "typeName"]),
        ..Default::default()
    }
}

/// 取第一个非空字段；数字字段转成十进制文本。
fn pick(node: &Value, keys: &[&str]) -> String {
    for key in keys {
        let Some(value) = node.get(*key) else {
            continue;
        };
        if let Some(text) = value.as_str() {
            if !text.trim().is_empty() {
                return text.trim().to_string();
            }
        }
        if let Some(number) = value.as_i64() {
            return number.to_string();
        }
    }
    String::new()
}

/// 牛果把密钥定义为请求 URI 的前 16 字节，不足补零。
/// 这里的 URI 指「路径 + 查询串」，不含协议与域名，与站点口径一致。
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

fn decrypt_payload(body: &str, key: &[u8; 16]) -> Result<Value, SourceError> {
    let encoded = body.trim();
    if encoded.is_empty() {
        return Err(SourceError::parse("niuguo.decrypt", "站点返回了空响应"));
    }
    const ENGINE: base64::engine::GeneralPurpose = base64::engine::GeneralPurpose::new(
        &base64::alphabet::STANDARD,
        base64::engine::GeneralPurposeConfig::new(),
    );
    let raw = ENGINE
        .decode(encoded)
        .or_else(|_| ENGINE.decode(encoded.trim_end_matches('=')))
        .map_err(|_| SourceError::parse("niuguo.decrypt", "响应不是有效的 Base64 数据"))?;
    if raw.is_empty() || raw.len() % 16 != 0 {
        return Err(SourceError::parse(
            "niuguo.decrypt",
            "响应长度不符合加密块要求",
        ));
    }
    let cipher = Aes128::new(aes::cipher::generic_array::GenericArray::from_slice(key));
    let mut plain = raw;
    for block in plain.as_chunks_mut::<16>().0 {
        cipher.decrypt_block(aes::cipher::generic_array::GenericArray::from_mut_slice(
            block,
        ));
    }
    let unpadded = unpad(&plain)?;
    serde_json::from_slice(unpadded)
        .map_err(|_| SourceError::parse("niuguo.decrypt", "解密后不是有效数据"))
}

/// 严格校验 PKCS#7 填充：填充字节必须全部等于填充长度。
fn unpad(data: &[u8]) -> Result<&[u8], SourceError> {
    let Some(&pad) = data.last() else {
        return Err(SourceError::parse("niuguo.decrypt", "解密结果为空"));
    };
    let pad = pad as usize;
    if pad == 0 || pad > 16 || pad > data.len() {
        return Err(SourceError::parse("niuguo.decrypt", "响应解密失败"));
    }
    if !data[data.len() - pad..]
        .iter()
        .all(|byte| *byte as usize == pad)
    {
        return Err(SourceError::parse("niuguo.decrypt", "响应解密失败"));
    }
    Ok(&data[..data.len() - pad])
}

/// 百分号编码：只保留 RFC 3986 的非保留字符，其余按 UTF-8 逐字节转义。
fn encode_component(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*byte as char);
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
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
    fn encode_component_escapes_utf8_and_keeps_unreserved() {
        assert_eq!(encode_component("abc-_.~"), "abc-_.~");
        assert_eq!(encode_component("最新"), "%E6%9C%80%E6%96%B0");
        assert_eq!(encode_component("a b"), "a%20b");
    }

    #[test]
    fn unpad_rejects_tampered_padding() {
        // 末尾声明 4 字节填充，实际只有 3 个 4。
        assert!(unpad(&[1, 2, 3, 4, 4, 4, 4, 4, 5]).is_err());
        let mut bad = vec![8u8; 8];
        bad[7] = 9;
        assert!(unpad(&bad).is_err());
        // 填充长度超过块长。
        assert!(unpad(&[1, 2, 17]).is_err());
        let good = [7u8, 2, 2];
        assert_eq!(unpad(&good).map(|data| data.to_vec()), Ok(vec![7]));
    }

    #[test]
    fn items_deduplicates_and_skips_missing_ids() {
        let value = serde_json::json!({
            "data": [
                {"vod_id": 1, "vod_name": "甲"},
                {"vod_id": 1, "vod_name": "甲重复"},
                {"vod_name": "没有 id"}
            ]
        });
        let items = items_from(&value);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].source_id, "1");
        assert_eq!(items[0].title, "甲");
        assert_eq!(items[0].id, "niuguo:1");
    }

    #[test]
    fn items_reads_nested_list_shape() {
        let value = serde_json::json!({
            "data": {"list": [{"vod_id": "9", "vod_name": "乙"}]}
        });
        let items = items_from(&value);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].source_id, "9");
    }
}
