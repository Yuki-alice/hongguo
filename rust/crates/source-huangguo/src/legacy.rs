//! 黄果旧版（cloudfront API）。
//!
//! 这是三源里唯一在当前网络下**能完整在线验证**的：官网前端
//! `d2pypzndaqisk.cloudfront.net` 与 API `dr6skssi3nxbk.cloudfront.net` 都可达。
//!
//! 协议三层：
//! 1. 从官网前端 `main-*.js` 里提取 `interfaceKey` / `parameterKey` / `parameterIv`；
//! 2. 请求参数用 `parameterKey` + `parameterIv` 做 AES-CBC 加密，Base64 后放 `data`；
//! 3. 响应用 `interfaceKey` 与响应自带的 12 字节前缀派生密钥再解密。

use std::sync::Mutex;

use aes::cipher::{BlockDecrypt, BlockEncrypt, KeyInit};
use aes::Aes128;
use async_trait::async_trait;
use base64::Engine;
use serde_json::Value;
use sha2::{Digest, Sha256};

use guo_source_api::{Capability, ContentType, SourceMeta, SourcePlugin, CURRENT_API_LEVEL};
use guo_source_api::{
    Category, Chapter, Detail, Drama, FetchRequest, Media, Page, SourceEnv, SourceError,
};

pub struct LegacySource {
    meta: SourceMeta,
    session: Mutex<Option<Session>>,
    protocol: Mutex<Option<Protocol>>,
}

#[derive(Clone)]
struct Protocol {
    interface_key: Vec<u8>,
    param_key: [u8; 16],
    param_iv: [u8; 16],
}

#[derive(Clone)]
struct Session {
    device_id: String,
    token: String,
}

const API_BASE: &str = "https://dr6skssi3nxbk.cloudfront.net";
const FRONTEND: &str = "https://d2pypzndaqisk.cloudfront.net";
const CDN: &str = "https://sjljsla.lkkwip.cn";
const USER_AGENT: &str =
    "BuildID=com.abc.Butterfly;SysType=ios;DevID=00000000000000000000000000000;\
Ver=1.0.0;DevType=iPhone;DeviceBrand=APPLE;DeviceModel=iPhone;SystemName=iOS;SystemVersion=18.7;\
Terminal=1;IsH5=1;Sid=00000000000000000000000000000000";
const PAGE_SIZE: u32 = 20;

impl Default for LegacySource {
    fn default() -> Self {
        Self::new()
    }
}

impl LegacySource {
    pub fn new() -> Self {
        Self {
            meta: SourceMeta {
                id: "cloudfront".into(),
                name: "黄果旧版".into(),
                group: "duanju".into(),
                api_level: CURRENT_API_LEVEL,
                content_types: vec![ContentType::ShortDrama],
                capabilities: vec![
                    Capability::Catalog,
                    Capability::Detail,
                    Capability::Categories,
                ],
            },
            session: Mutex::new(None),
            protocol: Mutex::new(None),
        }
    }

    fn cached_protocol(&self) -> Option<Protocol> {
        self.protocol.lock().ok().and_then(|guard| guard.clone())
    }

    fn cached_session(&self) -> Option<Session> {
        self.session.lock().ok().and_then(|guard| guard.clone())
    }

    fn store_session(&self, session: Option<Session>) {
        if let Ok(mut guard) = self.session.lock() {
            *guard = session;
        }
    }

    /// 从官网前端脚本提取协议密钥。取不到就无法请求任何接口。
    async fn protocol(&self, env: &SourceEnv) -> Result<Protocol, SourceError> {
        if let Some(protocol) = self.cached_protocol() {
            return Ok(protocol);
        }
        let page = env.text(FetchRequest::get(format!("{FRONTEND}/"))).await?;
        let script_path = page
            .split("src=\"")
            .skip(1)
            .filter_map(|rest| rest.split('"').next())
            .find(|src| src.contains("/main-") && src.ends_with(".js"))
            .ok_or_else(|| SourceError::parse("cloudfront.protocol", "官网未提供前端脚本"))?;
        let script = env
            .text(FetchRequest::get(format!("{FRONTEND}{script_path}")))
            .await?;
        let protocol = parse_protocol(&script)
            .ok_or_else(|| SourceError::parse("cloudfront.protocol", "官网协议已变化"))?;
        if let Ok(mut guard) = self.protocol.lock() {
            *guard = Some(protocol.clone());
        }
        Ok(protocol)
    }

