//! 红果短剧主源。
//!
//! 这是**唯一随包分发**的代码源（ARCHITECTURE.md §5）：
//! 签名是字节级混淆（X-Gorgon / X-Argus / X-Ladon），无法用声明式规则表达。
//!
//! 分层：
//! - [`sign`]：请求签名，纯函数，用 Go 版的固定向量做对拍；
//! - [`router`]：`_ROUTER_DATA` 内嵌 JSON 的提取与字段映射；
//! - [`source`]：`SourcePlugin` 实现（目录 / 详情 / 取流 / 分类）。

mod argus;
mod capabilities;
mod device;
mod rankings;
mod router;
mod sign;
mod source;

pub use argus::{comment_headers, sm3, CommentHeaders, CommentNonce};
pub use capabilities::{
    base_title_for_search, group_seasons, parse_danmaku, parse_recommend_page,
    parse_suggestion_dramas, parse_suggestions, recommend_payload, season_of, DANMAKU_LIMIT,
    SUGGESTION_LIMIT,
};
pub use device::DeviceIdentity;
pub use rankings::{board_path, boards, find_board, parse_ranking_page, PAGE_SIZE};
pub use router::{parse_router_data, router_loader_map, HongguoDrama};
pub use sign::{gorgon, SignInputs};
pub use source::HongguoSource;
