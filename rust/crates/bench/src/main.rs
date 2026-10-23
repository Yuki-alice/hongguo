//! 引擎热路径基准。
//!
//! 为什么不用 criterion：它引入一组开发依赖，而这里只需要「同一份夹具反复
//! 解析，报出 P50 / P95」。用标准库计时 + 预热就够，且结果可直接入库做回归
//! 对比。需要更细的分析时再换 criterion 也不迟。
//!
//! 用法：
//! ```bash
//! cargo run --release -p guo-bench
//! cargo run --release -p guo-bench -- --iterations 500 --json
//! ```
//!
//! 夹具取自 `rust/bridge/tests/fixtures/`——与线上回归用的是同一批真实响应，
//! 因此数字有参考价值；但它不覆盖网络耗时（那部分属于在线用例）。

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use guo_engine_core::{Engine, EngineConfig};
use guo_rule_engine::{RuleDocument, RuleExecutor};
use guo_source_api::Drama;

/// 一次基准的统计结果。
struct Sample {
    name: String,
    iterations: usize,
    p50: Duration,
    p95: Duration,
    min: Duration,
    max: Duration,
}

impl Sample {
    fn from_durations(name: &str, mut durations: Vec<Duration>) -> Self {
        durations.sort_unstable();
        let pick = |percentile: f64| -> Duration {
            if durations.is_empty() {
                return Duration::ZERO;
            }
            let index = ((durations.len() as f64 - 1.0) * percentile).round() as usize;
            durations[index.min(durations.len() - 1)]
        };
        Self {
            name: name.to_string(),
            iterations: durations.len(),
            p50: pick(0.50),
            p95: pick(0.95),
            min: durations.first().copied().unwrap_or_default(),
            max: durations.last().copied().unwrap_or_default(),
        }
    }
}

fn micros(value: Duration) -> f64 {
    value.as_secs_f64() * 1_000_000.0
}

/// 仓库根：从 crate 目录向上三级。
fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("定位仓库根失败")
}

fn read(path: &Path) -> String {
    std::fs::read_to_string(path)
        .unwrap_or_else(|err| panic!("读取 {} 失败：{err}", path.display()))
}

fn rule(root: &Path, name: &str) -> RuleDocument {
    let path = root.join("rules").join(format!("{name}.json"));
    let text = read(&path);
    RuleDocument::from_json(&text).unwrap_or_else(|err| panic!("解析规则 {name} 失败：{err}"))
}

fn fixture(root: &Path, name: &str) -> String {
    read(&root.join("bridge/tests/fixtures").join(name))
}

/// 计时一个闭包，重复 `iterations` 次（含预热）。
fn measure(name: &str, iterations: usize, mut body: impl FnMut()) -> Sample {
    // 预热：让分配器与 CPU 缓存进入稳态，否则首轮数字偏高。
    for _ in 0..iterations.min(20) {
        body();
    }
    let mut durations = Vec::with_capacity(iterations);
    for _ in 0..iterations {
        let started = Instant::now();
        body();
        durations.push(started.elapsed());
    }
    Sample::from_durations(name, durations)
}