    /// 匿名登录。设备号形如「8 位大写十六进制 + 13 位毫秒时间戳」。
    async fn session(&self, env: &SourceEnv) -> Result<Session, SourceError> {
        if let Some(session) = self.cached_session() {
            return Ok(session);
        }
        let protocol = self.protocol(env).await?;
        let device_id = device_id();
        let body = call(
            env,
            &protocol,
            "POST",
            "/api/app/mine/login/h5",
            Some(serde_json::json!({
                "devID": device_id,
                "sysType": "ios",
                "isAppStore": false,
            })),
            Some(&device_id),
            None,
        )
        .await?;
        let token = body
            .get("token")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim()
            .to_string();
        if token.is_empty() || token.len() > 8192 {
            return Err(SourceError::parse(
                "cloudfront.auth",
                "访客登录未返回有效令牌",
            ));
        }
        let session = Session { device_id, token };
        self.store_session(Some(session.clone()));
        Ok(session)
    }

    /// 带会话调用接口；返回 5005 时丢弃会话重试一次。
    async fn api(
        &self,
        env: &SourceEnv,
        path: &str,
        params: Option<Value>,
    ) -> Result<Value, SourceError> {
        for attempt in 0..2 {
            let protocol = self.protocol(env).await?;
            let session = self.session(env).await?;
            match call(
                env,
                &protocol,
                "GET",
                path,
                params.clone(),
                Some(&session.device_id),
                Some(&session.token),
            )
            .await
            {
                Ok(value) => return Ok(value),
                Err(err) if attempt == 0 && is_session_expired(&err) => self.store_session(None),
                Err(err) => return Err(err),
            }
        }
        Err(SourceError::parse(
            "cloudfront.auth",
            "访客会话已失效，请重试",
        ))
    }
}

#[async_trait]
impl SourcePlugin for LegacySource {
    fn meta(&self) -> SourceMeta {
        self.meta.clone()
    }

    async fn categories(&self, env: &SourceEnv) -> Result<Vec<Category>, SourceError> {
        // 分类清单来自同一个 tab 接口，catalog 直接复用 `tabs()`，
        // 这里只是把它转成对外契约的形态。
        Ok(self
            .tabs(env)
            .await?
            .into_iter()
            .map(|(id, name)| Category { id, name })
            .collect())
    }

    async fn catalog(
        &self,
        env: &SourceEnv,
        page: u32,
        category: &str,
    ) -> Result<Page, SourceError> {
        let tabs = self.tabs(env).await?;
        let selected: Vec<(String, String)> = if category.trim().is_empty() {
            tabs
        } else {
            tabs.into_iter()
                .filter(|(id, _)| id == category.trim())
                .collect()
        };
        if selected.is_empty() {
            return Err(SourceError::parse("cloudfront.catalog", "未知分类"));
        }
        let mut items = Vec::new();
        let mut seen = std::collections::HashSet::new();
        let mut failures = Vec::new();
        for (id, name) in selected {
            let path = format!("/api/app/playlet/home/tab/{}", encode_component(&id));
            let params = Some(serde_json::json!({
                "pageNumber": page.max(1).to_string(),
                "pageSize": PAGE_SIZE.to_string(),
                "tabSortType": "1",
            }));
            match self.api(env, &path, params).await {
                Ok(value) => {
                    for drama in list_from(&value, &name) {
                        if seen.insert(drama.source_id.clone()) {
                            items.push(drama);
                        }
                    }
                }
                Err(err) => failures.push(format!("{name}: {err}")),
            }
        }
        if items.is_empty() && !failures.is_empty() {
            return Err(SourceError::parse(
                "cloudfront.catalog",
                failures.join("; "),
            ));
        }
        Ok(Page {
            items,
            has_more: !failures.is_empty() || page > 0,
            page,
            warning: failures.join("; "),
        })
    }

