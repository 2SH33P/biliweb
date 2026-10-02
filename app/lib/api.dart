// B站 API 客户端。纯 http + 手写 cookie 管理，不引第三方 B站 SDK。
//
// 三件事要注意（都是实测踩出来的）：
//  1. 搜索这类接口要 WBI 签名：mixin_key = 按固定表重排(img_key+sub_key) 取前 32 位。
//  2. 评论翻页必须用传统接口 /x/v2/reply；游标版 /x/v2/reply/wbi/main 传 pn 无效。
//  3. 写操作（赞/币/藏/关注）要 csrf=bili_jct，而且状态有数秒延迟，别写完立刻回读。
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

const String kUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

const String _api = 'https://api.bilibili.com';

const List<int> _mixinTab = [
  46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
  33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40,
  61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11,
  36, 20, 34, 44, 52,
];

const Map<int, String> kQuality = {
  127: '8K', 126: '杜比视界', 125: 'HDR', 120: '4K', 116: '1080P60',
  112: '1080P+', 100: '智能修复', 80: '1080P', 74: '720P60', 64: '720P',
  32: '480P', 16: '360P',
};

class BiliException implements Exception {
  BiliException(this.code, this.message);
  final int code;
  final String message;
  @override
  String toString() => '[$code] $message';
}

class BiliApi {
  BiliApi({Map<String, String>? cookies}) {
    if (cookies != null) _cookies.addAll(cookies);
  }

  final http.Client _client = http.Client();
  final Map<String, String> _cookies = {};
  String? _mixin;
  DateTime _mixinAt = DateTime.fromMillisecondsSinceEpoch(0);
  Map<String, dynamic> _nav = {};
  DateTime _navAt = DateTime.fromMillisecondsSinceEpoch(0);

  Map<String, String> get cookies => Map.unmodifiable(_cookies);
  bool get isLogin => (_cookies['SESSDATA'] ?? '').isNotEmpty;
  bool get hasCsrf => (_cookies['bili_jct'] ?? '').isNotEmpty;

  // ---------- 底层请求 ----------

  Map<String, String> _headers({String referer = 'https://www.bilibili.com/'}) => {
        'User-Agent': kUserAgent,
        'Referer': referer,
        if (_cookies.isNotEmpty)
          'Cookie': _cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
      };

  void _absorbCookies(http.Response res) {
    // http 包不自动管 cookie，自己从 set-cookie 里捡。
    // 注意：多个 Set-Cookie 被合并成一个字符串，而 Expires 里带逗号，
    // 不能直接 split(',')，得只在「逗号 + name=」处切。
    final raw = res.headers['set-cookie'];
    if (raw == null) return;
    final parts = raw.split(RegExp(r',(?=\s*[\w\-_.]+=)'));
    for (final part in parts) {
      final seg = part.split(';').first.trim();
      final i = seg.indexOf('=');
      if (i <= 0) continue;
      final name = seg.substring(0, i).trim();
      final value = seg.substring(i + 1).trim();
      if (value.isEmpty) {
        _cookies.remove(name);
      } else {
        _cookies[name] = value;
      }
    }
  }

  Future<Map<String, dynamic>> _send(Uri uri,
      {Map<String, String>? form, String referer = 'https://www.bilibili.com/'}) async {
    late http.Response res;
    if (form == null) {
      res = await _client.get(uri, headers: _headers(referer: referer));
    } else {
      res = await _client.post(uri,
          headers: _headers(referer: referer), body: form);
    }
    _absorbCookies(res);
    if (res.statusCode == 412) {
      throw BiliException(-412, '被 B 站风控拦了，等几分钟或换个网络');
    }
    final decoded = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final code = decoded['code'];
    if (code is int && code != 0) {
      throw BiliException(code, (decoded['message'] ?? '请求失败').toString());
    }
    return decoded;
  }

  Future<Map<String, dynamic>> get(String url, Map<String, dynamic> params,
      {bool wbi = false, String referer = 'https://www.bilibili.com/'}) async {
    final query = <String, String>{};
    params.forEach((k, v) {
      if (v != null) query[k] = v.toString();
    });
    final signed = wbi ? await _sign(query) : query;
    return _send(Uri.parse('$url?${Uri(queryParameters: signed).query}'),
        referer: referer);
  }

  Future<Map<String, dynamic>> post(String url, Map<String, String> form) async {
    if (!hasCsrf) {
      throw BiliException(-110, 'cookie 里没有 bili_jct，写操作会被拒（重新登录一次）');
    }
    return _send(Uri.parse(url), form: form);
  }

