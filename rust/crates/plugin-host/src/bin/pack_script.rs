//! 把脚本扩展目录（`plugin.toml` + `main.js`）打包为随包 / 仓库用的 zip。
//!
//! 用法：
//! ```bash
//! cargo run -q -p guo-plugin-host --bin pack_script -- \
//!     examples/extensions/maoguo ../assets/bundled_plugins
//! ```
//!
//! 产物：`<output>/<id>-<version>.zip`（平铺，匹配 Flutter assets 布局），
//! 并在 stdout 打印该包的 `index.json` 条目 JSON，供粘进随包索引。
//!
//! 与 `pack_rules` 同一个理由做成构建步骤：哈希与大小由同一段代码算出，
//! 不出现「手算 sha256 写错 → 安装被拒但看不出为什么」。

use std::fs;
use std::io::{Cursor, Write};
use std::path::PathBuf;

use guo_plugin_host::{sha256_hex, PluginManifest};
use zip::write::SimpleFileOptions;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1);
    let dir = args
        .next()
        .map(PathBuf::from)
        .ok_or("用法：pack_script <扩展目录> <输出目录>")?;
    let output = args.next().map(PathBuf::from).ok_or("缺少输出目录参数")?;

    let manifest_text = fs::read_to_string(dir.join("plugin.toml"))
        .map_err(|err| format!("读取 {}：{err}", dir.join("plugin.toml").display()))?;
    let manifest = PluginManifest::parse(&manifest_text)?;

    let entry = manifest
        .entry
        .as_deref()
        .ok_or("清单缺少 entry（脚本包必填）")?;
    let script = fs::read(dir.join(entry)).map_err(|err| format!("读取脚本 {entry}：{err}"))?;

    let archive = zip_package(&manifest_text, entry, &script)?;
    let file_name = format!("{}-{}.zip", manifest.id, manifest.version);
    fs::create_dir_all(&output)?;
    fs::write(output.join(&file_name), &archive)?;

    let sha = sha256_hex(&archive);
    let content_types: Vec<String> = manifest
        .content_types
        .iter()
        .map(|kind| kind.as_str().to_string())
        .collect();
    let author = if manifest.authors.is_empty() {
        "official".to_string()
    } else {
        manifest.authors.join(", ")
    };
    println!(
        "{{\n  \"id\": \"{}\",\n  \"name\": \"{}\",\n  \"version\": \"{}\",\n  \"kind\": \"{}\",\n  \"api\": {},\n  \"minHost\": \"{}\",\n  \"author\": \"{}\",\n  \"contentTypes\": [{}],\n  \"size\": {},\n  \"sha256\": \"{}\",\n  \"path\": \"{}\"\n}}",
        manifest.id,
        manifest.name,
        manifest.version,
        manifest.kind.as_str(),
        manifest.api.level,
        manifest.api.min_host,
        author,
        content_types
            .iter()
            .map(|item| format!("\"{item}\""))
            .collect::<Vec<_>>()
            .join(", "),
        archive.len(),
        sha,
        file_name,
    );
    println!(
        "\n产物：{}（{} 字节）",
        output.join(&file_name).display(),
        archive.len()
    );
    Ok(())
}

fn zip_package(
    manifest: &str,
    entry: &str,
    script: &[u8],
) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    let mut buffer = Cursor::new(Vec::new());
    {
        let mut writer = zip::ZipWriter::new(&mut buffer);
        let options =
            SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
        writer.start_file("plugin.toml", options)?;
        writer.write_all(manifest.as_bytes())?;
        writer.start_file(entry, options)?;
        writer.write_all(script)?;
        writer.finish()?;
    }
    Ok(buffer.into_inner())
}
