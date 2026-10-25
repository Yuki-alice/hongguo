//! 离线扩展校验 / 冒烟工具（A5）。
//!
//! ```bash
//! # 静态校验：只读包，不联网（提交前 / CI 跑这个）
//! cargo run -p guo-runtime --bin check_plugin -- rust/examples/extensions/maoguo
//! cargo run -p guo-runtime --bin check_plugin -- dist/rules/plugins/guo.fanguo/guo.fanguo-1.0.0.zip
//!
//! # 冒烟：真实发一次目录 / 搜索请求
//! cargo run -p guo-runtime --bin check_plugin -- <包路径> --live
//!
//! # 机器可读输出（CI 用）
//! cargo run -p guo-runtime --bin check_plugin -- <包路径> --json
//! ```
//!
//! 实现都在 [`guo_runtime::check`]：CLI 只做参数解析与输出，
//! 这样校验逻辑可以被普通测试覆盖。
//!
//! 退出码：`0` 通过；`1` 有阻塞性问题；`2` 用法错误。

use std::path::PathBuf;

use guo_runtime::check;

const USAGE: &str = "\
check_plugin — 离线校验站源扩展包

用法：
  check_plugin <包路径>           静态校验（zip 或解包目录，不联网）
  check_plugin <包路径> --live    额外发一次目录 / 搜索请求做冒烟
  check_plugin <包路径> --json    输出 JSON（CI）

选项：
  -k, --keyword <词>   冒烟搜索用的关键词（默认「测试」）
  -h, --help           显示帮助

退出码：0 通过 / 1 有问题 / 2 用法错误";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.iter().any(|arg| arg == "-h" || arg == "--help") {
        println!("{USAGE}");
        return;
    }
    if args.is_empty() {
        fail_usage("缺少包路径");
    }

    let mut target: Option<PathBuf> = None;
    let mut live = false;
    let mut json = false;
    let mut keyword = "测试".to_string();
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--live" => live = true,
            "--json" => json = true,
            "--keyword" | "-k" => {
                index += 1;
                match args.get(index) {
                    Some(value) => keyword = value.clone(),
                    None => fail_usage("--keyword 需要一个值"),
                }
            }
            other if other.starts_with('-') => fail_usage(&format!("未知参数 {other}")),
            other => {
                if target.is_some() {
                    fail_usage("只接受一个包路径");
                }
                target = Some(PathBuf::from(other));
            }
        }
        index += 1;
    }
    let Some(target) = target else {
        fail_usage("缺少包路径");
    };

    let mut report = check::check(&target);
    if live && report.ok() {
        if !json {
            println!("\n—— 冒烟（真实请求）——");
        }
        check::smoke(&mut report, &keyword);
    }

    if json {
        println!("{}", report.to_json());
    } else {
        report.print();
    }
    std::process::exit(if report.ok() { 0 } else { 1 });
}

fn fail_usage(message: &str) -> ! {
    eprintln!("{message}\n\n{USAGE}");
    std::process::exit(2);
}
