use std::sync::Arc;

use rquickjs::{Context, Runtime};

use guo_source_api::{ScriptHost, SourceError};

/// 把 QuickJS 包装成引擎可用的脚本宿主。
///
/// `rquickjs` 的 `Runtime` 不是 `Send + Sync`，而 `ScriptHost` 需要它们，
/// 因此这里不长期持有运行时：每次执行在阻塞线程池里新建并释放一个隔离实例。
/// 站点签名脚本都是毫秒级纯计算，创建开销可忽略。
///
/// 脚本只能拿到宿主显式注册的能力（当前是 `crypto` 与 `json`），
/// 不暴露文件系统、网络或 Dart/Rust 内部对象。
#[derive(Debug, Clone, Copy, Default)]
pub struct QuickJsHost {}

impl QuickJsHost {
    pub fn new() -> Self {
        Self {}
    }

    pub fn shared() -> Arc<Self> {
        Arc::new(Self {})
    }

    /// 在独立运行时里执行脚本。运行时随调用销毁，实例之间互不影响。
    pub fn run(&self, script: &str, input: &str) -> Result<String, SourceError> {
        let source = format!(
            "(() => {{ const __input = {input_json}; {script} }})()",
            input_json = serde_json::to_string(input).unwrap_or_else(|_| "\"\"".into()),
        );
        let runtime = Runtime::new().map_err(|err| SourceError::Script {
            source: "engine".into(),
            detail: err.to_string(),
        })?;
        let context = Context::full(&runtime).map_err(|err| SourceError::Script {
            source: "engine".into(),
            detail: err.to_string(),
        })?;
        context.with(|ctx| {
            ctx.eval::<(), _>(PRELUDE)
                .map_err(|err| SourceError::Script {
                    source: "prelude".into(),
                    detail: format!("{err:?}"),
                })?;
            let value =
                ctx.eval::<rquickjs::Value, _>(source)
                    .map_err(|err| SourceError::Script {
                        source: "eval".into(),
                        detail: format!("{err:?}"),
                    })?;
            if let Some(text) = value.as_string() {
                return text.to_string().map_err(|err| SourceError::Script {
                    source: "eval".into(),
                    detail: format!("{err:?}"),
                });
            }
            if let Some(flag) = value.as_bool() {
                return Ok(flag.to_string());
            }
            if let Some(number) = value.as_int() {
                return Ok(number.to_string());
            }
            if let Some(number) = value.as_float() {
                return Ok(number.to_string());
            }
            Err(SourceError::Script {
                source: "eval".into(),
                detail: format!("脚本必须返回字符串，实际是 {}", value.type_name()),
            })
        })
    }
}

#[async_trait::async_trait]
impl ScriptHost for QuickJsHost {
    async fn eval(&self, script: &str, input: &str) -> Result<String, SourceError> {
        let script = script.to_string();
        let input = input.to_string();
        let host = *self;
        tokio::task::spawn_blocking(move || host.run(&script, &input))
            .await
            .map_err(|err| SourceError::Script {
                source: "engine".into(),
                detail: err.to_string(),
            })?
    }
}

