//! `plugin.toml` 清单：结构与加载期校验（ARCHITECTURE.md §7.3）。

use std::fmt;
use std::str::FromStr;

use semver::Version;
use serde::{Deserialize, Serialize};

use guo_source_api::ContentType;

use crate::error::PluginError;

/// 当前支持的包格式版本。
pub const PLUGIN_SPEC: u32 = 1;
/// 当前宿主提供的插件 API 级别。
pub const CURRENT_API_LEVEL: u32 = 1;

/// 插件 id：`[a-z0-9][a-z0-9._-]{2,63}`。
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct PluginId(String);

impl PluginId {
    pub fn parse(text: &str) -> Result<Self, PluginError> {
        let valid_len = (3..=64).contains(&text.len());
        let first_ok = text
            .chars()
            .next()
            .map(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
            .unwrap_or(false);
        let rest_ok = text
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || "._-".contains(c));
        if !(valid_len && first_ok && rest_ok) {
            return Err(PluginError::invalid(
                "id",
                format!("{text} 必须匹配 [a-z0-9][a-z0-9._-]{{2,63}}"),
            ));
        }
        Ok(Self(text.to_string()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for PluginId {
    fn fmt(&self, out: &mut fmt::Formatter<'_>) -> fmt::Result {
        out.write_str(&self.0)
    }
}

impl FromStr for PluginId {
    type Err = PluginError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::parse(s)
    }
}

impl<'de> serde::Deserialize<'de> for PluginId {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let raw = String::deserialize(deserializer)?;
        Self::parse(&raw).map_err(serde::de::Error::custom)
    }
}

/// 插件类型。三种形态共用同一 zip 容器，内容不同。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PluginKind {
    /// 一条或多条声明式规则。
    Declarative,
    /// 单个 WASM 组件。
    Component,
    /// 一个 JS 脚本（`entry` 指向 `main.js`）。
    Script,
}

impl PluginKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Declarative => "declarative",
            Self::Component => "component",
            Self::Script => "script",
        }
    }
}

/// 宿主版本区间要求。
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct ApiRequirement {
    pub level: u32,
    pub min_host: Version,
    #[serde(default)]
    pub max_host: Option<Version>,
}

impl ApiRequirement {
    /// 宿主是否满足该插件的 API 与版本要求。
    pub fn accepts(&self, host: &Version) -> Result<(), PluginError> {
        if self.level > CURRENT_API_LEVEL {
            return Err(PluginError::Unsupported {
                detail: format!(
                    "插件要求 API level {}，宿主只支持到 {CURRENT_API_LEVEL}",
                    self.level
                ),
            });
        }
        if host < &self.min_host {
            return Err(PluginError::Unsupported {
                detail: format!("插件要求宿主 ≥ {}，当前 {host}", self.min_host),
            });
        }
        if let Some(max) = &self.max_host {
            if host > max {
                return Err(PluginError::Unsupported {
                    detail: format!("插件要求宿主 ≤ {max}，当前 {host}"),
                });
            }
        }
        Ok(())
    }
}

/// 权限声明。不是文件路径，而是宿主侧的能力命名空间。
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
pub struct PluginPermissions {
    /// 允许访问的主机名（不含协议与路径）。
    #[serde(default)]
    pub network: Vec<String>,
    /// 允许使用的存储命名空间。
    #[serde(default)]
    pub storage: Vec<String>,
    #[serde(default)]
    pub script: Option<ScriptPermission>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
pub struct ScriptPermission {
    pub timeout_ms: u64,
    pub memory_kb: u64,
}

/// 声明式插件内的一条规则条目。
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct RuleEntry {
    pub path: String,
    pub site: String,
}

/// `plugin.toml` 的完整结构。
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct PluginManifest {
    pub spec: u32,
    pub id: PluginId,
    pub name: String,
    pub version: Version,
    pub kind: PluginKind,
    pub api: ApiRequirement,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub authors: Vec<String>,
    #[serde(default)]
    pub homepage: Option<String>,
    #[serde(default)]
    pub license: Option<String>,
    #[serde(default)]
    pub permissions: PluginPermissions,
    /// 内容类型标注。**仅用于分发与商店展示**：运行期以规则 JSON / 脚本
    /// `describe()` 的声明为准，两者不一致由 `check_plugin` 报错。
    #[serde(default)]
    pub content_types: Vec<ContentType>,
    /// 声明式插件的规则列表；`kind = "declarative"` 时不能为空。
    #[serde(default, rename = "rules")]
    pub rules: Vec<RuleEntry>,
    /// 代码插件的入口；`kind = "component"` 时必填。
    #[serde(default)]
    pub entry: Option<String>,
}

impl PluginManifest {
    /// 解析并校验清单文本。
    pub fn parse(text: &str) -> Result<Self, PluginError> {
        let manifest: Self =
            toml::from_str(text).map_err(|err| PluginError::invalid("清单", format!("{err}")))?;
        manifest.validate()?;
        Ok(manifest)
    }

