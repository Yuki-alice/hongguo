//! 声明式规则引擎。
//!
//! 负责三件事，全部是纯函数：
//! 1. 解析并**加载期校验**规则文档（`spec: 1.0` 现状，P1 升到 `spec: 2`）；
//! 2. 渲染地址模板（`{page}`/`{category}`/`{md5:…}`/`{ts10}` 等）；
//! 3. 用 CSS 选择器或 JSON 路径从响应里提取条目。
//!
//! 它不发起网络请求：请求由 `FetchRequest` 描述，交给 `guo-host` 执行。

mod embedded;
mod executor;
mod json_executor;
mod jsonpath;
mod rules;
mod template;

pub use executor::RuleExecutor;
pub use json_executor::JsonRuleExecutor;
pub use jsonpath::{absolute, find_url, first_value, select, select_items, text_at, text_of};
pub use rules::{
    CatalogRule, CategoryRule, DetailRule, EpisodesRule, RequestRule, ResolveRule, RuleDocument,
    RuleFields, RuleKind, SearchRule, SelectorList, TemplateCtx, UrlRule,
};
pub use template::{digest_hex, hmac_sha256_hex, tokens_in, Digest, Token, Transform};
