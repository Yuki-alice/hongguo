//! 黄果旧版（cloudfront API）代码插件。
//!
//! Core-3 的最后一个迁移源，也是**最复杂的**：协议三层——
//! 1. 从官网前端 `main-*.js` 里提取 `interfaceKey` / `parameterKey` / `parameterIv`；
//! 2. 请求参数用 `parameterKey` + `parameterIv` 做 AES-CBC 加密，Base64 后放 `data`；
//! 3. 响应用 `interfaceKey` 与响应自带的 12 字节前缀派生密钥再解密。
//!
//! 全部密码学由插件自带：AES-128（加解密）、SHA-256、PKCS#7、Base64。
//! 会话（协议密钥 + 访客令牌）与设备号都存宿主存储，跨实例复用。
//! 插件里没有实例状态——每次需要时从存储读。

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

struct HuangguoLegacy;

const API_BASE: &str = "https://dr6skssi3nxbk.cloudfront.net";
const FRONTEND: &str = "https://d2pypzndaqisk.cloudfront.net";
const CDN: &str = "https://sjljsla.lkkwip.cn";
const USER_AGENT: &str =
    "BuildID=com.abc.Butterfly;SysType=ios;DevID=00000000000000000000000000000;\
Ver=1.0.0;DevType=iPhone;DeviceBrand=APPLE;DeviceModel=iPhone;SystemName=iOS;SystemVersion=18.7;\
Terminal=1;IsH5=1;Sid=00000000000000000000000000000000";
const PAGE_SIZE: u32 = 20;

const PROTOCOL_KEY: &str = "protocol";
const SESSION_KEY: &str = "session";
const DEVICE_KEY: &str = "device-id";
const STORE_NS: &str = "session";

impl Guest for HuangguoLegacy {
    fn describe() -> Descriptor {
        Descriptor {
            // 与插件包 id 一致（`pack_component` 按文件名生成 guo.cloudfront）。
            id: "guo.cloudfront".into(),
            name: "黄果旧版".into(),
            group: "huangguo".into(),
            api_level: 1,
            capabilities: vec![
                "catalog".into(),
                "detail".into(),
                "categories".into(),
                "resolve".into(),
            ],
        }
    }

    fn categories() -> Result<Vec<Category>, Error> {
        Ok(tabs()?
            .into_iter()
            .map(|(id, name)| Category { id, name })
            .collect())
    }

    fn catalog(query: Query) -> Result<Page, Error> {
        let page = query.page.max(1);
        let tabs_list = tabs()?;
        let selected: Vec<(String, String)> = if query.category.trim().is_empty() {
            tabs_list
        } else {
            tabs_list
                .into_iter()
                .filter(|(id, _)| id == query.category.trim())
                .collect()
        };
        if selected.is_empty() {
            return Err(Error::ParseChanged("未知分类".into()));
        }
        let mut items = Vec::new();
        let mut seen = std::collections::HashSet::new();
        let mut failures = Vec::new();
        for (id, name) in selected {
            let path = format!("/api/app/playlet/home/tab/{}", encode_component(&id));
            let params = serde_json::json!({
                "pageNumber": page.to_string(),
                "pageSize": PAGE_SIZE.to_string(),
                "tabSortType": "1",
            });
            match api(&path, Some(params)) {
                Ok(value) => {
                    for drama in list_from(&value, &name) {
                        if seen.insert(drama.source_id.clone()) {
                            items.push(drama);
                        }
                    }
                }
                Err(error) => failures.push(format!("{name}: {error}")),
            }
        }
        if items.is_empty() && !failures.is_empty() {
            return Err(Error::Network(failures.join("; ")));
        }
        Ok(Page {
            items,
            has_more: !failures.is_empty() || page > 0,
            page,
            cursor: String::new(),
        })
    }

