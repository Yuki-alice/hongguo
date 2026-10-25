// 猫果（七猫）扩展 —— 脚本型站源试点。
//
// 这是 `kind = "script"` 的第一个真实样本，也是后续扩展的模板：
// - 顶层 `function xxx(input) {}` 即为导出，宿主加载期自动探测；
// - 没有导出的能力，宿主报 `Unsupported`，UI 按能力位隐藏入口；
// - crypto 用宿主提供的 `crypto.md5`；需要 AES 等算法时随包自带实现。
//
// 签名规则与 `crates/source-maoguo/src/maoguo.rs` 逐字对齐，
// 由 `bridge/tests/script_maoguo_parity.rs` 做对拍。

var BASE = 'https://api-store.qmplaylet.com';
var READ_BASE = 'https://api-read.qmplaylet.com';
var KEY = 'd3dGiJc651gSQ8w1';
var TRACK_ID = 'ec1280db127955061754851657967';

function describe() {
    return {
        id: 'maoguo',
        name: '猫果',
        group: 'duanju',
        apiLevel: 1,
        contentTypes: ['short-drama'],
    };
}

// ---- 签名：MD5 拼串，与编译版同源 ----

function signCatalog(tagId, page) {
    var text = 'operation=1playlet_privacy=1tag_id=' + tagId;
    if (page > 1) { text += 'next_id=' + page; }
    return crypto.md5(text + KEY);
}

function signDetail(sourceId) {
    return crypto.md5('playlet_id=' + sourceId + KEY);
}

function signSearch(query) {
    return crypto.md5('extend=page=1read_preference=0track_id=' + TRACK_ID + 'wd=' + query + KEY);
}

function signTags() {
    return crypto.md5('operation=1' + KEY);
}

// 供对拍测试直接调用。
function signatures(input) {
    return {
        catalog: signCatalog(input.tagId || '0', input.page || 1),
        detail: signDetail(input.sourceId || '0'),
        search: signSearch(input.query || ''),
        tags: signTags(),
    };
}

// ---- 请求头：qm-params 设备指纹 + authorization 签名 ----
//
// 编译版在 `crates/source-maoguo/src/maoguo.rs` 里做同样的事：设备信息 JSON
// → Base64 → 字符映射，再对整串做一次授权签名。**签名对了但请求头没带，
// 等于没签名**——站点会直接返回 `44010120 验签失败`，这是排查此源时最容易
// 走错的岔路（曾经把它误判成「站点改了签名规则」）。
//
// 这段代码也是「复杂站点能不能只用 JS 表达」的实测样本：只依赖宿主给的
// `crypto.md5`，Base64 与字符映射随包自带。

var B64_TABLE = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

// 七猫的 `qm-params` 字符映射表：Base64 结果整体替换后才参与签名。
var CHAR_MAP = {
    '+': 'P',
    '/': 'X',
    '0': 'M',
    '1': 'U',
    '2': 'l',
    '3': 'E',
    '4': 'r',
    '5': 'Y',
    '6': 'W',
    '7': 'b',
    '8': 'd',
    '9': 'J',
    'A': '9',
    'B': 's',
    'C': 'a',
    'D': 'I',
    'E': '0',
    'F': 'o',
    'G': 'y',
    'H': '_',
    'I': 'H',
    'J': 'G',
    'K': 'i',
    'L': 't',
    'M': 'g',
    'N': 'N',
    'O': 'A',
    'P': '8',
    'Q': 'F',
    'R': 'k',
    'S': '3',
    'T': 'h',
    'U': 'f',
    'V': 'R',
    'W': 'q',
    'X': 'C',
    'Y': '4',
    'Z': 'p',
    'a': 'm',
    'b': 'B',
    'c': 'O',
    'd': 'u',
    'e': 'c',
    'f': '6',
    'g': 'K',
    'h': 'x',
    'i': '5',
    'j': 'T',
    'k': '-',
    'l': '2',
    'm': 'z',
    'n': 'S',
    'o': 'Z',
    'p': '1',
    'q': 'V',
    'r': 'v',
    's': 'j',
    't': 'Q',
    'u': '7',
    'v': 'D',
    'w': 'w',
    'x': 'n',
    'y': 'L',
    'z': 'e'
};

