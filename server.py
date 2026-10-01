#!/usr/bin/env python3
"""biliweb —— 极简第三方 B站网页客户端，只依赖 Python 标准库。

设计取舍（和「戒刷」这个目标一致）：
  - 只有 搜索 → 看 → 互动。没有首页推荐流、没有自动连播、没有相关推荐。
  - 零第三方依赖：Termux / iSH / 任何有 python3 的机器直接跑，不用 pip。
  - cookie（SESSDATA/bili_jct）只活在进程内存里，不下发前端、不写日志。

用法:
    python3 server.py                                   # 127.0.0.1:8000，本机可用
    python3 server.py --host 0.0.0.0 --token 我的口令    # 局域网/手机可用，必须带口令
    python3 server.py --selftest                        # 只读自检，不启服务

cookie 文件是 Netscape 格式（bili_login.py 的产物），默认找同目录 cookies.txt。
"""
import argparse, hashlib, html, http.cookiejar, io, json, os, re, shutil, socket, subprocess, sys, tarfile, time
import urllib.parse, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UA = ('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36')
API = 'https://api.bilibili.com'
MIXIN_TAB = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
    33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40,
    61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11,
    36, 20, 34, 44, 52]

# 专栏正文是平台给的 HTML，直接塞进页面等于把 XSS 面交给上游，先剥一遍
_SCRIPT = re.compile(r'<(script|iframe|style|object|embed)[^>]*>.*?</\1>', re.S | re.I)
_ONATTR = re.compile(r'\son\w+\s*=\s*("[^"]*"|\'[^\']*\'|[^\s>]+)', re.I)
_JSURL = re.compile(r'(href|src)\s*=\s*("|\')\s*javascript:[^"\']*\2', re.I)
_EMTAG = re.compile(r'</?em[^>]*>')

# 清晰度 id → 人话（和 B 站一致）
QUALITY = {127: '8K', 126: '杜比视界', 125: 'HDR', 120: '4K', 116: '1080P60',
           112: '1080P+', 100: '智能修复', 80: '1080P', 74: '720P60', 64: '720P',
           32: '480P', 16: '360P'}
# 下载优先挑 H.264：手机上 hvc1/av01 经常放不出来
CODEC_RANK = {'avc1': 0, 'hvc1': 1, 'hev1': 1, 'av01': 2}

# 历史记录字段故意只留这一点：之前带了封面/时长/进度/徽章十几个字段，
# JSON 又大又慢，而实际只看「看了什么、谁的、什么时候」。


def parse_ts(v, default, end_of_day=False):
    """接受 epoch 秒或 'YYYY-MM-DD' / 'YYYY-MM-DD HH:MM'。
    只给日期时，作为结束边界要含当天，所以补到 23:59:59。"""
    if v is None or v == '':
        return default
    v = str(v).strip()
    if v.isdigit():
        return int(v)
    for fmt in ('%Y-%m-%dT%H:%M:%S', '%Y-%m-%dT%H:%M', '%Y-%m-%d %H:%M', '%Y-%m-%d'):
        try:
            t = int(time.mktime(time.strptime(v, fmt)))
            return t + 86399 if (end_of_day and fmt == '%Y-%m-%d') else t
        except ValueError:
            continue
    return default


def strip_em(s):
    return html.unescape(_EMTAG.sub('', s or '')).strip()


def sanitize(h):
    h = _SCRIPT.sub('', h or '')
    h = _ONATTR.sub('', h)
    h = _JSURL.sub(r'\1="#"', h)
    return h


def https_url(u):
    if not u:
        return ''
    return 'https:' + u if u.startswith('//') else u


class BiliError(Exception):
    def __init__(self, code, message):
        super().__init__(f'{code}: {message}')
        self.code, self.message = code, message


