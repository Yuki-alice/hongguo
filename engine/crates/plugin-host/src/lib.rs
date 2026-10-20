//! 插件包格式、仓库协议与安装器。
//!
//! 分三层，全部是**纯数据 + 文件系统**，不联网：
//! - [`manifest`]：`plugin.toml` 的解析与加载期校验；
//! - [`package`]：zip 容器解包、路径穿越与体积上限防护、逐包 SHA-256；
//! - [`repository`]：`repo.toml` + `index.json` 的解析、Ed25519 可选校验和 TOFU 指纹。
//!
//! 仓库拉取（网络）由 `runtime` 侧完成，本 crate 只接受已下载的字节，
//! 因此可以被安装器、CLI 与测试共用而不绑定 tokio（ARCHITECTURE.md §7.3）。

mod error;
mod installer;
mod manifest;
mod package;
mod repository;
mod store;

pub use error::PluginError;
pub use installer::{install_package, select_entry, InstallRequest, HOST_VERSION};
pub use manifest::{ApiRequirement, PluginId, PluginKind, PluginManifest, PluginPermissions};
pub use package::{sha256_hex, unpack, PackageLimits, UnpackedPackage};
pub use repository::{
    decode_base64, parse_index, parse_repo_from_path, trust_label, verify_index_signature,
    RepoIndexEntry, RepoManifest, RepositoryIndex,
};
pub use store::{InstallSource, InstalledPlugin, PluginStore, RepoRecord};
