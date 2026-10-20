//! 模板 token 的白名单与语法。
//!
//! 规则里所有 `{…}` 都必须能从这份清单里找到对应项，否则**加载期**就报错。
//! 之前是「未知 token 原样保留」，结果请求地址里带着字面量 `{foo}` 发出去，
//! 站点返回 200 + 空列表，看起来像「源站改版」——最难查的一类静默失败。

use guo_source_api::{md5_hex, sha256_hex};

/// 模板里允许出现的 token。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Token<'a> {
    /// `{page}`
    Page,
    /// `{category}`
    Category,
    /// `{keyword}`
    Keyword,
    /// `{id}`
    Id,
    /// `{idFirst}` / `{idRest}`
    IdPart { head: bool },
    /// `{base}`
    Base,
    /// `{ts}`（毫秒）
    TimestampMillis,
    /// `{ts10}`（秒）
    TimestampSeconds,
    /// `{md5:<inner>}` / `{sha256:<inner>}`
    Digest { algorithm: Digest, inner: &'a str },
    /// `{upper:<inner>}` / `{lower:<inner>}` / `{trim:<inner>}`
    Transform { kind: Transform, inner: &'a str },
    /// `{hmac:sha256:<key>:<inner>}`
    Hmac { key: &'a str, inner: &'a str },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Digest {
    Md5,
    Sha256,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Transform {
    Upper,
    Lower,
    Trim,
}

/// 解析单个 token（不含花括号）。未知 token 返回 `None`。
pub fn parse(token: &str) -> Option<Token<'_>> {
    if let Some(inner) = token.strip_prefix("md5:") {
        return Some(Token::Digest {
            algorithm: Digest::Md5,
            inner,
        });
    }
    if let Some(inner) = token.strip_prefix("sha256:") {
        return Some(Token::Digest {
            algorithm: Digest::Sha256,
            inner,
        });
    }
    if let Some(rest) = token.strip_prefix("upper:") {
        return Some(Token::Transform {
            kind: Transform::Upper,
            inner: rest,
        });
    }
    if let Some(rest) = token.strip_prefix("lower:") {
        return Some(Token::Transform {
            kind: Transform::Lower,
            inner: rest,
        });
    }
    if let Some(rest) = token.strip_prefix("trim:") {
        return Some(Token::Transform {
            kind: Transform::Trim,
            inner: rest,
        });
    }
    if let Some(rest) = token.strip_prefix("hmac:sha256:") {
        // `{hmac:sha256:key:inner}`：key 不能为空，inner 可以为空（对空串取摘要）。
        let (key, inner) = rest.split_once(':')?;
        if key.is_empty() {
            return None;
        }
        return Some(Token::Hmac { key, inner });
    }
    Some(match token {
        "page" => Token::Page,
        "category" => Token::Category,
        "keyword" => Token::Keyword,
        "id" => Token::Id,
        "idFirst" => Token::IdPart { head: true },
        "idRest" => Token::IdPart { head: false },
        "base" => Token::Base,
        "ts" => Token::TimestampMillis,
        "ts10" => Token::TimestampSeconds,
        _ => return None,
    })
}

/// 抽出一段文本里出现的全部 token 原文，供加载期校验。
///
/// 只做括号配对，不校验语义：语义交给 [`parse`]。
pub fn tokens_in(template: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let bytes = template.as_bytes();
    let mut index = 0usize;
    while index < bytes.len() {
        if bytes[index] != b'{' {
            index += 1;
            continue;
        }
        match template[index + 1..].find('}') {
            Some(offset) => {
                out.push(&template[index + 1..index + 1 + offset]);
                index = index + 1 + offset + 1;
            }
            None => break,
        }
    }
    out
}

/// 计算 HMAC-SHA256，返回十六进制小写。
///
/// 规则层只有这一处需要「带密钥」的摘要；自己实现比引入 `hmac` crate 更省依赖，
/// 且实现只有十几行，容易对照 RFC 2104 复核。
pub fn hmac_sha256_hex(key: &[u8], message: &[u8]) -> String {
    const BLOCK: usize = 64;
    let mut normalized = [0u8; BLOCK];
    if key.len() > BLOCK {
        let digest = sha256_bytes(key);
        normalized[..32].copy_from_slice(&digest);
    } else {
        normalized[..key.len()].copy_from_slice(key);
    }
    let mut inner = Vec::with_capacity(BLOCK + message.len());
    let mut outer = Vec::with_capacity(BLOCK + 32);
    for byte in normalized {
        inner.push(byte ^ 0x36);
        outer.push(byte ^ 0x5c);
    }
    inner.extend_from_slice(message);
    let inner_digest = sha256_bytes(&inner);
    outer.extend_from_slice(&inner_digest);
    to_hex(&sha256_bytes(&outer))
}

fn sha256_bytes(input: &[u8]) -> [u8; 32] {
    let hex = sha256_hex(input);
    let mut out = [0u8; 32];
    for (index, slot) in out.iter_mut().enumerate() {
        *slot = u8::from_str_radix(&hex[index * 2..index * 2 + 2], 16)
            .expect("sha256 输出必为十六进制");
    }
    out
}

fn to_hex(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

/// 渲染 digest token 用的辅助：调用方传已渲染的内部文本。
pub fn digest_hex(algorithm: Digest, text: &str) -> String {
    match algorithm {
        Digest::Md5 => md5_hex(text.as_bytes()),
        Digest::Sha256 => sha256_hex(text.as_bytes()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recognizes_known_tokens() {
        assert_eq!(parse("page"), Some(Token::Page));
        assert_eq!(parse("ts10"), Some(Token::TimestampSeconds));
        assert_eq!(parse("idFirst"), Some(Token::IdPart { head: true }));
        assert_eq!(
            parse("md5:{ts10}"),
            Some(Token::Digest {
                algorithm: Digest::Md5,
                inner: "{ts10}"
            })
        );
        assert_eq!(
            parse("sha256:abc"),
            Some(Token::Digest {
                algorithm: Digest::Sha256,
                inner: "abc"
            })
        );
        assert_eq!(
            parse("upper:{id}"),
            Some(Token::Transform {
                kind: Transform::Upper,
                inner: "{id}"
            })
        );
    }

    #[test]
    fn rejects_unknown_tokens() {
        for bad in ["foo", "{page}", "", "md5", "hmac:sha256:", "hmac:md5:a:b"] {
            assert_eq!(parse(bad), None, "{bad} 不应被接受");
        }
    }

    #[test]
    fn extracts_tokens_from_templates() {
        assert_eq!(
            tokens_in("https://x/{base}/list?page={page}&c={category}"),
            vec!["base", "page", "category"]
        );
        assert_eq!(tokens_in("no tokens here"), Vec::<&str>::new());
        assert_eq!(tokens_in("{unclosed"), Vec::<&str>::new());
    }

    #[test]
    fn hmac_matches_rfc4231_case_2() {
        // RFC 4231 Test Case 2：key = "Jefe"，data = "what do ya want for nothing?"
        assert_eq!(
            hmac_sha256_hex(b"Jefe", b"what do ya want for nothing?"),
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        );
    }

    #[test]
    fn hmac_handles_long_keys_by_hashing() {
        // key 超过 64 字节时先取 SHA-256，结果必须与短 key 的路径区分开。
        let long = vec![0xaa; 100];
        let first = hmac_sha256_hex(&long, b"message");
        let second = hmac_sha256_hex(&long, b"message");
        assert_eq!(first, second);
        assert_eq!(first.len(), 64);
        assert_ne!(first, hmac_sha256_hex(b"short", b"message"));
    }

    #[test]
    fn digest_hex_dispatches_by_algorithm() {
        assert_eq!(
            digest_hex(Digest::Md5, "abc"),
            "900150983cd24fb0d6963f7d28e17f72"
        );
        assert_eq!(
            digest_hex(Digest::Sha256, "abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }
}