    async fn detail(&self, env: &SourceEnv, source_id: &str) -> Result<Detail, SourceError> {
        let id = source_id.trim().trim_matches('/');
        if id.is_empty() {
            return Err(SourceError::parse("cloudfront.detail", "缺少剧集标识"));
        }
        let value = self
            .api(
                env,
                &format!("/api/app/playlet/detail/{}", encode_component(id)),
                None,
            )
            .await?;
        let mut drama = drama_from(&value, id);
        drama.id = Drama::identity("cloudfront", id);
        drama.source = "cloudfront".into();
        drama.source_id = id.to_string();

        let chapters_value = self
            .api(
                env,
                &format!("/api/app/playlet-chapter/list/{}", encode_component(id)),
                None,
            )
            .await?;
        let rows = chapters_value
            .get("data")
            .and_then(Value::as_array)
            .ok_or_else(|| SourceError::parse("cloudfront.detail", "缺少分集列表"))?;
        let mut chapters = Vec::with_capacity(rows.len());
        for (index, row) in rows.iter().enumerate() {
            let video = pick(row, &["videoUrl"]);
            if video.is_empty() {
                continue;
            }
            let number = row
                .get("currentEpisode")
                .and_then(Value::as_u64)
                .map(|value| value as u32)
                .unwrap_or(index as u32 + 1)
                .max(1);
            let title = pick(row, &["title"]);
            chapters.push(Chapter {
                id: format!("{id}:{number}"),
                title: if title.is_empty() {
                    format!("第{number}集")
                } else {
                    title
                },
                source: "cloudfront".into(),
                // 存的是加密路径段，取流时再拼成 m3u8 地址。
                video_url: video,
                referer: format!("{FRONTEND}/"),
                vip: row.get("unlockType").and_then(Value::as_u64).unwrap_or(0) > 0,
                ..Default::default()
            });
        }
        if chapters.is_empty() {
            return Err(SourceError::parse("cloudfront.detail", "未返回可播放分集"));
        }
        Ok(Detail { drama, chapters })
    }

    async fn resolve(
        &self,
        env: &SourceEnv,
        _drama: &Drama,
        chapter: &Chapter,
    ) -> Result<Media, SourceError> {
        if chapter.video_url.is_empty() {
            return Err(SourceError::parse(
                "cloudfront.resolve",
                "此分集没有可用的播放地址",
            ));
        }
        let session = self.session(env).await?;
        let path = format!(
            "/api/app/vid/h5/m3u8/{}?token={}&c={}",
            encode_component(chapter.video_url.trim().trim_matches('/')),
            encode_component(&session.token),
            encode_component(CDN),
        );
        let referer = format!("{FRONTEND}/");
        let body = env
            .text(FetchRequest::get(format!("{API_BASE}{path}")).header("Referer", &referer))
            .await?;
        let playlist = guo_media::parse_playlist(&body, &format!("{API_BASE}{path}"));
        if !playlist.is_hls {
            return Ok(Media {
                url: format!("{API_BASE}{path}"),
                referer,
                ..Default::default()
            });
        }
        Ok(Media {
            url: format!("{API_BASE}{path}"),
            referer,
            playlist: Some(playlist.segments),
            key_uri: playlist.key_uri.clone().unwrap_or_default(),
            key_iv: playlist.key_iv.clone().unwrap_or_default(),
            ..Default::default()
        })
    }
}

impl LegacySource {
    async fn tabs(&self, env: &SourceEnv) -> Result<Vec<(String, String)>, SourceError> {
        let value = self.api(env, "/api/app/playlet-tab/all", None).await?;
        let rows = value
            .get("data")
            .and_then(Value::as_array)
            .ok_or_else(|| SourceError::parse("cloudfront.categories", "缺少分类列表"))?;
        let mut tabs = Vec::new();
        for row in rows {
            let id = pick(row, &["id"]);
            let name = pick(row, &["name"]);
            if !id.is_empty() && !name.is_empty() {
                tabs.push((id, name));
            }
        }
        Ok(tabs)
    }
}

