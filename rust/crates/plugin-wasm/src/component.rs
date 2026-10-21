//! 组件型站源：把 WASM 插件包装成 `SourcePlugin`。
//!
//! 每次动作调用都新建 store（于是 fuel / 内存 / 时间预算按调用重置），
//! 但 `Component` 与 `InstancePre` 复用同一份 Pulley 预编译产物，
//! 因此重复调用不需要重新编译。

use std::sync::Arc;

use async_trait::async_trait;
use guo_source_api::{
    Category, Chapter, Detail, Drama, Media, Page, SourceEnv, SourceError, SourceMeta,
    SourcePlugin, CURRENT_API_LEVEL,
};

use crate::bindings::{
    category_from_wit, chapter_from_wit, descriptor_capabilities, drama_from_wit_for,
    media_from_wit, page_from_wit_for, plugin_error, types, Plugin,
};
use crate::sandbox::{add_host_to_linker, engine, host_of, Capabilities, HostState, SandboxLimits};

/// 已加载的组件型站源。
pub struct ComponentSource {
    component: wasmtime::component::Component,
    instance: PluginPre<HostState>,
    meta: SourceMeta,
    /// 插件声明的网络白名单，来自 `plugin.toml` 的 `permissions.network`。
    network: Vec<String>,
    storage: Vec<String>,
    limits: SandboxLimits,
}

use crate::bindings::PluginPre;

impl ComponentSource {
    /// 从组件字节构造。
    ///
    /// `network` / `storage` 来自清单的权限声明：插件不能自己扩大权限。
    pub fn load(
        bytes: &[u8],
        network: Vec<String>,
        storage: Vec<String>,
        limits: SandboxLimits,
    ) -> Result<Self, SourceError> {
        let engine = engine();
        let component = wasmtime::component::Component::from_binary(&engine, bytes)
            .map_err(|err| SourceError::parse("plugin", format!("组件编译失败：{err}")))?;
        assert_allowed_imports(&component)?;

        let mut linker = wasmtime::component::Linker::<HostState>::new(&engine);
        add_host_to_linker(&mut linker)
            .map_err(|err| SourceError::parse("plugin", format!("宿主能力注册失败：{err}")))?;
        let instance = linker
            .instantiate_pre(&component)
            .map_err(|err| SourceError::parse("plugin", format!("组件实例化失败：{err}")))?;
        let instance = PluginPre::new(instance)
            .map_err(|err| SourceError::parse("plugin", format!("组件不满足 WIT 契约：{err}")))?;

        // 先实例化一次拿描述符，后续每次调用都重新构造 store。
        let capabilities = Capabilities {
            env: placeholder_env(),
            network: network.clone(),
            storage: storage.clone(),
            limits,
        };
        let mut store = HostState::store(capabilities);
        let plugin = instance
            .instantiate(&mut store)
            .map_err(|err| SourceError::parse("plugin", format!("组件实例化失败：{err}")))?;
        let descriptor = plugin
            .guo_source_source()
            .call_describe(&mut store)
            .map_err(|err| SourceError::parse("plugin", format!("descriptor 调用失败：{err}")))?;

        let capabilities = descriptor_capabilities(&descriptor);
        let meta = SourceMeta {
            id: descriptor.id,
            name: descriptor.name,
            group: descriptor.group,
            api_level: descriptor.api_level,
            capabilities,
        };
        if meta.api_level > CURRENT_API_LEVEL {
            return Err(SourceError::parse(
                "plugin",
                format!(
                    "插件 API level {} 高于宿主 {CURRENT_API_LEVEL}",
                    meta.api_level
                ),
            ));
        }

        Ok(Self {
            component,
            instance,
            meta,
            network,
            storage,
            limits,
        })
    }

    fn capabilities(&self, env: &SourceEnv) -> Capabilities {
        let mut capabilities = Capabilities::new(env.clone());
        capabilities.network = self.network.clone();
        capabilities.storage = self.storage.clone();
        capabilities.limits = self.limits;
        capabilities
    }

    pub fn component(&self) -> &wasmtime::component::Component {
        &self.component
    }

    pub fn limits(&self) -> SandboxLimits {
        self.limits
    }
}

fn placeholder_env() -> SourceEnv {
    // 描述符调用不需要网络；构造一个空环境，避免把 `SourceEnv` 变成 `Option`。
    SourceEnv {
        source_id: "plugin".into(),
        transport: Arc::new(NoTransport),
        store: Arc::new(NoStore),
        scripts: None,
        log: Arc::new(NoLog),
    }
}

struct NoTransport;
#[async_trait]
impl guo_source_api::Transport for NoTransport {
    async fn fetch(
        &self,
        request: guo_source_api::FetchRequest,
    ) -> Result<guo_source_api::FetchResponse, SourceError> {
        Err(SourceError::network(
            request.url,
            "插件描述阶段不应发起网络请求",
        ))
    }
}

struct NoStore;
#[async_trait]
impl guo_source_api::SourceStore for NoStore {
    async fn get(&self, _key: &str) -> Result<Option<String>, SourceError> {
        Ok(None)
    }
    async fn set(&self, _key: &str, _value: &str) -> Result<(), SourceError> {
        Ok(())
    }
}

struct NoLog;
impl guo_source_api::LogSink for NoLog {
    fn debug(&self, _message: &str) {}
    fn warn(&self, _message: &str) {}
}