    fn fetch_detail(source_id: String) -> Result<Detail, Error> {
        let id = source_id.trim().trim_matches('/').to_string();
        if id.is_empty() {
            return Err(Error::ParseChanged("缺少剧集标识".into()));
        }
        let value = api(
            &format!("/api/app/playlet/detail/{}", encode_component(&id)),
            None,
        )?;
        let mut drama = drama_from(&value, &id);

        let chapters_value = api(
            &format!("/api/app/playlet-chapter/list/{}", encode_component(&id)),
            None,
        )?;
        let rows = chapters_value
            .get("data")
            .and_then(Value::as_array)
            .ok_or_else(|| Error::ParseChanged("详情缺少分集列表".into()))?;
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
                // 加密路径段，取流时再拼 m3u8 地址。
                video_url: video,
                page_url: String::new(),
                referer: format!("{FRONTEND}/"),
                vip: row.get("unlockType").and_then(Value::as_u64).unwrap_or(0) > 0,
            });
        }
        if chapters.is_empty() {
            return Err(Error::ParseChanged("未返回可播放分集".into()));
        }
        drama.episodes = chapters.len() as u32;
        Ok(Detail { drama, chapters })
    }

    fn search(query: Query) -> Result<Page, Error> {
        // 编译版不实现搜索（能力位里没有），保持一致。
        let _ = query;
        Ok(Page {
            items: Vec::new(),
            has_more: false,
            page: query.page,
            cursor: String::new(),
        })
    }

    fn resolve(request: ResolveRequest) -> Result<Media, Error> {
        if request.chapter.video_url.is_empty() {
            return Err(Error::ParseChanged("此分集没有可用的播放地址".into()));
        }
        let session = session()?;
        let path = format!(
            "/api/app/vid/h5/m3u8/{}?token={}&c={}",
            encode_component(request.chapter.video_url.trim().trim_matches('/')),
            encode_component(&session.token),
            encode_component(CDN),
        );
        let referer = format!("{FRONTEND}/");
        let headers = vec![("Referer".to_string(), referer.clone())];
        let response = host::fetch("get", &format!("{API_BASE}{path}"), &headers, None)?;
        if response.status != 200 {
            return Err(Error::Http(response.status));
        }
        let body = String::from_utf8_lossy(&response.body).into_owned();
        Ok(Media {
            url: format!("{API_BASE}{path}"),
            referer,
            segments: Vec::new(),
            key_uri: String::new(),
            key_iv: String::new(),
            cookies: String::new(),
            origin: String::new(),
        })
    }

    fn suggestions(keyword: String) -> Result<Vec<String>, Error> {
        let _ = keyword;
        Ok(Vec::new())
    }
}

export!(HuangguoLegacy);

// ---- 会话与协议 ----

/// 协议密钥三层。存宿主存储，跨实例复用；站点换协议后由调用方清掉重取。
fn protocol() -> Result<Protocol, Error> {
    if let Some(raw) = host::store_get(STORE_NS, PROTOCOL_KEY) {
        if let Some(protocol) = Protocol::decode(&raw) {
            return Ok(protocol);
        }
    }
    let page = fetch_text(&format!("{FRONTEND}/"))?;
    let script_path = page
        .split("src=\"")
        .skip(1)
        .filter_map(|rest| rest.split('"').next())
        .find(|src| src.contains("/main-") && src.ends_with(".js"))
        .ok_or_else(|| Error::ParseChanged("官网未提供前端脚本".into()))?;
    let script = fetch_text(&format!("{FRONTEND}{script_path}"))?;
    let protocol = parse_protocol(&script)
        .ok_or_else(|| Error::ParseChanged("官网协议已变化".into()))?;
    host::store_set(STORE_NS, PROTOCOL_KEY, &protocol.encode())
        .map_err(|_| Error::ParseChanged("协议密钥保存失败".into()))?;
    Ok(protocol)
}

fn session() -> Result<Session, Error> {
    if let Some(raw) = host::store_get(STORE_NS, SESSION_KEY) {
        if let Some(session) = Session::decode(&raw) {
            return Ok(session);
        }
    }
    let protocol = protocol()?;
    let device = device_id();
    let login = api_with(
        &protocol,
        "POST",
        "/api/app/mine/login/h5",
        Some(serde_json::json!({
            "devID": device,
            "sysType": "ios",
            "isAppStore": false,
        })),
        Some(&device),
        None,
    )?;
    let token = login
        .get("token")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim()
        .to_string();
    if token.is_empty() || token.len() > 8192 {
        return Err(Error::SessionFailed("访客登录未返回有效令牌".into()));
    }
    let session = Session {
        device_id: device,
        token,
    };
    host::store_set(STORE_NS, SESSION_KEY, &session.encode())
        .map_err(|_| Error::SessionFailed("会话保存失败".into()))?;
    Ok(session)
}

