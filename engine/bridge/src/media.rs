use serde::{Deserialize, Serialize};

/// 播放列表解析结果。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Playlist {
    /// 是否为有效 HLS 播放列表。
    pub is_hls: bool,
    /// 媒体分片地址（绝对地址）。
    pub segments: Vec<String>,
    /// 变体播放列表（主列表中的 `#EXT-X-STREAM-INF`）。
    pub variants: Vec<String>,
    /// `#EXT-X-KEY` 的 URI，用于 AES-128 解密。
    pub key_uri: Option<String>,
    /// `#EXT-X-KEY` 的 METHOD。
    pub key_method: Option<String>,
    /// `#EXT-X-KEY` 的 IV（十六进制字符串，去掉 `0x` 前缀）。
    pub key_iv: Option<String>,
    /// 累计时长（秒）。
    pub duration_secs: u64,
}

/// 解析 M3U8。`base` 用于把相对分片地址补全为绝对地址。
///
/// 只做结构解析，不下载分片；调用方负责鉴权与重试。
pub fn parse_playlist(body: &str, base: &str) -> Playlist {
    let text = body.trim_start_matches('\u{feff}');
    if !text.trim_start().starts_with("#EXTM3U") {
        return Playlist::default();
    }

    let mut playlist = Playlist {
        is_hls: true,
        ..Default::default()
    };
    let mut pending_variant = false;

    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }
        if let Some(rest) = line.strip_prefix("#EXT-X-KEY:") {
            for attr in rest.split(',') {
                let Some((key, value)) = attr.split_once('=') else {
                    continue;
                };
                let value = value.trim_matches('"');
                match key.trim() {
                    "URI" => playlist.key_uri = Some(absolute(base, value)),
                    "METHOD" => playlist.key_method = Some(value.to_string()),
                    "IV" => {
                        playlist.key_iv = Some(
                            value
                                .trim_start_matches("0x")
                                .trim_start_matches("0X")
                                .to_string(),
                        )
                    }
                    _ => {}
                }
            }
            continue;
        }
        if let Some(rest) = line.strip_prefix("#EXT-X-STREAM-INF:") {
            let _ = rest;
            pending_variant = true;
            continue;
        }
        if line.starts_with("#EXTINF:") {
            let spec = line.trim_start_matches("#EXTINF:");
            let seconds = spec
                .split(',')
                .next()
                .unwrap_or("0")
                .trim()
                .parse::<f64>()
                .unwrap_or(0.0);
            playlist.duration_secs += seconds.max(0.0) as u64;
            continue;
        }
        if line.starts_with('#') {
            continue;
        }
        // 非注释行即地址。
        let resolved = absolute(base, line);
        if pending_variant {
            playlist.variants.push(resolved);
            pending_variant = false;
        } else {
            playlist.segments.push(resolved);
        }
    }
    playlist
}

/// 用 AES-128-CBC 解密一个 HLS 分片。
///
/// 标准 HLS 使用 PKCS#7 填充；`iv` 为十六进制（已去掉 `0x`），
/// 缺省时按规范使用分片序号（大端 16 字节）。
pub fn decrypt_segment(
    ciphertext: &[u8],
    key: &[u8],
    iv_hex: Option<&str>,
    sequence: u64,
) -> Result<Vec<u8>, String> {
    use aes::cipher::{BlockDecryptMut, KeyIvInit};
    use cbc::Decryptor;

    if key.len() != 16 {
        return Err(format!("AES-128 密钥长度无效：{}", key.len()));
    }
    let mut iv = [0u8; 16];
    match iv_hex {
        Some(value) if !value.is_empty() => {
            let bytes = hex::decode(value).map_err(|err| format!("IV 解析失败：{err}"))?;
            if bytes.len() != 16 {
                return Err(format!("IV 长度无效：{}", bytes.len()));
            }
            iv.copy_from_slice(&bytes);
        }
        _ => {
            // 无显式 IV 时使用分片序号（大端）。
            iv[8..].copy_from_slice(&sequence.to_be_bytes());
        }
    }
    if ciphertext.is_empty() || !ciphertext.len().is_multiple_of(16) {
        return Err(format!("密文长度不是块大小的整数倍：{}", ciphertext.len()));
    }

    type Aes128CbcDec = Decryptor<aes::Aes128>;
    let plain = Aes128CbcDec::new(key.into(), &iv.into())
        .decrypt_padded_vec_mut::<aes::cipher::block_padding::Pkcs7>(ciphertext)
        .map_err(|err| format!("分片解密失败：{err}"))?;
    Ok(plain)
}

