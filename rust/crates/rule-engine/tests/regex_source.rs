//! 正则型站源端到端验收：用 guoapp2 里黄果的**原始正则**跑通一条规则。
//!
//! `reference/guoapp2/native/core/provider_huangguo.go` 是 1306 行 Go，
//! 靠 12 条 `regexp` 提取、完全没有 DOM 结构可依赖——这是 `kind = "regex"`
//! 存在的理由。本文件里的正则逐条抄自那份实现，用来证明声明式规则
//! 能承载这类站点，不必落到编译源或 Wasm 插件。
//!
//! 站点当前不可达（PLAN §5），因此夹具按那 12 条正则的语义构造，
//! 而不是抓取真实页面。

use guo_rule_engine::{RuleDocument, RuleExecutor};
use guo_source_api::Drama;

/// `reVideoCard` / `reHuangguoLink` / `reDataHLS` 等，抄自 provider_huangguo.go。
const HUANGGUO_RULE: &str = r#"{
    "schema": "1.0",
    "id": "huangguo",
    "name": "黄果",
    "base": "https://huangguo.example",
    "kind": "regex",
    "capabilities": ["catalog", "detail", "search", "resolve"],
    "catalog": {
        "url": "/category/{category}?page={page}",
        "item": "(?is)<article\\b[^>]*class=[\"'][^\"']*\\bvideo-card\\b[^\"']*[\"'][^>]*>.*?</article>",
        "fields": {
            "id": "(?is)<a\\b[^>]*href=[\"']([^\"']*/(?:series|video)/([^\"'/?#]+)[^\"']*)[\"']",
            "title": "(?is)(?:title|alt|aria-label)=[\"']([^\"']+)[\"']",
            "cover": "(?is)data-src=[\"']([^\"']+)[\"']",
            "description": "(?is)data-description=[\"']([^\"']+)[\"']"
        }
    },
    "detail": {
        "episodes": {
            "pattern": "(?is)<a\\b[^>]*href=[\"']([^\"']*/video/[^\"']+)[\"'][^>]*>(.*?)</a>",
            "titleGroup": 2
        },
        "title": "(?is)<h1[^>]*>(.*?)</h1>",
        "description": "(?is)<meta\\b[^>]*(?:name|property)=[\"'](?:description|og:description)[\"'][^>]*content=[\"']([^\"']+)[\"'][^>]*>"
    },
    "resolve": {
        "urlRegex": [
            "(?is)data-hls=[\"']([^\"']+)[\"']",
            "(?is)data-play-src=[\"']([^\"']+)[\"']",
            "(?is)[\"']?(?:videoSrc|videoUrl|playUrl|src|url)[\"']?\\s*[:=]\\s*[\"']([^\"']+\\.(?:m3u8|mp4)(?:[^\"']*)?)[\"']"
        ]
    }
}"#;

const CATALOG_HTML: &str = r#"<html><body>
    <article class="video-card group">
        <a href="/series/8848.html" title="都市狂龙">
            <img data-src="https://cdn.huangguo.test/8848.jpg" alt="封面">
        </a>
        <div class="bg-black/55">更新至 30 集</div>
    </article>
    <article class="video-card group">
        <a href="/video/90210.html" title="短剧之王" data-description="他是最强的男人">
            <img data-src="/uploads/90210.jpg">
        </a>
    </article>
    <article class="video-card group">
        <a href="/video/8848.html" title="重复条目"></a>
    </article>
    <article class="video-card group">
        <a href="/video/77777.html"><img data-src="/uploads/77777.jpg"></a>
    </article>
</body></html>"#;

fn rule() -> RuleDocument {
    RuleDocument::from_json(HUANGGUO_RULE).expect("黄果规则必须能通过加载期校验")
}

