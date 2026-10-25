//! 编译进二进制的站源装配。
//!
//! 这里只回答一个问题：**哪些源随包编译**。装配动作由 `guo-engine` 完成，
//! 因为注册表、插件目录与会话存储都属于进程级单例（Core-1）。
//!
//! 三部分按优先级注册：
//! 1. **主源**（红果）：随包分发，不走插件体系（ARCHITECTURE.md §5）；
//! 2. **随包规则**：迁移期保留，P1 后逐步搬进官方仓库包；
//! 3. **已安装插件**：声明式读 JSON、代码插件走 WASM 宿主。
//!
//! 插件装配失败不会影响前两部分——否则一个坏包能让主源也起不来。

use std::sync::Arc;

use guo_source_api::SourceRegistry;
use guo_source_hongguo::HongguoSource;
use guo_source_huangguo::{HuangguoAiSource, HuangguoVideoSource, LegacySource};
use guo_source_huangju::HuangjuSource;
use guo_source_niuguo::NiuguoSource;
use guo_source_yaguo::YaguoSource;

/// 把编译期站源注册进注册表。
///
/// 作为 `guo_engine::BuiltinSources` 传给 `Engine::initialize`；
/// 随包规则与已安装插件由引擎自己加载，这里不重复。
pub fn register_builtin_sources(registry: &mut SourceRegistry) {
    // 主源固定注册：它随包分发，不走插件体系（ARCHITECTURE.md §5）。
    registry.register(Arc::new(HongguoSource::new()));
    registry.register(Arc::new(NiuguoSource::new()));
    registry.register(Arc::new(YaguoSource::new()));
    registry.register(Arc::new(HuangjuSource::new()));
    // 黄果三源：`cloudfront` 可在线验证，`huangguoai` / `huangguo-video`
    // 的站点在 2026-10-21 全部超时，只有离线对拍（见 crate 文档）。
    registry.register(Arc::new(LegacySource::new()));
    registry.register(Arc::new(HuangguoAiSource::new()));
    registry.register(Arc::new(HuangguoVideoSource::new()));
}