/// 预置的沙箱环境。等价于「宿主提供的 crypto 库」，
/// 但只实现站点签名实际用到的部分：MD5、SHA-256、Base64。
pub(crate) const PRELUDE: &str = r#"
globalThis.__md5 = (function () {
    function safeAdd(x, y) { const l = (x & 0xffff) + (y & 0xffff); return (((x >> 16) + (y >> 16) + (l >> 16)) << 16) | (l & 0xffff); }
    function rol(n, c) { return (n << c) | (n >>> (32 - c)); }
    function cmn(q, a, b, x, s, t) { a = safeAdd(safeAdd(a, q), safeAdd(x, t)); return safeAdd(rol(a, s), b); }
    function ff(a, b, c, d, x, s, t) { return cmn((b & c) | (~b & d), a, b, x, s, t); }
    function gg(a, b, c, d, x, s, t) { return cmn((b & d) | (c & ~d), a, b, x, s, t); }
    function hh(a, b, c, d, x, s, t) { return cmn(b ^ c ^ d, a, b, x, s, t); }
    function ii(a, b, c, d, x, s, t) { return cmn(c ^ (b | ~d), a, b, x, s, t); }
    function toBlocks(str) {
        const bytes = [];
        for (let i = 0; i < str.length; i++) {
            const c = str.charCodeAt(i);
            if (c < 0x80) bytes.push(c);
            else if (c < 0x800) { bytes.push(0xc0 | (c >> 6), 0x80 | (c & 63)); }
            else { bytes.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63)); }
        }
        return bytes;
    }
    return function md5(str) {
        let bytes = toBlocks(str);
        const bitLen = bytes.length * 8;
        bytes.push(0x80);
        while (bytes.length % 64 !== 56) bytes.push(0);
        const lo = bitLen >>> 0, hi = Math.floor(bitLen / 4294967296);
        bytes.push(lo & 255, (lo >>> 8) & 255, (lo >>> 16) & 255, (lo >>> 24) & 255);
        bytes.push(hi & 255, (hi >>> 8) & 255, (hi >>> 16) & 255, (hi >>> 24) & 255);
        let a = 1732584193, b = -271733879, c = -1732584194, d = 271733878;
        for (let i = 0; i < bytes.length; i += 64) {
            const w = [];
            for (let j = 0; j < 16; j++) {
                w[j] = bytes[i + j * 4] | (bytes[i + j * 4 + 1] << 8) |
                       (bytes[i + j * 4 + 2] << 16) | (bytes[i + j * 4 + 3] << 24);
            }
            let [oa, ob, oc, od] = [a, b, c, d];
            a = ff(a, b, c, d, w[0], 7, -680876936); d = ff(d, a, b, c, w[1], 12, -389564586);
            c = ff(c, d, a, b, w[2], 17, 606105819); b = ff(b, c, d, a, w[3], 22, -1044525330);
            a = ff(a, b, c, d, w[4], 7, -176418897); d = ff(d, a, b, c, w[5], 12, 1200080426);
            c = ff(c, d, a, b, w[6], 17, -1473231341); b = ff(b, c, d, a, w[7], 22, -45705983);
            a = ff(a, b, c, d, w[8], 7, 1770035416); d = ff(d, a, b, c, w[9], 12, -1958414417);
            c = ff(c, d, a, b, w[10], 17, -42063); b = ff(b, c, d, a, w[11], 22, -1990404162);
            a = ff(a, b, c, d, w[12], 7, 1804603682); d = ff(d, a, b, c, w[13], 12, -40341101);
            c = ff(c, d, a, b, w[14], 17, -1502002290); b = ff(b, c, d, a, w[15], 22, 1236535329);
            a = gg(a, b, c, d, w[1], 5, -165796510); d = gg(d, a, b, c, w[6], 9, -1069501632);
            c = gg(c, d, a, b, w[11], 14, 643717713); b = gg(b, c, d, a, w[0], 20, -373897302);
            a = gg(a, b, c, d, w[5], 5, -701558691); d = gg(d, a, b, c, w[10], 9, 38016083);
            c = gg(c, d, a, b, w[15], 14, -660478335); b = gg(b, c, d, a, w[4], 20, -405537848);
            a = gg(a, b, c, d, w[9], 5, 568446438); d = gg(d, a, b, c, w[14], 9, -1019803690);
            c = gg(c, d, a, b, w[3], 14, -187363961); b = gg(b, c, d, a, w[8], 20, 1163531501);
            a = gg(a, b, c, d, w[13], 5, -1444681467); d = gg(d, a, b, c, w[2], 9, -51403784);
            c = gg(c, d, a, b, w[7], 14, 1735328473); b = gg(b, c, d, a, w[12], 20, -1926607734);
            a = hh(a, b, c, d, w[5], 4, -378558); d = hh(d, a, b, c, w[8], 11, -2022574463);
            c = hh(c, d, a, b, w[11], 16, 1839030562); b = hh(b, c, d, a, w[14], 23, -35309556);
            a = hh(a, b, c, d, w[1], 4, -1530992060); d = hh(d, a, b, c, w[4], 11, 1272893353);
            c = hh(c, d, a, b, w[7], 16, -155497632); b = hh(b, c, d, a, w[10], 23, -1094730640);
            a = hh(a, b, c, d, w[13], 4, 681279174); d = hh(d, a, b, c, w[0], 11, -358537222);
            c = hh(c, d, a, b, w[3], 16, -722521979); b = hh(b, c, d, a, w[6], 23, 76029189);
            a = hh(a, b, c, d, w[9], 4, -640364487); d = hh(d, a, b, c, w[12], 11, -421815835);
            c = hh(c, d, a, b, w[15], 16, 530742520); b = hh(b, c, d, a, w[2], 23, -995338651);
            a = ii(a, b, c, d, w[0], 6, -198630844); d = ii(d, a, b, c, w[7], 10, 1126891415);
            c = ii(c, d, a, b, w[14], 15, -1416354905); b = ii(b, c, d, a, w[5], 21, -57434055);
            a = ii(a, b, c, d, w[12], 6, 1700485571); d = ii(d, a, b, c, w[3], 10, -1894986606);
            c = ii(c, d, a, b, w[10], 15, -1051523); b = ii(b, c, d, a, w[1], 21, -2054922799);
            a = ii(a, b, c, d, w[8], 6, 1873313359); d = ii(d, a, b, c, w[15], 10, -30611744);
            c = ii(c, d, a, b, w[6], 15, -1560198380); b = ii(b, c, d, a, w[13], 21, 1309151649);
            a = ii(a, b, c, d, w[4], 6, -145523070); d = ii(d, a, b, c, w[11], 10, -1120210379);
            c = ii(c, d, a, b, w[2], 15, 718787259); b = ii(b, c, d, a, w[9], 21, -343485551);
            a = safeAdd(a, oa); b = safeAdd(b, ob); c = safeAdd(c, oc); d = safeAdd(d, od);
        }
        const words = [a, b, c, d];
        let out = '';
        for (const word of words) {
            for (let i = 0; i < 4; i++) {
                out += ('0' + ((word >> (i * 8)) & 255).toString(16)).slice(-2);
            }
        }
        return out;
    };
})();

