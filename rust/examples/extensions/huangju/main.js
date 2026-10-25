// 剧果（huangju.net）扩展 —— 脚本型站源。
//
// 由 `crates/source-huangju`（527 行 Rust，已删除）迁移而来，行为以
// `bridge/tests/huangju_fixtures.rs` 的夹具测试与 `huangju_live.rs` 锁定。
//
// 难点不在加密而在**会话与凭证**：
// 1. 所有接口都要访客令牌（POST /auth/guest，deviceId 为 UUID v4）；
//    过期（401/403）后丢弃并重新申请一次；
// 2. 详情按 `slug`（如 `yanyu-2788`）取，不是数字 id；
// 3. 取流响应会下发 CDN 签名 Cookie，播放列表与分片必须带着它。
//
// 与编译版的差异：脚本没有跨调用内存态，令牌与设备标识走 `ctx.store`
// 落盘（编译版每次进程重启都重新注册访客，脚本形态下顺带减少了注册次数；
// 401 时设备标识一并丢弃，与编译版「重新生成设备号」一致）。

var API_BASE = 'https://api.huangju.net';
var SITE = 'https://huangju.net';
var USER_AGENT =
    'Mozilla/5.0 (Linux; Android 11; Pixel 5) AppleWebKit/537.36 ' +
    '(KHTML, like Gecko) Chrome/90.0.4430.91 Mobile Safari/537.36';
// 目录页固定 20 条，与接口默认值一致。
var PAGE_SIZE = 20;
// 「最新」分类用排序而不是分类过滤，与 Web 端一致。
var NEWEST = '__newest';
var TOKEN_KEY = 'token';
var COOKIE_ATTRIBUTES = ['domain', 'path', 'expires', 'max-age', 'secure', 'httponly', 'samesite'];

function describe() {
    return {
        id: 'huangju',
        name: '剧果',
        group: 'duanju',
        apiLevel: 1,
        contentTypes: ['short-drama'],
    };
}

// ---- 工具 ----

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

function parseJson(body, what) {
    try { return JSON.parse(body); } catch (err) {
        throw new Error(what + ' 响应不是 JSON：' + String(body).slice(0, 120));
    }
}

