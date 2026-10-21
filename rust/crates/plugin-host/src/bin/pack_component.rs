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
        "用法：pack_component <输出目录> --plugin <wasm> --network <host,host> [--plugin ... --network ...] [--version x.y.z]",
    )?;

    let mut version = "1.0.0".to_string();
    let mut extra: Vec<String> = args.collect();
    let mut specs: Vec<(PathBuf, Vec<String>)> = Vec::new();
    // 每个分支都从队首消费「选项 + 值」，因此用空检查而不是下标。
    while !extra.is_empty() {
        match extra[0].as_str() {
            "--version" if extra.len() > 1 => {
                version = extra.remove(1);
                extra.remove(0);
            }
            "--plugin" if extra.len() > 1 => {
                let path = PathBuf::from(extra.remove(1));
                extra.remove(0);
                specs.push((path, Vec::new()));
            }
            "--network" if extra.len() > 1 => {
                let hosts: Vec<String> = extra
                    .remove(1)
                    .split(',')
                    .map(str::trim)
                    .filter(|host| !host.is_empty())
                    .map(str::to_string)
                    .collect();
                extra.remove(0);
                // 网络权限**逐个插件**声明：共用一个白名单会让每个插件
                // 都拿到全部主机，违反最小权限。
                let Some(spec) = specs.last_mut() else {
                    return Err("--network 必须跟在 --plugin 之后".into());
                };
                if spec.1.is_empty() {
                    spec.1 = hosts;
                } else {
                    spec.1.extend(hosts);
                }
            }
            other => return Err(format!("无法识别的参数：{other}").into()),
        }
    }
    if specs.is_empty() {
        return Err("至少需要一个 --plugin <wasm>".into());
    }
    for (path, network) in &specs {
        if network.is_empty() {
            return Err(format!(
                "{} 缺少 --network：宿主会拒绝未声明主机的请求",
                path.display()
            )
            .into());
        }
    }

    fs::create_dir_all(&output)?;
    let mut entries = Vec::new();
    let mut files = Vec::new();

    for (wasm, network) in &specs {
        let bytes = fs::read(wasm)?;
        let (plugin_id, name, _) = inspect(wasm, &bytes)?;

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
