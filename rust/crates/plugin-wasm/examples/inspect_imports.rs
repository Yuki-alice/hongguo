//! 打印组件的导入/导出集合，用于核对插件是否符合能力白名单。
//!
//! ```bash
//! cargo run -p guo-plugin-wasm --example inspect_imports -- path/to/plugin.wasm
//! ```

fn main() {
    let path = std::env::args()
        .nth(1)
        .expect("用法：inspect_imports <plugin.wasm>");
    let bytes = std::fs::read(&path).expect("读取组件失败");
    let engine = guo_plugin_wasm::engine();
    let component =
        wasmtime::component::Component::from_binary(&engine, &bytes).expect("组件编译失败");
    let ty = component.component_type();
    let mut imports: Vec<String> = ty
        .imports(&engine)
        .map(|(name, _)| name.to_string())
        .collect();
    imports.sort();
    println!("imports ({}):", imports.len());
    for name in &imports {
        println!("  {name}");
    }
    let mut exports: Vec<String> = ty
        .exports(&engine)
        .map(|(name, _)| name.to_string())
        .collect();
    exports.sort();
    println!("exports ({}):", exports.len());
    for name in &exports {
        println!("  {name}");
    }
}
