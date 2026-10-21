//! 剧果站源。
//!
//! 三处无法用声明式规则表达：
//! 1. 接口要访客令牌（`POST /auth/guest`），过期后需重新申请；
//! 2. 详情按 `slug` 取，取流按分集数字 `id`；
//! 3. 媒体域走 CDN 签名，播放必须带上取流响应下发的 Cookie。

mod huangju;

pub use huangju::HuangjuSource;
