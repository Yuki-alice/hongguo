use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Drama {
    pub id: String,
    pub source: String,
    pub source_id: String,
    pub title: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub description: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub cover: String,
    #[serde(default)]
    pub episodes: u32,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub category: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub vip: Option<bool>,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub heat: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub views: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub online_date: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tags: Vec<String>,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub release_status: String,
}

impl Drama {
    pub fn identity(source: &str, source_id: impl Into<String>) -> String {
        format!("{source}:{}", source_id.into())
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Chapter {
    pub id: String,
    pub title: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub source: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub video_url: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub page_url: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub referer: String,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub vip: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Page {
    pub items: Vec<Drama>,
    #[serde(default)]
    pub has_more: bool,
    #[serde(default)]
    pub page: u32,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub warning: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Media {
    pub url: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub referer: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub playlist: Option<Vec<String>>,
    /// HLS AES-128 密钥地址；为空表示未加密。
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub key_uri: String,
    /// AES-128 的 IV（十六进制，无 `0x`）。
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub key_iv: String,
    /// 播放时必须随请求发送的 Cookie。
    ///
    /// 部分站点的媒体域走 CDN 签名：取流接口在响应头里下发
    /// `CloudFront-Policy` / `Signature` / `Key-Pair-Id`，只有带上它们
    /// 才能拉到播放列表与分片。为空表示不需要。
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub cookies: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Category {
    pub id: String,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Detail {
    pub drama: Drama,
    pub chapters: Vec<Chapter>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drama_identity_is_source_scoped() {
        assert_eq!(Drama::identity("wuguo", "42"), "wuguo:42");
    }

    #[test]
    fn drama_serializes_with_camel_case() {
        let drama = Drama {
            id: "wuguo:42".into(),
            source: "wuguo".into(),
            source_id: "42".into(),
            title: "样本".into(),
            ..Default::default()
        };
        let json = serde_json::to_string(&drama).expect("serialize");
        assert!(json.contains("\"sourceId\":\"42\""));
        assert!(!json.contains("description"));
    }
}

/// 榜单单条目：名次 + 剧目 + 展示用指标。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RankingItem {
    pub rank: u32,
    pub drama: Drama,
    /// 榜单展示的热度 / 播放量文本，直接来自站点。
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub metric: String,
}

/// 榜单的一页。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RankingPage {
    pub items: Vec<RankingItem>,
    #[serde(default)]
    pub has_more: bool,
    #[serde(default)]
    pub page: u32,
    /// 站点标注的更新时间，例如「9月13日已更新」。
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub updated_text: String,
    /// 使用上一次成功结果的缓存数据时置位，UI 据此提示「可能不是最新」。
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub stale: bool,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub warning: String,
}

/// 榜单看板（站点的固定榜单入口）。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RankingBoard {
    pub id: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub group: String,
}

/// 搜索联想词。`kind` 是站点给出的词性，可能为空。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Suggestion {
    pub name: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub kind: String,
}

/// 一条弹幕。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Danmaku {
    /// 出现时间（毫秒）。
    pub time_ms: i64,
    pub text: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub color: String,
}

/// 一集按时间轴切分的弹幕分段。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DanmakuPage {
    pub items: Vec<Danmaku>,
    /// 本段结束时间（毫秒）；等于视频时长表示已到末尾。
    pub end_ms: i64,
    pub has_more: bool,
}

/// 系列剧的季信息：同一部剧的不同季。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SeriesSeason {
    pub season: u32,
    /// 该季在站点的标题。
    pub title: String,
    /// 对应剧目的 source_id。
    pub source_id: String,
}

/// 推荐流的游标。翻页靠 `offset` + `session_id`，与 Go 版一致。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecommendCursor {
    #[serde(default)]
    pub offset: u32,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub session_id: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub genre: String,
}

/// 推荐流的一页。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecommendPage {
    pub items: Vec<Drama>,
    pub cursor: RecommendCursor,
    #[serde(default)]
    pub has_more: bool,
}