  // ---------- WBI 签名 ----------

  Future<String> _mixinKey() async {
    if (_mixin != null && DateTime.now().difference(_mixinAt).inMinutes < 10) {
      return _mixin!;
    }
    final w = (await nav())['wbi_img'] as Map<String, dynamic>? ?? {};
    final img = (w['img_url'] ?? '').toString().split('/').last.split('.').first;
    final sub = (w['sub_url'] ?? '').toString().split('/').last.split('.').first;
    final raw = img + sub;
    final buf = StringBuffer();
    for (final i in _mixinTab) {
      if (i < raw.length) buf.write(raw[i]);
    }
    _mixin = buf.toString();
    _mixinAt = DateTime.now();
    return _mixin!;
  }

  Future<Map<String, String>> _sign(Map<String, String> params) async {
    final key = await _mixinKey();
    final p = Map<String, String>.from(params)
      ..['wts'] = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    final keys = p.keys.toList()..sort();
    final q = keys
        .map((k) => '${Uri.encodeQueryComponent(k)}=${Uri.encodeQueryComponent(_filter(p[k]!))}')
        .join('&');
    p['w_rid'] = md5.convert(utf8.encode(q + key)).toString();
    // 故意返回「未编码」的参数：调用方用 Uri(queryParameters:) 编一次，
    // 而它用的正是 encodeQueryComponent 同一套规则，所以签名值串与实发串一致。
    // （之前这里返回了已编码的值，被 Uri 又编一遍变成 %25，签名必错。）
    return p;
  }

  static String _filter(String v) => v.replaceAll(RegExp(r"[!'()*]"), '');

  // ---------- 登录 ----------

  /// 返回 (qrcode_key, 链接)。链接在同一台设备上打开即可确认登录，不必真的扫二维码。
  Future<(String, String)> qrGenerate() async {
    final d = (await get(
            'https://passport.bilibili.com/x/passport-login/web/qrcode/generate',
            {'source': 'main-fe-header'}))['data'] as Map<String, dynamic>;
    return (d['qrcode_key'].toString(), d['url'].toString());
  }

  /// code: 0 成功 / 86090 已扫码待确认 / 86101 未扫码 / 86038 已过期
  Future<(int, String)> qrPoll(String key) async {
    final d = (await get(
        'https://passport.bilibili.com/x/passport-login/web/qrcode/poll',
        {'qrcode_key': key, 'source': 'main-fe-header'}))['data'] as Map<String, dynamic>;
    return (d['code'] as int? ?? -1, (d['message'] ?? '').toString());
  }

  /// 补 buvid3/buvid4 设备指纹，写操作被风控的概率会低一些
  Future<void> fetchBuvid() async {
    try {
      final d = (await get('$_api/x/frontend/finger/spi', {}))['data']
          as Map<String, dynamic>?;
      if (d == null) return;
      if ((d['b_3'] ?? '').toString().isNotEmpty) _cookies['buvid3'] = d['b_3'].toString();
      if ((d['b_4'] ?? '').toString().isNotEmpty) _cookies['buvid4'] = d['b_4'].toString();
    } catch (_) {
      // 拿不到就算了，不影响登录
    }
  }

  // ---------- 读接口 ----------

  Future<Map<String, dynamic>> nav({bool fresh = false}) async {
    if (!fresh && DateTime.now().difference(_navAt).inSeconds < 60 && _nav.isNotEmpty) {
      return _nav;
    }
    _nav = (await get('$_api/x/web-interface/nav', {}))['data']
            as Map<String, dynamic>? ??
        {};
    _navAt = DateTime.now();
    return _nav;
  }

  Future<Map<String, dynamic>> me() async {
    final d = await nav(fresh: true);
    return {
      'isLogin': d['isLogin'] == true,
      'uname': (d['uname'] ?? '').toString(),
      'mid': d['mid'],
      'coins': d['money'],
      'level': (d['level_info'] as Map<String, dynamic>?)?['current_level'],
    };
  }

