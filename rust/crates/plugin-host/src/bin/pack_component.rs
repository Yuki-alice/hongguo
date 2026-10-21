//! 把已编译的组件插件打成官方插件包，并生成索引。
//!
//! 用法：
//! ```bash
//! cargo run -p guo-plugin-host --bin pack_component -- \
//!   dist/components examples/plugins/maoguo/guo_plugin_maoguo.component.wasm
//! ```
//!
//! 产物结构与 `pack_rules` 一致（`index.json` + `plugins/<id>/<id>-<ver>.zip`），
//! 因此随包预装与从网络仓库安装走同一套校验与安装代码。
//!
//! 清单里的 `permissions.network` 是**必需的**：宿主只允许插件访问声明过的主机，
//! 漏写会让插件在运行时才失败。因此这里要求调用方显式给出，不提供默认值。

use std::fs;
use std::io::{Cursor, Write};
use std::path::{Path, PathBuf};

use guo_plugin_host::sha256_hex;
use zip::write::SimpleFileOptions;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1);
    let output = args.next().map(PathBuf::from).ok_or(
        "用法：pack_component <输出目录> <组件 wasm>... [--network host,host] [--version x.y.z]",
    )?;

    let mut wasm_paths = Vec::new();
    let mut version = "1.0.0".to_string();
    let mut network: Vec<String> = Vec::new();
    let mut extra: Vec<String> = args.collect();
    let mut index = 0;
    while index < extra.len() {
        match extra[index].as_str() {
            "--version" if index + 1 < extra.len() => {
                version = extra.remove(index + 1);
                extra.remove(index);
            }
            "--network" if index + 1 < extra.len() => {
                network = extra
                    .remove(index + 1)
                    .split(',')
                    .map(str::trim)
                    .filter(|host| !host.is_empty())
                    .map(str::to_string)
                    .collect();
                extra.remove(index);
            }
            _ => {
                wasm_paths.push(PathBuf::from(&extra[index]));
                index += 1;
            }
        }
    }
    if wasm_paths.is_empty() {
        return Err("缺少组件 wasm 路径".into());
    }
    if network.is_empty() {
        return Err("必须用 --network 声明插件可访问的主机（宿主会强制白名单）".into());
    }

    fs::create_dir_all(&output)?;
    let mut entries = Vec::new();
    let mut files = Vec::new();

    for wasm in &wasm_paths {
        let bytes = fs::read(wasm)?;
        let (plugin_id, name, host_from_descriptor) = inspect(wasm, &bytes)?;
        // 描述符里的主机不可靠（插件可以少声明），以调用方给的为准；
        // 但两者完全对不上时给出提示，避免打了一个永远联不上网的包。
        if let Some(host) = &host_from_descriptor {
            if !network.iter().any(|allowed| allowed == host) {
                eprintln!("提示：{plugin_id} 描述符提到 {host}，但 --network 未包含它");
            }
        }

        let manifest = format!(
            "spec = 1\nid = \"{plugin_id}\"\nname = \"{name}\"\nversion = \"{version}\"\nkind = \"component\"\nentry = \"plugin.wasm\"\napi = {{ level = 1, min_host = \"0.3.0\" }}\ndescription = \"官方代码插件\"\nauthors = [\"official\"]\n\n[permissions]\nnetwork = [{}]\n",
            network
                .iter()
                .map(|host| format!("\"{host}\""))
                .collect::<Vec<_>>()
                .join(", ")
        );

        let archive = zip_component(&manifest, &bytes)?;
        let sha = sha256_hex(&archive);
        let relative = format!("plugins/{plugin_id}/{plugin_id}-{version}.zip");
        let target = output.join(&relative);
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(&target, &archive)?;

        entries.push(format!(
            "    {{\n      \"id\": \"{plugin_id}\",\n      \"name\": \"{name}\",\n      \"version\": \"{version}\",\n      \"kind\": \"component\",\n      \"api\": 1,\n      \"minHost\": \"0.3.0\",\n      \"author\": \"official\",\n      \"size\": {},\n      \"sha256\": \"{sha}\",\n      \"path\": \"{relative}\"\n    }}",
            archive.len()
        ));
        files.push(format!("{plugin_id} ({} 字节)", archive.len()));
        println!("打包 {plugin_id} ({version}) {} 字节", archive.len());
    }

    fs::write(
        output.join("index.json"),
        format!("[\n{}\n]\n", entries.join(",\n")),
    )?;
    println!("\n产物：{}", output.display());
    println!("共 {} 个组件包", files.len());
    Ok(())
}

/// 校验产物并取插件 id。
///
/// 这里只做**结构级**检查，不实例化组件：`plugin-host` 刻意不依赖 wasmtime
/// （它要能在轻量工具里用），真正的导出校验由宿主加载时完成。
/// id 取自文件命名约定，猜一个只会产生「装上了但源名不对」这种更难排查的问题。
fn inspect(
    path: &Path,
    bytes: &[u8],
) -> Result<(String, String, Option<String>), Box<dyn std::error::Error>> {
    // 组件化产物以 `\0asm` 开头，版本字段第 4 字节为 1。
    if bytes.len() < 8 || &bytes[0..4] != b"\0asm" {
        return Err(format!("{} 不是 WebAssembly 二进制", path.display()).into());
    }
    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or("组件路径没有文件名")?;
    let plugin_id = file_name
        .strip_prefix("guo_plugin_")
        .and_then(|rest| rest.split('.').next())
        .map(|id| id.replace('_', "-"))
        .ok_or_else(|| {
            format!(
                "{} 不符合 guo_plugin_<id>.component.wasm 命名，无法确定插件 id",
                file_name
            )
        })?;
    let name = plugin_id.clone();
    Ok((format!("guo.{plugin_id}"), name, None))
}

fn zip_component(manifest: &str, wasm: &[u8]) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    let mut buffer = Cursor::new(Vec::new());
    {
        let mut writer = zip::ZipWriter::new(&mut buffer);
        let options =
            SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
        for (name, body) in [
            ("plugin.toml", manifest.as_bytes().to_vec()),
            ("plugin.wasm", wasm.to_vec()),
        ] {
            writer.start_file(name, options)?;
            writer.write_all(&body)?;
        }
        writer.finish()?;
    }
    Ok(buffer.into_inner())
}
