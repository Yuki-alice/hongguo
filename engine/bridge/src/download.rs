use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio::io::AsyncWriteExt;

use crate::env::{FetchRequest, SourceEnv};
use crate::SourceError;

/// 单个下载任务的持久化元数据。
///
/// 与 Go 实现保持一致：`<target>.json` 记录校验信息，`<target>.part` 存数据，
/// 两者分离以便中断后按 `Range` 续传。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FileState {
    /// 单文件下载记录地址；HLS 下载记录分片列表签名。
    #[serde(default)]
    pub url: String,
    /// 单文件下载的 ETag / Last-Modified；HLS 下载留空。
    #[serde(default)]
    pub validator: String,
    /// 单文件下载为总字节数；HLS 下载为分片总数。
    #[serde(default)]
    pub total: i64,
    /// HLS 已完成的分片数，用于精确续传。
    #[serde(default)]
    pub completed_segments: i64,
}

/// 分片列表签名：列表变化（清晰度切换、源站重排）后不得续传旧字节。
///
/// 公开是为了让调用方与测试能按同一规则判断「能否续传」。
pub fn playlist_signature(segments: &[String]) -> String {
    let joined = segments.join("\n");
    crate::crypto::md5_hex(joined.as_bytes())
}

/// 一次下载的结果。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DownloadOutcome {
    /// 完成，返回最终字节数。
    Completed(u64),
    /// 服务器数据已变化，需要从零重下。
    Restart,
}

/// HLS 解密材料。
#[derive(Debug, Clone, Copy)]
pub struct HlsKey<'a> {
    /// 16 字节 AES-128 密钥。
    pub bytes: &'a [u8],
    /// 播放列表声明的 IV（十六进制，无 `0x` 前缀）。
    pub iv_hex: Option<&'a str>,
}

/// 下载 HLS 分片并拼接为单个文件。
///
/// 分片按顺序追加写入 `target.part`，已存在的部分会被跳过，
/// 因此中断后可以继续。分片之间不做转码，直接字节拼接，
/// 与 Go 实现的 `cat segments` 行为一致。
pub async fn download_hls(
    env: &SourceEnv,
    segments: &[String],
    referer: &str,
    target: &Path,
    key: Option<HlsKey<'_>>,
    progress: impl Fn(u64, i64) + Send + Sync,
) -> Result<DownloadOutcome, SourceError> {
    if segments.is_empty() {
        return Err(SourceError::parse("download", "播放列表没有分片"));
    }
    let part_path = with_suffix(target, "part");
    let meta_path = with_suffix(target, "json");
    if let Some(parent) = part_path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|err| SourceError::parse("download", format!("创建目录失败：{err}")))?;
    }

    // 断点续传：元数据里的分片签名必须与本次播放列表一致，且 `.part` 已存在，
    // 才从已完成的分片继续；否则从零开始，避免把不同列表的字节混拼。
    let total = segments.len() as i64;
    let signature = playlist_signature(segments);
    let previous = read_state(&meta_path).await;
    let (mut written, resume_from) = if previous.url == signature && previous.total == total {
        match std::fs::metadata(&part_path) {
            Ok(info) if info.len() > 0 => {
                let done = previous.completed_segments.max(0) as usize;
                let done = done.min(segments.len());
                // `.part` 的实际长度可能与记录不符（进程被杀），以记录为准从下一个分片继续。
                (info.len(), done)
            }
            _ => (0, 0),
        }
    } else {
        let _ = std::fs::remove_file(&part_path);
        (0, 0)
    };
    if resume_from >= segments.len() && total > 0 {
        return Ok(DownloadOutcome::Restart);
    }

    for (index, segment) in segments.iter().enumerate().skip(resume_from) {
        let mut request = FetchRequest::get(segment)
            .header("Referer", referer)
            .header("Accept-Encoding", "identity")
            .priority(crate::env::RequestPriority::Media);
        request.timeout = Duration::from_secs(120);
        let response = env.transport.fetch(request).await?;
        if response.status != 200 && response.status != 206 {
            return Err(SourceError::http(segment, response.status));
        }
        let mut bytes = response.body;
        if bytes.is_empty() {
            return Err(SourceError::parse("download", "分片内容为空"));
        }
        // AES-128 加密的分片必须先解密再落盘，否则拼接结果无法播放。
        if let Some(material) = key.as_ref() {
            bytes = crate::media::decrypt_segment(
                &bytes,
                material.bytes,
                material.iv_hex,
                index as u64,
            )
            .map_err(|err| SourceError::parse("download", err))?;
        }
        append(&part_path, &bytes).await?;
        written += bytes.len() as u64;
        progress(written, total);
        // 每完成一个分片就落一次元数据，进程被杀后能准确知道续传位置。
        let meta = FileState {
            url: signature.clone(),
            validator: String::new(),
            total,
            completed_segments: index as i64 + 1,
        };
        if let Ok(encoded) = serde_json::to_vec(&meta) {
            let _ = write_atomic(&meta_path, &encoded).await;
        }
    }

    let meta = FileState {
        url: signature,
        validator: String::new(),
        total,
        completed_segments: total,
    };
    if let Ok(encoded) = serde_json::to_vec(&meta) {
        let _ = write_atomic(&meta_path, &encoded).await;
    }
    Ok(DownloadOutcome::Completed(written))
}

