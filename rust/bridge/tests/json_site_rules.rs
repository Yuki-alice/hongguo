use guo_engine::{builtin_registry, Drama, RuleDocument, RuleExecutor, SourceError, TemplateCtx};

const FANGUO: &str = include_str!("../../rules/fanguo.json");
const XINGGUO: &str = include_str!("../../rules/xingguo.json");
const GUANGUO: &str = include_str!("../../rules/guanguo.json");
const HEGUO: &str = include_str!("../../rules/heguo.json");

fn drama(source: &str, source_id: &str) -> Drama {
    Drama {
        id: Drama::identity(source, source_id),
        source: source.to_string(),
        source_id: source_id.to_string(),
        ..Default::default()
    }
}

fn ctx<'a>(page: u32, category: &'a str, keyword: &'a str, id: &'a str) -> TemplateCtx<'a> {
    TemplateCtx {
        page,
        category,
        keyword,
        id,

        vars: None,
    }
}

#[test]
fn builtin_registry_loads_every_shipped_rule() {
    let registry = builtin_registry();
    let metas = registry.metas();
    for id in [
        "maoguo", "wuguo", "huaguo", "fanguo", "guanguo", "xingguo", "heguo", "wangguo", "dsd",
        "faguo", "niuguo", "huangju",
    ] {
        assert!(
            metas.iter().any(|meta| meta.id == id),
            "{id} 未注册或规则加载失败"
        );
    }
    assert!(metas.iter().all(|meta| !meta.capabilities.is_empty()));
}

#[test]
fn fanguo_reads_composite_ids_from_nested_search_payload() {
    let document = RuleDocument::from_json(FANGUO).expect("饭果规则");
    let body = r#"{"code":200,"result":{"elements":[{"contents":[
        {"duanjuVo":{"duanjuId":"7788","source":"ifeng","title":"战神归来","description":"简介",
         "coverImageUrl":"https://img.example/a.jpg","total":60,"categories":["都市","逆袭"]}},
        {"duanjuVo":{"duanjuId":"7788","source":"ifeng","title":"重复条目"}},
        {"duanjuVo":{"duanjuId":"7789","title":"无来源条目","name":"备用标题"}}
    ]}]}}"#;
    let page = RuleExecutor::new(&document)
        .parse_catalog(body, 1)
        .expect("目录");
    assert_eq!(page.items.len(), 2);
    let first = &page.items[0];
    assert_eq!(first.id, "fanguo:7788#ifeng");
    assert_eq!(first.title, "战神归来");
    assert_eq!(first.episodes, 60);
    assert_eq!(first.category, "都市, 逆袭");
    assert_eq!(page.items[1].source_id, "7789");
    assert!(!page.has_more);

    let catalog = document.catalog.as_ref().expect("catalog");
    let category = catalog.category_for("");
    assert_eq!(category, "都市");
    let url = catalog
        .url_candidates(&document, &ctx(1, category, "", ""))
        .expect("地址");
    assert!(url.contains("keyword=都市"), "{url}");
    assert!(url.contains("reqType=search"), "{url}");
}

#[test]
fn fanguo_detail_fills_meta_and_skips_duplicate_episodes() {
    let document = RuleDocument::from_json(FANGUO).expect("饭果规则");
    let body = r#"{"result":{"duanjuId":"7788","title":"战神归来","total":60,"current":60,
        "updateStatus":"已完结","episodeList":[
        {"index":1,"title":"第1集","playUrl":"https://v.example/1.mp4"},
        {"index":2,"playUrl":"https://v.example/2.mp4"},
        {"index":2,"playUrl":"https://v.example/dup.mp4"},
        {"index":3,"title":"缺地址"}
    ]}}"#;
    let parsed = RuleExecutor::new(&document);
    let mut target = drama("fanguo", "7788#ifeng");
    parsed.fill_drama(body, &mut target);
    assert_eq!(target.title, "战神归来");
    assert_eq!(target.release_status, "finished");

    let chapters = parsed.parse_chapters(body, &target).expect("分集");
    assert_eq!(chapters.len(), 2);
    assert_eq!(chapters[1].id, "fanguo:7788#ifeng:2");
    assert_eq!(chapters[1].title, "第2集");
    assert_eq!(chapters[0].referer, "https://xifan-api-cn.youlishipin.com/");
}

