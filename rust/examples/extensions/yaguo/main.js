// 芽果（星芽）扩展 —— 脚本型站源。
//
// 由 `crates/source-yaguo`（773 行 Rust，已删除）迁移而来，行为以
// `bridge/tests/yaguo_fixtures.rs` 的夹具测试与 `yaguo_live.rs` 实网金丝雀锁定。
//
// 三个链路特征（与编译版一致）：
// 1. 业务接口都要设备登录令牌，有效期 6 小时；失效（401/403）重新登录一次；
// 2. 分类是 `theater/classes` 的顶层分组，其中 `9`（排行榜）走独立接口；
// 3. 分集直接给出 MP4 地址，取流只做透传。
//
// 与编译版的一个实现差异：脚本每次调用都是全新 JS 运行时，没有跨调用的
// 内存态，因此令牌缓存完全走 `ctx.store` 落盘（引擎按 source_id 命名空间
// 持久化，重启后复用），落盘格式沿用编译版的 `{value, obtained_at}`。

var BASE = 'https://app.whjzjx.cn';
var LOGIN_URL = 'https://u.shytkjgs.com/user/v1/account/login';
// Go 版固定使用的设备号，登录端点只认它。
var DEVICE = '24250683a3bdb3f118dff25ba4b1cba1a';
var USER_AGENT =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
    '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
var PLATFORM = '1';
var VERSION_NAME = '3.8.3.1';
var PAGE_SIZE = 24;
var TOKEN_TTL_SECS = 6 * 60 * 60;
var TOKEN_KEY = 'token';
// 同一设备号并发登录时服务端返回 2010007（系统繁忙），隔一会重试即可。
var BUSY_CODE = '2010007';
var LOGIN_ATTEMPTS = 3;
// 分类 9 是榜单，走 /cloud/v1/first_level_ranking/detail。
var RANKING_CATEGORY = '9';
var RANKING_ID = '1';

function describe() {
    return {
        id: 'yaguo',
        name: '芽果',
        group: 'duanju',
        apiLevel: 1,
        contentTypes: ['short-drama'],
    };
}

// ---- 工具：与编译版逐字对齐 ----

// 兼容字符串与数字两种标量；数字用于 id / total 这类字段。
function pick(node, keys) {
    if (!node || typeof node !== 'object') { return ''; }
    for (var i = 0; i < keys.length; i++) {
        var value = node[keys[i]];
        if (value === undefined || value === null) { continue; }
        if (typeof value === 'string') {
            var text = value.replace(/^\s+|\s+$/g, '');
            if (text) { return text; }
        } else if (typeof value === 'number') {
            return String(value);
        }
    }
    return '';
}

function truthy(value) {
    if (value === true) { return true; }
    if (typeof value === 'string') { return value === 'true' || value === '1'; }
    if (typeof value === 'number') { return value !== 0; }
    return false;
}