/// 一次完整调用：加密参数 → 请求 → 解密响应。
async fn call(
    env: &SourceEnv,
    protocol: &Protocol,
    method: &str,
    path: &str,
    params: Option<Value>,
    device_id: Option<&str>,
    token: Option<&str>,
) -> Result<Value, SourceError> {
    let mut url = format!("{API_BASE}{path}");
    let mut body = None;
    if let Some(params) = params {
        let encoded = encrypt_params(protocol, &params)?;
        if method == "GET" {
            let separator = if path.contains('?') { '&' } else { '?' };
            url.push(separator);
            url.push_str("data=");
            url.push_str(&encode_component(&encoded));
        } else {
            body = Some(serde_json::json!({ "data": encoded }).to_string());
        }
    }
    let agent = match device_id {
        Some(id) if !id.is_empty() => USER_AGENT.replace(
            "DevID=00000000000000000000000000000",
            &format!("DevID={id}"),
        ),
        _ => USER_AGENT.to_string(),
    };
    let mut request = if let Some(body) = body {
        FetchRequest::post(&url, body.into_bytes()).header("Content-Type", "application/json")
    } else {
        FetchRequest::get(&url)
    }
    .header("Accept", "application/json")
    .header("temp", "test")
    .header("X-User-Agent", agent)
    .header("Origin", FRONTEND)
    .header("Referer", format!("{FRONTEND}/"))
    .header("User-Agent", USER_AGENT);
    if let Some(token) = token {
        request = request.header("Authorization", token);
    }
    let raw = env.text(request).await?;
    let envelope: Value = serde_json::from_str(&raw)
        .map_err(|err| SourceError::parse("cloudfront", format!("{err}: {raw:.120}")))?;
    let code = envelope.get("code").and_then(Value::as_i64).unwrap_or(0);
    if code != 200 {
        let message = envelope
            .get("msg")
            .and_then(Value::as_str)
            .unwrap_or_default();
        return Err(SourceError::parse(
            "cloudfront",
            format!("接口错误 {code}: {message}"),
        ));
    }
    let data = envelope
        .get("data")
        .ok_or_else(|| SourceError::parse("cloudfront", "响应缺少 data"))?;
    match data {
        Value::String(text) => decrypt_response(text, &protocol.interface_key),
        other => Ok(other.clone()),
    }
}

/// 请求参数：JSON → PKCS#7 → AES-CBC → Base64。
fn encrypt_params(protocol: &Protocol, params: &Value) -> Result<String, SourceError> {
    let plain = serde_json::to_vec(params)
        .map_err(|err| SourceError::parse("cloudfront", format!("{err}")))?;
    let padded = pkcs7_pad(&plain);
    let cipher = Aes128::new(aes::cipher::generic_array::GenericArray::from_slice(
        &protocol.param_key,
    ));
    let mut out = padded;
    for block in out.as_chunks_mut::<16>().0 {
        cipher.encrypt_block(aes::cipher::generic_array::GenericArray::from_mut_slice(
            block,
        ));
    }
    // 与 Go 版一致：IV 固定，用 CBC 的逐块异或实现。
    let mut previous = protocol.param_iv;
    for block in out.as_chunks_mut::<16>().0 {
        for (byte, mask) in block.iter_mut().zip(previous.iter()) {
            *byte ^= mask;
        }
        previous.copy_from_slice(block);
    }
    Ok(base64::engine::general_purpose::STANDARD.encode(out))
}