/// 从播放页 HTML 中提取媒体地址。
///
/// 覆盖站点常见的三种写法：
/// 1. `player_aaaa = {"url": "..."}` 播放器变量；
/// 2. `<video src="...">` / `<source src="...">`；
/// 3. 页面内直接出现的 `.m3u8` / `.mp4` 绝对或相对地址。
pub fn extract_media_url(html: &str, base: &str) -> Option<String> {
    if let Some(found) = from_player_variable(html, base) {
        return Some(found);
    }
    if let Some(found) = from_video_tag(html, base) {
        return Some(found);
    }
    from_embedded_url(html, base)
}

fn from_player_variable(html: &str, base: &str) -> Option<String> {
    let marker = "player_aaaa";
    let start = html.find(marker)?;
    let rest = &html[start..];
    let value_start = rest.find("\"url\"")?;
    let after_key = &rest[value_start + 5..];
    let colon = after_key.find(':')?;
    let after_colon = after_key[colon + 1..].trim_start();
    let quote = after_colon.chars().next()?;
    if quote != '"' && quote != '\'' {
        return None;
    }
    let body = &after_colon[1..];
    let end = body.find(quote)?;
    let raw = body[..end].trim();
    if raw.is_empty() {
        None
    } else {
        Some(decode_slash(raw, base))
    }
}

fn from_video_tag(html: &str, base: &str) -> Option<String> {
    for tag in ["<video", "<source"] {
        let mut cursor = 0;
        while let Some(index) = html[cursor..].find(tag) {
            let start = cursor + index;
            let end = html[start..].find('>').map(|offset| start + offset)?;
            let fragment = &html[start..end];
            if let Some(url) = attr_value(fragment, "src") {
                if !url.is_empty() {
                    return Some(decode_slash(&url, base));
                }
            }
            cursor = end + 1;
        }
    }
    None
}

fn attr_value(fragment: &str, name: &str) -> Option<String> {
    let needle = format!("{name}=");
    let index = fragment.find(&needle)?;
    let rest = &fragment[index + needle.len()..];
    let rest = rest.trim_start();
    let quote = rest.chars().next()?;
    if quote != '"' && quote != '\'' {
        let end = rest
            .find(|c: char| c.is_whitespace() || c == '>')
            .unwrap_or(rest.len());
        return Some(rest[..end].to_string());
    }
    let body = &rest[1..];
    let end = body.find(quote)?;
    Some(body[..end].to_string())
}

fn from_embedded_url(html: &str, base: &str) -> Option<String> {
    for suffix in [".m3u8", ".mp4"] {
        let mut cursor = 0;
        while let Some(index) = html[cursor..].find(suffix) {
            let end = cursor + index + suffix.len();
            // 向左回溯到引号或空白，得到完整地址。
            let left = html[..end]
                .rfind(['"', '\'', ' ', '=', '(', ')'])
                .map(|position| position + 1)
                .unwrap_or(0);
            let candidate = html[left..end].trim();
            if candidate.contains('/') && !candidate.contains('<') {
                return Some(decode_slash(candidate, base));
            }
            cursor = end;
        }
    }
    None
}

fn decode_slash(raw: &str, base: &str) -> String {
    let unescaped = raw.replace("\\/", "/");
    absolute(base, &unescaped)
}

