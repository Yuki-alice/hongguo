//! P0 探针：确认 Pulley 解释器可用、组件模型已启用。
//!
//! 不假设 `Config` 暴露读回接口：用「真实组件字节 + 实际编译」证明配置生效。

/// 最小合法组件：组件模型魔数 + 版本 0x0d 0x00 + 层 0x01 0x00。
const MINIMAL_COMPONENT: &[u8] = &[
    0x00, 0x61, 0x73, 0x6d, // \0asm
    0x0d, 0x00, 0x01, 0x00, // component model, layer 1
];

#[test]
fn component_model_compiles_a_minimal_component() {
    let mut config = wasmtime::Config::new();
    config.wasm_component_model(true);
    config.target("pulley64").expect("pulley64 有效");
    let engine = wasmtime::Engine::new(&config).expect("engine");
    let component = wasmtime::component::Component::from_binary(&engine, MINIMAL_COMPONENT);
    assert!(component.is_ok(), "最小组件应可编译：{:?}", component.err());
}

#[test]
fn pulley_target_compiles_to_portable_bytecode() {
    let mut config = wasmtime::Config::new();
    config.wasm_component_model(true);
    config.target("pulley64").expect("pulley64 有效");
    let engine = wasmtime::Engine::new(&config).expect("engine");
    // 直接对组件字节预编译：这正是宿主安装插件时的路径。
    let bytes = engine
        .precompile_component(MINIMAL_COMPONENT)
        .expect("precompile");
    assert!(!bytes.is_empty(), "预编译产物不能为空");
}

#[test]
fn engine_builds_without_fiber() {
    // `engine()` 用关闭 async 的配置构建；能成功即说明没有走 fiber 协程栈。
    let _ = guo_plugin_wasm::engine();
}
