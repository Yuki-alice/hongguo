//! 冷启动测量：编译 + 实例化一个最小组件所需的墙钟时间。
fn main() {
    const MINIMAL: &[u8] = &[0x00, 0x61, 0x73, 0x6d, 0x0d, 0x00, 0x01, 0x00];
    let start = std::time::Instant::now();
    let engine = guo_plugin_wasm::engine();
    let engine_ms = start.elapsed().as_secs_f64() * 1000.0;

    let start = std::time::Instant::now();
    let component = wasmtime::component::Component::from_binary(&engine, MINIMAL).expect("compile");
    let compile_ms = start.elapsed().as_secs_f64() * 1000.0;

    let start = std::time::Instant::now();
    let mut store = wasmtime::Store::new(&engine, ());
    let linker = wasmtime::component::Linker::new(&engine);
    let instance = linker
        .instantiate(&mut store, &component)
        .expect("instantiate");
    let instantiate_ms = start.elapsed().as_secs_f64() * 1000.0;
    let _ = instance;

    println!("engine={engine_ms:.2}ms compile={compile_ms:.2}ms instantiate={instantiate_ms:.2}ms");
}