/// 响应解密：12 字节前缀参与密钥派生，再 AES-CBC 解出 JSON。
fn decrypt_response(encoded: &str, interface_key: &[u8]) -> Result<Value, SourceError> {
    let raw = base64::engine::general_purpose::STANDARD
        .decode(encoded.trim())
        .map_err(|_| SourceError::parse("cloudfront", "响应不是有效 Base64"))?;
    if raw.len() < 12 {
        return Err(SourceError::parse("cloudfront", "响应过短"));
    }
    let (prefix, ciphertext) = raw.split_at(12);
    let mut joined = interface_key.to_vec();
    joined.extend_from_slice(prefix);
    let half = joined.len() / 2;
    let seed = sha256(&joined)[8..24].to_vec();
    let mut left = seed.clone();
    left.extend_from_slice(&joined[..half]);
    let mut right = joined[half..].to_vec();
    right.extend_from_slice(&seed);
    let left_hash = sha256(&left);
    let right_hash = sha256(&right);
    // 密钥取派生材料的前 16 字节（AES-128）。
    // 原实现把 8 + 16 + 8 = 32 字节全拼进来，必然被 key.len() != 16 拦下——
    // 该分支在线上从未走通过（data 为对象的响应不走解密）。
    // 这里截取前 16 字节；若与站点实际协议不符，错误信息与插件侧一致。
    let mut material = left_hash[..8].to_vec();
    material.extend_from_slice(&right_hash[8..24]);
    material.extend_from_slice(&left_hash[24..]);
    let key = material[..16].to_vec();
    let mut iv = right_hash[..4].to_vec();
    iv.extend_from_slice(&left_hash[12..20]);
    iv.extend_from_slice(&right_hash[28..]);
    if key.len() != 16 || iv.len() != 16 || ciphertext.len() % 16 != 0 {
        return Err(SourceError::parse("cloudfront", "响应长度不符合加密块要求"));
    }
    let cipher = Aes128::new(aes::cipher::generic_array::GenericArray::from_slice(&key));
    let mut plain = ciphertext.to_vec();
    for block in plain.as_chunks_mut::<16>().0 {
        cipher.decrypt_block(aes::cipher::generic_array::GenericArray::from_mut_slice(
            block,
        ));
    }
    // CBC：逐块解出后与前一密文块异或。
    let mut previous = [0u8; 16];
    previous.copy_from_slice(&iv);
    let mut blocks = plain.as_chunks_mut::<16>().0.to_vec();
    for (index, block) in blocks.iter_mut().enumerate() {
        let source = if index == 0 {
            previous
        } else {
            let mut value = [0u8; 16];
            value.copy_from_slice(&ciphertext[(index - 1) * 16..index * 16]);
            value
        };
        for (byte, mask) in block.iter_mut().zip(source.iter()) {
            *byte ^= mask;
        }
    }
    let flat: Vec<u8> = blocks.into_iter().flatten().collect();
    let unpadded = unpad(&flat)?;
    serde_json::from_slice(unpadded)
        .map_err(|_| SourceError::parse("cloudfront", "解密后不是有效数据"))
}

fn sha256(data: &[u8]) -> Vec<u8> {
    Sha256::digest(data).to_vec()
}

fn pkcs7_pad(data: &[u8]) -> Vec<u8> {
    let pad = 16 - data.len() % 16;
    let mut out = data.to_vec();
    out.extend(std::iter::repeat_n(pad as u8, pad));
    out
}

fn unpad(data: &[u8]) -> Result<&[u8], SourceError> {
    let Some(&pad) = data.last() else {
        return Err(SourceError::parse("cloudfront", "解密结果为空"));
    };
    let pad = pad as usize;
    if pad == 0 || pad > 16 || pad > data.len() {
        return Err(SourceError::parse("cloudfront", "响应解密失败"));
    }
    if !data[data.len() - pad..]
        .iter()
        .all(|byte| *byte as usize == pad)
    {
        return Err(SourceError::parse("cloudfront", "响应解密失败"));
    }
    Ok(&data[..data.len() - pad])
}

fn parse_protocol(script: &str) -> Option<Protocol> {
    let interface_key = script_value(script, "interfaceKey")?;
    let param_key = script_value(script, "parameterKey")?;
    let param_iv = script_value(script, "parameterIv")?;
    if param_key.len() != 16 || param_iv.len() != 16 {
        return None;
    }
    let mut key = [0u8; 16];
    key.copy_from_slice(param_key.as_bytes());
    let mut iv = [0u8; 16];
    iv.copy_from_slice(param_iv.as_bytes());
    Some(Protocol {
        interface_key: interface_key.into_bytes(),
        param_key: key,
        param_iv: iv,
    })
}