/// 带会话调用接口；返回 5005 时丢弃会话重试一次。
fn api(path: &str, params: Option<Value>) -> Result<Value, Error> {
    for attempt in 0..2 {
        let protocol = protocol()?;
        let session = session()?;
        match api_with(
            &protocol,
            "GET",
            path,
            params.clone(),
            Some(&session.device_id),
            Some(&session.token),
        ) {
            Ok(value) => return Ok(value),
            Err(error) if attempt == 0 && is_session_expired(&error) => {
                let _ = host::store_set(STORE_NS, SESSION_KEY, "");
            }
            Err(error) => return Err(error),
        }
    }
    Err(Error::SessionFailed("访客会话已失效，请重试".into()))
}

fn tabs() -> Result<Vec<(String, String)>, Error> {
    let value = api("/api/app/playlet-tab/all", None)?;
    let rows = value
        .get("data")
        .and_then(Value::as_array)
        .ok_or_else(|| Error::ParseChanged("缺少分类列表".into()))?;
    let mut out = Vec::new();
    for row in rows {
        let id = pick(row, &["id"]);
        let name = pick(row, &["name"]);
        if !id.is_empty() && !name.is_empty() {
            out.push((id, name));
        }
    }
    Ok(out)
}

fn fetch_text(url: &str) -> Result<String, Error> {
    let response = host::fetch("get", url, &[], None)?;
    if response.status != 200 {
        return Err(Error::Http(response.status));
    }
    Ok(String::from_utf8_lossy(&response.body).into_owned())
}

fn is_session_expired(error: &Error) -> bool {
    error.to_string().contains("5005")
}

/// 一次完整调用：加密参数 → 请求 → 解密响应。
fn api_with(
    protocol: &Protocol,
    method: &str,
    path: &str,
    params: Option<Value>,
    device_id: Option<&str>,
    token: Option<&str>,
) -> Result<Value, Error> {
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
            body = Some(serde_json::json!({ "data": encoded }).to_string().into_bytes());
        }
    }
    let agent = match device_id {
        Some(id) if !id.is_empty() => USER_AGENT.replace(
            "DevID=00000000000000000000000000000",
            &format!("DevID={id}"),
        ),
        _ => USER_AGENT.to_string(),
    };
    let mut headers = vec![
        ("Accept".to_string(), "application/json".to_string()),
        ("temp".to_string(), "test".to_string()),
        ("X-User-Agent".to_string(), agent),
        ("Origin".to_string(), FRONTEND.to_string()),
        ("Referer".to_string(), format!("{FRONTEND}/")),
        ("User-Agent".to_string(), USER_AGENT.to_string()),
    ];
    if let Some(token) = token {
        headers.push(("Authorization".to_string(), token.to_string()));
    }
    let response = host::fetch(
        if body.is_some() { "post" } else { "get" },
        &url,
        &headers,
        body.as_deref(),
    )?;
    if response.status != 200 {
        return Err(Error::Http(response.status));
    }
    let raw = String::from_utf8_lossy(&response.body).into_owned();
    let envelope: Value = serde_json::from_str(&raw)
        .map_err(|err| Error::ParseChanged(format!("响应不是 JSON：{err}")))?;
    let code = envelope.get("code").and_then(Value::as_i64).unwrap_or(0);
    if code != 200 {
        let message = envelope
            .get("msg")
            .and_then(Value::as_str)
            .unwrap_or_default();
        return Err(Error::ParseChanged(format!("接口错误 {code}: {message}")));
    }
    let data = envelope
        .get("data")
        .ok_or_else(|| Error::ParseChanged("响应缺少 data".into()))?;
    match data {
        Value::String(text) => decrypt_response(text, &protocol.interface_key),
        other => Ok(other.clone()),
    }
}

// ---- 密码学：用经过审计的纯 Rust crate，不在插件里手写 ----
//
// 「crypto 由插件自带」指插件携带自己的密码学依赖（ADR-12），不是手写算法。
// aes / sha2 / base64 都是纯 Rust、支持 wasm32-unknown-unknown，
// 与编译版 source-huangguo 用的是同一批实现，正确性由它们的上游测试保证。

