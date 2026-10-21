//! 把 `engine/rules/*.json` 打成官方规则包，并生成 `index.json`。
//!
//! 用法：
//! ```bash
//! cargo run -p guo-plugin-host --bin pack_rules -- engine/dist/rules
//! ```
//!
//! 产物：
//! ```text
//! dist/rules/
//!   repo.toml
//!   index.json
//!   plugins/guo.fanguo/guo.fanguo-1.0.0.zip
//! ```
//!
//! 刻意做成可重复执行的构建步骤而不是手写 zip：
//! 规则一改就重新生成，`index.json` 里的哈希由同一段代码计算，
//! 不会出现「哈希忘了更新」这种只有用户装不上时才会发现的问题。

use std::fs;
use std::io::{Cursor, Write};
use std::path::{Path, PathBuf};

use guo_plugin_host::sha256_hex;
use zip::write::SimpleFileOptions;

/// 规则包版本。规则内容变化时手动递增。
const RULE_VERSION: &str = "1.0.0";
/// 宿主版本要求，与 `plugin-host` 的 `HOST_VERSION` 保持一致。
const MIN_HOST: &str = "0.3.0";
/// 插件 id 前缀。D6 未定，这里用占位前缀。
const ID_PREFIX: &str = "guo.";

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let output = std::env::args()
        .nth(1)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("dist/rules"));

    // 默认从 workspace 根的 `rules/` 读：脚本在 `engine/` 下执行时可直接命中。
    let rules_dir = std::env::args()
        .nth(2)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("rules"));

    let mut entries = Vec::new();
    let mut files: Vec<(String, String)> = Vec::new();
    for path in collect_rules(&rules_dir)? {
        files.push((path.clone(), path));
    }
    files.sort();

    for (source, name) in &files {
        let text = fs::read_to_string(source)?;
        let meta = RuleMeta::parse(&text, name)?;
        let plugin_id = format!("{ID_PREFIX}{}", meta.id);
        let manifest = format!(
            "spec = 1\nid = \"{plugin_id}\"\nname = \"{}\"\nversion = \"{RULE_VERSION}\"\nkind = \"declarative\"\napi = {{ level = 1, min_host = \"{MIN_HOST}\" }}\ndescription = \"{}\"\nauthors = [\"official\"]\n\n[permissions]\nnetwork = [\"{}\"]\n\n[[rules]]\npath = \"rules/{}.json\"\nsite = \"{}\"\n",
            meta.name, meta.name, meta.host, meta.id, meta.id
        );

        let rule_path = format!("rules/{}.json", meta.id);
        let archive = zip_package(&manifest, &rule_path, text.as_bytes())?;
        let sha = sha256_hex(&archive);
        let relative = format!("plugins/{plugin_id}/{plugin_id}-{RULE_VERSION}.zip");
        let target = output.join(&relative);
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(&target, &archive)?;

        entries.push(format!(
            "    {{\n      \"id\": \"{plugin_id}\",\n      \"name\": \"{}\",\n      \"version\": \"{RULE_VERSION}\",\n      \"kind\": \"declarative\",\n      \"api\": 1,\n      \"minHost\": \"{MIN_HOST}\",\n      \"author\": \"official\",\n      \"size\": {},\n      \"sha256\": \"{sha}\",\n      \"path\": \"{relative}\"\n    }}",
            meta.name,
            archive.len()
        ));
        println!("打包 {plugin_id} ({} 字节)", archive.len());
    }

    fs::create_dir_all(&output)?;
    let index = format!("[\n{}\n]\n", entries.join(",\n"));
    fs::write(output.join("index.json"), index)?;

    let repo = "spec = 1\nid = \"official\"\nname = \"真果鉴官方规则仓库\"\ndescription = \"官方维护的短剧站源规则\"\nindex = \"index.json\"\n";
    fs::write(output.join("repo.toml"), repo)?;

    println!("\n产物：{}", output.display());
    println!("共 {} 个规则包", entries.len());
    Ok(())
}

fn collect_rules(directory: &Path) -> Result<Vec<String>, Box<dyn std::error::Error>> {
    let mut out = Vec::new();
    for entry in fs::read_dir(directory)? {
        let path = entry?.path();
        if path.extension().and_then(|ext| ext.to_str()) == Some("json") {
            out.push(path.display().to_string());
        }
    }
    if out.is_empty() {
        return Err(format!("{} 下没有规则文件", directory.display()).into());
    }
    Ok(out)
}

/// 只取打包需要的字段，避免把整个规则结构复制进构建脚本。
struct RuleMeta {
    id: String,
    name: String,
    host: String,
}

impl RuleMeta {
    fn parse(text: &str, path: &str) -> Result<Self, Box<dyn std::error::Error>> {
        let value: serde_json::Value =
            serde_json::from_str(text).map_err(|err| format!("{path} 不是合法 JSON：{err}"))?;
        let field = |name: &str| -> Result<String, Box<dyn std::error::Error>> {
            value
                .get(name)
                .and_then(|item| item.as_str())
                .map(str::to_string)
                .ok_or_else(|| format!("{path} 缺少 {name}").into())
        };
        let host = value
            .get("base")
            .and_then(|item| item.as_str())
            .and_then(|base| base.split("://").nth(1))
            .and_then(|rest| rest.split('/').next())
            .ok_or_else(|| format!("{path} 的 base 不是合法 URL"))?
            .to_string();
        Ok(Self {
            id: field("id")?,
            name: field("name")?,
            host,
        })
    }
}

fn zip_package(
    manifest: &str,
    rule_path: &str,
    rule: &[u8],
) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    let mut buffer = Cursor::new(Vec::new());
    {
        let mut writer = zip::ZipWriter::new(&mut buffer);
        let options =
            SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
        writer.start_file("plugin.toml", options)?;
        writer.write_all(manifest.as_bytes())?;
        writer.start_file(rule_path, options)?;
        writer.write_all(rule)?;
        writer.finish()?;
    }
    Ok(buffer.into_inner())
}