/// 下载单个媒体文件，支持断点续传。
///
/// `target` 是不带扩展名的目标路径；实际写入 `target.part`，
/// 元数据写入 `target.json`。
pub async fn download_file(
    env: &SourceEnv,
    address: &str,
    referer: &str,
    target: &Path,
    progress: impl Fn(u64, i64) + Send + Sync,
) -> Result<DownloadOutcome, SourceError> {
    if !is_media_url(address) {
        return Err(SourceError::parse("download", "媒体下载地址无效"));
    }
    let meta_path = with_suffix(target, "json");
    let part_path = with_suffix(target, "part");
    let state = read_state(&meta_path).await;

    let offset = match std::fs::metadata(&part_path) {
        Ok(info) if info.len() > 0 => info.len() as i64,
        _ => 0,
    };
    let mut request = FetchRequest::get(address)
        .header("Referer", referer)
        .header("Accept-Encoding", "identity")
        .priority(crate::env::RequestPriority::Media);
    request.timeout = Duration::from_secs(3600);

    if offset > 0 {
        request
            .headers
            .insert("Range".into(), format!("bytes={offset}-"));
        if !state.validator.is_empty() {
            request
                .headers
                .insert("If-Range".into(), state.validator.clone());
        }
    }

    let response = env.transport.fetch(request).await?;
    let status = response.status;

    // 范围不可满足或前置条件失败：服务器数据已变化，从头再来。
    if offset > 0 && (status == 416 || status == 412) {
        return Ok(DownloadOutcome::Restart);
    }
    if status != 200 && status != 206 {
        return Err(SourceError::http(address, status));
    }

    // 服务器忽略了 Range，返回完整内容：必须从头写。
    let effective_offset = if status == 200 { 0 } else { offset };
    // 记录本次响应的校验值，供下次 `If-Range` 判断内容是否变化。
    let validator = response.validator();
    let body = response.body;
    if body.is_empty() {
        // 续传时服务器返回空的 206 表示「从该偏移起已无数据」，即文件已完整；
        // 这不是错误，直接按已完成处理，否则重试会永久失败。
        if effective_offset > 0 && status == 206 {
            progress(effective_offset as u64, effective_offset);
            return Ok(DownloadOutcome::Completed(effective_offset as u64));
        }
        return Err(SourceError::parse("download", "服务器返回空内容"));
    }

    let total = if status == 206 {
        state.total.max(body.len() as i64)
    } else {
        body.len() as i64
    };

    if effective_offset == 0 {
        if let Some(parent) = part_path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|err| SourceError::parse("download", format!("创建目录失败：{err}")))?;
        }
        write_atomic(&part_path, &body).await?;
    } else {
        append(&part_path, &body).await?;
    }

    let received = effective_offset + body.len() as i64;
    progress(received as u64, total);

    let written = FileState {
        url: address.to_string(),
        validator: if validator.is_empty() {
            state.validator
        } else {
            validator
        },
        total,
        completed_segments: 0,
    };
    if let Ok(encoded) = serde_json::to_vec(&written) {
        let _ = write_atomic(&meta_path, &encoded).await;
    }

    Ok(DownloadOutcome::Completed(received as u64))
}

