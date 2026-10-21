//! 牛果站源。
//!
//! 两处无法用声明式规则表达：
//! 1. 响应体是 AES-ECB 密文，密钥取自实际请求 URI 的前 16 字节；
//! 2. 分集里的 `url` 是内部分集 ID，必须再经外部解析服务换取播放地址。

mod niuguo;

pub use niuguo::NiuguoSource;