// 百分号编码：只保留 RFC 3986 非保留字符（encodeURIComponent 会放过 !'()*，补上）。
function encodeComponent(value) {
    return encodeURIComponent(String(value)).replace(
        /[!'()*]/g,
        function (ch) { return '%' + ch.charCodeAt(0).toString(16).toUpperCase(); }
    );
}

// ---- 访客令牌：store 落盘 → 申请；401 时连设备标识一起换 ----

// UUID v4。Math.random 由运行时用系统熵播种；只做设备标识，不追求密码学强度。
function uuidV4() {
    var bytes = [];
    for (var i = 0; i < 16; i++) { bytes.push(Math.floor(Math.random() * 256)); }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    var out = '';
    for (var j = 0; j < 16; j++) {
        if (j === 4 || j === 6 || j === 8 || j === 10) { out += '-'; }
        out += (bytes[j] < 16 ? '0' : '') + bytes[j].toString(16);
    }
    return out;
}

function readSession() {
    var raw = ctx.store.get(TOKEN_KEY);
    if (!raw) { return null; }
    try {
        var saved = JSON.parse(raw);
        if (saved && typeof saved.token === 'string' && saved.token) { return saved; }
    } catch (err) { /* 落盘内容损坏按未登录处理 */ }
    return null;
}

// token 为空表示显式失效：下次调用会生成新设备号重新申请。
function writeSession(device, token) {
    ctx.store.set(TOKEN_KEY, JSON.stringify(token ? { device: device, token: token } : {}));
}

function guestToken() {
    var saved = readSession();
    if (saved && saved.token) { return saved.token; }
    var device = uuidV4();
    var res = ctx.fetch({
        url: API_BASE + '/auth/guest',
        method: 'post',
        headers: {
            'Content-Type': 'application/json',
            'User-Agent': USER_AGENT,
            'Referer': SITE + '/',
            'Origin': SITE,
        },
        body: JSON.stringify({ deviceId: device }),
    });
    var value = parseJson(res.body, 'huangju.auth');
    var token = String(
        (value && value.token) || (value && value.data && value.data.token) || ''
    ).replace(/^\s+|\s+$/g, '');
    if (!token || token.length > 8192) {
        throw new Error('huangju.auth 未返回有效的访客授权');
    }
    writeSession(device, token);
    return token;
}

// 带令牌请求；401/403 时丢弃令牌重试一次（与编译版两次尝试一致）。
function getJson(path, what) {
    for (var attempt = 0; attempt < 2; attempt++) {
        var token = guestToken();
        var res = ctx.fetch({
            url: API_BASE + path,
            headers: {
                'Authorization': 'Bearer ' + token,
                'User-Agent': USER_AGENT,
                'Accept': 'application/json, text/plain, */*',
                'Referer': SITE + '/',
                'Origin': SITE,
            },
        });
        if (res.status === 401 || res.status === 403) {
            if (attempt === 0) {
                writeSession(null, null);
                continue;
            }
            throw new Error('huangju.auth 访客授权失效，请重试');
        }
        return parseJson(res.body, 'huangju.' + what);
    }
    throw new Error('huangju.auth 访客授权失效，请重试');
}

// ---- 分类 / 目录 / 详情 / 搜索 / 取流 ----

// 站点的分类列表没有独立接口（编译版声明了能力位但默认实现返回空）；
// 目录用 category=<名> 过滤，最新用 sort=new。
function categories() {
    return [];
}

function catalogPath(category, page) {
    page = Math.max(page, 1);
    category = String(category || '').replace(/^\s+|\s+$/g, '');
    var filter;
    if (!category) {
        filter = 'sort=hot&page=' + page;
    } else if (category === NEWEST) {
        filter = 'sort=new&page=' + page;
    } else {
        filter = 'category=' + encodeComponent(category) + '&page=' + page;
    }
    return '/dramas?' + filter;
}

function hasMoreFrom(value, page, itemsLen) {
    var pageSize = Math.max(Number(value.pageSize) || PAGE_SIZE, 1);
    if (typeof value.total === 'number') {
        return page * pageSize < value.total;
    }
    return itemsLen >= pageSize;
}

function itemsFrom(value, what) {
    var rows = value.items;
    if (!Array.isArray(rows)) { throw new Error('huangju.' + what + ' 缺少 items'); }
    var out = [];
    for (var i = 0; i < rows.length; i++) { out.push(dramaFromNode(rows[i])); }
    return out;
}

function catalog(input) {
    var page = Math.max(Number(input.page) || 1, 1);
    var value = getJson(catalogPath(input.category, page), 'catalog');
    var items = itemsFrom(value, 'catalog');
    return { items: items, hasMore: hasMoreFrom(value, page, items.length), page: page };
}

function detail(input) {
    var sourceId = String(input.id || '');
    var value = getJson('/dramas/' + encodeComponent(sourceId), 'detail');
    var drama = dramaFromNode(value);

    var episodes = value.episodes;
    if (!Array.isArray(episodes)) { throw new Error('huangju.detail 缺少 episodes'); }
    var chapters = [];
    for (var i = 0; i < episodes.length; i++) {
        var node = episodes[i];
        var id = pick(node, ['id']);
        if (!id) { continue; }
        // epNo 缺失时按下标补位；分集存的是数字 id，取流时拼进 /play/<id>。
        var number = typeof node.epNo === 'number' && node.epNo > 0 ? node.epNo : i + 1;
        var title = pick(node, ['title']);
        chapters.push({
            id: sourceId + ':' + number,
            title: title || ('第' + number + '集'),
            videoUrl: id,
            referer: SITE + '/',
        });
    }
    // 按分集号稳定排序；无法解析的排最后（与编译版 u32::MAX 兜底一致）。
    chapters.sort(function (left, right) {
        var toNumber = function (id) {
            var tail = id.slice(id.lastIndexOf(':') + 1);
            return /^\d+$/.test(tail) ? Number(tail) : Infinity;
        };
        return toNumber(left.id) - toNumber(right.id);
    });
    if (!chapters.length) { throw new Error('huangju.detail 未返回可播放分集'); }
    return { drama: drama, chapters: chapters };
}

function search(input) {
    var query = String(input.query || '').replace(/^\s+|\s+$/g, '');
    if (!query) {
        return { items: [], hasMore: false, page: Math.max(Number(input.page) || 1, 1) };
    }
    var page = Math.max(Number(input.page) || 1, 1);
    var value = getJson('/dramas?q=' + encodeComponent(query) + '&page=' + page, 'search');
    var items = itemsFrom(value, 'search');
    return { items: items, hasMore: hasMoreFrom(value, page, items.length), page: page };
}

// 取流：/play/<分集数字 id>，响应下发 CDN 签名 Cookie，要带给播放器。
function resolve(input) {
    var chapter = input.chapter || {};
    var episodeId = String(chapter.videoUrl || '').replace(/^\s+|\s+$/g, '');
    if (!episodeId) {
        throw new Error('huangju.resolve 分集缺少播放标识，请刷新详情后重试');
    }
    var token = guestToken();
    var res = ctx.fetch({
        url: API_BASE + '/play/' + encodeComponent(episodeId),
        headers: {
            'Authorization': 'Bearer ' + token,
            'User-Agent': USER_AGENT,
            'Referer': SITE + '/',
            'Origin': SITE,
        },
    });
    if (res.status < 200 || res.status >= 300) {
        throw new Error('huangju.resolve HTTP ' + res.status + '：' + String(res.body).slice(0, 120));
    }
    var value = parseJson(res.body, 'huangju.resolve');
    var url = pick(value, ['url']);
    if (!url) { throw new Error('huangju.resolve 未返回播放地址'); }
    return { url: url, referer: SITE + '/', cookies: cookieHeader(res.headers), origin: SITE };
}

// ---- 字段映射 ----

// status：completed → finished；ongoing 原样。
function dramaFromNode(node) {
    var sourceId = pick(node, ['slug']);
    if (!sourceId) { throw new Error('huangju 条目缺少 slug'); }
    var status = pick(node, ['status']);
    return {
        sourceId: sourceId,
        title: pick(node, ['title']),
        description: pick(node, ['description']),
        cover: pick(node, ['coverUrl']),
        episodes: Number(node.totalEpisodes) || 0,
        category: pick(node, ['category']),
        releaseStatus: status === 'completed' ? 'finished' : status === 'ongoing' ? 'ongoing' : '',
    };
}

// 传输层把多条 set-cookie 用换行拼进同一个键；只取 name=value，丢掉属性。
function cookieHeader(headers) {
    var raw = headers && headers['set-cookie'];
    if (!raw) { return ''; }
    var pairs = [];
    var lines = String(raw).split('\n');
    for (var i = 0; i < lines.length; i++) {
        var pair = lines[i].split(';')[0];
        var eq = pair.indexOf('=');
        if (eq <= 0) { continue; }
        var name = pair.slice(0, eq).replace(/^\s+|\s+$/g, '');
        var value = pair.slice(eq + 1).replace(/^\s+|\s+$/g, '');
        if (!name || !value || isCookieAttribute(name)) { continue; }
        pairs.push(name + '=' + value);
    }
    return pairs.join('; ');
}

function isCookieAttribute(name) {
    return COOKIE_ATTRIBUTES.indexOf(name.toLowerCase()) !== -1;
}