/// 把 `.part` 提交为最终文件。
pub fn commit(target: &Path) -> Result<PathBuf, SourceError> {
    let part = with_suffix(target, "part");
    let meta = with_suffix(target, "json");
    let final_path = target.to_path_buf();
    if final_path.exists() {
        let _ = std::fs::remove_file(&final_path);
    }
    std::fs::rename(&part, &final_path)
        .map_err(|err| SourceError::parse("download", format!("提交文件失败：{err}")))?;
    let _ = std::fs::remove_file(&meta);
    Ok(final_path)
}

/// 清理未完成的中间文件。
pub fn discard(target: &Path) {
    let _ = std::fs::remove_file(with_suffix(target, "part"));
    let _ = std::fs::remove_file(with_suffix(target, "json"));
}

fn with_suffix(target: &Path, extension: &str) -> PathBuf {
    let mut path = target.to_path_buf();
    let name = path
        .file_name()
        .map(|value| value.to_string_lossy().to_string())
        .unwrap_or_default();
    path.set_file_name(format!("{name}.{extension}"));
    path
}

async fn read_state(path: &Path) -> FileState {
    match tokio::fs::read(path).await {
        Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_default(),
        Err(_) => FileState::default(),
    }
}

async fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), SourceError> {
    let mut temporary = path.to_path_buf();
    let name = temporary
        .file_name()
        .map(|value| value.to_string_lossy().to_string())
        .unwrap_or_default();
    temporary.set_file_name(format!(".{name}.tmp"));
    {
        let mut file = tokio::fs::File::create(&temporary)
            .await
            .map_err(|err| SourceError::parse("download", format!("写入失败：{err}")))?;
        file.write_all(bytes)
            .await
            .map_err(|err| SourceError::parse("download", format!("写入失败：{err}")))?;
        file.flush()
            .await
            .map_err(|err| SourceError::parse("download", format!("刷盘失败：{err}")))?;
    }
    tokio::fs::rename(&temporary, path)
        .await
        .map_err(|err| SourceError::parse("download", format!("提交失败：{err}")))
}

async fn append(path: &Path, bytes: &[u8]) -> Result<(), SourceError> {
    // `append(true)` 不会创建文件；首次写入必须允许 create。
    let mut file = tokio::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .await
        .map_err(|err| SourceError::parse("download", format!("续写失败：{err}")))?;
    file.write_all(bytes)
        .await
        .map_err(|err| SourceError::parse("download", format!("续写失败：{err}")))?;
    file.flush()
        .await
        .map_err(|err| SourceError::parse("download", format!("刷盘失败：{err}")))
}

fn is_media_url(address: &str) -> bool {
    let lower = address.to_lowercase();
    (lower.starts_with("http://") || lower.starts_with("https://")) && !lower.contains(' ')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn suffix_helpers_keep_the_stem() {
        let target = Path::new("/tmp/media/1");
        assert_eq!(with_suffix(target, "part"), Path::new("/tmp/media/1.part"));
        assert_eq!(with_suffix(target, "json"), Path::new("/tmp/media/1.json"));
    }

    #[test]
    fn rejects_non_http_addresses() {
        assert!(!is_media_url("file:///etc/passwd"));
        assert!(!is_media_url("ftp://a.test/x.mp4"));
        assert!(!is_media_url("https://a.test/x y.mp4"));
        assert!(is_media_url("https://a.test/x.mp4"));
    }

    #[test]
    fn file_state_round_trips() {
        let state = FileState {
            url: "https://a.test/x.mp4".into(),
            validator: "\"etag\"".into(),
            total: 1234,
            completed_segments: 0,
        };
        let encoded = serde_json::to_string(&state).expect("encode");
        let decoded: FileState = serde_json::from_str(&encoded).expect("decode");
        assert_eq!(decoded, state);
    }

    #[test]
    fn empty_state_is_tolerated() {
        let decoded: FileState = serde_json::from_str("{}").expect("decode");
        assert_eq!(decoded, FileState::default());
    }
}