  Future<Map<String, dynamic>> search(String type, String q, int page) async {
    final r = await get(
        '$_api/x/web-interface/wbi/search/type',
        {'search_type': type, 'keyword': q, 'page': page},
        wbi: true);
    final d = r['data'] as Map<String, dynamic>? ?? {};
    final items = <Map<String, dynamic>>[];
    for (final raw in (d['result'] as List? ?? [])) {
      final it = raw as Map<String, dynamic>;
      if (type == 'video') {
        if ((it['bvid'] ?? '').toString().isEmpty) continue;
        items.add({
          'kind': 'video',
          'id': it['bvid'],
          'title': _clean(it['title']),
          'author': _clean(it['author']),
          'pic': _https(it['pic']),
          'duration': _clean(it['duration']),
          'play': it['play'],
          'pubdate': it['pubdate'],
        });
      } else if (type == 'bili_user') {
        items.add({
          'kind': 'user',
          'id': it['mid'].toString(),
          'title': _clean(it['uname']),
          'author': '',
          'pic': _https(it['upic']),
          'fans': it['fans'],
          'videos': it['videos'],
          'sign': _clean(it['usign']),
        });
      } else {
        items.add({
          'kind': 'article',
          'id': it['id'].toString(),
          'title': _clean(it['title']),
          'author': _clean(it['author']),
          'pic': _https(((it['image_urls'] as List?) ?? []).isEmpty
              ? ''
              : (it['image_urls'] as List).first),
          'view': it['view'],
          'reply': it['reply'],
        });
      }
    }
    return {
      'items': items,
      'total': d['numResults'] ?? 0,
      'pages': d['numPages'] ?? 1,
    };
  }

  Future<Map<String, dynamic>> video(String bvid) async {
    final v = (await get('$_api/x/web-interface/view', {'bvid': bvid}))['data']
            as Map<String, dynamic>? ??
        {};
    Map<String, dynamic> rel = {};
    var favoured = false;
    var follow = 0;
    if (isLogin) {
      rel = (await get('$_api/x/web-interface/archive/relation', {'bvid': bvid}))['data']
              as Map<String, dynamic>? ??
          {};
      favoured = ((await get('$_api/x/v2/fav/video/favoured', {'aid': v['aid']}))['data']
                  as Map<String, dynamic>? ??
              {})['favoured'] ==
          true;
      final mid = (v['owner'] as Map<String, dynamic>? ?? {})['mid'];
      if (mid != null) {
        follow = ((await get('$_api/x/relation', {'fid': mid}))['data']
                as Map<String, dynamic>? ??
            {})['attribute'] as int? ?? 0;
      }
    }
    final owner = v['owner'] as Map<String, dynamic>? ?? {};
    return {
      'id': v['bvid'],
      'aid': v['aid'],
      'title': v['title'],
      'pic': _https(v['pic']),
      'desc': v['desc'],
      'duration': v['duration'],
      'pubdate': v['pubdate'],
      'stat': v['stat'] ?? {},
      'owner': {
        'mid': owner['mid'],
        'name': owner['name'],
        'face': _https(owner['face']),
      },
      'liked': rel['like'] == true,
      'coined': rel['coin'] ?? 0,
      'favoured': favoured,
      'follow': follow,
      'url': 'https://www.bilibili.com/video/${v['bvid']}',
    };
  }

  Future<Map<String, dynamic>> article(String id) async {
    final d = (await get('$_api/x/article/view', {'id': id}))['data']
            as Map<String, dynamic>? ??
        {};
    final info = (await get('$_api/x/article/viewinfo', {'id': id}))['data']
            as Map<String, dynamic>? ??
        {};
    final stats = info['stats'] as Map<String, dynamic>? ?? {};
    final author = info['author'] as Map<String, dynamic>? ?? {};
    return {
      'id': id,
      'title': d['title'] ?? '',
      // 专栏正文是上游给的 HTML。这里直接转纯文本，不引 HTML 渲染库
      //（少一个依赖，也就少一处 XSS 面）。想看排版就点原页。
      'content': _plainText(d['content']),
      'author': {'mid': author['mid'], 'name': author['name']},
      'stat': {
        'view': stats['view'],
        'like': stats['like'],
        'reply': stats['reply'],
      },
      'url': 'https://www.bilibili.com/read/cv$id',
    };
  }