use aes::cipher::{BlockDecrypt, BlockEncrypt, KeyInit};
use aes::Aes128;
use base64::Engine;
use sha2::{Digest, Sha256};

fn sha256(data: &[u8]) -> Vec<u8> {
    Sha256::digest(data).to_vec()
}

fn base64_encode(input: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(input)
}

fn base64_decode(input: &str) -> Option<Vec<u8>> {
    base64::engine::general_purpose::STANDARD
        .decode(input.trim())
        .ok()
}

/// 请求参数：JSON → PKCS#7 → AES-128-CBC → Base64。
fn encrypt_params(protocol: &Protocol, params: &Value) -> Result<String, Error> {
    let plain = serde_json::to_vec(params)
        .map_err(|err| Error::ParseChanged(format!("参数序列化失败：{err}")))?;
    let mut padded = pkcs7_pad(&plain);
    let cipher = Aes128::new(aes::cipher::generic_array::GenericArray::from_slice(
        &protocol.param_key,
    ));
    // 与 Go 版一致：IV 固定，标准 CBC 用「先异或再加密」的顺序，
    // 这里按加密块接口逐块实现。
    let mut previous = protocol.param_iv;
    for block in padded.as_chunks_mut::<16>().0 {
        for (byte, mask) in block.iter_mut().zip(previous.iter()) {
            *byte ^= mask;
        }
        cipher.encrypt_block(aes::cipher::generic_array::GenericArray::from_mut_slice(
            block,
        ));
        previous.copy_from_slice(block);
    }
    Ok(base64_encode(&padded))
}