// 设备信息固定不变，只有 session-id 取当前毫秒。键按字典序排列——与
// 编译版 `serde_json` 的输出逐字节一致，这样两边能直接对拍。
var QM_BEFORE = '{"brand":"Redmi","client-id":"aa7de295aad621a6","device-id":"20250220125449b9b8cac84c2dd3d035c9052a2572f7dd0122edde3cc42a70","imei":"","mac":"","model":"22021211RC","oaid":"","oaid-no-cache":"","phone-level":"H","refresh-type":"0","session-id":"';
var QM_AFTER = '","sourceuid":"aa7de295aad621a6","static_score":"0.8","sys-ver":"12","trusted-id":"","uuid":"00000000-7fc7-08dc-0000-000000000000","wlb-imei":"","wlb-uid":"aa7de295aad621a6"}';

// 标准 Base64（自带实现：宿主只保证 crypto.md5，不含 btoa）。
function base64Encode(text) {
    var out = '';
    for (var i = 0; i < text.length; i += 3) {
        var has2 = i + 1 < text.length;
        var has3 = i + 2 < text.length;
        var c1 = text.charCodeAt(i);
        var c2 = has2 ? text.charCodeAt(i + 1) : 0;
        var c3 = has3 ? text.charCodeAt(i + 2) : 0;
        out += B64_TABLE.charAt(c1 >> 2);
        out += B64_TABLE.charAt(((c1 & 3) << 4) | (c2 >> 4));
        out += has2 ? B64_TABLE.charAt(((c2 & 15) << 2) | (c3 >> 6)) : '=';
        out += has3 ? B64_TABLE.charAt(c3 & 63) : '=';
    }
    return out;
}

function mapChars(text) {
    var out = '';
    for (var i = 0; i < text.length; i++) {
        var ch = text.charAt(i);
        out += CHAR_MAP[ch] !== undefined ? CHAR_MAP[ch] : ch;
    }
    return out;
}

function qmParams(sessionId) {
    return mapChars(base64Encode(QM_BEFORE + sessionId + QM_AFTER));
}

function signAuthorization(qm) {
    return crypto.md5(
        'AUTHORIZATION=app-version=10001application-id=com.duoduo.read' +
        'channel=unknownis-white=net-env=5platform=android' +
        'qm-params=' + qm + 'reg=' + KEY
    );
}

// 每次请求新建 session-id：编译版同样按时间戳生成，重试时会换一个。
function requestHeaders(sessionId) {
    var qm = qmParams(sessionId);
    return {
        'Referer': BASE + '/',
        'platform': 'android',
        'application-id': 'com.duoduo.read',
        'app-version': '10001',
        'channel': 'unknown',
        'net-env': '5',
        'is-white': '',
        'reg': '',
        'authorization': '',
        'qm-params': qm,
        'sign': signAuthorization(qm),
        'Accept': 'application/json',
        'X-Requested-With': 'com.duoduo.read',
        'user-agent': 'webviewversion/0',
    };
}

// 供对拍测试直接调用：传固定 sessionId 才能逐字节比较。
function headers(input) {
    var sessionId = (input && input.sessionId) || String(new Date().getTime());
    return requestHeaders(sessionId);
}

// ---- 取数 ----

function pick(node, keys) {
    for (var i = 0; i < keys.length; i++) {
        var value = node[keys[i]];
        if (value !== undefined && value !== null && String(value) !== '') { return String(value); }
    }
    return '';
}

