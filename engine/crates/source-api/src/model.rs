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
