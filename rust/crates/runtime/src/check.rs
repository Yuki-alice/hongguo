//! 扩展包的离线校验与冒烟（`check_plugin` 的实现）。
//!
//! 放在库里而不是直接写进 bin：这样能用普通集成测试覆盖「好包 / 坏包」，
//! 不必为了测一段 CLI 逻辑去启动子进程。
//!
//! 校验走的是**宿主同一条加载路径**（解包 → 清单校验 → 规则 `from_json` /
//! 脚本 `describe()`），所以「本地校验通过」就等于「装载时不会失败」。

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use guo_host::{HttpTransport, QuickJsHost, DEFAULT_USER_AGENT};
use guo_plugin_host::{unpack, PluginKind, PluginManifest, UnpackedPackage};
use guo_source_api::{
    Capability, LogSink, SourceEnv, SourceError, SourcePlugin, SourceStore, Transport,
};

use crate::plugins::script_limits;
use crate::rule_source::RuleSource;
use crate::script_source::{placeholder_env, ScriptSource};

/// 冒烟单请求超时：留出重试预算，但不让 CI 挂死。
const LIVE_TIMEOUT: Duration = Duration::from_secs(45);

// ---------------------------------------------------------------- 加载

/// 输入可能是 zip，也可能是解包后的目录（作者本地开发时通常是目录）。
pub fn load_package(target: &Path) -> Result<UnpackedPackage, String> {
    if target.is_dir() {
        return load_directory(target);
    }
    let bytes =
        std::fs::read(target).map_err(|err| format!("读取 {} 失败：{err}", target.display()))?;
    unpack(&bytes, None, Default::default()).map_err(|err| err.to_string())
}

fn load_directory(root: &Path) -> Result<UnpackedPackage, String> {
    let manifest_path = root.join("plugin.toml");
    let text = std::fs::read_to_string(&manifest_path)
        .map_err(|err| format!("读取 {} 失败：{err}", manifest_path.display()))?;
    let manifest = PluginManifest::parse(&text).map_err(|err| err.to_string())?;

    let mut files = BTreeMap::new();
    for relative in manifest.declared_paths() {
        let path = root.join(relative);
        let bytes = std::fs::read(&path)
            .map_err(|err| format!("缺少清单声明的文件 {}：{err}", path.display()))?;
        files.insert(relative.to_string(), bytes);
    }
    Ok(UnpackedPackage {
        manifest,
        files,
        sha256: String::new(),
    })
}

// ---------------------------------------------------------------- 检查

/// 一条规则的检查结果（一个包可能带多条规则）。
pub struct SourceFindings {
    /// 规则文件路径 / 脚本入口，用于错误定位。
    pub label: String,
    pub id: String,
    pub name: String,
    pub capabilities: Vec<Capability>,
    pub content_types: Vec<String>,
    /// 前置编排步数：确认 `preflight` 没被静默丢弃。
    pub preflight_steps: usize,
    /// 冒烟阶段复用同一个实例；`SourcePlugin` 的方法都以 `env` 入参，
    /// 静态阶段用占位环境、冒烟阶段换真实环境即可，不必重新解析。
    plugin: Arc<dyn SourcePlugin>,
}

pub struct Report {
    pub target: String,
    pub package_id: String,
    pub name: String,
    pub version: String,
    pub kind: String,
    pub sha256: String,
    pub sources: Vec<SourceFindings>,
    pub problems: Vec<String>,
    pub notes: Vec<String>,
    /// (检查项, 结果描述, 是否通过)
    pub smoke: Vec<(String, String, bool)>,
}

impl Report {
    pub fn rejected(target: &Path, detail: String) -> Self {
        Self {
            target: target.display().to_string(),
            package_id: String::new(),
            name: String::new(),
            version: String::new(),
            kind: String::new(),
            sha256: String::new(),
            sources: Vec::new(),
            problems: vec![detail],
            notes: Vec::new(),
            smoke: Vec::new(),
        }
    }

    pub fn ok(&self) -> bool {
        self.problems.is_empty() && self.smoke.iter().all(|(_, _, passed)| *passed)
    }