class Bili:
    def __init__(self, cookies=None):
        self.jar = http.cookiejar.MozillaCookieJar(cookies or '')
        if cookies and os.path.exists(cookies):
            self.jar.load(ignore_discard=True, ignore_expires=True)
        self.op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))
        self._wbi, self._wbi_ts, self._nav = None, 0.0, None
        self.ffmpeg_ok = True            # main() 会按实际检查结果覆盖；没有 ffmpeg 就退到单文件流
        if not self.cookie('buvid3'):
            try:
                spi = self.get(f'{API}/x/frontend/finger/spi').get('data') or {}
                if spi.get('b_3'):
                    self.set_cookie('buvid3', spi['b_3'])
                    if spi.get('b_4'):
                        self.set_cookie('buvid4', spi['b_4'])
            except Exception:
                pass                      # buvid3 只是降风控概率，拿不到也继续

    # ---------- 基础 ----------
    def cookie(self, name):
        for c in self.jar:
            if c.name == name and c.domain.endswith('bilibili.com'):
                return c.value
        return ''

    def set_cookie(self, name, value):
        self.jar.set_cookie(http.cookiejar.Cookie(
            0, name, value, None, False, '.bilibili.com', True, True, '/', True,
            False, None, False, None, None, {}))

    def logged_in(self):
        return bool(self.cookie('SESSDATA'))

    def csrf(self):
        return self.cookie('bili_jct')

    def _call(self, url, data=None):
        headers = {'User-Agent': UA, 'Referer': 'https://www.bilibili.com/'}
        body = urllib.parse.urlencode(data).encode() if data else None
        req = urllib.request.Request(url, data=body, headers=headers)
        try:
            raw = self.op.open(req, timeout=20).read().decode()
        except urllib.error.HTTPError as e:
            if e.code == 412:
                raise BiliError(-412, '被 B 站风控拦了，等几分钟或换个网络再试')
            raise BiliError(e.code, str(e.reason))
        out = json.loads(raw)
        if out.get('code') not in (0, None):
            raise BiliError(out['code'], out.get('message') or '请求失败')
        return out

    def get(self, url, params=None, wbi=False):
        if params:
            url += '?' + (self._sign(params) if wbi else urllib.parse.urlencode(params))
        return self._call(url)

    def post(self, url, data):
        if not self.csrf():
            raise BiliError(-110, '没有 bili_jct（CSRF token），这个操作需要登录态')
        return self._call(url, data)

    # ---------- WBI 签名 ----------
    def _sign(self, params):
        p = {k: v for k, v in params.items() if v is not None}
        p['wts'] = int(time.time())
        clean = [(k, ''.join(c for c in str(v) if c not in "!'()*"))
                 for k, v in sorted(p.items())]
        q = urllib.parse.urlencode(clean)
        p['w_rid'] = hashlib.md5((q + self._mixin()).encode()).hexdigest()
        return urllib.parse.urlencode(sorted(p.items()))

    def _mixin(self):
        if self._wbi and time.time() - self._wbi_ts < 600:
            return self._wbi
        w = (self.nav().get('wbi_img') or {})
        raw = (w.get('img_url', '').rsplit('/', 1)[-1].split('.')[0]
               + w.get('sub_url', '').rsplit('/', 1)[-1].split('.')[0])
        self._wbi = ''.join(raw[i] for i in MIXIN_TAB)[:32]
        self._wbi_ts = time.time()
        return self._wbi

    def nav(self, fresh=False):
        if self._nav is None or fresh:
            self._nav = self.get(f'{API}/x/web-interface/nav').get('data') or {}
        return self._nav

    # ---------- 读 ----------
    def me(self):
        d = self.nav(fresh=True)
        return {'isLogin': bool(d.get('isLogin')), 'uname': d.get('uname', ''),
                'mid': d.get('mid'), 'coins': d.get('money'),
                'vip': d.get('vipStatus', 0), 'level': (d.get('level_info') or {}).get('current_level'),
                # 缺 bili_jct 的话所有写操作都会回 -111，提前告诉前端比让它报错强
                'csrf': bool(self.csrf()), 'buvid3': bool(self.cookie('buvid3'))}

    def diagnose(self, bvid):
        """写操作自检：把 before → 写 → after 的原始响应全部吐出来。
        只做一对可逆操作（没赞过就赞→取消，已赞过就取消→赞），净效果为零。"""
        def rel():
            return self.get(f'{API}/x/web-interface/archive/relation', {'bvid': bvid}).get('data') or {}
        out = {'cookie': {'SESSDATA': bool(self.cookie('SESSDATA')),
                          'bili_jct': bool(self.csrf()),
                          'buvid3': bool(self.cookie('buvid3')),
                          'names': sorted({c.name for c in self.jar})},
               'csrf_sent': (self.csrf()[:6] + '…') if self.csrf() else '(空)',
               'before': rel()}
        was = bool(out['before'].get('like'))
        for step, want in (('step1', not was), ('step2', was)):
            try:
                out[step] = self.act_like(bvid, want)
            except BiliError as e:
                out[step] = {'code': e.code, 'message': e.message}
            time.sleep(2)
            out['after_' + step] = rel()
        out['final'] = rel()
        out['restored'] = bool(out['final'].get('like')) == was
        return out

    def search(self, kind, q, page=1):
        r = self.get(f'{API}/x/web-interface/wbi/search/type',
                     {'search_type': kind, 'keyword': q, 'page': page}, wbi=True)
        d = r.get('data') or {}
        items = d.get('result') or []
        out = []
        if kind == 'video':
            for it in items:
                if not it.get('bvid'):
                    continue
                out.append({'kind': 'video', 'id': it['bvid'], 'title': strip_em(it.get('title')),
                            'author': strip_em(it.get('author')), 'mid': it.get('mid'),
                            'pic': https_url(it.get('pic')), 'play': it.get('play'),
                            'danmaku': it.get('video_review'), 'duration': it.get('duration', ''),
                            'pubdate': it.get('pubdate'), 'desc': strip_em(it.get('description'))})
        elif kind == 'bili_user':
            for it in items:
                out.append({'kind': 'user', 'id': str(it.get('mid')), 'name': strip_em(it.get('uname')),
                            'pic': https_url(it.get('upic')), 'fans': it.get('fans'),
                            'videos': it.get('videos'), 'sign': strip_em(it.get('usign')),
                            'level': it.get('level'), 'official': strip_em((it.get('official_verify') or {}).get('desc'))})
        elif kind == 'article':
            for it in items:
                out.append({'kind': 'article', 'id': str(it.get('id')), 'title': strip_em(it.get('title')),
                            'author': strip_em(it.get('author')), 'mid': it.get('mid'),
                            'cover': https_url(it.get('image_urls') and it['image_urls'][0]),
                            'view': it.get('view'), 'like': it.get('like'),
                            'reply': it.get('reply'), 'pub_time': it.get('pub_time'),
                            'desc': strip_em(it.get('desc'))})
        return {'items': out, 'total': d.get('numResults', 0), 'pages': d.get('numPages', 0)}

    def video(self, bvid):
        v = self.get(f'{API}/x/web-interface/view', {'bvid': bvid}).get('data') or {}
        rel, favoured = {}, False
        if self.logged_in():
            rel = (self.get(f'{API}/x/web-interface/archive/relation',
                            {'bvid': bvid}).get('data') or {})
            favoured = bool((self.get(f'{API}/x/v2/fav/video/favoured',
                                      {'aid': v.get('aid')}).get('data') or {}).get('favoured'))
        owner = v.get('owner') or {}
        follow = None
        if self.logged_in() and owner.get('mid'):
            follow = (self.get(f'{API}/x/relation', {'fid': owner['mid']}).get('data') or {}).get('attribute')
        return {'kind': 'video', 'id': v.get('bvid'), 'aid': v.get('aid'), 'title': v.get('title'),
                'pic': https_url(v.get('pic')), 'desc': v.get('desc'), 'duration': v.get('duration'),
                'pubdate': v.get('pubdate'), 'pages': len(v.get('pages') or []) or 1,
                'owner': {'mid': owner.get('mid'), 'name': owner.get('name'),
                          'face': https_url(owner.get('face'))},
                'stat': v.get('stat') or {},
                'liked': bool(rel.get('like')), 'coined': rel.get('coin', 0) or 0,
                'favoured': favoured, 'follow': follow,
                'url': f'https://www.bilibili.com/video/{v.get("bvid")}'}

    def article(self, aid):
        d = self.get(f'{API}/x/article/view', {'id': aid}).get('data') or {}
        r = self.get(f'{API}/x/article/viewinfo', {'id': aid}).get('data') or {}
        stats = r.get('stats') or {}
        author = r.get('author') or d.get('author') or {}
        return {'kind': 'article', 'id': str(aid), 'title': d.get('title'), 'content': sanitize(d.get('content')),
                'summary': d.get('summary'),
                'banner': https_url(r.get('banner_url')), 'author': {'mid': author.get('mid'), 'name': author.get('name'), 'face': https_url(author.get('face'))},
                'stat': {'view': stats.get('view'), 'like': stats.get('like'), 'favorite': stats.get('favorite'), 'reply': stats.get('reply')},
                'url': f'https://www.bilibili.com/read/cv{aid}'}

    def comments(self, oid, ctype=1, pn=1):
        # 用传统接口而不是 /x/v2/reply/wbi/main：后者是游标分页，实测传 pn 无效
        #（第 1、2 页首条 rpid 完全相同），照它写翻页会原地打转。
        r = self.get(f'{API}/x/v2/reply', {'type': ctype, 'oid': oid, 'pn': pn, 'sort': 2})
        d = r.get('data') or {}
        page = d.get('page') or {}
        total = page.get('count') or 0
        out = []
        for c in d.get('replies') or []:
            m = c.get('member') or {}
            ct = c.get('content') or {}
            out.append({'rpid': c.get('rpid'), 'uname': m.get('uname'), 'mid': m.get('mid'),
                        'face': https_url(m.get('avatar')), 'message': ct.get('message'),
                        'like': c.get('like'), 'rcount': c.get('rcount'), 'ctime': c.get('ctime'),
                        'location': (c.get('reply_control') or {}).get('location')})
        return {'items': out, 'total': total, 'pn': pn,
                'is_end': pn * 20 >= total or not out}

    def _playurl(self, bvid, qn=127, fnval=4048, v=None):
        if v is None:
            v = self.get(f'{API}/x/web-interface/view', {'bvid': bvid}).get('data') or {}
        p = self.get(f'{API}/x/player/wbi/playurl',
                     {'bvid': bvid, 'cid': v.get('cid'), 'qn': qn,
                      'fnval': fnval, 'fourk': 1}, wbi=True).get('data') or {}
        return v, p

    @staticmethod
    def _pick(xs):
        return sorted(xs, key=lambda a: (CODEC_RANK.get((a.get('codecs') or '').split('.')[0], 9),
                                         -(a.get('bandwidth') or 0)))[0]

    @staticmethod
    def _fps(x):
        try:                       # frame_rate 有时是数字，有时是 "30.000" 这种字符串
            return round(float(x.get('frame_rate') or 0))
        except (TypeError, ValueError):
            return 0

    def formats(self, bvid):
        """按清晰度分组，每个档位只留一个最兼容的流，并估算文件大小"""
        v, p = self._playurl(bvid)
        dash = p.get('dash') or {}
        dur = max(v.get('duration') or 0, 1)
        auds = [a for a in (dash.get('audio') or []) if 'mp4a' in (a.get('codecs') or '')] \
            or (dash.get('audio') or [])
        abr = max((a.get('bandwidth') or 0) for a in auds) if auds else 0
        groups = {}
        for x in dash.get('video') or []:
            groups.setdefault(x['id'], []).append(x)
        out = []
        for q, xs in groups.items():
            x = self._pick(xs)
            out.append({'q': q, 'label': QUALITY.get(q, str(q)), 'height': x.get('height'),
                        'width': x.get('width'), 'fps': self._fps(x),
                        'codec': (x.get('codecs') or '').split('.')[0],
                        'bytes': int(((x.get('bandwidth') or 0) + abr) / 8 * dur)})
        out.sort(key=lambda a: -a['q'])
        return {'bvid': bvid, 'title': v.get('title'), 'duration': dur, 'items': out,
                'muxed_fallback': not out}   # 没有 dash 的老视频只能退到单文件流

    def download(self, bvid, q):
        """dash: 返回 (视频流, 音频流)；durl: 返回 B 站自己 mux 好的单文件 URL"""
        v, p = self._playurl(bvid)
        dash = p.get('dash') or {}
        # 要 127 但只到 720P 时不该退到单文件流，应该给最接近的那一档
        pool = [x for x in (dash.get('video') or []) if x['id'] <= q] or (dash.get('video') or [])
        qa = max((x['id'] for x in pool), default=None)
        xs = [x for x in pool if x['id'] == qa]
        if xs and self.ffmpeg_ok:
            auds = [a for a in (dash.get('audio') or []) if 'mp4a' in (a.get('codecs') or '')] \
                or (dash.get('audio') or [])
            if auds:
                aud = max(auds, key=lambda a: a.get('bandwidth') or 0)
                x = self._pick(xs)
                return 'dash', (x, aud, v, QUALITY.get(qa, str(qa)))
        # 回退：fnval=1 拿 B 站自己 mux 好的单文件流（清晰度上限较低）
        _, p2 = self._playurl(bvid, qn=q, fnval=1)
        urls = p2.get('durl') or []
        if not urls:
            raise BiliError(-404, '这个视频没有可下载的流')
        q2 = p2.get('quality') or q
        return 'durl', (urls[0]['url'], v, QUALITY.get(q2, str(q2)))

    def history(self, start=None, end=None, max_pages=20, ps=30):
        """看过的历史记录，按时间倒序。

        指定时间段的思路：游标接口只能从最新的往前翻，但它支持用
        「max = view_at = 同一个时间戳」直接跳到那个时刻，所以先把游标
        种在 end 上，再一页页往前翻到越过 start 为止。
        （实测只传 max 不传 view_at 会被忽略，直接返回最新记录，别踩。）
        """
        end = end or int(time.time())
        start = start or 0
        out, seen, cur, used, done = [], set(), None, 0, False
        for _ in range(max(1, max_pages)):
            if cur:
                p = {'ps': ps, 'max': cur['max'], 'view_at': cur['view_at'],
                     'business': cur.get('business', '')}
            else:
                p = {'ps': ps, 'max': end, 'view_at': end}
            d = self.get(f'{API}/x/web-interface/history/cursor', p).get('data') or {}
            lst = d.get('list') or []
            used += 1
            if not lst:
                done = True
                break
            for it in lst:
                ts = it.get('view_at', 0)
                key = ((it.get('history') or {}).get('oid'), (it.get('history') or {}).get('business'))
                if key in seen or ts > end or (start and ts < start):
                    continue           # 窗口外的条目要丢掉，不能只靠翻页边界
                seen.add(key)
                out.append(self._hist_item(it))
            if min(x.get('view_at', 0) for x in lst) < start:
                done = True
                break
            cur = d.get('cursor') or {}
            if not cur.get('view_at'):
                done = True
                break
            time.sleep(0.35)                 # 翻页快会把风控惹毛
        return {'items': out, 'count': len(out), 'start': start, 'end': end, 'pages': used,
                'truncated': not done,
                'oldest': min((x['view_at'] for x in out), default=None),
                'newest': max((x['view_at'] for x in out), default=None)}

    @staticmethod
    def _hist_item(it):
        h = it.get('history') or {}
        return {'view_at': it.get('view_at'),
                'view_at_local': time.strftime('%Y-%m-%d %H:%M:%S',
                                               time.localtime(it.get('view_at') or 0)),
                'business': h.get('business') or '',
                'title': it.get('title'),
                'author': it.get('author_name'),
                'bvid': h.get('bvid') or '',
                'oid': h.get('oid') or it.get('kid')}

    def user(self, mid, pn=1):
        """UP 主主页：资料 + 投稿列表（都走 wbi，搜索用的一样的签名）"""
        d = self.get(f'{API}/x/space/wbi/acc/info',
                     {'mid': mid, 'platform': 'web', 'web_location': 1550101}, wbi=True).get('data') or {}
        st = {}
        try:
            st = self.get(f'{API}/x/relation/stat', {'vmid': mid}).get('data') or {}
        except BiliError:
            pass
        r = self.get(f'{API}/x/space/wbi/arc/search',
                     {'mid': mid, 'ps': 30, 'pn': pn, 'order': 'pubdate',
                      'platform': 'web', 'web_location': 1550101}, wbi=True).get('data') or {}
        page = r.get('page') or {}
        items = []
        for x in ((r.get('list') or {}).get('vlist') or []):
            items.append({'kind': 'video', 'id': x.get('bvid'), 'title': x.get('title'),
                          'author': d.get('name'), 'mid': mid, 'pic': https_url(x.get('pic')),
                          'play': x.get('play'), 'duration': x.get('length'),
                          'pubdate': x.get('created'), 'desc': x.get('description')})
        return {'mid': str(mid), 'name': d.get('name'), 'face': https_url(d.get('face')),
                'sign': d.get('sign'), 'level': (d.get('level') or 0),
                'fans': st.get('follower'), 'following': st.get('following'),
                'total': page.get('count'), 'pn': pn, 'pages': (page.get('count') or 0) // 30 + 1,
                'items': items}

    def relation(self, fid):
        """只拿关注状态：attribute 0 未关注 / 2 已关注 / 6 互关 / 128 拉黑。
        /x/relation 不返回昵称、粉丝数，那些让前端从搜索结果里带过来。"""
        d = self.get(f'{API}/x/relation', {'fid': fid}).get('data') or {}
        return {'fid': str(fid), 'attribute': d.get('attribute')}

    def folders(self):
        mid = self.nav().get('mid')
        d = self.get(f'{API}/x/v3/fav/folder/created/list-all', {'up_mid': mid}).get('data') or {}
        return [{'id': f['id'], 'title': f['title'], 'count': f.get('media_count')}
                for f in (d.get('list') or [])]

    # ---------- 写（都要 csrf）----------
    def act_like(self, bvid, on):
        return self.post(f'{API}/x/web-interface/archive/like',
                         {'bvid': bvid, 'like': 1 if on else 2, 'csrf': self.csrf()})

    def act_coin(self, bvid, n=1):
        return self.post(f'{API}/x/web-interface/coin/add',
                         {'bvid': bvid, 'multiply': int(n), 'select_like': 0, 'csrf': self.csrf()})

    def act_fav(self, aid, add='', dele=''):
        return self.post(f'{API}/x/v3/fav/resource/deal',
                         {'rid': aid, 'type': 2, 'add_media_ids': add,
                          'del_media_ids': dele, 'csrf': self.csrf()})

    def act_follow(self, fid, on):
        return self.post(f'{API}/x/relation/modify',
                         {'fid': fid, 'act': 1 if on else 2, 're_src': 11, 'csrf': self.csrf()})


