mod maoguo;
mod rule_source;

pub use maoguo::MaoguoSource;
pub use rule_source::RuleSource;

use crate::source::SourceRegistry;

/// 注册所有内置站源。新增站源只需在这里加一行。
pub fn builtin_registry() -> SourceRegistry {
    let mut registry = SourceRegistry::new();
    registry.register(std::sync::Arc::new(MaoguoSource::new()));
    for text in BUILTIN_RULES {
        match RuleSource::from_json(text) {
            Ok(source) => {
                registry.register(std::sync::Arc::new(source));
            }
            Err(err) => {
                // 规则随包分发，加载失败属于构建期缺陷，必须显式暴露。
                eprintln!("内置规则加载失败：{err}");
            }
        }
    }
    registry
}

/// 随包分发的声明式规则。
const BUILTIN_RULES: &[&str] = &[
    include_str!("../../../rules/wuguo.json"),
    include_str!("../../../rules/huaguo.json"),
    include_str!("../../../rules/fanguo.json"),
    include_str!("../../../rules/guanguo.json"),
    include_str!("../../../rules/xingguo.json"),
    include_str!("../../../rules/heguo.json"),
    include_str!("../../../rules/wangguo.json"),
];