    pub fn print(&self) {
        println!("包：{}", self.target);
        if self.package_id.is_empty() {
            for problem in &self.problems {
                println!("  ✗ {problem}");
            }
            println!("结论：有问题（见上）");
            return;
        }
        println!(
            "  id={} name={} version={} kind={}",
            self.package_id, self.name, self.version, self.kind
        );
        if !self.sha256.is_empty() {
            let size = std::fs::metadata(&self.target)
                .map(|meta| meta.len())
                .unwrap_or_default();
            println!("  sha256={} size={size}", self.sha256);
        }
        for source in &self.sources {
            let caps: Vec<&str> = source
                .capabilities
                .iter()
                .map(|cap| name_of(*cap))
                .collect();
            let types = if source.content_types.is_empty() {
                "未标注".to_string()
            } else {
                source.content_types.join(", ")
            };
            println!(
                "  ✓ {} → id={} name={} 类型={} 能力=[{}]{}",
                source.label,
                source.id,
                source.name,
                types,
                caps.join(", "),
                if source.preflight_steps > 0 {
                    format!(" 前置={} 步", source.preflight_steps)
                } else {
                    String::new()
                }
            );
        }
        for note in &self.notes {
            println!("  · {note}");
        }
        for (what, detail, passed) in &self.smoke {
            println!("  {} {what}：{detail}", if *passed { "✓" } else { "✗" });
        }
        for problem in &self.problems {
            println!("  ✗ {problem}");
        }
        println!(
            "结论：{}",
            if self.ok() {
                "通过"
            } else {
                "有问题（见上）"
            }
        );
    }

    pub fn to_json(&self) -> String {
        let quote = |text: &str| serde_json::to_string(text).unwrap_or_else(|_| "\"\"".into());
        let sources: Vec<String> = self
            .sources
            .iter()
            .map(|source| {
                format!(
                    r#"{{"label":{},"id":{},"name":{},"capabilities":[{}],"contentTypes":[{}],"preflightSteps":{}}}"#,
                    quote(&source.label),
                    quote(&source.id),
                    quote(&source.name),
                    source
                        .capabilities
                        .iter()
                        .map(|cap| quote(name_of(*cap)))
                        .collect::<Vec<_>>()
                        .join(","),
                    source
                        .content_types
                        .iter()
                        .map(|kind| quote(kind))
                        .collect::<Vec<_>>()
                        .join(","),
                    source.preflight_steps
                )
            })
            .collect();
        let smoke: Vec<String> = self
            .smoke
            .iter()
            .map(|(what, detail, passed)| {
                format!(
                    r#"{{"check":{},"detail":{},"ok":{}}}"#,
                    quote(what),
                    quote(detail),
                    passed
                )
            })
            .collect();
        format!(
            r#"{{"target":{},"id":{},"name":{},"version":{},"kind":{},"sha256":{},"sources":[{}],"problems":[{}],"notes":[{}],"smoke":[{}],"ok":{}}}"#,
            quote(&self.target),
            quote(&self.package_id),
            quote(&self.name),
            quote(&self.version),
            quote(&self.kind),
            quote(&self.sha256),
            sources.join(","),
            self.problems
                .iter()
                .map(|problem| quote(problem))
                .collect::<Vec<_>>()
                .join(","),
            self.notes
                .iter()
                .map(|note| quote(note))
                .collect::<Vec<_>>()
                .join(","),
            smoke.join(","),
            self.ok()
        )
    }
}

/// 校验一个包（zip 或解包目录）。返回的报告同时覆盖「包坏了」与「包能装但有问题」。
pub fn check(target: &Path) -> Report {
    match load_package(target) {
        Ok(package) => inspect(&package, target),
        Err(detail) => Report::rejected(target, detail),
    }
}