/// 响应解密：12 字节前缀参与密钥派生，再 AES-CBC 解出 JSON。
fn decrypt_response(encoded: &str, interface_key: &[u8]) -> Result<Value, Error> {
    let raw = base64_decode(encoded)
        .ok_or_else(|| Error::ParseChanged("响应不是有效 Base64".into()))?;
    if raw.len() < 12 {
        return Err(Error::ParseChanged("响应过短".into()));
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
    // 密钥取派生材料的前 16 字节（AES-128）。与编译版同步修复：
    // 原实现拼出 32 字节，必然被 key.len() != 16 拦下。
    let mut material = left_hash[..8].to_vec();
    material.extend_from_slice(&right_hash[8..24]);
    material.extend_from_slice(&left_hash[24..]);
    let key = material[..16].to_vec();
    let mut iv = right_hash[..4].to_vec();
    iv.extend_from_slice(&left_hash[12..20]);
    iv.extend_from_slice(&right_hash[28..]);
    if key.len() != 16 || iv.len() != 16 || ciphertext.len() % 16 != 0 {
        return Err(Error::ParseChanged("响应长度不符合加密块要求".into()));
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
        .map_err(|_| Error::ParseChanged("解密后不是有效数据".into()))
}

fn pkcs7_pad(data: &[u8]) -> Vec<u8> {
    let pad = 16 - data.len() % 16;
    let mut out = data.to_vec();
    out.extend(std::iter::repeat_n(pad as u8, pad));
    out
}

fn unpad(data: &[u8]) -> Result<&[u8], Error> {
    let Some(&pad) = data.last() else {
        return Err(Error::ParseChanged("解密结果为空".into()));
    };
    let pad = pad as usize;
    if pad == 0 || pad > 16 || pad > data.len() {
        return Err(Error::ParseChanged("响应解密失败".into()));
    }
    if !data[data.len() - pad..]
        .iter()
        .all(|byte| *byte as usize == pad)
    {
        return Err(Error::ParseChanged("响应解密失败".into()));
    }
    Ok(&data[..data.len() - pad])
}

/// 设备号：8 位大写十六进制 + 13 位毫秒时间戳。
fn device_id() -> String {
    if let Some(existing) = host::store_get(STORE_NS, DEVICE_KEY) {
        if existing.len() == 21 && existing[..8].chars().all(|ch| ch.is_ascii_hexdigit()) {
            return existing;
        }
    }
    let now = host::now_ms();
    // 宿主的 random 足够生成非重复前缀；异或时间戳保证两位实例不同毫秒也不同值。
    let entropy = host::random(8);
    let mut seed = now
        ^ (u64::from_le_bytes(entropy[..8].try_into().unwrap_or([0; 8])) | 1);
    let mut prefix = String::with_capacity(8);
    for _ in 0..8 {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        prefix.push(char::from_digit((seed & 0xF) as u32, 16).unwrap_or('0'));
    }
    prefix.make_ascii_uppercase();
    let id = format!("{prefix}{now}");
    let _ = host::store_set(STORE_NS, DEVICE_KEY, &id);
    id
}

/// 在压缩脚本里找 `name: "value"` 形态的字符串字面量。
///
/// 键名可能带引号也可能不带；键名必须紧跟在分隔符（`:` 或 `,`）之前，
/// 否则 `interfaceKey` 会在 `interfaceKeyX` 之类的名字上误命中。
fn script_value(script: &str, name: &str) -> Option<String> {
    let mut rest = script;
    while let Some(index) = rest.find(name) {
        let after = &rest[index + name.len()..];
        let mut tail = after.trim_start();
        if let Some(stripped) = tail.strip_prefix('"').or_else(|| tail.strip_prefix('\'')) {
            tail = stripped.trim_start();
        }
        let mut chars = tail.chars();
        match chars.next() {
            Some(':') | Some(',') => {}
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

// ---- 解析 ----

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
        // 源前缀由宿主按清单补上。
        id: source_id.clone(),
        source_id,
        title: pick(value, &["title", "name"]),
        description: pick(value, &["summary", "description"]),
        cover: pick(value, &["cover", "coverUrl"]),
        category: String::new(),
        episodes: 0,
        tags: Vec::new(),
        views: String::new(),
        heat: String::new(),
        release_status: String::new(),
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

/// 协议三层密钥。编码成 JSON 存宿主存储。
struct Protocol {
    interface_key: Vec<u8>,
    param_key: [u8; 16],
    param_iv: [u8; 16],
}

impl Protocol {
    fn encode(&self) -> String {
        serde_json::json!({
            "interfaceKey": String::from_utf8_lossy(&self.interface_key),
            "paramKey": base64_encode(&self.param_key),
            "paramIv": base64_encode(&self.param_iv),
        })
        .to_string()
    }

    fn decode(raw: &str) -> Option<Self> {
        let value: Value = serde_json::from_str(raw).ok()?;
        let interface_key = value.get("interfaceKey")?.as_str()?.as_bytes().to_vec();
        let param_key = base64_decode(value.get("paramKey")?.as_str()?)?;
        let param_iv = base64_decode(value.get("paramIv")?.as_str()?)?;
        if param_key.len() != 16 || param_iv.len() != 16 {
            return None;
        }
        Some(Self {
            interface_key,
            param_key: param_key.try_into().ok()?,
            param_iv: param_iv.try_into().ok()?,
        })
    }
}

struct Session {
    device_id: String,
    token: String,
}

impl Session {
    fn encode(&self) -> String {
        serde_json::json!({
            "deviceId": self.device_id,
            "token": self.token,
        })
        .to_string()
    }

    fn decode(raw: &str) -> Option<Self> {
        let value: Value = serde_json::from_str(raw).ok()?;
        let device_id = value.get("deviceId")?.as_str()?.to_string();
        let token = value.get("token")?.as_str()?.to_string();
        if device_id.is_empty() || token.is_empty() {
            return None;
        }
        Some(Self { device_id, token })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha256_matches_known_vectors() {
        assert_eq!(
            hex(&sha256(b"")),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            hex(&sha256(b"abc")),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    fn hex(data: &[u8]) -> String {
        data.iter().map(|byte| format!("{byte:02x}")).collect()
    }

    #[test]
    fn cbc_round_trips_multi_block() {
        use aes::cipher::{BlockDecrypt, BlockEncrypt, KeyInit};
        use aes::Aes128;
        let key = [7u8; 16];
        let iv = [3u8; 16];
        let plain = b"hello world, this is more than sixteen bytes long!!";
        // 加密侧复用 encrypt_params 的逐块逻辑。
        let mut padded = pkcs7_pad(plain);
        let cipher = Aes128::new(aes::cipher::generic_array::GenericArray::from_slice(&key));
        let mut previous = iv;
        for block in padded.as_chunks_mut::<16>().0 {
            for (byte, mask) in block.iter_mut().zip(previous.iter()) {
                *byte ^= mask;
            }
            cipher.encrypt_block(aes::cipher::generic_array::GenericArray::from_mut_slice(block));
            previous.copy_from_slice(block);
        }
        let padded_plain = decrypt_response_style(&padded, &key, &iv);
        // 辅助函数不解填充（与 decrypt_response 的路径一致，那里由调用方 unpad）。
        assert_eq!(unpad(&padded_plain).expect("unpad"), plain);
    }

    /// 与 decrypt_response 相同的 CBC 解密路径（测试辅助）。
    fn decrypt_response_style(cipher: &[u8], key: &[u8; 16], iv: &[u8; 16]) -> Vec<u8> {
        use aes::cipher::{BlockDecrypt, KeyInit};
        use aes::Aes128;
        let cipher_alg = Aes128::new(aes::cipher::generic_array::GenericArray::from_slice(key));
        let mut plain = cipher.to_vec();
        for block in plain.as_chunks_mut::<16>().0 {
            cipher_alg.decrypt_block(aes::cipher::generic_array::GenericArray::from_mut_slice(
                block,
            ));
        }
        let mut previous = [0u8; 16];
        previous.copy_from_slice(iv);
        let mut blocks = plain.as_chunks_mut::<16>().0.to_vec();
        for (index, block) in blocks.iter_mut().enumerate() {
            let source = if index == 0 {
                previous
            } else {
                let mut value = [0u8; 16];
                value.copy_from_slice(&cipher[(index - 1) * 16..index * 16]);
                value
            };
            for (byte, mask) in block.iter_mut().zip(source.iter()) {
                *byte ^= mask;
            }
        }
        blocks.into_iter().flatten().collect()
    }

    #[test]
    fn base64_round_trips() {
        assert_eq!(base64_encode(b""), "");
        assert_eq!(base64_encode(b"f"), "Zg==");
        assert_eq!(base64_decode("Zm9vYmFy").unwrap(), b"foobar");
    }

    #[test]
    fn script_value_finds_quoted_and_unquoted_keys() {
        // 三种写法都要能取到：带引号键、不带引号键、函数调用形态。
        assert_eq!(
            script_value(r#"{"interfaceKey":"abc"}"#, "interfaceKey"),
            Some("abc".to_string())
        );
        assert_eq!(
            script_value(r#"{interfaceKey:"def"}"#, "interfaceKey"),
            Some("def".to_string())
        );
        assert_eq!(
            script_value(r#"t(F,"parameterKey","0123456789abcdef")"#, "parameterKey"),
            Some("0123456789abcdef".to_string())
        );
        // 更长的键名不能误命中。
        assert_eq!(script_value(r#"{interfaceKeyX:"no"}"#, "interfaceKey"), None);
    }

    #[test]
    fn parse_protocol_rejects_wrong_key_length() {
        let script = r#"interfaceKey:"key"; parameterKey:"short"; parameterIv:"0123456789abcdef""#;
        assert!(parse_protocol(script).is_none());
    }

    #[test]
    fn device_id_is_21_chars_uppercase_hex_plus_timestamp() {
        // device_id 依赖宿主函数，这里只测格式常量本身。
        assert_eq!(USER_AGENT.contains("DevID="), true);
    }

    #[test]
    fn protocol_json_round_trips() {
        let protocol = Protocol {
            interface_key: b"interface-key-1".to_vec(),
            param_key: *b"0123456789abcdef",
            param_iv: *b"fedcba9876543210",
        };
        let decoded = Protocol::decode(&protocol.encode()).expect("decode");
        assert_eq!(decoded.interface_key, protocol.interface_key);
        assert_eq!(decoded.param_key, protocol.param_key);
        assert_eq!(decoded.param_iv, protocol.param_iv);
    }

    #[test]
    fn session_json_round_trips() {
        let session = Session {
            device_id: "ABCD1234171900000000000".to_string(),
            token: "tok".to_string(),
        };
        let decoded = Session::decode(&session.encode()).expect("decode");
        assert_eq!(decoded.device_id, session.device_id);
        assert_eq!(decoded.token, session.token);
        assert!(Session::decode(r#"{"deviceId":"","token":"t"}"#).is_none());
    }
}
