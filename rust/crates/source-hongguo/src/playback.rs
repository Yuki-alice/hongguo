//! 红果第三方解析通道（`djapi.999888456.xyz`）——取流降级链的第一通道。
//!
//! Go 参考实现 `provider_hongguo_playback.go` 的 Rust 移植：
//! v2 加密响应解密 + CENC 内容密钥还原 + 多画质候选。算法逐行对齐，
//! 向量由 `tests/tools/vectorgen` 从 Go 参考生成（`hongguo_playback_vectors.json`），
//! 任何偏差在离线对拍就暴露，而不是等用户取流失败。
//!
//! 通道现状（2026-10-25 实测）：服务存活、协议不变，但对所有请求返回
//! `{"parse":0,"url":""}`（后端不再吐解析结果）。实现保留的意义：
//! **服务一恢复数据，这里直接给出全画质 CENC 流，无需发版**——
//! 这正是取流降级链存在的原因。调用方应把 [`PlaybackOutcome::NoResult`]
//! 视作「落到下一通道」，而不是终态错误。

use base64::Engine as _;
use serde::Deserialize;
use serde_json::Value;

use guo_source_api::SourceError;

/// 第三方解析接口。请求参数 `id` 是 Base64 的引用 JSON，Referer 用官网。
pub const PLAYBACK_API: &str = "https://djapi.999888456.xyz/api/hongguo/play";
/// 媒体地址的 Referer，与 Go 版一致（不是官网域名）。
pub const PLAYBACK_MEDIA_REFERER: &str = "https://novel.snssdk.com/";

/// 一个画质的媒体候选。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlaybackVariant {
    pub url: String,
    /// 画质高度（从 `name` 里的数字提取；0 表示未知）。
    pub quality: u32,
    /// CENC 内容密钥（AES-128，16 字节）。
    pub key: [u8; 16],
}

/// 一次解析的结局。`NoResult` 不是错误：服务明确表示「没这条」，
/// 调用方应落到下一通道。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PlaybackOutcome {
    NoResult,
    Variants(Vec<PlaybackVariant>),
}

/// 解析一次取流响应：v2 解密 → JSON → `key_urls` 候选。
///
/// `parse` / `jx` 是「是否需要二次解析」的标志：假值表示 `key_urls` 里
/// 已有直接地址；真值表示响应需要客户端再跳一步（Go 版按不支持处理）。
pub fn parse_playback(body: &str) -> Result<PlaybackOutcome, SourceError> {
    let plain = decode_playback_response(body)?;
    let value: Value = serde_json::from_slice(&plain).map_err(|err| {
        SourceError::parse("hongguo.playback", format!("响应不是有效数据：{err}"))
    })?;
    // Go 版逐字对齐：parse / jx 任一非空非假即拒绝。
    for flag in ["parse", "jx"] {
        if is_truthy_flag(value.get(flag)) {
            return Err(SourceError::parse(
                "hongguo.playback",
                "解析结果需要二次跳转，没有直接媒体地址",
            ));
        }
    }
    let Some(rows) = value.get("key_urls").and_then(Value::as_array) else {
        return Ok(PlaybackOutcome::NoResult);
    };
    let mut variants = Vec::new();
    for row in rows {
        let row: KeyUrl = serde_json::from_value(row.clone()).map_err(|err| {
            SourceError::parse("hongguo.playback", format!("key_urls 条目无效：{err}"))
        })?;
        if row.src.trim().is_empty() || row.src.len() > 8192 || !row.src.starts_with("http") {
            continue;
        }
        // kid 是 16 字节密钥标识；解不出直接跳过该候选。
        let kid_valid = hex::decode(row.kid.trim()).is_ok_and(|raw| raw.len() == 16);
        if !kid_valid {
            continue;
        }
        let Ok(key) = content_key(&row.spade_a) else {
            continue;
        };
        variants.push(PlaybackVariant {
            url: row.src.trim().to_string(),
            quality: first_number(&row.name),
            key,
        });
    }
    if variants.is_empty() {
        return Ok(PlaybackOutcome::NoResult);
    }
    Ok(PlaybackOutcome::Variants(variants))
}

#[derive(Debug, Deserialize)]
struct KeyUrl {
    #[serde(default)]
    name: String,
    #[serde(default)]
    src: String,
    #[serde(default)]
    kid: String,
    #[serde(default)]
    spade_a: String,
}

