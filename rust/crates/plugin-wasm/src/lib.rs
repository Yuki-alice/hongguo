//! 代码插件宿主：WASM 组件的加载、能力注入与资源限制。
//!
//! 设计要点（ARCHITECTURE.md §9）：
//! - **统一 Pulley 解释器**：iOS 禁止可执行内存，三端只保留一条执行路径；
//! - **能力注入**：插件只能看到 `guo:source/host` 这一组宿主函数，
//!   `wasi:*` 在安装期就被 [`is_allowed_import`] 拒绝；
//! - **资源上限**：fuel 限制指令数、`StoreLimits` 限制线性内存、响应体上限；
//! - **解析留在宿主**：插件拿 `html-select` / `json-path` 的结果，不自己解析 HTML。

mod bindings;
mod component;
mod sandbox;

pub use bindings::{guo, Plugin};
pub use component::{assert_allowed_imports, validate_network, ComponentSource};
pub use sandbox::{
    engine, engine_config, is_allowed_import, runtime_version, Capabilities, HostState,
    SandboxLimits, ALLOWED_IMPORT_PREFIX,
};