fn inspect(package: &UnpackedPackage, target: &Path) -> Report {
    let manifest = &package.manifest;
    let mut report = Report {
        target: target.display().to_string(),
        package_id: manifest.id.to_string(),
        name: manifest.name.clone(),
        version: manifest.version.to_string(),
        kind: manifest.kind.as_str().to_string(),
        sha256: package.sha256.clone(),
        sources: Vec::new(),
        problems: Vec::new(),
        notes: Vec::new(),
        smoke: Vec::new(),
    };

    if manifest.content_types.is_empty() {
        report
            .notes
            .push("清单没有 content_types：商店里会显示为「未标注」".to_string());
    }

    match manifest.kind {
        PluginKind::Declarative => inspect_rules(package, &mut report),
        PluginKind::Script => inspect_script(package, &mut report),
        PluginKind::Component => report.notes.push(
            "Wasm 组件不在本工具范围内（WIT 已冻结，装配校验由 plugin-wasm 负责）".to_string(),
        ),
    }

    check_content_types(manifest, &mut report);
    report
}

/// 清单里的内容类型是「展示副本」，规则 / 脚本里的才是运行期真相。
/// 两侧不一致必须报错：否则商店分类会长期显示错误信息。
fn check_content_types(manifest: &PluginManifest, report: &mut Report) {
    if manifest.content_types.is_empty() {
        return;
    }
    let declared: Vec<&str> = manifest
        .content_types
        .iter()
        .map(|kind| kind.as_str())
        .collect();
    for source in &report.sources {
        if source.content_types.is_empty() {
            report.problems.push(format!(
                "清单声明了 content_types={declared:?}，但 {} 没有声明",
                source.label
            ));
        } else if declared != source.content_types {
            report.problems.push(format!(
                "清单 content_types={declared:?} 与 {} 的 {:?} 不一致",
                source.label, source.content_types
            ));
        }
    }
}

fn inspect_rules(package: &UnpackedPackage, report: &mut Report) {
    for rule in &package.manifest.rules {
        let Some(bytes) = package.file(&rule.path) else {
            report.problems.push(format!("缺少规则文件 {}", rule.path));
            continue;
        };
        let text = match std::str::from_utf8(bytes) {
            Ok(text) => text,
            Err(err) => {
                report
                    .problems
                    .push(format!("{} 不是 UTF-8：{err}", rule.path));
                continue;
            }
        };
        match RuleSource::from_json(text) {
            Ok(source) => {
                let meta = source.meta();
                report.sources.push(SourceFindings {
                    label: rule.path.clone(),
                    id: meta.id,
                    name: meta.name,
                    capabilities: meta.capabilities,
                    content_types: meta
                        .content_types
                        .iter()
                        .map(|kind| kind.as_str().to_string())
                        .collect(),
                    preflight_steps: source.rule().preflight.len(),
                    plugin: Arc::new(source),
                });
            }
            Err(err) => report
                .problems
                .push(format!("{} 加载失败：{err}", rule.path)),
        }
    }
}

fn inspect_script(package: &UnpackedPackage, report: &mut Report) {
    let Some(entry) = package.manifest.entry.as_deref() else {
        report.problems.push("脚本插件缺少 entry".to_string());
        return;
    };
    let Some(bytes) = package.file(entry) else {
        report.problems.push(format!("缺少脚本入口 {entry}"));
        return;
    };
    let text = match std::str::from_utf8(bytes) {
        Ok(text) => text,
        Err(err) => {
            report.problems.push(format!("{entry} 不是 UTF-8：{err}"));
            return;
        }
    };
    let env = placeholder_env();
    match ScriptSource::load(
        &env,
        text,
        script_limits(&package.manifest),
        package.manifest.permissions.network.clone(),
    ) {
        Ok(source) => {
            let meta = source.meta();
            if meta.capabilities.is_empty() {
                report
                    .problems
                    .push("脚本没有导出任何能力（宿主上会完全不可用）".to_string());
            }
            report.sources.push(SourceFindings {
                label: entry.to_string(),
                id: meta.id,
                name: meta.name,
                capabilities: meta.capabilities,
                content_types: meta
                    .content_types
                    .iter()
                    .map(|kind| kind.as_str().to_string())
                    .collect(),
                preflight_steps: 0,
                plugin: Arc::new(source),
            });
        }
        Err(err) => report.problems.push(format!("{entry} 加载失败：{err}")),
    }
}

// ---------------------------------------------------------------- 冒烟