/// `parse` / `jx` 的「需要二次解析」判定。Go 版对响应**原始字节**做
/// switch：空 / null / false / 0 / `"0"` / `""` 都算假值，其余（包括
/// 字符串 `"false"`）都算真值——这里按语义等价实现。
fn is_truthy_flag(value: Option<&Value>) -> bool {
    match value {
        None | Some(Value::Null) => false,
        Some(Value::Bool(flag)) => *flag,
        Some(Value::Number(number)) => number.as_f64().is_some_and(|value| value != 0.0),
        Some(Value::String(text)) => !matches!(text.trim(), "" | "0"),
        Some(_) => true,
    }
}

/// `name` 里第一段连续数字（如 `"720p"` → 720）。
fn first_number(text: &str) -> u32 {
    let mut digits = String::new();
    for ch in text.chars() {
        if ch.is_ascii_digit() {
            digits.push(ch);
        } else if !digits.is_empty() {
            break;
        }
    }
    digits.parse().unwrap_or(0)
}

/// v2 加密响应解密。明文响应原样透传。
///
/// 格式：`v2.<4 字符前缀><hex 物料>.<base64 密文>`；物料经 mask 链还原出
/// 32 字节（AES-128 密钥 + IV），密文按 CBC 解密去 PKCS#7。
pub fn decode_playback_response(body: &str) -> Result<Vec<u8>, SourceError> {
    let text = body.trim();
    let Some(rest) = text.strip_prefix("v2.") else {
        return Ok(text.as_bytes().to_vec());
    };
    // Go 版对完整文本 SplitN(".", 3)：parts[1] 是物料（前 4 字符为形态标记），
    // parts[2] 是密文——对 rest 只需切成两段。
    let parts: Vec<&str> = rest.splitn(2, '.').collect();
    if parts.len() != 2 || parts[0].len() <= 4 || parts[0].len() > 1028 {
        return Err(SourceError::parse("hongguo.playback", "响应密钥无效"));
    }
    // Go 版固定切掉前 4 字符（线上是 "api_"），不管它是什么。
    let Some(hex_part) = parts[0].get(4..) else {
        return Err(SourceError::parse("hongguo.playback", "响应密钥无效"));
    };
    let encoded = hex::decode(hex_part)
        .ok()
        .filter(|raw| raw.len() >= 32)
        .ok_or_else(|| SourceError::parse("hongguo.playback", "响应密钥无效"))?;
    const MASK: [u8; 20] = [
        104, 64, 70, 166, 190, 168, 143, 130, 225, 254, 251, 217, 196, 34, 45, 60, 29, 20, 103, 105,
    ];
    let mut material = vec![0u8; encoded.len()];
    for (index, current) in encoded.iter().enumerate() {
        let previous = if index == 0 {
            109u8
        } else {
            encoded[index - 1]
        };
        let slot = index % MASK.len();
        let salt = MASK[slot] ^ ((90 + 13 * slot) & 0xff) as u8 ^ 85;
        let shifted = current
            .wrapping_add(215)
            .wrapping_sub(((11 * index) & 0xff) as u8);
        material[index] = previous ^ salt ^ shifted.rotate_left(3);
    }
    let ciphertext = decode_base64(parts[1])
        .ok_or_else(|| SourceError::parse("hongguo.playback", "加密响应无效"))?;
    if ciphertext.is_empty() || ciphertext.len() % 16 != 0 {
        return Err(SourceError::parse("hongguo.playback", "加密响应无效"));
    }
    let mut plain = ciphertext;
    aes_cbc_decrypt(&material[..16], &material[16..32], &mut plain)?;
    unpad(&plain)
        .map(<[u8]>::to_vec)
        .ok_or_else(|| SourceError::parse("hongguo.playback", "响应解密失败"))
}

