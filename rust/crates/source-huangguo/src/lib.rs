//! 黄果站源：AI、视频与旧版（cloudfront）三个入口。
//!
//! **验证状态不一致**：
//! - `cloudfront`（`legacy.rs`）的官网前端与 API 在当前网络下可达，是三个源里
//!   唯一具备在线验证条件的；
//! - `huangguoai.com`、`huangguo.video` 及其六个镜像在 2026-10-21 实测全部
//!   连接超时，只能按 Go 版结构翻译并用合成 markup 做离线对拍，
//!   站点恢复后必须补在线验证才能标为可用。

mod ai;
mod legacy;
mod video;

pub use ai::HuangguoAiSource;
pub use legacy::LegacySource;
pub use video::HuangguoVideoSource;
