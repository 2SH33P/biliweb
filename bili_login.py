#!/usr/bin/env python3
"""扫码/链接登录 B站，导出 yt-dlp 用的 Netscape cookies.txt
用法: bili_login.py <cookies.txt> <超时秒数>
过期的二维码会自动重新生成，并把新链接写进 /tmp/bili_qr.url
"""
import http.cookiejar, json, os, sys, tempfile, time, urllib.request

UA = ('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36')
SRC = 'main-fe-header'
HDR = {'User-Agent': UA, 'Referer': 'https://www.bilibili.com/'}

out = sys.argv[1] if len(sys.argv) > 1 else 'cookies.txt'
deadline = time.time() + (int(sys.argv[2]) if len(sys.argv) > 2 else 175)

jar = http.cookiejar.MozillaCookieJar(out)
op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))


def get(url):
    req = urllib.request.Request(url, headers=HDR)
    return json.loads(op.open(req, timeout=15).read().decode())


def announce(d, tag):
    # 链接本身就是登录凭证，只落盘 + 打到 stdout，不发往任何第三方
    # 安卓/Termux 里没有 /tmp，得走 tempfile；而且这个文件只是方便调试，
    # 写不进去也不能把登录流程弄挂（第一版就是这么挂在你手机上的）。
    try:
        with open(os.path.join(tempfile.gettempdir(), 'bili_qr.url'), 'w') as f:
            f.write(d['url'])
    except OSError:
        pass
    print(f'[{tag}] URL: {d["url"]}', flush=True)
    print(f'[{tag}] KEY: {d["qrcode_key"]}', flush=True)


d = get(f'https://passport.bilibili.com/x/passport-login/web/qrcode/generate?source={SRC}')['data']
announce(d, 'QR')
key = d['qrcode_key']
last = None

while time.time() < deadline:
    r = get(f'https://passport.bilibili.com/x/passport-login/web/qrcode/poll'
            f'?qrcode_key={key}&source={SRC}')['data']
    code = r['code']
    if code == 0:
        # 顺手把 buvid3/buvid4 也存进去：B 站风控靠这组指纹认设备，
        # 缺了它们写操作（点赞/投币/收藏）更容易被拦。
        if not any(c.name == 'buvid3' for c in jar):
            try:
                spi = get('https://api.bilibili.com/x/frontend/finger/spi')['data']
                for name, key in (('buvid3', 'b_3'), ('buvid4', 'b_4')):
                    if spi.get(key):
                        jar.set_cookie(http.cookiejar.Cookie(
                            0, name, spi[key], None, False, '.bilibili.com', True, True,
                            '/', True, False, None, False, None, None, {}))
                print('已一并写入 buvid 指纹', flush=True)
            except Exception as e:                      # noqa: BLE001
                print('buvid 获取失败（不影响登录）:', e, flush=True)
        jar.save(ignore_discard=True, ignore_expires=True)   # SESSDATA 是 session cookie，必须 ignore_discard
        print(f'SUCCESS: cookie 已写入 {out}', flush=True)
        sys.exit(0)
    if code == 86038:                      # 二维码过期 -> 自动换一张
        d = get(f'https://passport.bilibili.com/x/passport-login/web/qrcode/generate?source={SRC}')['data']
        announce(d, 'QR-REFRESH')
        key = d['qrcode_key']
    elif code not in (86101, 86090):       # 86101 未扫码 / 86090 已扫码待确认
        print(f'FATAL: {r}', flush=True)
        sys.exit(2)
    if r['message'] != last:
        last = r['message']
        print(f'状态: {last}', flush=True)
    time.sleep(2)

print('TIMEOUT: 超时未确认', flush=True)
sys.exit(3)
