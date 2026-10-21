//! 猫果站源。
//!
//! 三套 `sign` 参数与字符映射无法用声明式规则表达，因此保留为代码源；
//! P1 会把它搬成 WASM 代码插件（ARCHITECTURE.md §7.1）。

mod maoguo;

pub use maoguo::MaoguoSource;
