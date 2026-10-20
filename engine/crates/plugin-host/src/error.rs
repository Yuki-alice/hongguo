use std::fmt;

/// 插件安装与校验过程中的错误。
///
/// 与 `SourceError` 分开：站源错误面向「运行时取数失败」，这里面向「包不可信或不可用」，
/// UI 的处置也不同（前者重试，后者提示用户或拒绝安装）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PluginError {
    /// 清单 / 索引结构不合法。
    Invalid { what: &'static str, detail: String },
    /// 文件缺失、读取失败等 IO 问题。
    Io { path: String, detail: String },
    /// 哈希或签名不匹配。
    Integrity { what: &'static str, detail: String },
    /// API 级别或宿主版本不满足要求。
    Unsupported { detail: String },
    /// 解压防护触发（路径穿越、条目过多、体积超限）。
    Unsafe { detail: String },
}

impl PluginError {
    pub fn invalid(what: &'static str, detail: impl fmt::Display) -> Self {
        Self::Invalid {
            what,
            detail: detail.to_string(),
        }
    }

    pub fn io(path: impl Into<String>, detail: impl fmt::Display) -> Self {
        Self::Io {
            path: path.into(),
            detail: detail.to_string(),
        }
    }

    pub fn integrity(what: &'static str, detail: impl fmt::Display) -> Self {
        Self::Integrity {
            what,
            detail: detail.to_string(),
        }
    }

    pub fn unsafe_entry(detail: impl fmt::Display) -> Self {
        Self::Unsafe {
            detail: detail.to_string(),
        }
    }
}

impl fmt::Display for PluginError {
    fn fmt(&self, out: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Invalid { what, detail } => write!(out, "插件{what}不合法：{detail}"),
            Self::Io { path, detail } => write!(out, "读取 {path} 失败：{detail}"),
            Self::Integrity { what, detail } => write!(out, "{what}校验失败：{detail}"),
            Self::Unsupported { detail } => write!(out, "插件不受支持：{detail}"),
            Self::Unsafe { detail } => write!(out, "插件包被拒绝：{detail}"),
        }
    }
}

impl std::error::Error for PluginError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn integrity_errors_mention_the_subject() {
        let err = PluginError::integrity("包哈希", "期望 a，实际 b");
        assert!(err.to_string().contains("包哈希"), "{err}");
        assert!(err.to_string().contains("期望 a"), "{err}");
    }

    #[test]
    fn unsafe_entries_are_reported_verbatim() {
        let err = PluginError::unsafe_entry("路径穿越：../evil");
        assert!(err.to_string().contains("../evil"), "{err}");
    }
}