/// `spade_a` → CENC 内容密钥。
///
/// 布局：`[b0] + 交错编码(内容) + 异或 tag`；`b0` 携带 tag 长度
/// （`b0^b1^b2 - 48`），内容解出后首位是 Base36 填充数，其后 32 字符
/// 是十六进制密钥。`app_v2` / `web_v2` 版本不支持（Go 版同款拒绝）。
pub fn content_key(spade_a: &str) -> Result<[u8; 16], SourceError> {
    let raw = decode_base64(spade_a)
        .ok_or_else(|| SourceError::parse("hongguo.playback", "媒体密钥编码无效"))?;
    if raw.len() > 1024 {
        return Err(SourceError::parse("hongguo.playback", "媒体密钥数据过长"));
    }
    if raw.len() < 3 {
        return Err(SourceError::parse("hongguo.playback", "媒体密钥编码无效"));
    }
    let tag_length = (raw[0] ^ raw[1] ^ raw[2]) as i64 - 48;
    if tag_length < 1 {
        return Err(SourceError::parse("hongguo.playback", "媒体密钥结构无效"));
    }
    let tag_length = tag_length as usize;
    let Some(content_length) = raw.len().checked_sub(tag_length + 1) else {
        return Err(SourceError::parse("hongguo.playback", "媒体密钥结构无效"));
    };
    if content_length < 33 || content_length >= raw.len() {
        return Err(SourceError::parse("hongguo.playback", "媒体密钥结构无效"));
    }
    let seed = raw[raw.len() - tag_length - 2] ^ raw[raw.len() - tag_length - 1];
    let tag: Vec<u8> = raw[raw.len() - tag_length..]
        .iter()
        .map(|byte| byte ^ seed)
        .collect();
    if tag == b"app_v2" || tag == b"web_v2" {
        return Err(SourceError::parse(
            "hongguo.playback",
            "媒体密钥版本暂不支持",
        ));
    }
    let mut decoded = vec![0u8; content_length];
    let (mut previous_even, mut previous_odd) = (250u8, 85u8);
    for (index, current) in raw[1..1 + content_length].iter().enumerate() {
        let previous = if index % 2 == 0 {
            let slot = previous_even;
            previous_even = *current;
            slot
        } else {
            let slot = previous_odd;
            previous_odd = *current;
            slot
        };
        decoded[index] = (previous ^ current)
            .wrapping_sub(21)
            .wrapping_sub((index.count_ones() % 256) as u8);
    }
    // Go 版：ParseUint(首字节, 36, 8)；contentLength - padding - 1 必须 == 32。
    let padding = (decoded[0] as char)
        .to_digit(36)
        .ok_or_else(|| SourceError::parse("hongguo.playback", "媒体密钥内容无效"))?
        as usize;
    if content_length.checked_sub(padding) != Some(33) {
        return Err(SourceError::parse("hongguo.playback", "媒体密钥内容无效"));
    }
    let key_text = std::str::from_utf8(&decoded[1..33])
        .ok()
        .and_then(|text| hex::decode(text).ok())
        .filter(|key| key.len() == 16)
        .ok_or_else(|| SourceError::parse("hongguo.playback", "媒体密钥不是有效的 AES-128 密钥"))?;
    let mut key = [0u8; 16];
    key.copy_from_slice(&key_text);
    Ok(key)
}

/// 标准 Base64，无填充形态回退（Go 版 decodeHongguoBase64 的语义）。
pub(crate) fn decode_base64(value: &str) -> Option<Vec<u8>> {
    let text = value.trim();
    if text.is_empty() {
        return Some(Vec::new());
    }
    if text.ends_with('=') {
        base64::engine::general_purpose::STANDARD.decode(text).ok()
    } else {
        base64::engine::general_purpose::STANDARD_NO_PAD
            .decode(text)
            .ok()
    }
}

/// AES-128-CBC 原地解密（纯计算，无 IO）。
fn aes_cbc_decrypt(key: &[u8], iv: &[u8], data: &mut [u8]) -> Result<(), SourceError> {
    use aes::cipher::{BlockDecrypt, KeyInit};
    use aes::Aes128;
    let cipher = Aes128::new_from_slice(key)
        .map_err(|err| SourceError::parse("hongguo.playback", format!("密钥无效：{err}")))?;
    let mut previous = [0u8; 16];
    previous.copy_from_slice(iv);
    for chunk in data.as_chunks_mut::<16>().0 {
        // 先存本块密文（下一块的 IV），再在本块上解密并与前块异或。
        let mut current = *chunk;
        cipher.decrypt_block(aes::cipher::generic_array::GenericArray::from_mut_slice(
            &mut current,
        ));
        for (slot, byte) in current.iter_mut().enumerate() {
            *byte ^= previous[slot];
        }
        previous = *chunk;
        chunk.copy_from_slice(&current);
    }
    Ok(())
}

/// PKCS#7 去填充（严格校验）。
fn unpad(data: &[u8]) -> Option<&[u8]> {
    let pad = *data.last()? as usize;
    if pad == 0 || pad > 16 || pad > data.len() {
        return None;
    }
    if !data[data.len() - pad..]
        .iter()
        .all(|byte| *byte as usize == pad)
    {
        return None;
    }
    Some(&data[..data.len() - pad])
}
