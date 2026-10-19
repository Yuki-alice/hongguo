//! 代码插件宿主。
//!
//! P0 阶段只验证运行时可在各端编译并实例化组件；能力注入与 ABI 绑定在 P1 落地。
//! 运行策略见 ARCHITECTURE.md §9.3：统一 Pulley 解释器，关闭 wasmtime 的 `async` 特性。

/// 运行时配置：固定 Pulley 目标，禁止 JIT。
pub fn engine_config() -> wasmtime::Config {
    let mut config = wasmtime::Config::new();
    config.wasm_component_model(true);
    // iOS 不允许可执行内存，三端统一走解释器，避免出现两套执行路径。
    config.target("pulley64").expect("pulley64 必须是有效目标");
    config
}

/// 组件引擎，供宿主复用。
pub fn engine() -> wasmtime::Engine {
    wasmtime::Engine::new(&engine_config()).expect("engine 配置在编译期已校验")
}

/// 运行时版本，用于诊断面板与包体核对。
pub fn runtime_version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}