fn main() {
    let mut iterations = 200usize;
    let mut as_json = false;
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--iterations" => {
                index += 1;
                iterations = args
                    .get(index)
                    .and_then(|value| value.parse().ok())
                    .unwrap_or_else(|| {
                        eprintln!("--iterations 需要一个正整数");
                        std::process::exit(2);
                    });
            }
            "--json" => as_json = true,
            other => {
                eprintln!("未知参数：{other}");
                std::process::exit(2);
            }
        }
        index += 1;
    }

    let root = repo_root();
    let mut samples = Vec::new();

    // ── 规则加载 ─────────────────────────────────────────────
    // 每次冷启动都会解析全部随包规则；这条路径直接决定首屏可用时间。
    {
        let texts: Vec<(String, String)> = ["wuguo", "huaguo", "faguo", "dsd"]
            .iter()
            .map(|name| {
                (
                    (*name).to_string(),
                    read(&root.join("rules").join(format!("{name}.json"))),
                )
            })
            .collect();
        samples.push(measure("rule_load(4 rules)", iterations, || {
            for (name, text) in &texts {
                RuleDocument::from_json(text)
                    .unwrap_or_else(|err| panic!("规则 {name} 解析失败：{err}"));
            }
        }));
    }

    // ── HTML 目录解析 ────────────────────────────────────────
    for (rule_name, fixture_name) in [
        ("wuguo", "wuguo_catalog.html"),
        ("huaguo", "huaguo_catalog.html"),
        ("wangguo", "wangguo_catalog.html"),
        ("faguo", "faguo_catalog.html"),
        ("dsd", "dsd_catalog.html"),
    ] {
        let document = rule(&root, rule_name);
        let executor = RuleExecutor::new(&document);
        let body = fixture(&root, fixture_name);
        samples.push(measure(
            &format!("catalog_html/{rule_name}"),
            iterations,
            || {
                let page = executor
                    .parse_catalog(&body, 1)
                    .unwrap_or_else(|err| panic!("{rule_name} 目录解析失败：{err}"));
                // 防止优化器把整段计算消掉。
                std::hint::black_box(page.items.len());
            },
        ));
    }

    // ── 详情分集解析 ─────────────────────────────────────────
    for (rule_name, fixture_name) in [
        ("wuguo", "wuguo_detail.html"),
        ("wangguo", "wangguo_detail.html"),
        ("faguo", "faguo_detail.html"),
    ] {
        let document = rule(&root, rule_name);
        let executor = RuleExecutor::new(&document);
        let body = fixture(&root, fixture_name);
        let drama = Drama::default();
        samples.push(measure(
            &format!("detail_html/{rule_name}"),
            iterations,
            || {
                let chapters = executor
                    .parse_chapters(&body, &drama)
                    .unwrap_or_else(|err| panic!("{rule_name} 分集解析失败：{err}"));
                std::hint::black_box(chapters.len());
            },
        ));
    }

    // ── 内嵌 JSON（`__NEXT_DATA__` 类）───────────────────────
    {
        let document = rule(&root, "heguo");
        let executor = RuleExecutor::new(&document);
        let body = fixture(&root, "wuguo_home.html");
        samples.push(measure("embedded_json/heguo", iterations, || {
            let page = executor.parse_catalog(&body, 1);
            std::hint::black_box(page.map(|page| page.items.len()).unwrap_or(0));
        }));
    }

    // ── 引擎装配 ─────────────────────────────────────────────
    // 冷启动时最贵的一段：打开数据目录、恢复会话与缓存索引、建 HTTP 客户端。
    // 这里用 `Engine::open` 而不是单例初始化——单例只能成功一次，无法重复计时。
    {
        let base = std::env::temp_dir().join(format!("guo-bench-engine-{}", std::process::id()));
        let mut round = 0usize;
        samples.push(measure("engine_open", iterations.min(50), || {
            round += 1;
            let directory = base.join(format!("round-{round}"));
            let engine = Engine::open(EngineConfig::new(&directory))
                .unwrap_or_else(|err| panic!("引擎装配失败：{err}"));
            std::hint::black_box(engine.config().data_directory.as_os_str());
        }));
        let _ = std::fs::remove_dir_all(&base);
    }

    // ── 输出 ─────────────────────────────────────────────────
    if as_json {
        print_json(&samples);
    } else {
        print_table(&samples);
    }
}

fn print_table(samples: &[Sample]) {
    println!(
        "{:<28} {:>8} {:>10} {:>10} {:>10} {:>10}",
        "case", "iters", "p50(us)", "p95(us)", "min(us)", "max(us)"
    );
    println!("{}", "-".repeat(82));
    for sample in samples {
        println!(
            "{:<28} {:>8} {:>10.2} {:>10.2} {:>10.2} {:>10.2}",
            sample.name,
            sample.iterations,
            micros(sample.p50),
            micros(sample.p95),
            micros(sample.min),
            micros(sample.max),
        );
    }
}

fn print_json(samples: &[Sample]) {
    let rows: Vec<String> = samples
        .iter()
        .map(|sample| {
            format!(
                "    {{\"case\": \"{}\", \"iterations\": {}, \"p50_us\": {:.2}, \
                 \"p95_us\": {:.2}, \"min_us\": {:.2}, \"max_us\": {:.2}}}",
                sample.name,
                sample.iterations,
                micros(sample.p50),
                micros(sample.p95),
                micros(sample.min),
                micros(sample.max),
            )
        })
        .collect();
    println!("[\n{}\n]", rows.join(",\n"));
}
