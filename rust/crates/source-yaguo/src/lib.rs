//! 芽果站源。
//!
//! 接口型站源：设备登录令牌 + JSON 目录 / 详情 / 搜索，分集直接给出 MP4 地址。

mod yaguo;

pub use yaguo::YaguoSource;
