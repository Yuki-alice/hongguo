//! `check_plugin` 的校验行为（A5）。
//!
//! 覆盖四类失败：规则写错、内容类型两侧不一致、脚本加载失败、包结构损坏。
//! 这些正是「自己把扩展做满」阶段最容易反复犯的错，交给测试而不是靠肉眼。

use std::fs;
use std::io::{Cursor, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use guo_runtime::check;
use zip::write::SimpleFileOptions;

static NEXT: AtomicU64 = AtomicU64::new(0);

fn temporary_dir(name: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!(
        "guo-check-{name}-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    let _ = fs::remove_dir_all(&path);
    fs::create_dir_all(&path).expect("create dir");
    path
}

fn write(directory: &Path, relative: &str, text: &str) {
    let path = directory.join(relative);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("parent");
    }
    fs::write(path, text).expect("write");
}

fn manifest(kind: &str, extra: &str) -> String {
    format!(
        "spec = 1\nid = \"guo.test\"\nname = \"测试源\"\nversion = \"1.0.0\"\nkind = \"{kind}\"\napi = {{ level = 1, min_host = \"0.3.0\" }}\n{extra}"
    )
}

const RULE: &str = r#"{
  "schema": "1.0",
  "id": "test",
  "name": "测试源",
  "group": "duanju",
  "base": "https://example.test",
  "kind": "html",
  "contentTypes": ["short-drama"],
  "preflight": [
    { "name": "站点", "url": "{base}/api/site", "extract": { "vars": { "site": "$.data.site" } } }
  ],
  "catalog": {
    "url": "{var:site}/list?page={page}",
    "item": "a.card",
    "fields": { "id": "a@href", "title": ".title" }
  },
  "detail": {
    "url": "{var:site}/detail/{id}",
    "episodes": "a.ep",
    "title": "h1"
  }
}"#;

const SCRIPT: &str = r#"
function describe() {
    return { id: 'test', name: '测试源', group: 'duanju', apiLevel: 1, contentTypes: ['short-drama'] };
}
function catalog(input) {
    return { items: [{ sourceId: '1', title: '示例', cover: '', chapterCount: 1 }], hasMore: false, page: 1 };
}
"#;

#[test]
fn accepts_a_well_formed_rule_package() {
    let dir = temporary_dir("ok");
    write(
        &dir,
        "plugin.toml",
        &manifest(
            "declarative",
            "content_types = [\"short-drama\"]\n\n[[rules]]\npath = \"rules/test.json\"\nsite = \"test\"\n",
        ),
    );
    write(&dir, "rules/test.json", RULE);

    let report = check::check(&dir);
    assert!(report.ok(), "{:?}", report.problems);
    assert_eq!(report.sources.len(), 1);
    let source = &report.sources[0];
    assert_eq!(source.id, "test");
    assert_eq!(source.content_types, vec!["short-drama"]);
    // preflight 被完整解析（不是静默丢弃）。
    assert_eq!(source.preflight_steps, 1);
}