#[test]
fn xingguo_carries_introduction_in_the_id_and_recurses_for_urls() {
    let document = RuleDocument::from_json(XINGGUO).expect("星果规则");
    let body = r#"{"code":1,"data":{"datalist":[
        {"id":"555","name":"星河","introduction":"简介文本","icon":"http://img.example/i.jpg",
         "chapterCount":3,"heat":22},
        {"id":"556","name":"短剧","shortPlayList":[]}
    ]}}"#;
    let page = RuleExecutor::new(&document)
        .parse_catalog(body, 1)
        .expect("目录");
    assert_eq!(page.items.len(), 2);
    assert_eq!(page.items[0].id, "xingguo:555@简介文本");
    assert_eq!(page.items[0].views, "22万播放");
    assert_eq!(page.items[0].cover, "http://img.example/i.jpg");
    assert_eq!(page.items[1].source_id, "556");

    let url = document
        .detail
        .as_ref()
        .expect("detail")
        .url_candidates(&document, &ctx(1, "", "", "555@简介文本"))
        .expect("地址");
    assert!(url.contains("bookId=555"), "{url}");

    let chapters = r#"{"data":[
        {"chapterNum":2,"shortPlayList":[{"shortPlayUrl":"http://v.example/2.mp4"}]},
        {"chapterNum":1,"shortPlayUrl":"http://v.example/1.mp4"},
        {"chapterNum":1,"shortPlayUrl":"http://v.example/dup.mp4"}
    ]}"#;
    let list = RuleExecutor::new(&document)
        .parse_chapters(chapters, &drama("xingguo", "555@简介文本"))
        .expect("分集");
    assert_eq!(list.len(), 2);
    assert_eq!(list[0].video_url, "http://v.example/1.mp4");
    assert_eq!(list[1].video_url, "http://v.example/2.mp4");
    assert_eq!(list[0].title, "第1集");
}

#[test]
fn xingguo_request_keeps_static_credentials() {
    let document = RuleDocument::from_json(XINGGUO).expect("星果规则");
    let url = document
        .catalog
        .as_ref()
        .expect("catalog")
        .url_candidates(&document, &ctx(3, "1288", "", ""))
        .expect("地址");
    assert!(
        url.starts_with("http://read.api.duodutek.com/novel-api/app/pageModel/getResourceById?"),
        "{url}"
    );
    assert!(url.contains("resourceId=1288"), "{url}");
    assert!(url.contains("pageNum=3"), "{url}");
    assert!(
        url.contains("token=202509271001001446030204698626"),
        "{url}"
    );
}

#[test]
fn guanguo_maps_views_and_picks_best_clarity() {
    let document = RuleDocument::from_json(GUANGUO).expect("观果规则");
    let body = r#"{"code":200,"msg":"success","data":[{"title":"九转星辰诀",
        "oneId":"110000042659853849","shortPlayTag":["玄幻仙侠"],"viewCount":658970,
        "description":"天才少年","horzPoster":"https://pic.example/a.jpg","episodeCount":81}]}"#;
    let page = RuleExecutor::new(&document)
        .parse_catalog(body, 1)
        .expect("目录");
    assert_eq!(page.items.len(), 1);
    assert_eq!(page.items[0].id, "guanguo:110000042659853849");
    assert_eq!(page.items[0].views, "65.9万次播放");
    assert_eq!(page.items[0].category, "玄幻仙侠");
    assert!(!page.has_more);

    let detail = r#"{"title":"九转星辰诀","description":"天才少年","vertPoster":"https://pic.example/v.jpg",
        "shortPlayTag":["玄幻仙侠"],"viewedEpisodeNumber":12000,"totalEpisodeCount":2,"data":[
        {"playOrder":1,"title":"第1集","videoClarityList":[
            {"clarity":720,"playUrl":"https://v.example/1-720.mp4"},
            {"clarity":1080,"playUrl":"https://v.example/1-1080.mp4"}]},
        {"playOrder":2,"playUrl":"https://v.example/2.mp4"}
    ]}"#;
    let parsed = RuleExecutor::new(&document);
    let mut target = drama("guanguo", "110000042659853849");
    parsed.fill_drama(detail, &mut target);
    assert_eq!(target.views, "1.2万次播放");
    assert_eq!(target.cover, "https://pic.example/v.jpg");
    assert_eq!(target.episodes, 2);
    let chapters = parsed.parse_chapters(detail, &target).expect("分集");
    assert_eq!(chapters.len(), 2);
    assert_eq!(chapters[0].video_url, "https://v.example/1-1080.mp4");
}

#[test]
fn guanguo_detail_needs_client_info_and_okhttp_agent() {
    let document = RuleDocument::from_json(GUANGUO).expect("观果规则");
    let url = document
        .detail
        .as_ref()
        .expect("detail")
        .url_candidates(&document, &ctx(1, "", "", "110000042659853849"))
        .expect("地址");
    assert!(url.contains("oneId=110000042659853849"), "{url}");
    assert!(url.contains("queryAll=true"), "{url}");
    let marker = url
        .split("clientInfo=")
        .nth(1)
        .expect("clientInfo")
        .split('&')
        .next()
        .expect("clientInfo 值")
        .to_string();
    assert_eq!(marker.len(), 32, "clientInfo 应是 md5 摘要：{marker}");
    assert!(marker.chars().all(|c| c.is_ascii_hexdigit()), "{marker}");

    let catalog = document.catalog.as_ref().expect("catalog");
    let request = document.build_request(&catalog.request, url.clone(), &ctx(2, "玄幻", "", ""));
    assert_eq!(
        request.headers.get("User-Agent").map(String::as_str),
        Some("okhttp/5.1.0")
    );
    assert_eq!(
        request.headers.get("Content-Type").map(String::as_str),
        Some("application/json; charset=utf-8")
    );
    let sent = String::from_utf8(request.body.expect("请求体")).expect("utf8");
    assert!(sent.contains("\"page\":2"), "{sent}");
    assert!(sent.contains("\"pageSize\":30"), "{sent}");
    assert!(sent.contains("\"subject\":\"玄幻\""), "{sent}");
}