/// 安装期与加载期都会调用的导入白名单断言（§9.1）。
///
/// 只允许 `guo:source/*`；`wasi:*` 一律拒绝，因为插件不该直接触碰文件与网络。
pub fn assert_allowed_imports(
    component: &wasmtime::component::Component,
) -> Result<(), SourceError> {
    let engine = engine();
    let ty = component.component_type();
    for (name, _export) in ty.imports(&engine) {
        let module = &name;
        if !crate::sandbox::is_allowed_import(module) {
            return Err(SourceError::parse(
                "plugin",
                format!("插件导入了不允许的模块：{module}（只允许 guo:source/*）"),
            ));
        }
    }
    Ok(())
}

#[async_trait]
impl SourcePlugin for ComponentSource {
    fn meta(&self) -> SourceMeta {
        self.meta.clone()
    }

    async fn categories(&self, env: &SourceEnv) -> Result<Vec<Category>, SourceError> {
        let instance = self.instance.clone();
        let capabilities = self.capabilities(env);
        let list = blocking(move || {
            let mut store = HostState::store(capabilities);
            let plugin = instantiate(&instance, &mut store)?;
            let value = plugin
                .guo_source_source()
                .call_categories(&mut store)
                .map_err(call_error)?;
            value.map_err(plugin_error)
        })
        .await?;
        Ok(list.into_iter().map(category_from_wit).collect())
    }

    async fn catalog(
        &self,
        env: &SourceEnv,
        page: u32,
        category: &str,
    ) -> Result<Page, SourceError> {
        let query = types::Query {
            page,
            category: category.to_string(),
            keyword: String::new(),
            cursor: String::new(),
        };
        let instance = self.instance.clone();
        let capabilities = self.capabilities(env);
        let page = blocking(move || {
            let mut store = HostState::store(capabilities);
            let plugin = instantiate(&instance, &mut store)?;
            let value = plugin
                .guo_source_source()
                .call_catalog(&mut store, &query)
                .map_err(call_error)?;
            value.map_err(plugin_error)
        })
        .await?;
        Ok(page_from_wit_for(page, &self.meta.id))
    }

    async fn detail(&self, env: &SourceEnv, source_id: &str) -> Result<Detail, SourceError> {
        let source_id = source_id.to_string();
        let instance = self.instance.clone();
        let capabilities = self.capabilities(env);
        let detail = blocking(move || {
            let mut store = HostState::store(capabilities);
            let plugin = instantiate(&instance, &mut store)?;
            let value = plugin
                .guo_source_source()
                .call_fetch_detail(&mut store, &source_id)
                .map_err(call_error)?;
            value.map_err(plugin_error)
        })
        .await?;
        Ok(Detail {
            drama: drama_from_wit_for(detail.drama, &self.meta.id),
            chapters: detail.chapters.into_iter().map(chapter_from_wit).collect(),
        })
    }

    async fn search(&self, env: &SourceEnv, query: &str, page: u32) -> Result<Page, SourceError> {
        let query = types::Query {
            page,
            category: String::new(),
            keyword: query.to_string(),
            cursor: String::new(),
        };
        let instance = self.instance.clone();
        let capabilities = self.capabilities(env);
        let result = blocking(move || {
            let mut store = HostState::store(capabilities);
            let plugin = instantiate(&instance, &mut store)?;
            let value = plugin
                .guo_source_source()
                .call_search(&mut store, &query)
                .map_err(call_error)?;
            value.map_err(plugin_error)
        })
        .await?;
        Ok(page_from_wit_for(result, &self.meta.id))
    }

    async fn resolve(
        &self,
        env: &SourceEnv,
        drama: &Drama,
        chapter: &Chapter,
    ) -> Result<Media, SourceError> {
        let request = types::ResolveRequest {
            source_id: drama.source_id.clone(),
            chapter: types::Chapter {
                id: chapter.id.clone(),
                title: chapter.title.clone(),
                video_url: chapter.video_url.clone(),
                page_url: chapter.page_url.clone(),
                referer: chapter.referer.clone(),
                vip: chapter.vip,
            },
        };
        let instance = self.instance.clone();
        let capabilities = self.capabilities(env);
        let media = blocking(move || {
            let mut store = HostState::store(capabilities);
            let plugin = instantiate(&instance, &mut store)?;
            let value = plugin
                .guo_source_source()
                .call_resolve(&mut store, &request)
                .map_err(call_error)?;
            value.map_err(plugin_error)
        })
        .await?;
        Ok(media_from_wit(media))
    }
}

fn instantiate(
    instance: &PluginPre<HostState>,
    store: &mut wasmtime::Store<HostState>,
) -> Result<Plugin, SourceError> {
    instance
        .instantiate(store)
        .map_err(|err| SourceError::parse("plugin", format!("实例化失败：{err}")))
}

fn call_error(err: wasmtime::Error) -> SourceError {
    // fuel 耗尽 / epoch 超时都会走到这里，归为「解析失败」而不是网络错误。
    SourceError::parse("plugin", format!("插件调用失败：{err}"))
}

/// 在阻塞线程池里跑同步的 wasm 调用，避免占住 tokio 工作线程。
async fn blocking<T, F>(f: F) -> Result<T, SourceError>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T, SourceError> + Send + 'static,
{
    tokio::task::spawn_blocking(f)
        .await
        .map_err(|err| SourceError::parse("plugin", format!("任务调度失败：{err}")))?
}

/// 校验网络声明里的主机名（清单解析时已做一次，这里防御性再查）。
pub fn validate_network(hosts: &[String]) -> Result<(), SourceError> {
    for host in hosts {
        if host_of(&format!("https://{host}/")).is_none() {
            return Err(SourceError::parse(
                "plugin",
                format!("网络声明不是合法主机名：{host}"),
            ));
        }
    }
    Ok(())
}
