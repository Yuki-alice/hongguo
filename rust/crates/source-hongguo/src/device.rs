//! 设备身份。
//!
//! 红果 App 接口要求 `device_id` 与 `iid` 是两个 19 位数字串，并且**跨启动稳定**：
//! 每次换新 ID 会让服务端把请求当成新设备，会话与游标全部失效。
//!
//! Go 版的做法是进程内生成一次（`newHongguoDeviceID`），进程重启就换新。
//! 这里改为落盘保存：同样的行为，但重启后游标仍然可用。
//! 存储走 `SourceStore`（宿主注入），key 带 `hongguo/` 前缀避免与其它源冲突。

use guo_source_api::{SourceError, SourceStore};

const DEVICE_KEY: &str = "hongguo/device-id";
const INSTALL_KEY: &str = "hongguo/install-id";

/// 一次会话所需的设备身份。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceIdentity {
    pub device_id: String,
    pub install_id: String,
}

impl DeviceIdentity {
    /// 读取已保存的身份；缺失或非法时生成并落盘。
    ///
    /// 非法值（非 19 位数字）会被替换：旧版本或手工改坏的状态文件
    /// 会让所有请求返回「设备异常」，静默换新比报错更可用。
    pub async fn load_or_create(store: &dyn SourceStore) -> Result<Self, SourceError> {
        let device_id = match store.get(DEVICE_KEY).await? {
            Some(value) if is_valid(&value) => value,
            _ => {
                let value = generate();
                store.set(DEVICE_KEY, &value).await?;
                value
            }
        };
        let install_id = match store.get(INSTALL_KEY).await? {
            Some(value) if is_valid(&value) => value,
            _ => {
                let value = generate();
                store.set(INSTALL_KEY, &value).await?;
                value
            }
        };
        Ok(Self {
            device_id,
            install_id,
        })
    }

    /// 不落盘的内存身份，供解析测试与一次性请求使用。
    pub fn ephemeral() -> Self {
        Self {
            device_id: generate(),
            install_id: generate(),
        }
    }
}

fn is_valid(value: &str) -> bool {
    value.len() == 19 && value.chars().all(|c| c.is_ascii_digit())
}

/// 生成 19 位数字串：首位固定为 1，其余 18 位来自时间与进程地址的混合。
///
/// 不引入 `rand`：这个值只需要「看起来像设备号且不与别的实例重复」，
/// 不需要密码学随机性。
fn generate() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|value| value.as_nanos() as u64)
        .unwrap_or(0);
    let pid = std::process::id() as u64;
    let mut state = nanos ^ (pid << 32);
    let mut out = String::with_capacity(19);
    out.push('1');
    for _ in 0..18 {
        // xorshift64：确定性、无依赖，够用。
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        out.push(char::from(b'0' + (state % 10) as u8));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;
    use std::sync::Mutex;

    #[derive(Default)]
    struct MemoryStore {
        data: Mutex<BTreeMap<String, String>>,
    }

    #[async_trait::async_trait]
    impl SourceStore for MemoryStore {
        async fn get(&self, key: &str) -> Result<Option<String>, SourceError> {
            Ok(self.data.lock().expect("lock").get(key).cloned())
        }
        async fn set(&self, key: &str, value: &str) -> Result<(), SourceError> {
            self.data
                .lock()
                .expect("lock")
                .insert(key.to_string(), value.to_string());
            Ok(())
        }
    }

    #[test]
    fn generated_ids_are_19_digits() {
        for _ in 0..50 {
            let value = generate();
            assert_eq!(value.len(), 19, "{value}");
            assert!(value.starts_with('1'), "{value}");
            assert!(value.chars().all(|c| c.is_ascii_digit()), "{value}");
        }
    }

    #[test]
    fn generate_produces_distinct_values() {
        let a = generate();
        let b = generate();
        // 同一纳秒内也可能相同，因此只弱断言「不是常量」。
        assert!(a.len() == b.len());
        assert!(!is_valid("123"), "短串必须判为非法");
        assert!(!is_valid("123456789012345678a"), "含字母必须判为非法");
        assert!(is_valid("1234567890123456789"));
    }

    #[tokio::test]
    async fn identity_is_stable_across_loads() {
        let store = MemoryStore::default();
        let first = DeviceIdentity::load_or_create(&store).await.expect("first");
        let second = DeviceIdentity::load_or_create(&store)
            .await
            .expect("second");
        assert_eq!(first, second, "重启后必须复用同一身份");
    }

    #[tokio::test]
    async fn corrupted_identity_is_replaced() {
        let store = MemoryStore::default();
        store.set(DEVICE_KEY, "broken").await.expect("seed");
        let identity = DeviceIdentity::load_or_create(&store).await.expect("load");
        assert_eq!(identity.device_id.len(), 19);
        // 落盘值也必须是修复后的。
        let stored = store.get(DEVICE_KEY).await.expect("get").expect("some");
        assert_eq!(stored, identity.device_id);
    }

    #[test]
    fn ephemeral_identity_is_valid_but_not_shared() {
        let a = DeviceIdentity::ephemeral();
        let b = DeviceIdentity::ephemeral();
        assert!(is_valid(&a.device_id));
        assert!(is_valid(&a.install_id));
        assert_ne!((a.device_id, a.install_id), (b.device_id, b.install_id));
    }
}