# ---------------------------------------------------------------- HTTP 层
INDEX = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'index.html')


class Handler(BaseHTTPRequestHandler):
    bili = None
    token = ''
    cookies_path = ''
    bundle_cookies = False
    ffmpeg = 'ffmpeg'
    server_version = 'biliweb'
    protocol_version = 'HTTP/1.1'      # 下载要边拉边推，1.1 才能用 chunked + 长连接

    def log_message(self, fmt, *a):
        sys.stderr.write('%s - %s\n' % (self.address_string(), fmt % a))

    def _json(self, obj, status=200):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    def _ok(self, data=None):
        self._json({'ok': True, 'data': data})

    def _fail(self, e):
        code = getattr(e, 'code', -1)
        self._json({'ok': False, 'code': code, 'message': str(getattr(e, 'message', e))})

    def _auth(self, q):
        if not self.token:
            return True
        given = q.get('t', [''])[0] or self.headers.get('X-Token', '')
        return given == self.token

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        if not self._auth(q):
            return self._json({'ok': False, 'message': '口令不对'}, 403)
        try:
            if u.path in ('/', '/index.html'):
                return self._serve_index()
            if u.path == '/biliweb.tar.gz':
                return self._serve_bundle()
            if u.path == '/api/me':
                return self._ok(self.bili.me())
            if u.path == '/api/search':
                kind = q.get('type', ['video'])[0]
                if kind not in ('video', 'bili_user', 'article'):
                    return self._fail(BiliError(-400, 'type 只能是 video/bili_user/article'))
                return self._ok(self.bili.search(kind, q.get('q', [''])[0], int(q.get('page', ['1'])[0])))
            if u.path == '/api/video':
                return self._ok(self.bili.video(q['bvid'][0]))
            if u.path == '/api/article':
                return self._ok(self.bili.article(q['id'][0]))
            if u.path == '/api/comments':
                return self._ok(self.bili.comments(q['oid'][0], int(q.get('type', ['1'])[0]),
                                                   int(q.get('pn', ['1'])[0])))
            if u.path == '/api/relation':
                return self._ok(self.bili.relation(q['fid'][0]))
            if u.path == '/api/formats':
                return self._ok(self.bili.formats(q['bvid'][0]))
            if u.path == '/api/diagnose':
                return self._ok(self.bili.diagnose(q['bvid'][0]))
            if u.path == '/api/user':
                return self._ok(self.bili.user(q['mid'][0], int(q.get('page', ['1'])[0])))
            if u.path == '/api/history':
                return self._ok(self.bili.history(*self._hist_range(q), max_pages=self._pages(q)))
            if u.path == '/api/history/export':
                return self._export_history(q)
            if u.path == '/api/download':
                mode, payload = self.bili.download(q['bvid'][0], int(q.get('q', ['127'])[0]))
                return self._dl_dash(*payload) if mode == 'dash' else self._dl_durl(*payload)
            if u.path == '/api/folders':
                return self._ok(self.bili.folders())
            return self._json({'ok': False, 'message': '没有这个接口'}, 404)
        except Exception as e:                                    # noqa: BLE001
            return self._fail(e)

    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        if not self._auth(q):
            return self._json({'ok': False, 'message': '口令不对'}, 403)
        try:
            n = int(self.headers.get('Content-Length') or 0)
            body = json.loads(self.rfile.read(n) or b'{}')
            act = body.get('act')
            if act == 'like':
                self.bili.act_like(body['id'], bool(body.get('on')))
            elif act == 'coin':
                self.bili.act_coin(body['id'], int(body.get('n', 1)))
            elif act == 'fav':
                self.bili.act_fav(body['aid'], body.get('add', ''), body.get('del', ''))
            elif act == 'follow':
                self.bili.act_follow(str(body['fid']), bool(body.get('on')))
            else:
                return self._fail(BiliError(-400, '未知操作'))
            return self._ok({'act': act})
        except Exception as e:                                    # noqa: BLE001
            return self._fail(e)

    # ---------- 下载 ----------
    @staticmethod
    def _fname(v, label):
        t = re.sub(r'[\\/:*?"<>|\r\n\t]+', '_', (v.get('title') or 'video'))[:80].strip()
        return f'{t} [{label}].mp4'

    def _send_dl_headers(self, filename, length=None):
        self.send_response(200)
        self.send_header('Content-Type', 'video/mp4')
        self.send_header('Content-Disposition',
                         "attachment; filename*=UTF-8''" + urllib.parse.quote(filename))
        self.send_header('Cache-Control', 'no-store')
        if length:
            self.send_header('Content-Length', str(length))
        else:
            self.send_header('Transfer-Encoding', 'chunked')   # 合并后的长度事先不知道
        self.end_headers()

    def _chunk(self, b):
        self.wfile.write(b'%x\r\n' % len(b) + b + b'\r\n')

    def _dl_dash(self, x, aud, v, label):
        """把 DASH 的视频流 + 音频流用 ffmpeg 边合并边推给浏览器，服务器不落盘。
        （yt-dlp 写 stdout 时会强制用 mpegts，手机播放器不友好，所以自己调 ffmpeg
        产出 fragmented MP4。）"""
        hdr = 'Referer: https://www.bilibili.com/\r\nUser-Agent: ' + UA + '\r\n'
        cmd = [self.ffmpeg, '-hide_banner', '-loglevel', 'error',
               '-headers', hdr, '-i', x['base_url'],
               '-headers', hdr, '-i', aud['base_url'],
               '-c', 'copy', '-movflags', 'frag_keyframe+empty_moov', '-f', 'mp4', 'pipe:1']
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            first = p.stdout.read1(262144)      # 先拿到数据再发响应头，失败了才能干净地报错
            if not first:
                err = (p.stderr.read() or b'').decode('utf-8', 'ignore').strip()[-300:]
                raise BiliError(-500, 'ffmpeg 没输出：' + (err or '未知错误'))
            self._send_dl_headers(self._fname(v, label))
            self._chunk(first)
            sent = len(first)
            while True:
                b = p.stdout.read1(262144)
                if not b:
                    break
                self._chunk(b)
                sent += len(b)
            self.wfile.write(b'0\r\n\r\n')
            sys.stderr.write(f'[download] {v.get("bvid")} {label} 完成 {sent / 1e6:.1f}MB\n')
        except (BrokenPipeError, ConnectionResetError):
            sys.stderr.write('[download] 客户端断开，已中止 ffmpeg\n')
        finally:
            p.kill()
            p.wait()

    def _dl_durl(self, url, v, label):
        """老视频/无 ffmpeg 时的退路：直接代理 B 站 mux 好的单文件流，长度已知"""
        req = urllib.request.Request(url, headers={'User-Agent': UA,
                                                  'Referer': 'https://www.bilibili.com/'})
        r = self.bili.op.open(req, timeout=30)
        total = int(r.headers.get('Content-Length') or 0)
        self._send_dl_headers(self._fname(v, label + ' 单文件'), total or None)
        sent = 0
        try:
            while True:
                b = r.read(262144)
                if not b:
                    break
                if total:
                    self.wfile.write(b)
                else:
                    self._chunk(b)
                sent += len(b)
            if not total:
                self.wfile.write(b'0\r\n\r\n')
            sys.stderr.write(f'[download] {v.get("bvid")} {label} 单文件 {sent / 1e6:.1f}MB\n')
        except (BrokenPipeError, ConnectionResetError):
            sys.stderr.write('[download] 客户端断开\n')
        finally:
            r.close()

    # ---------- 历史记录 ----------
    @staticmethod
    def _pages(q):
        try:
            return max(1, min(200, int(q.get('pages', ['20'])[0])))
        except ValueError:
            return 20

    @staticmethod
    def _hist_range(q):
        now = int(time.time())
        end = parse_ts(q.get('end', [''])[0], now, end_of_day=True)
        start = parse_ts(q.get('start', [''])[0], 0)
        return start, end

    def _export_history(self, q):
        start, end = self._hist_range(q)
        d = self.bili.history(start, end, max_pages=self._pages(q))
        me = self.bili.me()
        fmt = '%Y-%m-%d %H:%M:%S'
        payload = {'exported_at': time.strftime(fmt),
                   'source': 'biliweb（第三方网页客户端，非 B 站官方导出）',
                   'account': {'mid': me['mid'], 'uname': me['uname']},
                   'range': {'start': start, 'start_local': time.strftime(fmt, time.localtime(start)) if start else None,
                             'end': end, 'end_local': time.strftime(fmt, time.localtime(end))},
                   'count': d['count'], 'pages': d['pages'],
                   'oldest': d['oldest'], 'newest': d['newest'],
                   'truncated': d['truncated'],
                   'note': (f'翻了 {d["pages"]} 页后因达到上限而停；truncated=true 说明这个时间段没取完，'
                            f'调大 pages 再导一遍' if d['truncated'] else '时间段已完整取完'),
                   'items': d['items']}
        body = json.dumps(payload, ensure_ascii=False, indent=2).encode()
        day = lambda t: time.strftime('%Y%m%d', time.localtime(t))
        name = f"bili-history_{day(start) if start else 'all'}-{day(end)}.json"
        self.send_response(200)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Disposition', "attachment; filename=\"" + name + "\"")
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)

    # ---------- 自打包：方便往手机/其它机器上部署 ----------
    def _serve_bundle(self):
        root = os.path.dirname(os.path.abspath(__file__))
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode='w:gz') as tf:
            for name in ('server.py', 'index.html', 'bili_login.py', 'README.md'):
                p = os.path.join(root, name)
                if os.path.exists(p):
                    tf.add(p, arcname='biliweb/' + name)
            # 把登录态一起打进压缩包（--bundle-cookies 开启时才做）。
            # 注意：包里有 SESSDATA（等于账号控制权），默认关闭。
            if self.bundle_cookies and self.cookies_path and os.path.exists(self.cookies_path):
                tf.add(self.cookies_path, arcname='biliweb/cookies.txt')
        body = buf.getvalue()
        self.send_response(200)
        self.send_header('Content-Type', 'application/gzip')
        self.send_header('Content-Disposition', 'attachment; filename="biliweb.tar.gz"')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _serve_index(self):
        try:
            with open(INDEX, 'rb') as f:
                body = f.read()
        except OSError:
            return self._json({'ok': False, 'message': f'找不到 {INDEX}'}, 500)
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)


