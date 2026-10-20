//! 依赖方向守卫：source-api 不得依赖网络、运行时或 wasm（ARCHITECTURE.md §6.3）。
//!
//! 断言只看 `[dependencies]` 段的**有效行**（跳过注释、空行与包元数据），
//! 否则一句「不要引入 tokio」的注释就会让测试自己失败。

/// 清单里 `[dependencies]` 段的依赖名。
fn dependency_names() -> Vec<String> {
    let manifest = include_str!("../Cargo.toml");
    let mut in_dependencies = false;
    let mut names = Vec::new();
    for line in manifest.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if line.starts_with('[') {
            in_dependencies = line == "[dependencies]";
            continue;
        }
        if !in_dependencies {
            continue;
        }
        if let Some((name, _)) = line.split_once('=') {
            // `serde.workspace = true` 与 `serde = "1"` 都要解析出 `serde`。
            let name = name.trim().trim_end_matches(".workspace").trim();
            names.push(name.to_string());
        }
    }
    names
}

#[test]
fn dependency_section_is_parsed() {
    // 防止解析逻辑失效后「零依赖 → 全部通过」的假绿。
    let names = dependency_names();
    assert!(
        names.iter().any(|name| name == "serde"),
        "没有解析到 serde，说明清单解析逻辑坏了：{names:?}"
    );
}

#[test]
fn source_api_manifest_stays_runtime_free() {
    let names = dependency_names();
    for forbidden in [
        "tokio",
        "reqwest",
        "wasmtime",
        "rquickjs",
        "scraper",
        "cssparser",
    ] {
        assert!(
            !names.iter().any(|name| name == forbidden),
            "source-api 不应依赖 {forbidden}：契约层必须保持零 IO"
        );
    }
}

#[test]
fn source_api_only_depends_on_contract_crates() {
    // async-trait 是过程宏，不引入运行时；serde / serde_json 只用于结构与 JSON 编解码。
    let allowed = ["async-trait", "serde", "serde_json"];
    for name in dependency_names() {
        assert!(
            allowed.contains(&name.as_str()),
            "source-api 出现了未列入白名单的依赖：{name}（新依赖必须先确认不破坏零 IO 契约）"
        );
    }
}