// 百分号编码：只保留 RFC 3986 非保留字符，其余按 UTF-8 逐字节转义。
// encodeURIComponent 会额外放过 !'()*，补上即可与编译版逐字一致。
function encodeComponent(value) {
    return encodeURIComponent(String(value)).replace(
        /[!'()*]/g,
        function (ch) { return '%' + ch.charCodeAt(0).toString(16).toUpperCase(); }
    );
}

// ---- 令牌：内存态不存在，三级回落改成「store → 登录」两级 ----

// 落盘结构沿用编译版 SavedToken：{value, obtained_at}（秒级时间戳）。
function readToken() {
    var raw = ctx.store.get(TOKEN_KEY);
    if (!raw) { return null; }
    var saved;
    try { saved = JSON.parse(raw); } catch (err) { return null; }
    if (!saved || typeof saved.value !== 'string') { return null; }
    var age = ctx.now() / 1000 - Number(saved.obtained_at || 0);
    if (!(age >= 0) || age >= TOKEN_TTL_SECS) { return null; }
    var value = saved.value.replace(/^\s+|\s+$/g, '');
    if (!value || value.length > 8192) { return null; }
    return value;
}

function writeToken(value) {
    var payload = value
        ? { value: value, obtained_at: Math.floor(ctx.now() / 1000) }
        : { value: '', obtained_at: 0 };
    ctx.store.set(TOKEN_KEY, JSON.stringify(payload));
}

// 设备登录。繁忙（2010007）时重试；编译版的 250ms 间隔在脚本里没有
// 对应原语，直接连续重试（夹具验证三次内成功）。
function login() {
    var detail = '未返回有效的访问令牌';
    var body = JSON.stringify({ device: DEVICE });
    for (var attempt = 0; attempt < LOGIN_ATTEMPTS; attempt++) {
        var res = ctx.fetch({
            url: LOGIN_URL,
            method: 'post',
            headers: {
                'Content-Type': 'application/json',
                'platform': PLATFORM,
                'User-Agent': USER_AGENT,
            },
            body: body,
        });
        var value;
        try { value = JSON.parse(res.body); } catch (err) {
            throw new Error('yaguo.auth 登录响应不是 JSON：' + String(res.body).slice(0, 120));
        }
        var token = String(
            (value && value.data && value.data.token) || (value && value.token) || ''
        ).replace(/^\s+|\s+$/g, '');
        if (token && token.length <= 8192) {
            writeToken(token);
            return token;
        }
        if (value && value.msg) { detail = String(value.msg); }
        if (!value || value.code !== BUSY_CODE) { break; }
    }
    throw new Error('yaguo.auth ' + detail);
}

// ---- 带令牌的请求；401/403 丢弃令牌、重新登录并重试一次 ----

function api(request, token) {
    var headers = {};
    if (request.headers) {
        for (var key in request.headers) { headers[key] = request.headers[key]; }
    }
    headers['authorization'] = token;
    headers['platform'] = PLATFORM;
    headers['version_name'] = VERSION_NAME;
    headers['User-Agent'] = USER_AGENT;
    headers['Referer'] = BASE + '/';
    var signed = { url: request.url, method: request.method, headers: headers };
    if (request.body !== undefined) { signed.body = request.body; }
    return ctx.fetch(signed);
}

function requestJson(request, what) {
    var token = readToken();
    if (!token) { token = login(); }
    var res = api(request, token);
    if (res.status === 401 || res.status === 403) {
        writeToken(null);
        token = login();
        res = api(request, token);
    }
    if (res.status < 200 || res.status >= 300) {
        throw new Error('yaguo.' + what + ' ' + request.url + ' HTTP ' + res.status);
    }
    try { return JSON.parse(res.body); } catch (err) {
        throw new Error('yaguo.' + what + ' 响应不是 JSON：' + String(res.body).slice(0, 120));
    }
}

// ---- 分类 / 目录 / 详情 / 搜索 / 取流 ----

function categories() {
    var value = requestJson({ url: BASE + '/cloud/v2/theater/classes' }, 'categories');
    var groups = (value.data && value.data.list) || [];
    var seen = {};
    var out = [];
    for (var i = 0; i < groups.length; i++) {
        var group = groups[i];
        var id = pick(group, ['id']);
        var name = pick(group, ['class_name', 'name']);
        if (!id || !name || name.length > 24 || seen[id]) { continue; }
        seen[id] = true;
        out.push({ id: id, name: name });
    }
    if (!out.length) { throw new Error('yaguo.categories 未返回有效分类'); }
    return out;
}

function catalogRequest(category, page) {
    category = String(category || '').replace(/^\s+|\s+$/g, '');
    if (category === RANKING_CATEGORY) {
        return { url: BASE + '/cloud/v1/first_level_ranking/detail?id=' + RANKING_ID };
    }
    var isDigits = /^\d+$/.test(category);
    var cls = category && isDigits ? category : '';
    return {
        url: BASE + '/cloud/v2/theater/home_page?theater_class_id=' + cls +
            '&type=1&class2_ids=0&page_num=' + Math.max(page, 1) + '&page_size=' + PAGE_SIZE,
    };
}

function catalog(input) {
    var page = Math.max(Number(input.page) || 1, 1);
    var category = String(input.category || '');
    var ranking = category.replace(/^\s+|\s+$/g, '') === RANKING_CATEGORY;
    var value = requestJson(catalogRequest(category, page), 'catalog');
    var data = value.data;
    if (!data || typeof data !== 'object' || Array.isArray(data)) {
        throw new Error('yaguo.catalog 缺少 data');
    }
    var rows = data.list || [];
    var items = [];
    for (var i = 0; i < rows.length; i++) {
        var drama = dramaFromNode(rows[i]);
        if (drama) { items.push(drama); }
    }
    var hasMore = false;
    if (!ranking) {
        var total = Number(pick(data, ['total'])) || 0;
        hasMore = !truthy(data.is_end) && items.length > 0 && total > page * items.length;
    }
    return { items: items, hasMore: hasMore, page: page };
}

function detail(input) {
    var sourceId = String(input.id || '');
    var value = requestJson(
        { url: BASE + '/v2/theater_parent/detail?theater_parent_id=' + encodeComponent(sourceId) },
        'detail'
    );
    var data = value.data;
    if (!data || typeof data !== 'object' || Array.isArray(data)) {
        throw new Error('yaguo.detail 缺少剧集资料');
    }
    var drama = dramaFromFields(data);
    drama.releaseStatus = releaseStatus(data);
    var chapters = chaptersFrom(data, sourceId);
    if (!chapters.length) { throw new Error('yaguo.detail 未返回可播放分集'); }
    drama.episodes = chapters.length;
    return { drama: drama, chapters: chapters };
}

function search(input) {
    var query = String(input.query || '').replace(/^\s+|\s+$/g, '');
    if (!query) {
        return { items: [], hasMore: false, page: Math.max(Number(input.page) || 1, 1) };
    }
    var value = requestJson({
        url: BASE + '/v3/search',
        method: 'post',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ text: query }),
    }, 'search');
    var theater = value.data && value.data.theater;
    var rows = (theater && theater.search_data) || (value.data && value.data.list);
    if (!rows) { throw new Error('yaguo.search 缺少搜索列表'); }
    var items = [];
    for (var i = 0; i < rows.length; i++) {
        var drama = dramaFromNode(rows[i]);
        if (drama) { items.push(drama); }
    }
    return { items: items, hasMore: false, page: Math.max(Number(input.page) || 1, 1) };
}