pub fn smoke(report: &mut Report, keyword: &str) {
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(err) => {
            report.problems.push(format!("无法创建运行时：{err}"));
            return;
        }
    };
    runtime.block_on(async {
        let transport: Arc<dyn Transport> = match HttpTransport::new(DEFAULT_USER_AGENT) {
            Ok(transport) => Arc::new(transport),
            Err(err) => {
                report.problems.push(format!("无法创建 HTTP 客户端：{err}"));
                return;
            }
        };
        let mut results = Vec::new();
        for source in &report.sources {
            let env = SourceEnv {
                source_id: source.id.clone(),
                transport: Arc::clone(&transport),
                store: Arc::new(MemoryStore::default()),
                scripts: Some(QuickJsHost::shared()),
                log: Arc::new(StderrLog),
            };
            results.extend(smoke_one(source, &env, keyword).await);
        }
        report.smoke = results;
    });
}

async fn smoke_one(
    source: &SourceFindings,
    env: &SourceEnv,
    keyword: &str,
) -> Vec<(String, String, bool)> {
    let mut out = Vec::new();
    let plugin = Arc::clone(&source.plugin);

    if source.capabilities.contains(&Capability::Catalog) {
        out.push(
            match tokio::time::timeout(LIVE_TIMEOUT, plugin.catalog(env, 1, "")).await {
                Ok(Ok(page)) => {
                    let sample = page
                        .items
                        .first()
                        .map(|drama| format!("首条「{}」", drama.title))
                        .unwrap_or_else(|| "空列表".to_string());
                    (
                        "目录第 1 页".to_string(),
                        format!("{} 条（{sample}）", page.items.len()),
                        !page.items.is_empty(),
                    )
                }
                Ok(Err(err)) => ("目录第 1 页".to_string(), err.to_string(), false),
                Err(_) => (
                    "目录第 1 页".to_string(),
                    format!("超时（{} 秒）", LIVE_TIMEOUT.as_secs()),
                    false,
                ),
            },
        );
    }

    if source.capabilities.contains(&Capability::Search) {
        out.push(
            match tokio::time::timeout(LIVE_TIMEOUT, plugin.search(env, keyword, 1)).await {
                Ok(Ok(page)) => (
                    format!("搜索「{keyword}」"),
                    format!("{} 条", page.items.len()),
                    // 搜不到不算故障：关键词本身可能确实没有结果。
                    true,
                ),
                Ok(Err(err)) => (format!("搜索「{keyword}」"), err.to_string(), false),
                Err(_) => (
                    format!("搜索「{keyword}」"),
                    format!("超时（{} 秒）", LIVE_TIMEOUT.as_secs()),
                    false,
                ),
            },
        );
    }

    if out.is_empty() {
        out.push((
            "冒烟".to_string(),
            "该源没有目录 / 搜索能力，跳过".to_string(),
            true,
        ));
    }
    out
}

// ---------------------------------------------------------------- 环境

/// 冒烟期间的会话存储：进程内即可，工具跑完即丢。
#[derive(Default)]
struct MemoryStore {
    inner: Mutex<BTreeMap<String, String>>,
}

#[async_trait::async_trait]
impl SourceStore for MemoryStore {
    async fn get(&self, key: &str) -> Result<Option<String>, SourceError> {
        Ok(self
            .inner
            .lock()
            .map(|map| map.get(key).cloned())
            .unwrap_or_default())
    }

    async fn set(&self, key: &str, value: &str) -> Result<(), SourceError> {
        if let Ok(mut map) = self.inner.lock() {
            map.insert(key.to_string(), value.to_string());
        }
        Ok(())
    }
}

struct StderrLog;

impl LogSink for StderrLog {
    fn debug(&self, message: &str) {
        eprintln!("  · {message}");
    }

    fn warn(&self, message: &str) {
        eprintln!("  ! {message}");
    }
}

fn name_of(capability: Capability) -> &'static str {
    match capability {
        Capability::Catalog => "catalog",
        Capability::Detail => "detail",
        Capability::Search => "search",
        Capability::Resolve => "resolve",
        Capability::Categories => "categories",
        Capability::Rankings => "rankings",
        Capability::Recommend => "recommend",
        Capability::Suggestions => "suggestions",
        Capability::Danmaku => "danmaku",
        Capability::Series => "series",
    }
}