#[test]
fn huangguo_catalog_extracts_cards_with_dedupe() {
    let rule = rule();
    let page = RuleExecutor::new(&rule)
        .parse_catalog(CATALOG_HTML, 1)
        .expect("catalog");

    // 8848 出现两次（series/ 与 video/），必须并成一个；77777 无标题被丢弃。
    assert_eq!(page.items.len(), 2, "实际：{:?}", page.items);
    assert_eq!(page.items[0].source_id, "8848");
    assert_eq!(page.items[0].title, "都市狂龙");
    assert_eq!(page.items[0].cover, "https://cdn.huangguo.test/8848.jpg");
    assert_eq!(page.items[1].source_id, "90210");
    assert_eq!(page.items[1].title, "短剧之王");
    assert_eq!(page.items[1].description, "他是最强的男人");
    // 相对路径的封面必须补成绝对地址，否则 UI 拿不到图。
    assert_eq!(
        page.items[1].cover,
        "https://huangguo.example/uploads/90210.jpg"
    );
}

#[test]
fn huangguo_detail_extracts_episodes() {
    let rule = rule();
    let drama = Drama {
        id: "huangguo:8848".into(),
        source: "huangguo".into(),
        source_id: "8848".into(),
        ..Default::default()
    };
    let html = r#"<div>
        <a href="/video/8848-1.html">第1集</a>
        <a href="/video/8848-2.html">第2集</a>
        <a href="/video/8848-1.html">重复</a>
    </div>"#;
    let chapters = RuleExecutor::new(&rule)
        .parse_chapters(html, &drama)
        .expect("chapters");
    assert_eq!(chapters.len(), 2, "同地址分集必须去重");
    assert_eq!(chapters[0].title, "第1集");
    assert_eq!(
        chapters[0].page_url,
        "https://huangguo.example/video/8848-1.html"
    );
}

#[test]
fn huangguo_fill_drama_reads_h1_and_meta_description() {
    let rule = rule();
    let mut drama = Drama {
        id: "huangguo:8848".into(),
        source: "huangguo".into(),
        source_id: "8848".into(),
        title: "目录页标题".into(),
        ..Default::default()
    };
    let html = r#"<html><head>
        <meta name="description" content="他是最强的男人">
    </head><body><h1>都市狂龙 全集</h1></body></html>"#;
    RuleExecutor::new(&rule).fill_drama(html, &mut drama);
    assert_eq!(drama.title, "都市狂龙 全集");
    assert_eq!(drama.description, "他是最强的男人");
}

#[test]
fn huangguo_media_url_falls_back_across_candidates() {
    let rule = rule();
    let executor = RuleExecutor::new(&rule);

    // 第一候选 data-hls 命中。
    assert_eq!(
        executor
            .media_url(r#"<video data-hls="https://cdn.test/a.m3u8"></video>"#)
            .as_deref(),
        Some("https://cdn.test/a.m3u8")
    );
    // data-hls 缺失时退到 data-play-src。
    assert_eq!(
        executor
            .media_url(r#"<div data-play-src="https://cdn.test/b.mp4"></div>"#)
            .as_deref(),
        Some("https://cdn.test/b.mp4")
    );
    // 两者都缺时退到脚本里的 videoSrc 字段。
    assert_eq!(
        executor
            .media_url(r#"<script>var x = {videoSrc:"https://cdn.test/c.m3u8"};</script>"#)
            .as_deref(),
        Some("https://cdn.test/c.m3u8")
    );
    assert_eq!(executor.media_url("<div>什么都没有</div>"), None);
}

#[test]
fn html_rules_are_unaffected_by_regex_kind() {
    // 回归护栏：新增 Regex 变体不能改变现有 9 条 HTML 规则的默认分支。
    let html_rule = RuleDocument::from_json(
        r#"{
            "schema": "1.0",
            "id": "wuguo",
            "name": "伍果",
            "base": "https://www.duanju55.com",
            "catalog": {
                "url": "index.php/vod/type/id/{category}/page/{page}.html",
                "item": "a.module-item",
                "fields": { "id": "a@href", "title": ".title" }
            },
            "detail": { "episodes": "a[href*=play]" }
        }"#,
    )
    .expect("rule");
    assert_eq!(html_rule.kind, guo_rule_engine::RuleKind::Html);
}
