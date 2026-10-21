//! 用 Go 版真实页面片段对拍红果的解析结果。
//!
//! 夹具取自 Go 测试里构造的 `_ROUTER_DATA` 结构（字段名与层级保持一致），
//! 目的不是「能解析」，而是「与 Go 解出同样的值」。

use guo_source_hongguo::{parse_router_data, router_loader_map, HongguoDrama, HongguoSource};

/// 分类页：包含 `video_data` 包裹与直接字段两种形态。
const CATEGORY_PAGE: &str = r#"<!DOCTYPE html><html><head><script>window._ROUTER_DATA = {"loaderData":{"category_$id":{"isSuccess":true,"recommendList":[
  {"video_data":{"series_id":9001,"series_title":"总裁的替身新娘","series_intro":"一场意外的替身婚姻","series_cover":"https://p3.test/9001.jpg","episode_cnt":"80","episode_right_text":"全80集","series_status":"1","tags":["都市","甜宠"],"series_play_cnt":"234567890"}},
  {"video_data":{"series_id":"9002","series_title":"重生之都市战神","episode_cnt":"60","episode_right_text":"更新至60集","series_status":"0","category_list":[{"name":"逆袭"}]}},
  {"video_data":{"series_id":"not-a-number","series_title":"无效条目"}},
  {"series_id":9003,"series_name":"顶层字段形态","episode_cnt":"12"}
],"pagination":{"totalPages":"7"}}}};</script></head><body></body></html>"#;

#[test]
fn category_page_matches_go_field_mapping() {
    let (dramas, total) =
        HongguoSource::parse_category_page(CATEGORY_PAGE, "真人剧").expect("解析成功");
    assert_eq!(total, 7, "totalPages 必须被读出");
    assert_eq!(dramas.len(), 3, "无效 id 条目必须被丢弃");

    let first = &dramas[0];
    assert_eq!(first.series_id, "9001");
    assert_eq!(first.title, "总裁的替身新娘");
    assert_eq!(first.description, "一场意外的替身婚姻");
    assert_eq!(first.cover, "https://p3.test/9001.jpg");
    assert_eq!(first.episodes, 80);
    assert_eq!(first.tags, vec!["都市", "甜宠"]);
    assert_eq!(first.release_status, "finished");
    assert_eq!(first.views, "234567890");
    assert_eq!(first.heat, "2.3亿");

    let second = &dramas[1];
    assert_eq!(second.release_status, "ongoing");
    assert_eq!(second.tags, vec!["逆袭"]);
    assert_eq!(second.category, "逆袭", "没有 category_name 时用首个 tag");

    let third = &dramas[2];
    assert_eq!(third.title, "顶层字段形态");
    assert_eq!(third.category, "真人剧", "顶层条目没有分类时用传入的路由名");
}

#[test]
fn category_page_without_router_data_is_an_error() {
    let err = HongguoSource::parse_category_page("<html><body>404</body></html>", "真人剧")
        .expect_err("必须失败");
    assert!(err.to_string().contains("_ROUTER_DATA"), "{err}");
}

#[test]
fn category_page_with_failed_flag_is_an_error() {
    let body = r#"<script>window._ROUTER_DATA = {"loaderData":{"category_page":{"isSuccess":false}}};</script>"#;
    let err = HongguoSource::parse_category_page(body, "真人剧").expect_err("必须失败");
    assert!(err.to_string().contains("isSuccess"), "{err}");
}

/// 详情页：`vid_list` 可能是字符串数组，也可能是数字数组。
const DETAIL_PAGE: &str = r#"<script>window._ROUTER_DATA = {"loaderData":{"detail_page":{"seriesDetail":{
  "series_name":"总裁的替身新娘","vid_list":["7001","7002",7003,""]}}}};</script>"#;

#[test]
fn detail_page_matches_go_chapter_shape() {
    let (title, chapters) =
        HongguoSource::parse_detail_page(DETAIL_PAGE, "9001").expect("解析成功");
    assert_eq!(title, "总裁的替身新娘");
    assert_eq!(chapters.len(), 3, "空 vid 必须被跳过");
    assert_eq!(chapters[0].video_url, "hongguo-cenc://7001");
    assert_eq!(chapters[1].title, "第2集");
    assert_eq!(chapters[2].video_url, "hongguo-cenc://7003");
    for chapter in &chapters {
        assert_eq!(chapter.source, "9001");
    }
}

#[test]
fn detail_page_without_vid_list_reports_actionable_error() {
    let body = r#"<script>window._ROUTER_DATA = {"loaderData":{"detail_page":{"seriesDetail":{"series_name":"x"}}}};</script>"#;
    let err = HongguoSource::parse_detail_page(body, "9001").expect_err("必须失败");
    assert!(err.to_string().contains("剧集 ID"), "{err}");
}

/// 播放页：地址藏在 `video_player_info` 的多层结构里。
const PLAYER_PAGE: &str = r#"<script>window._ROUTER_DATA = {"loaderData":{"player_page":{
  "vid":"7001","series_id":"9001","video_player_info":{
    "duration":"125.5","video_list":[{"main_url":"https://v.test/play/7001.m3u8","backup_url":"https://v2.test/play/7001.m3u8"}]
  }}}};</script>"#;

#[test]
fn player_page_matches_go_media_shape() {
    let media = HongguoSource::parse_player_page(PLAYER_PAGE, "9001", "7001").expect("解析成功");
    assert_eq!(media.url, "https://v.test/play/7001.m3u8");
    assert_eq!(media.referer, "https://hongguoduanju.com/");
    assert!(media.playlist.is_none(), "取流层不在这里展开播放列表");
}

#[test]
fn player_page_rejects_preview_substitution() {
    // Go 版的关键约束：返回的 vid 与请求不一致时不得当成目标集下载。
    let body = r#"<script>window._ROUTER_DATA = {"loaderData":{"player_page":{"vid":"9999","series_id":"9001","video_player_info":{"video_list":[{"main_url":"https://v.test/preview.m3u8"}]}}}};</script>"#;
    let err = HongguoSource::parse_player_page(body, "9001", "7001").expect_err("必须失败");
    assert!(err.to_string().contains("试看"), "{err}");
}

#[test]
fn router_loader_map_falls_back_to_prefix() {
    let data = parse_router_data(CATEGORY_PAGE).expect("router data");
    // 夹具里的键是 `category_$id`，精确名不存在，必须靠前缀命中。
    let page = router_loader_map(&data, &["category_page", "category_$"]).expect("page");
    assert_eq!(page["isSuccess"], true);
}

#[test]
fn drama_identity_is_source_prefixed() {
    let value: serde_json::Value =
        serde_json::from_str(r#"{"series_id":9001,"series_title":"x"}"#).expect("json");
    let drama = HongguoDrama::from_value(&value, "真人剧")
        .expect("drama")
        .into_drama();
    assert_eq!(drama.id, "hongguo:9001");
    assert_eq!(drama.source, "hongguo");
    assert_eq!(drama.source_id, "9001");
}