function tagNames(node) {
    var lists = [node.tags, node.tag_list];
    for (var i = 0; i < lists.length; i++) {
        var list = lists[i];
        if (!Array.isArray(list)) { continue; }
        var names = [];
        for (var j = 0; j < list.length; j++) {
            var entry = list[j];
            var name = typeof entry === 'string' ? entry : (entry && entry.tag_name) || '';
            if (String(name).trim() !== '') { names.push(String(name)); }
        }
        if (names.length > 0) { return names.join(','); }
    }
    return pick(node, ['tags', 'tag_list']);
}

function dramaFrom(node) {
    return {
        sourceId: pick(node, ['playlet_id', 'playletId', 'id']),
        title: pick(node, ['playlet_name', 'title', 'name']),
        description: pick(node, ['description', 'intro', 'summary']),
        cover: pick(node, ['image_link', 'imageLink', 'cover', 'cover_url']),
        episodes: parseInt(pick(node, ['total_episode_num', 'totalEpisodeNum', 'total']) || '0', 10) || 0,
        category: tagNames(node),
    };
}

function catalogUrl(tagId, page) {
    var url = BASE + '/api/v1/playlet/index?tag_id=' + tagId +
        '&playlet_privacy=1&operation=1';
    if (page > 1) { url += '&next_id=' + page; }
    return url + '&sign=' + signCatalog(tagId, page);
}

function catalog(input) {
    var page = input.page || 1;
    var category = input.category || '0';
    var res = ctx.fetch({
        url: catalogUrl(category, page),
        headers: requestHeaders(String(new Date().getTime())),
    });
    var body = JSON.parse(res.body);
    var data = (body && body.data) || {};
    var list = data.list || [];
    var items = [];
    for (var i = 0; i < list.length; i++) {
        var drama = dramaFrom(list[i]);
        // 与编译版一致：没有主键或标题的条目直接丢弃。
        if (drama.sourceId === '' || drama.title === '') { continue; }
        items.push(drama);
    }
    return { items: items, hasMore: !!data.next_id, page: page };
}

function detail(input) {
    var sourceId = input.id;
    var url = READ_BASE + '/player/api/v1/playlet/info?playlet_id=' +
        encodeURIComponent(sourceId) + '&sign=' + signDetail(sourceId);
    var res = ctx.fetch({
        url: url,
        headers: requestHeaders(String(new Date().getTime())),
    });
    var body = JSON.parse(res.body);
    var data = body && body.data;
    if (!data) { throw new Error('详情缺少 data 字段'); }

    var chapters = [];
    var list = data.play_list || [];
    for (var i = 0; i < list.length; i++) {
        var node = list[i];
        var videoUrl = pick(node, ['video_url', 'videoUrl', 'url']);
        if (videoUrl === '') { continue; }
        var number = parseInt(pick(node, ['sort', 'episode', 'index']) || '', 10);
        if (!number || number < 1) { number = i + 1; }
        var title = pick(node, ['title', 'name']);
        chapters.push({
            id: sourceId + ':' + number,
            title: title === '' ? ('第' + number + '集') : title,
            videoUrl: videoUrl,
            referer: BASE + '/',
        });
    }
    if (chapters.length === 0) { throw new Error('未返回可播放分集'); }
    chapters.sort(function (a, b) { return Number(a.id.split(':').pop()) - Number(b.id.split(':').pop()); });
    return { drama: dramaFrom(data), chapters: chapters };
}

function search(input) {
    var query = input.query || '';
    var url = BASE + '/api/v1/playlet/search?extend=&page=1&wd=' +
        encodeURIComponent(query) + '&read_preference=0&track_id=' + TRACK_ID +
        '&sign=' + signSearch(query);
    var res = ctx.fetch({
        url: url,
        headers: requestHeaders(String(new Date().getTime())),
    });
    var body = JSON.parse(res.body);
    var data = (body && body.data) || {};
    var list = data.list || [];
    var items = [];
    for (var i = 0; i < list.length; i++) {
        var drama = dramaFrom(list[i]);
        if (drama.sourceId === '' || drama.title === '') { continue; }
        items.push(drama);
    }
    return { items: items, hasMore: false, page: input.page || 1 };
}