// 直链透传：分集自带 MP4 地址，无需再请求。
function resolve(input) {
    var chapter = input.chapter || {};
    var url = String(chapter.videoUrl || '').replace(/^\s+|\s+$/g, '');
    if (!url) { throw new Error('yaguo.resolve 分集缺少播放地址，请刷新详情后重试'); }
    var referer = String(chapter.referer || '').replace(/^\s+|\s+$/g, '') || BASE + '/';
    return { url: url, referer: referer };
}

// ---- 字段映射 ----

// 列表条目既可能是 {"theater": {...}}（目录），也可能是剧目字段本身（搜索、榜单）。
function dramaFromNode(node) {
    var target = node && node.theater && typeof node.theater === 'object' ? node.theater : node;
    if (!target || typeof target !== 'object') { return null; }
    var drama = dramaFromFields(target);
    if (!drama.sourceId) { return null; }
    return drama;
}

function dramaFromFields(node) {
    return {
        sourceId: pick(node, ['id', 'theater_id', 'theater_parent_id']),
        title: pick(node, ['title', 'name']),
        description: pick(node, ['descrip', 'introduction', 'desc']),
        cover: cover(node),
        episodes: Number(pick(node, ['total', 'total_num', 'current_num'])) || 0,
        category: tags(node).join(', '),
    };
}

function chaptersFrom(data, sourceId) {
    var theaters = data.theaters;
    if (!Array.isArray(theaters)) { return []; }
    var rows = [];
    for (var index = 0; index < theaters.length; index++) {
        var node = theaters[index];
        var videoUrl = pick(node, ['son_video_url', 'video_url']);
        if (!videoUrl) { continue; }
        var number = Number(pick(node, ['num', 'sort']));
        if (!(number > 0)) { number = index + 1; }
        var title = pick(node, ['son_title', 'title']);
        if (!title) { title = '第' + number + '集'; }
        rows.push({
            number: number,
            chapter: {
                id: sourceId + ':' + number,
                title: title,
                videoUrl: videoUrl,
                referer: BASE + '/',
            },
        });
    }
    // 稳定排序，与编译版 sort_by_key 一致。
    rows.sort(function (left, right) { return left.number - right.number; });
    var out = [];
    for (var i = 0; i < rows.length; i++) { out.push(rows[i].chapter); }
    return out;
}

function releaseStatus(node) {
    var isOver = Number(pick(node, ['is_over'])) || 0;
    var total = Number(pick(node, ['total'])) || 0;
    var current = Number(pick(node, ['current_num'])) || 0;
    if (isOver === 2) { return 'finished'; }
    if (isOver === 1) { return 'ongoing'; }
    if (total > 0 && current >= total) { return 'finished'; }
    if (current > 0) { return 'ongoing'; }
    return '';
}

function cover(node) {
    var keys = ['cover_url', 'son_cover_url', 'cover'];
    for (var i = 0; i < keys.length; i++) {
        var value = coverValue(node ? node[keys[i]] : undefined);
        if (value) { return value; }
    }
    return '';
}

// 封面可能是字符串、数组或 {url} 对象，递归取第一个非空并补全为绝对地址。
function coverValue(value) {
    if (value === null || value === undefined) { return ''; }
    if (typeof value === 'string') { return absoluteUrl(value); }
    if (Array.isArray(value)) {
        for (var i = 0; i < value.length; i++) {
            var item = coverValue(value[i]);
            if (item) { return item; }
        }
        return '';
    }
    if (typeof value === 'object') {
        var keys = ['url', 'contentUrl', 'thumbnailUrl'];
        for (var j = 0; j < keys.length; j++) {
            var found = coverValue(value[keys[j]]);
            if (found) { return found; }
        }
    }
    return '';
}

function absoluteUrl(value) {
    value = String(value || '').replace(/^\s+|\s+$/g, '');
    if (!value) { return ''; }
    if (value.indexOf('http://') === 0 || value.indexOf('https://') === 0) { return value; }
    if (value.indexOf('//') === 0) { return 'https:' + value; }
    return BASE + '/' + value.replace(/^\/+/, '');
}

function tags(node) {
    var rows = node ? node.tags : undefined;
    if (!Array.isArray(rows)) { return []; }
    var out = [];
    for (var i = 0; i < rows.length; i++) {
        var row = rows[i];
        if (typeof row === 'string') {
            var text = row.replace(/^\s+|\s+$/g, '');
            if (text) { out.push(text); }
        } else if (row && typeof row === 'object') {
            var name = pick(row, ['name', 'title', 'class_name']);
            if (name) { out.push(name); }
        }
    }
    return out;
}
