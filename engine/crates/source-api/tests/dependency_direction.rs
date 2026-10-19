//! 依赖方向守卫：source-api 不得依赖网络、运行时或 wasm（ARCHITECTURE.md §6.3）。

#[test]
fn source_api_manifest_stays_runtime_free() {
    let manifest = include_str!("../Cargo.toml");
    for forbidden in [
        "tokio",
        "reqwest",
        "wasmtime",
        "rquickjs",
        "scraper",
        "async-trait",
    ] {
        assert!(
            !manifest.contains(forbidden),
            "source-api 不应依赖 {forbidden}：契约层必须保持零 IO"
        );
    }
}