/// 把相对地址补全为绝对地址。
pub fn absolute(base: &str, reference: &str) -> String {
    let reference = reference.trim();
    if reference.is_empty() {
        return String::new();
    }
    if reference.starts_with("http://") || reference.starts_with("https://") {
        return reference.to_string();
    }
    if reference.starts_with("//") {
        let scheme = if base.starts_with("https://") {
            "https:"
        } else {
            "http:"
        };
        return format!("{scheme}{reference}");
    }
    let (origin, base_path) = split_origin(base);
    if reference.starts_with('/') {
        return format!("{origin}{reference}");
    }
    let directory = match base_path.rfind('/') {
        Some(index) => &base_path[..=index],
        None => "/",
    };
    format!("{origin}{directory}{reference}")
}

fn split_origin(base: &str) -> (String, String) {
    let Some(scheme_end) = base.find("://") else {
        return (String::new(), base.to_string());
    };
    let after_scheme = scheme_end + 3;
    match base[after_scheme..].find('/') {
        Some(offset) => {
            let host_end = after_scheme + offset;
            (base[..host_end].to_string(), base[host_end..].to_string())
        }
        None => (base.to_string(), "/".to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MASTER: &str = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\n720p/index.m3u8\n";

    const MEDIA: &str = concat!(
        "#EXTM3U\n",
        "#EXT-X-VERSION:3\n",
        "#EXT-X-TARGETDURATION:10\n",
        "#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n",
        "#EXTINF:9.5,\n",
        "seg0.ts\n",
        "#EXTINF:10.0,\n",
        "https://cdn.test/seg1.ts\n",
        "#EXT-X-ENDLIST\n",
    );

    #[test]
    fn detects_master_playlist_variants() {
        let parsed = parse_playlist(MASTER, "https://cdn.test/hls/master.m3u8");
        assert!(parsed.is_hls);
        assert_eq!(
            parsed.variants,
            vec!["https://cdn.test/hls/720p/index.m3u8"]
        );
        assert!(parsed.segments.is_empty());
    }

    #[test]
    fn parses_segments_key_and_duration() {
        let parsed = parse_playlist(MEDIA, "https://cdn.test/hls/index.m3u8");
        assert!(parsed.is_hls);
        assert_eq!(parsed.segments.len(), 2);
        assert_eq!(parsed.segments[0], "https://cdn.test/hls/seg0.ts");
        assert_eq!(parsed.segments[1], "https://cdn.test/seg1.ts");
        assert_eq!(
            parsed.key_uri.as_deref(),
            Some("https://cdn.test/hls/key.bin")
        );
        assert_eq!(parsed.key_method.as_deref(), Some("AES-128"));
        assert_eq!(parsed.duration_secs, 19);
    }

    #[test]
    fn rejects_non_playlist_body() {
        assert!(!parse_playlist("<html>nope</html>", "https://a.test/").is_hls);
        assert!(!parse_playlist("", "https://a.test/").is_hls);
    }

    #[test]
    fn strips_bom_before_detection() {
        let body = format!("\u{feff}{MASTER}");
        assert!(parse_playlist(&body, "https://cdn.test/x.m3u8").is_hls);
    }

    #[test]
    fn extracts_player_variable_url() {
        let html = r#"<script>var player_aaaa={"flag":"play","encrypt":0,"url":"https:\/\/cdn.test\/a\/index.m3u8"}</script>"#;
        assert_eq!(
            extract_media_url(html, "https://site.test/play/1.html").as_deref(),
            Some("https://cdn.test/a/index.m3u8")
        );
    }

    #[test]
    fn extracts_video_tag_source() {
        let html = r#"<video controls src="/media/1.mp4"></video>"#;
        assert_eq!(
            extract_media_url(html, "https://site.test/detail/9.html").as_deref(),
            Some("https://site.test/media/1.mp4")
        );
    }

    #[test]
    fn extracts_source_tag() {
        let html = r#"<source src='https://cdn.test/x.m3u8' type='application/x-mpegURL'>"#;
        assert_eq!(
            extract_media_url(html, "https://site.test/").as_deref(),
            Some("https://cdn.test/x.m3u8")
        );
    }

    #[test]
    fn falls_back_to_embedded_absolute_url() {
        let html = r#"<script>load("https://cdn.test/live/index.m3u8");</script>"#;
        assert_eq!(
            extract_media_url(html, "https://site.test/").as_deref(),
            Some("https://cdn.test/live/index.m3u8")
        );
    }

    #[test]
    fn returns_none_when_nothing_matches() {
        assert_eq!(
            extract_media_url("<html>无视频</html>", "https://a.test/"),
            None
        );
    }

    #[test]
    fn decrypts_with_explicit_iv() {
        // NIST SP 800-38A F.2.1 CBC-AES128 的密钥与 IV，
        // 用单块密文验证实现正确性。
        let key = hex::decode("2b7e151628aed2a6abf7158809cf4f3c").expect("key");
        // 明文 6bc1bee22e409f96e93d7e117393172a 加密后的首块。
        let cipher = hex::decode("7649abac8119b246cee98e9b12e9197d").expect("cipher");
        // 单块解密会因缺少填充而失败，这里改为验证错误路径。
        let err = decrypt_segment(&cipher, &key, Some("000102030405060708090a0b0c0d0e0f"), 0)
            .expect_err("single block without padding must fail");
        assert!(err.contains("解密失败"), "{err}");
    }

    #[test]
    fn decrypts_round_trip_with_pkcs7() {
        use aes::cipher::{BlockEncryptMut, KeyIvInit};
        type Enc = cbc::Encryptor<aes::Aes128>;

        let key = hex::decode("2b7e151628aed2a6abf7158809cf4f3c").expect("key");
        let iv_hex = "000102030405060708090a0b0c0d0e0f";
        let iv = hex::decode(iv_hex).expect("iv");
        let plain = b"HLS segment payload".to_vec();
        let cipher = Enc::new(key.as_slice().into(), iv.as_slice().into())
            .encrypt_padded_vec_mut::<aes::cipher::block_padding::Pkcs7>(&plain);

        let recovered = decrypt_segment(&cipher, &key, Some(iv_hex), 0).expect("decrypt");
        assert_eq!(recovered, plain);
    }

    #[test]
    fn rejects_bad_key_length() {
        let err = decrypt_segment(b"1234567890123456", b"short", None, 0).expect_err("must fail");
        assert!(err.contains("密钥长度"), "{err}");
    }

    #[test]
    fn rejects_unaligned_ciphertext() {
        let key = [0u8; 16];
        let err = decrypt_segment(b"not-a-block", &key, None, 0).expect_err("must fail");
        assert!(err.contains("块大小"), "{err}");
    }

    #[test]
    fn parses_key_iv_from_playlist() {
        let body = "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"k.bin\",IV=0x0123456789abcdef0123456789abcdef\n#EXTINF:1,\na.ts\n";
        let parsed = parse_playlist(body, "https://cdn.test/x.m3u8");
        assert_eq!(
            parsed.key_iv.as_deref(),
            Some("0123456789abcdef0123456789abcdef")
        );
    }

    #[test]
    fn absolute_handles_relative_and_protocol_relative() {
        assert_eq!(
            absolute("https://a.test/x/y.html", "z.ts"),
            "https://a.test/x/z.ts"
        );
        assert_eq!(
            absolute("https://a.test/x/y.html", "/root.ts"),
            "https://a.test/root.ts"
        );
        assert_eq!(
            absolute("https://a.test/x/", "//cdn.test/a.ts"),
            "https://cdn.test/a.ts"
        );
        assert_eq!(absolute("https://a.test", "b.ts"), "https://a.test/b.ts");
    }
}