  /// 评论：只能用传统接口，游标版不认 pn
  Future<Map<String, dynamic>> comments(String oid, int type, int pn) async {
    final d = (await get('$_api/x/v2/reply',
            {'type': type, 'oid': oid, 'pn': pn, 'sort': 2}))['data']
            as Map<String, dynamic>? ??
        {};
    final page = d['page'] as Map<String, dynamic>? ?? {};
    final total = page['count'] as int? ?? 0;
    final items = <Map<String, dynamic>>[];
    for (final raw in (d['replies'] as List? ?? [])) {
      final c = raw as Map<String, dynamic>;
      final m = c['member'] as Map<String, dynamic>? ?? {};
      final ct = c['content'] as Map<String, dynamic>? ?? {};
      items.add({
        'uname': m['uname'],
        'face': _https(m['avatar']),
        'message': (ct['message'] ?? '').toString(),
        'like': c['like'],
        'rcount': c['rcount'],
        'ctime': c['ctime'],
      });
    }
    return {'items': items, 'total': total, 'pn': pn, 'isEnd': pn * 20 >= total};
  }

  Future<int> relation(String fid) async {
    final d = (await get('$_api/x/relation', {'fid': fid}))['data']
            as Map<String, dynamic>? ??
        {};
    return d['attribute'] as int? ?? 0;
  }

  Future<Map<String, dynamic>> user(String mid, int pn) async {
    final d = (await get('$_api/x/space/wbi/acc/info',
            {'mid': mid, 'platform': 'web', 'web_location': 1550101},
            wbi: true))['data'] as Map<String, dynamic>? ?? {};
    Map<String, dynamic> st = {};
    try {
      st = (await get('$_api/x/relation/stat', {'vmid': mid}))['data']
              as Map<String, dynamic>? ??
          {};
    } catch (_) {}
    final r = (await get('$_api/x/space/wbi/arc/search',
            {'mid': mid, 'ps': 30, 'pn': pn, 'order': 'pubdate',
             'platform': 'web', 'web_location': 1550101},
            wbi: true))['data'] as Map<String, dynamic>? ?? {};
    final page = r['page'] as Map<String, dynamic>? ?? {};
    final list = (r['list'] as Map<String, dynamic>? ?? {})['vlist'] as List? ?? [];
    final items = <Map<String, dynamic>>[];
    for (final raw in list) {
      final x = raw as Map<String, dynamic>;
      items.add({
        'kind': 'video',
        'id': x['bvid'],
        'title': x['title'],
        'author': d['name'],
        'pic': _https(x['pic']),
        'duration': x['length'],
        'play': x['play'],
        'pubdate': x['created'],
      });
    }
    final total = page['count'] as int? ?? 0;
    return {
      'mid': mid,
      'name': d['name'],
      'face': _https(d['face']),
      'sign': d['sign'] ?? '',
      'level': d['level'] ?? 0,
      'fans': st['follower'],
      'total': total,
      'items': items,
      'hasMore': pn * 30 < total,
    };
  }

  Future<List<Map<String, dynamic>>> folders() async {
    final mid = (await nav())['mid'];
    final d = (await get('$_api/x/v3/fav/folder/created/list-all', {'up_mid': mid}))['data']
            as Map<String, dynamic>? ??
        {};
    return ((d['list'] as List?) ?? [])
        .map((e) => (e as Map<String, dynamic>))
        .map((f) => {'id': f['id'].toString(), 'title': f['title'], 'count': f['media_count']})
        .toList();
  }