def selftest(cookies):
    b = Bili(cookies)
    me = b.me()
    print('登录:', me['isLogin'], '| 用户:', me['uname'][:2] + '***', '| 硬币:', me['coins'], '| 大会员:', me['vip'])
    for kind, label in (('video', '视频'), ('bili_user', '用户'), ('article', '专栏')):
        r = b.search(kind, '折纸')
        print(f'搜索{label}: {len(r["items"])} 条 / 共 {r["total"]}')
        print('   首条:', json.dumps(r['items'][0], ensure_ascii=False)[:110])
    v = b.video('BV1LV4y1C7wG')
    print('视频:', v['title'][:24], '| 赞', v['stat'].get('like'), '| 已赞', v['liked'], '| 已币', v['coined'],
          '| 已藏', v['favoured'], '| 关注attr', v['follow'])
    for pn in (1, 2):
        c = b.comments(v['aid'], 1, pn)
        head = c['items'][0]['message'][:20] if c['items'] else '(空)'
        print(f'评论第{pn}页: {len(c["items"])} 条 / 共 {c["total"]} | 首条: {head}')
    print('收藏夹:', [(f['id'], f['title'], f['count']) for f in b.folders()])
    rel = b.relation(2929582)
    print('UP主关注状态: attribute', rel['attribute'])
    a = b.article('15788794')
    print('专栏:', a['title'][:24], '| 正文长度', len(a['content'] or ''), '| by', a['author']['name'])
    ac = b.comments('15788794', 12, 1)
    print('专栏评论:', len(ac['items']), '条 / 共', ac['total'])
    print('自检完成：全部只读，未做任何写操作')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--host', default='127.0.0.1',
                    help='监听地址；IPv6 写具体地址或 ::（需要手机访问就填公网 IPv6）')
    ap.add_argument('--port', type=int, default=8000)
    ap.add_argument('--cookies', default=os.path.join(os.path.dirname(os.path.abspath(__file__)), 'cookies.txt'))
    ap.add_argument('--token', default='')
    ap.add_argument('--bundle-cookies', action='store_true',
                    help='/biliweb.tar.gz 里带上 cookies.txt（方便部署到手机，但压缩包等于账号控制权）')
    ap.add_argument('--ffmpeg', default='ffmpeg', help='ffmpeg 可执行文件路径（合并 DASH 流用）')
    ap.add_argument('--selftest', action='store_true')
    a = ap.parse_args()
    if a.selftest:
        return selftest(a.cookies)
    if ':' in a.host:            # IPv6 地址得用 AF_INET6，否则 bind 直接报错
        ThreadingHTTPServer.address_family = socket.AF_INET6
    ThreadingHTTPServer.request_queue_size = 128   # 浏览器会开 6 条以上并发连接，默认 backlog=5 不够
    Handler.bili = Bili(a.cookies)
    Handler.token = a.token
    Handler.cookies_path = a.cookies
    Handler.bundle_cookies = a.bundle_cookies
    Handler.ffmpeg = a.ffmpeg
    Handler.bili.ffmpeg_ok = bool(shutil.which(a.ffmpeg))
    me = Handler.bili.me()
    print('cookie :', a.cookies, '(存在)' if os.path.exists(a.cookies) else '(缺失，只能匿名浏览)')
    print('账号   :', (me['uname'] or '未登录'), '| 硬币', me['coins'])
    print('下载   :', f"{a.ffmpeg} —— 可下全部清晰度（含 1080P/4K，服务端合并、不落盘）"
          if Handler.bili.ffmpeg_ok else '没找到 ffmpeg，只能下 B 站已合并的单文件流（一般≤720P）')
    if a.host != '127.0.0.1' and not a.token:
        print('!! 监听非本机地址但没有 --token：任何能连上的人都拿到你的账号。建议加 --token')
    url = f'http://{f"[{a.host}]" if ":" in a.host else a.host}:{a.port}/' + (f'?t={a.token}' if a.token else '')
    print(f'打开   : {url}')
    ThreadingHTTPServer((a.host, a.port), Handler).serve_forever()


if __name__ == '__main__':
    main()