#[test]
fn guanguo_reports_empty_detail_as_upstream_issue() {
    let document = RuleDocument::from_json(GUANGUO).expect("观果规则");
    let err = RuleExecutor::new(&document)
        .parse_chapters(r#"{"code":200,"data":[]}"#, &drama("guanguo", "42"))
        .expect_err("空分集要报错");
    assert!(
        matches!(&err, SourceError::Parse { detail, .. } if detail.contains("观果")),
        "{err:?}"
    );
}

#[test]
fn heguo_catalog_reads_next_data_payloads() {
    let document = RuleDocument::from_json(HEGUO).expect("河果规则");
    let html = r#"<html><head><script id="__NEXT_DATA__" type="application/json">
        {"props":{"pageProps":{"page":1,"pages":3,
        "bannerList":[{"bookId":9000,"bookName":"横幅剧","statusDesc":"已完结","totalChapterNum":12}]
        ,"bookList":[{"bookId":9001,"bookName":"河马样本","coverWap":"https://pic.example/a.jpg",
            "statusDesc":"连载中","totalChapterNum":30}]}}}</script></head></html>"#;
    let page = RuleExecutor::new(&document)
        .parse_catalog(html, 1)
        .expect("目录");
    assert_eq!(page.items.len(), 2);
    assert_eq!(page.items[0].id, "heguo:9000");
    assert_eq!(page.items[0].release_status, "finished");
    assert_eq!(page.items[1].release_status, "ongoing");
    assert!(page.has_more);

    let catalog = document.catalog.as_ref().expect("catalog");
    assert_eq!(
        catalog
            .url_candidates(&document, &ctx(2, "417-464", "", ""))
            .expect("分类地址"),
        "https://www.kuaikaw.cn/browse/417-464/2"
    );
    assert_eq!(
        catalog
            .url_candidates(&document, &ctx(1, "", "", ""))
            .expect("首页地址"),
        "https://www.kuaikaw.cn/"
    );
}

#[test]
fn heguo_detail_defers_media_to_episode_pages() {
    let document = RuleDocument::from_json(HEGUO).expect("河果规则");
    let html = r#"<html><script id="__NEXT_DATA__" type="application/json">
        {"props":{"pageProps":{"bookInfoVo":{"bookId":9001,"bookName":"河马样本",
        "coverWap":"https://pic.example/a.jpg","introduction":"简介","statusDesc":"已完结",
        "totalChapterNum":2,"categoryList":[{"name":"甜宠"}]},
        "chapterList":[{"chapterId":"c1","chapterName":"第1集"},{"chapterId":"c2","chapterName":"第2集"}]}}}
        </script></html>"#;
    let parsed = RuleExecutor::new(&document);
    let mut target = drama("heguo", "9001");
    parsed.fill_drama(html, &mut target);
    assert_eq!(target.title, "河马样本");
    assert_eq!(target.category, "甜宠");
    assert_eq!(target.episodes, 2);
    let chapters = parsed.parse_chapters(html, &target).expect("分集");
    assert_eq!(chapters.len(), 2);
    assert!(chapters[0].video_url.is_empty());
    assert_eq!(
        chapters[0].page_url,
        "https://www.kuaikaw.cn/episode/9001/c1"
    );

    let episode = r#"<html><script id="__NEXT_DATA__" type="application/json">
        {"props":{"pageProps":{"chapterInfo":{"chapterVideoVo":{"mp4":"https://v.example/ep.mp4"}}}}}
        </script></html>"#;
    assert_eq!(
        parsed.media_url(episode).as_deref(),
        Some("https://v.example/ep.mp4")
    );
}

#[test]
fn heguo_search_accepts_plain_json_response() {
    let document = RuleDocument::from_json(HEGUO).expect("河果规则");
    let body = r#"{"code":200,"data":{"bookList":[{"bookId":9002,"bookName":"搜索结果","totalChapterNum":5}]}}"#;
    let page = RuleExecutor::new(&document)
        .parse_search(body, 1)
        .expect("搜索");
    assert_eq!(page.items.len(), 1);
    assert_eq!(page.items[0].id, "heguo:9002");
    assert_eq!(page.items[0].episodes, 5);

    let search = document.search.as_ref().expect("search");
    let request = document.build_request(
        &search.request,
        "https://www.kuaikaw.cn/seo/video/6007".into(),
        &ctx(1, "", "河马", ""),
    );
    assert_eq!(
        request.headers.get("pname").map(String::as_str),
        Some("www.kuaikaw.cn")
    );
    let sent = String::from_utf8(request.body.expect("请求体")).expect("utf8");
    assert!(sent.contains("\"sourceType\":1"), "{sent}");
    assert!(sent.contains("\"keyword\":\"河马\""), "{sent}");
}