  /// 观看历史。游标接口只能从最新往回翻，但把 max 和 view_at 设成同一个时间戳
  /// 就能跳到那个时刻，这是「指定时间段」的实现方式。
  Future<Map<String, dynamic>> history({
    required int start,
    required int end,
    int maxPages = 5,
    void Function(int done, int total)? onProgress,
  }) async {
    final items = <Map<String, dynamic>>[];
    final seen = <String>{};
    Map<String, dynamic>? cur;
    var done = false;
    for (var i = 0; i < maxPages; i++) {
      final params = <String, dynamic>{'ps': 30};
      if (cur == null) {
        params['max'] = end;
        params['view_at'] = end;
      } else {
        params['max'] = cur['max'];
        params['view_at'] = cur['view_at'];
        params['business'] = cur['business'] ?? '';
      }
      final resp = await get('$_api/x/web-interface/history/cursor', params);
      final data = resp['data'] as Map<String, dynamic>? ?? {};
      final list = data['list'] as List? ?? [];
      if (list.isEmpty) {
        done = true;
        break;
      }
      for (final raw in list) {
        final it = raw as Map<String, dynamic>;
        final h = it['history'] as Map<String, dynamic>? ?? {};
        final ts = it['view_at'] as int? ?? 0;
        final key = '${h['oid']}-${h['business']}';
        if (ts > end || (start > 0 && ts < start) || seen.contains(key)) continue;
        seen.add(key);
        items.add({
          'view_at': ts,
          'business': h['business'] ?? '',
          'title': it['title'] ?? '',
          'author': it['author_name'] ?? '',
          'bvid': h['bvid'] ?? '',
          'oid': h['oid'],
        });
      }
      onProgress?.call(i + 1, maxPages);
      final last = list.last as Map<String, dynamic>;
      if (((last['view_at'] as int?) ?? 0) < start) {
        done = true;
        break;
      }
      cur = data['cursor'] as Map<String, dynamic>?;
      if (cur == null || cur['view_at'] == null) {
        done = true;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 350)); // 别把风控惹毛
    }
    return {'items': items, 'count': items.length, 'truncated': !done};
  }

  // ---------- 写接口 ----------

  Future<void> like(String bvid, bool on) => post(
      '$_api/x/web-interface/archive/like',
      {'bvid': bvid, 'like': on ? '1' : '2', 'csrf': _cookies['bili_jct'] ?? ''});

  Future<void> coin(String bvid, int n) => post('$_api/x/web-interface/coin/add',
      {'bvid': bvid, 'multiply': '$n', 'select_like': '0', 'csrf': _cookies['bili_jct'] ?? ''});

  Future<void> fav(int aid, String add) => post('$_api/x/v3/fav/resource/deal',
      {'rid': '$aid', 'type': '2', 'add_media_ids': add, 'del_media_ids': '',
       'csrf': _cookies['bili_jct'] ?? ''});

  Future<void> follow(String fid, bool on) => post('$_api/x/relation/modify',
      {'fid': fid, 'act': on ? '1' : '2', 're_src': '11', 'csrf': _cookies['bili_jct'] ?? ''});

  // ---------- 工具 ----------

  static String _clean(dynamic s) =>
      (s ?? '').toString().replaceAll(RegExp(r'</?em[^>]*>'), '').trim();

  static String _https(dynamic u) {
    final s = (u ?? '').toString();
    return s.startsWith('//') ? 'https:$s' : s;
  }

  /// HTML 转可读纯文本：块级标签变换行，其余标签去掉，常见实体还原
  static String _plainText(dynamic h) {
    var s = (h ?? '').toString();
    s = s.replaceAll(RegExp(r'<(script|iframe|style)[^>]*>.*?</\1>',
        dotAll: true, caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    s = s.replaceAll(
        RegExp(r'</(p|div|li|h[1-6]|figure|blockquote)>', caseSensitive: false), '\n');
    s = s.replaceAll(RegExp(r'<img[^>]*>', caseSensitive: false), '[图片]');
    s = s.replaceAll(RegExp(r'<[^>]+>'), '');
    s = s
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
    return s.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  static int parseTs(String v, int fallback, {bool endOfDay = false}) {
    if (v.trim().isEmpty) return fallback;
    final t = v.trim();
    if (RegExp(r'^\d+$').hasMatch(t)) return int.parse(t);
    final d = DateTime.tryParse(t.length <= 10 ? '${t}T00:00:00' : t);
    if (d == null) return fallback;
    final local = d.millisecondsSinceEpoch ~/ 1000;
    return endOfDay && t.length == 10 ? local + 86399 : local;
  }

  static String fmtTime(int ts) {
    final d = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    return '${d.year}-${_p(d.month)}-${_p(d.day)} ${_p(d.hour)}:${_p(d.minute)}';
  }

  static String _p(int n) => n.toString().padLeft(2, '0');

  static String fmtCount(dynamic n) {
    final v = (n is int) ? n : int.tryParse('$n') ?? 0;
    if (v >= 100000000) return '${(v / 100000000).toStringAsFixed(1)}亿';
    if (v >= 10000) return '${(v / 10000).toStringAsFixed(1)}万';
    return '$v';
  }

  static String ago(dynamic ts) {
    final t = (ts is int) ? ts : int.tryParse('$ts') ?? 0;
    if (t == 0) return '';
    final diff = DateTime.now().millisecondsSinceEpoch ~/ 1000 - t;
    if (diff < 3600) return '${diff ~/ 60}分钟前';
    if (diff < 86400) return '${diff ~/ 3600}小时前';
    if (diff < 86400 * 30) return '${diff ~/ 86400}天前';
    return fmtTime(t).split(' ').first;
  }

  static String randomHex(int n) {
    final r = Random.secure();
    return List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
  }
}