    /// 加载期校验：结构完整、版本兼容、路径安全。
    pub fn validate(&self) -> Result<(), PluginError> {
        if self.spec != PLUGIN_SPEC {
            return Err(PluginError::Unsupported {
                detail: format!("包格式 spec {} 不受支持（当前 {PLUGIN_SPEC}）", self.spec),
            });
        }
        if self.name.trim().is_empty() {
            return Err(PluginError::invalid("清单", "name 不能为空"));
        }
        match self.kind {
            PluginKind::Declarative => {
                if self.rules.is_empty() {
                    return Err(PluginError::invalid(
                        "清单",
                        "声明式插件必须至少声明一条 [[rules]]",
                    ));
                }
                if self.entry.is_some() {
                    return Err(PluginError::invalid(
                        "清单",
                        "声明式插件不应声明 entry（那是代码插件的入口）",
                    ));
                }
                for rule in &self.rules {
                    check_relative(&rule.path, "rules[].path")?;
                }
            }
            PluginKind::Component => {
                let Some(entry) = &self.entry else {
                    return Err(PluginError::invalid("清单", "代码插件必须声明 entry"));
                };
                check_relative(entry, "entry")?;
                if !self.rules.is_empty() {
                    return Err(PluginError::invalid(
                        "清单",
                        "代码插件不应声明 [[rules]]（规则应写在声明式插件里）",
                    ));
                }
            }
            PluginKind::Script => {
                let Some(entry) = &self.entry else {
                    return Err(PluginError::invalid("清单", "脚本插件必须声明 entry"));
                };
                check_relative(entry, "entry")?;
                // 脚本插件允许同时带 [[rules]]：规则定义结构、脚本做签名与解密。
            }
        }
        for host in &self.permissions.network {
            let host = host.trim();
            if host.is_empty() || host.contains('/') || host.contains("://") {
                return Err(PluginError::invalid(
                    "permissions.network",
                    format!("{host} 必须是纯主机名，不能带协议或路径"),
                ));
            }
        }
        if let Some(script) = self.permissions.script {
            // 上限取 30s：脚本里的 `ctx.fetch` 会在 JS 线程上等网络，
            // 多步编排的站点（猫果/野果）10s 是正常值，卡 5s 会把合法脚本判死。
            // 这仍然是硬上限——中断处理器按墙钟时间生效。
            if script.timeout_ms == 0 || script.timeout_ms > 30_000 {
                return Err(PluginError::invalid(
                    "permissions.script",
                    "timeout_ms 必须在 1..=30000",
                ));
            }
            if script.memory_kb == 0 || script.memory_kb > 32 * 1024 {
                return Err(PluginError::invalid(
                    "permissions.script",
                    "memory_kb 必须在 1..=32768",
                ));
            }
        }
        Ok(())
    }