#[test]
fn rejects_a_rule_with_unknown_content_type() {
    let dir = temporary_dir("bad-type");
    write(
        &dir,
        "plugin.toml",
        &manifest(
            "declarative",
            "\n[[rules]]\npath = \"rules/test.json\"\nsite = \"test\"\n",
        ),
    );
    write(
        &dir,
        "rules/test.json",
        &RULE.replace(r#"["short-drama"]"#, r#"["短剧"]"#),
    );

    let report = check::check(&dir);
    assert!(!report.ok());
    assert!(
        report
            .problems
            .iter()
            .any(|problem| problem.contains("未知内容类型")),
        "{:?}",
        report.problems
    );
}

#[test]
fn flags_content_type_mismatch_between_manifest_and_rules() {
    let dir = temporary_dir("mismatch");
    write(
        &dir,
        "plugin.toml",
        &manifest(
            "declarative",
            "content_types = [\"movie\"]\n\n[[rules]]\npath = \"rules/test.json\"\nsite = \"test\"\n",
        ),
    );
    write(&dir, "rules/test.json", RULE);

    let report = check::check(&dir);
    assert!(!report.ok());
    assert!(
        report
            .problems
            .iter()
            .any(|problem| problem.contains("不一致")),
        "{:?}",
        report.problems
    );
}

#[test]
fn flags_a_manifest_that_forgets_content_types() {
    let dir = temporary_dir("missing-types");
    write(
        &dir,
        "plugin.toml",
        &manifest(
            "declarative",
            "content_types = [\"short-drama\"]\n\n[[rules]]\npath = \"rules/test.json\"\nsite = \"test\"\n",
        ),
    );
    write(
        &dir,
        "rules/test.json",
        &RULE.replace(r#""contentTypes": ["short-drama"],"#, ""),
    );

    let report = check::check(&dir);
    assert!(!report.ok());
    assert!(
        report
            .problems
            .iter()
            .any(|problem| problem.contains("没有声明")),
        "{:?}",
        report.problems
    );
}

#[test]
fn accepts_a_script_package_from_a_directory() {
    let dir = temporary_dir("script");
    write(
        &dir,
        "plugin.toml",
        &manifest(
            "script",
            "entry = \"main.js\"\ncontent_types = [\"short-drama\"]\n\n[permissions]\nnetwork = [\"example.test\"]\n",
        ),
    );
    write(&dir, "main.js", SCRIPT);

    let report = check::check(&dir);
    assert!(report.ok(), "{:?}", report.problems);
    let source = &report.sources[0];
    assert_eq!(source.label, "main.js");
    assert_eq!(source.content_types, vec!["short-drama"]);
}

#[test]
fn rejects_a_script_without_a_descriptor_id() {
    let dir = temporary_dir("script-bad");
    write(
        &dir,
        "plugin.toml",
        &manifest("script", "entry = \"main.js\"\n"),
    );
    write(&dir, "main.js", "function describe() { return {}; }");

    let report = check::check(&dir);
    assert!(!report.ok());
    assert!(
        report
            .problems
            .iter()
            .any(|problem| problem.contains("main.js 加载失败")),
        "{:?}",
        report.problems
    );
}

#[test]
fn reads_a_zip_package_and_reports_its_hash() {
    let dir = temporary_dir("zip");
    let archive = {
        let mut buffer = Cursor::new(Vec::new());
        {
            let mut writer = zip::ZipWriter::new(&mut buffer);
            let options =
                SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
            writer.start_file("plugin.toml", options).expect("start");
            writer
                .write_all(
                    manifest(
                        "declarative",
                        "content_types = [\"short-drama\"]\n\n[[rules]]\npath = \"rules/test.json\"\nsite = \"test\"\n",
                    )
                    .as_bytes(),
                )
                .expect("write");
            writer
                .start_file("rules/test.json", options)
                .expect("start");
            writer.write_all(RULE.as_bytes()).expect("write");
            writer.finish().expect("finish");
        }
        buffer.into_inner()
    };
    let path = dir.join("guo.test-1.0.0.zip");
    fs::write(&path, &archive).expect("write zip");

    let report = check::check(&path);
    assert!(report.ok(), "{:?}", report.problems);
    assert_eq!(report.sha256.len(), 64);
    assert_eq!(report.package_id, "guo.test");
}

#[test]
fn json_output_is_parseable() {
    let dir = temporary_dir("json");
    write(
        &dir,
        "plugin.toml",
        &manifest(
            "declarative",
            "\n[[rules]]\npath = \"rules/test.json\"\nsite = \"test\"\n",
        ),
    );
    write(&dir, "rules/test.json", RULE);

    let report = check::check(&dir);
    let value: serde_json::Value = serde_json::from_str(&report.to_json()).expect("合法 JSON");
    assert_eq!(value["ok"], serde_json::json!(true));
    assert_eq!(value["sources"][0]["contentTypes"][0], "short-drama");
    assert_eq!(value["sources"][0]["preflightSteps"], 1);
}