/// 在脚本里找 `name: "value"` 形态的字符串字面量。
///
/// 前端脚本是压缩后的 JS，键名可能带引号也可能不带：
/// `{"interfaceKey":"..."}`、`{interfaceKey:"..."}`、`t(F,"parameterKey","...")`
/// 三种写法都要能取到值。键名必须紧跟在分隔符（`:` 或 `,`）之前，
/// 否则 `interfaceKey` 会在 `interfaceKeyX` 之类的名字上误命中。
fn script_value(script: &str, name: &str) -> Option<String> {
    let mut rest = script;
    while let Some(index) = rest.find(name) {
        let after = &rest[index + name.len()..];
        // 键名后可能有收尾引号（带引号键），也可能直接就是分隔符。
        let mut tail = after.trim_start();
        if let Some(stripped) = tail.strip_prefix('"').or_else(|| tail.strip_prefix('\'')) {
            tail = stripped.trim_start();
        }
        let mut chars = tail.chars();
        match chars.next() {
            Some(':') | Some(',') => {}
            // 不是键名（例如出现在更长的标识符或字符串中间），继续往后找。
            _ => {
                rest = after;
                continue;
            }
        }
        let value_part = chars.as_str().trim_start();
        let Some(quote) = value_part
            .chars()
            .next()
            .filter(|q| *q == '"' || *q == '\'')
        else {
            rest = after;
            continue;
        };
        let body = &value_part[quote.len_utf8()..];
        // 值里出现转义或换行说明这不是我们要的字面量，继续找下一个。
        let end = match body.find(quote) {
            Some(end) => end,
            None => {
                rest = after;
                continue;
            }
        };
        let value = body[..end].trim();
        if !value.is_empty() && !value.contains('\\') && !value.contains('\n') {
            return Some(value.to_string());
        }
        rest = after;
    }
    None
}

fn is_session_expired(error: &SourceError) -> bool {
    let text = error.to_string();
    text.contains("5005")
}

fn list_from(value: &Value, tab: &str) -> Vec<Drama> {
    let Some(rows) = value.get("data") else {
        return Vec::new();
    };
    let rows = if let Some(list) = rows.get("list").and_then(Value::as_array) {
        list
    } else if let Some(list) = rows.as_array() {
        list
    } else {
        return Vec::new();
    };
    let mut items = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for row in rows {
        let mut drama = drama_from(row, "");
        if drama.source_id.is_empty() || !seen.insert(drama.source_id.clone()) {
            continue;
        }
        if drama.category.is_empty() {
            drama.category = tab.to_string();
        }
        items.push(drama);
    }
    items
}

fn drama_from(value: &Value, fallback_id: &str) -> Drama {
    let source_id = {
        let id = pick(value, &["id"]);
        if id.is_empty() {
            fallback_id.to_string()
        } else {
            id
        }
    };
    Drama {
        id: Drama::identity("cloudfront", &source_id),
        source: "cloudfront".into(),
        source_id,
        title: pick(value, &["title", "name"]),
        description: pick(value, &["summary", "description"]),
        cover: pick(value, &["cover", "coverUrl"]),
        ..Default::default()
    }
}

fn pick(value: &Value, keys: &[&str]) -> String {
    for key in keys {
        let Some(field) = value.get(*key) else {
            continue;
        };
        if let Some(text) = field.as_str() {
            if !text.trim().is_empty() {
                return text.trim().to_string();
            }
        }
        if let Some(number) = field.as_i64() {
            return number.to_string();
        }
    }
    String::new()
}