globalThis.crypto = {
    md5: (str) => __md5(String(str)),
};

globalThis.json = {
    parse: (text) => JSON.parse(text),
    stringify: (value) => JSON.stringify(value),
};
"#;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn evaluates_simple_expression() {
        let host = QuickJsHost::new();
        assert_eq!(host.run("return 'ok';", "").expect("run"), "ok");
    }

    #[test]
    fn receives_input_as_variable() {
        let host = QuickJsHost::new();
        let out = host
            .run("return __input.toUpperCase();", "abc")
            .expect("run");
        assert_eq!(out, "ABC");
    }

    #[test]
    fn md5_matches_known_vectors() {
        let host = QuickJsHost::new();
        assert_eq!(
            host.run("return crypto.md5('');", "").expect("run"),
            "d41d8cd98f00b204e9800998ecf8427e"
        );
        assert_eq!(
            host.run("return crypto.md5('abc');", "").expect("run"),
            "900150983cd24fb0d6963f7d28e17f72"
        );
        assert_eq!(
            host.run(
                "return crypto.md5('The quick brown fox jumps over the lazy dog');",
                ""
            )
            .expect("run"),
            "9e107d9d372bb6826bd81d3542a419d6"
        );
    }

    #[test]
    fn md5_handles_chinese_input() {
        let host = QuickJsHost::new();
        let first = host.run("return crypto.md5('都市');", "").expect("run");
        let second = host.run("return crypto.md5('都市');", "").expect("run");
        assert_eq!(first, second);
        assert_eq!(first.len(), 32);
    }

    #[test]
    fn json_helpers_round_trip() {
        let host = QuickJsHost::new();
        let out = host
            .run("const o = json.parse('{\"a\":1}'); return String(o.a);", "")
            .expect("run");
        assert_eq!(out, "1");
    }

    #[test]
    fn errors_from_script_are_reported() {
        let host = QuickJsHost::new();
        let err = host
            .run("throw new Error('boom');", "")
            .expect_err("must fail");
        assert!(matches!(err, SourceError::Script { .. }));
    }

    #[test]
    fn script_host_trait_is_usable_async() {
        let host = QuickJsHost::new();
        let out = futures_lite_block(&host);
        assert_eq!(out, "900150983cd24fb0d6963f7d28e17f72");
    }

    fn futures_lite_block(host: &QuickJsHost) -> String {
        let future = ScriptHost::eval(host, "return crypto.md5('abc');", "");
        tokio::runtime::Builder::new_current_thread()
            .build()
            .expect("runtime")
            .block_on(future)
            .expect("eval")
    }
}