    /// 清单声明的全部相对路径（解包时据此确认文件存在）。
    pub fn declared_paths(&self) -> Vec<&str> {
        let mut out: Vec<&str> = self.rules.iter().map(|rule| rule.path.as_str()).collect();
        if let Some(entry) = &self.entry {
            out.push(entry.as_str());
        }
        out
    }
}

/// 只接受相对路径：不能绝对、不能上跳、不能是目录。
fn check_relative(path: &str, field: &str) -> Result<(), PluginError> {
    let trimmed = path.trim();
    if trimmed.is_empty() {
        return Err(PluginError::invalid("清单", format!("{field} 不能为空")));
    }
    if trimmed.starts_with('/') || trimmed.contains("..") || trimmed.contains('\\') {
        return Err(PluginError::unsafe_entry(format!(
            "{field} 必须是包内相对路径：{path}"
        )));
    }
    if trimmed.ends_with('/') {
        return Err(PluginError::invalid(
            "清单",
            format!("{field} 必须指向文件：{path}"),
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const DECLARATIVE: &str = r#"
spec = 1
id = "guo.fanguo"
name = "饭果"
version = "1.0.0"
kind = "declarative"
api = { level = 1, min_host = "0.3.0" }
description = "西饭短剧搜索接口"
authors = ["community"]
license = "MIT"

[permissions]
network = ["xifan-api-cn.youlishipin.com"]
storage = ["session"]
script = { timeout_ms = 200, memory_kb = 4096 }

[[rules]]
path = "rules/fanguo.json"
site = "fanguo"
"#;

    #[test]
    fn parses_declarative_manifest() {
        let manifest = PluginManifest::parse(DECLARATIVE).expect("manifest");
        assert_eq!(manifest.id.as_str(), "guo.fanguo");
        assert_eq!(manifest.kind, PluginKind::Declarative);
        assert_eq!(manifest.version, Version::new(1, 0, 0));
        assert_eq!(manifest.declared_paths(), vec!["rules/fanguo.json"]);
        assert_eq!(manifest.permissions.network.len(), 1);
    }

    #[test]
    fn rejects_unknown_spec() {
        let text = DECLARATIVE.replace("spec = 1", "spec = 2");
        let err = PluginManifest::parse(&text).expect_err("must fail");
        assert!(matches!(err, PluginError::Unsupported { .. }), "{err}");
    }

    #[test]
    fn rejects_path_traversal_in_rules() {
        let text = DECLARATIVE.replace("rules/fanguo.json", "../evil.json");
        let err = PluginManifest::parse(&text).expect_err("must fail");
        assert!(matches!(err, PluginError::Unsafe { .. }), "{err}");
    }

    #[test]
    fn rejects_declarative_without_rules() {
        let text = "\
spec = 1
id = \"guo.empty\"
name = \"空\"
version = \"1.0.0\"
kind = \"declarative\"
api = { level = 1, min_host = \"0.3.0\" }
";
        let err = PluginManifest::parse(text).expect_err("must fail");
        assert!(err.to_string().contains("[[rules]]"), "{err}");
    }

    #[test]
    fn rejects_component_without_entry() {
        let text = "\
spec = 1
id = \"guo.empty\"
name = \"空\"
version = \"1.0.0\"
kind = \"component\"
api = { level = 1, min_host = \"0.3.0\" }
";
        let err = PluginManifest::parse(text).expect_err("must fail");
        assert!(err.to_string().contains("entry"), "{err}");
    }

    #[test]
    fn rejects_network_entries_with_scheme() {
        let text = DECLARATIVE.replace(
            "xifan-api-cn.youlishipin.com",
            "https://xifan-api-cn.youlishipin.com/path",
        );
        let err = PluginManifest::parse(&text).expect_err("must fail");
        assert!(err.to_string().contains("主机名"), "{err}");
    }

    #[test]
    fn rejects_invalid_plugin_id() {
        for bad in ["Guo.Fanguo", "a", "9guo!", "-guo"] {
            assert!(PluginId::parse(bad).is_err(), "{bad} 不应通过");
        }
        assert_eq!(
            PluginId::parse("guo.fanguo").expect("ok").as_str(),
            "guo.fanguo"
        );
    }

    #[test]
    fn api_level_above_host_is_rejected() {
        let requirement = ApiRequirement {
            level: CURRENT_API_LEVEL + 1,
            min_host: Version::new(0, 3, 0),
            max_host: None,
        };
        let err = requirement
            .accepts(&Version::new(0, 3, 0))
            .expect_err("must fail");
        assert!(matches!(err, PluginError::Unsupported { .. }), "{err}");
    }

    #[test]
    fn host_version_window_is_enforced() {
        let requirement = ApiRequirement {
            level: 1,
            min_host: Version::new(0, 3, 0),
            max_host: Some(Version::new(0, 4, 0)),
        };
        assert!(requirement.accepts(&Version::new(0, 3, 5)).is_ok());
        assert!(requirement.accepts(&Version::new(0, 5, 0)).is_err());
        assert!(requirement.accepts(&Version::new(0, 2, 0)).is_err());
    }

    #[test]
    fn script_budget_is_bounded() {
        let text = DECLARATIVE.replace("timeout_ms = 200", "timeout_ms = 0");
        let err = PluginManifest::parse(&text).expect_err("must fail");
        assert!(err.to_string().contains("timeout_ms"), "{err}");
    }
}