fn device_id() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or(0);
    let mut state =
        now ^ (std::process::id() as u64).rotate_left(29) ^ (&now as *const _ as usize as u64);
    let mut prefix = String::with_capacity(8);
    for _ in 0..8 {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        prefix.push(char::from_digit((state & 0xF) as u32, 16).unwrap_or('0'));
    }
    prefix.make_ascii_uppercase();
    format!("{prefix}{now}")
}

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
    fn protocol_parser_reads_quoted_keys() {
        let script = r#"var c={interfaceKey:"65dc07d1b7915c6b2937432b091837a7",parameterKey:'BxJand%xf5h3sycH',parameterIv:'BxJand%xf5h3sycH'};"#;
        let protocol = parse_protocol(script).expect("protocol");
        assert_eq!(protocol.param_key, *b"BxJand%xf5h3sycH");
        assert_eq!(protocol.interface_key.len(), 32);
    }

    #[test]
    fn script_value_accepts_quoted_and_bare_keys() {
        // 前端脚本是压缩后的 JS，键名带不带引号都可能出现。
        for script in [
            r#"{"interfaceKey":"abc","parameterKey":"0123456789abcdef"}"#,
            r#"var c={interfaceKey:"abc",parameterKey:"0123456789abcdef"}"#,
            r#"t(F,"interfaceKey","abc");t(F,"parameterKey","0123456789abcdef")"#,
        ] {
            assert_eq!(
                script_value(script, "parameterKey").as_deref(),
                Some("0123456789abcdef"),
                "{script}"
            );
        }
    }

    #[test]
    fn script_value_skips_non_key_matches() {
        // 键名出现在更长标识符里时不能命中；不匹配时必须继续向后扫，
        // 而不是整体返回 None。
        let script = r#"interfaceKeyX:"wrong";interfaceKey:"right""#;
        assert_eq!(
            script_value(script, "interfaceKey").as_deref(),
            Some("right")
        );

        // 值不是字符串字面量时继续找下一个。
        let script = r#"parameterKey:12345;parameterKey:"0123456789abcdef""#;
        assert_eq!(
            script_value(script, "parameterKey").as_deref(),
            Some("0123456789abcdef")
        );
    }

    #[test]
    fn script_value_returns_none_without_a_match() {
        assert!(script_value("nothing here", "interfaceKey").is_none());
        assert!(script_value(r#"interfaceKey:"unterminated"#, "interfaceKey").is_none());
        assert!(script_value("interfaceKey:12345", "interfaceKey").is_none());
    }

    #[test]
    fn protocol_parser_rejects_wrong_length_keys() {
        let script = r#"{"interfaceKey":"x","parameterKey":"short","parameterIv":"short"}"#;
        assert!(parse_protocol(script).is_none());
    }

    #[test]
    fn pkcs7_pad_and_unpad_round_trip() {
        for length in [0usize, 1, 15, 16, 17, 32] {
            let data = vec![7u8; length];
            let padded = pkcs7_pad(&data);
            assert_eq!(padded.len() % 16, 0);
            assert_eq!(unpad(&padded).expect("unpad"), data.as_slice());
        }
    }

    #[test]
    fn encrypt_params_is_deterministic_and_decodable() {
        let protocol = Protocol {
            interface_key: b"65dc07d1b7915c6b2937432b091837a7".to_vec(),
            param_key: *b"BxJand%xf5h3sycH",
            param_iv: *b"BxJand%xf5h3sycH",
        };
        let first = encrypt_params(&protocol, &serde_json::json!({"a": 1})).expect("encrypt");
        let second = encrypt_params(&protocol, &serde_json::json!({"a": 1})).expect("encrypt");
        assert_eq!(first, second, "固定 IV 下同一明文必须得到同一密文");
        assert!(base64::engine::general_purpose::STANDARD
            .decode(&first)
            .is_ok());
    }

    #[test]
    fn device_id_is_uppercase_hex_plus_timestamp() {
        let id = device_id();
        assert!(id.len() >= 21, "{id}");
        assert!(id[..8]
            .chars()
            .all(|ch| ch.is_ascii_hexdigit() && !ch.is_lowercase()));
        assert!(id[8..].chars().all(|ch| ch.is_ascii_digit()));
    }

    #[test]
    fn drama_maps_id_and_title() {
        let value = serde_json::json!({"id":"abc","title":"测试剧","summary":"简介"});
        let drama = drama_from(&value, "");
        assert_eq!(drama.source_id, "abc");
        assert_eq!(drama.id, "cloudfront:abc");
        assert_eq!(drama.title, "测试剧");
    }

    #[test]
    fn list_skips_entries_without_id() {
        let value =
            serde_json::json!({"data":{"list":[{"title":"无 id"},{"id":"1","title":"有 id"}]}});
        let items = list_from(&value, "分类");
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].category, "分类");
    }
}
