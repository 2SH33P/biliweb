# biliweb —— 极简第三方 B站网页客户端

用 Python 标准库写的 B站网页端，**零第三方依赖**（不需要 pip install），手机浏览器就能用。

## 它故意不做什么

这是它存在的理由，不是没写完：

- ❌ 首页推荐流、相关推荐、猜你喜欢
- ❌ 自动连播、无限滚动
- ❌ 动态流、稍后再看

只有 **搜索 → 看 → 互动**。打开页面是一片空白 + 一个搜索框，
你必须先想清楚要看什么。信息流产品靠「不用想就知道看什么」拿走你的时间，这里把这一步还回去。

## 能做什么

| 功能 | 说明 |
|---|---|
| 搜索 | 视频 / UP主 / 专栏 三类，分页 |
| 视频详情 | 标题、封面、UP主、播放点赞硬币收藏数、简介、原页链接 |
| 专栏阅读 | 正文渲染（服务端已剥 script/on* 事件，防上游 HTML 注入） |
| 评论查看 | 视频和专栏都支持，20 条一页显式翻页 |
| 点赞 | 可取消 |
| 投币 | 1 或 2 个，会二次确认（硬币不可撤回） |
| 收藏 | 列出你的收藏夹勾选加入 |
| 关注 / 取关 | 视频页和 UP主页都有 |
| **在线预览** | 点一下即可在页内播放，服务端 ffmpeg 合并后边下边推，画质取账号上限 |
| **下载** | 选清晰度（360P–4K，按你能拿到的档位列） |
| **在线播放** | 直连模式：把 CDN 原始地址塞进 `<video>`，流量由客户端直连 B 站，服务器零带宽。另有「走服务器播放」兼容 1080P |
| **观看历史** | 任意/指定时间段（今天 / 近7天 / 近30天 / 近一年 / 不限 / 自定义日期区间），显示进度百分比与是否看完 |
| **导出 JSON** | 把选定时间段的历史导成 JSON 文件下载（带起止时间、条数、是否截断） |
| 登录状态 | 右上角显示昵称、等级、剩余硬币 |

**不做播放**。看视频请点「在 B 站打开原页」——播放器自带推荐位，放进来就等于把流接回来了。

## 跑起来

```bash
# 1) 拿 cookie（生成 Netscape 格式的 cookies.txt）
python3 bili_login.py            # 手机上打开它打印的链接并确认

# 2) 启动
python3 server.py                                    # 127.0.0.1:8000
python3 server.py --host 0.0.0.0 --port 8000 --token 我的口令   # 手机/局域网访问

# 3) 只读自检（不启服务、不做任何写操作）
python3 server.py --selftest --cookies cookies.txt
```

- 没登录也能用，只是没有点赞/投币/收藏/关注，右上角会显示「未登录」。
- 手机访问局域网地址必须带 `--token`，否则同一网络下任何人都能操作你的账号。
  带 token 时访问 `http://<ip>:8000/?t=我的口令`，前端会自动把口令附到每个请求上。
- **不要把它暴露到公网。** 没有 HTTPS、没有爆破防护，暴露等于把账号交出去。

### 手机上跑

**Termux（Android）**——完整步骤：

```bash
# 1) 装依赖（Termux 请从 F-Droid / GitHub 装，Play 商店那个已废弃）
pkg update && pkg install python curl

# 2) 直接从已部署的服务器取源码（自带打包路由，不含 cookies）
TOKEN=你的口令
curl -O "http://<你的服务器地址>:8090/biliweb.tar.gz?t=$TOKEN"
tar xzf biliweb.tar.gz && cd biliweb
# 压缩包里已经带着 cookies.txt，不用再跑 login；想换账号就删掉它重跑 bili_login.py

# 3) 登录（SESSDATA 全程不离开手机）
python3 bili_login.py        # 手机浏览器打开它打印的链接并确认，产出 cookies.txt

# 4) 起服务（端口别用 8000，容易撞）
python3 server.py --host 127.0.0.1 --port 8090

# 5) 手机浏览器打开 http://127.0.0.1:8090/
```

本地跑时几个要点：

- **服务器就是手机**，直连和合并的带宽差别不存在（流量都是手机→B 站）。
  直连更省电省 CPU（不过 ffmpeg）；合并会让手机跑 ffmpeg，吃电。**本地跑优先用直连。**
- ffmpeg 只在你要「合并」或「走服务器播放 1080P」时才需要：`pkg install ffmpeg`（几十 MB）。
- 后头挂着跑：`termux-wake-lock`（防休眠）+ `nohup python3 server.py --port 8090 &`。
- 开机自启：装 Termux:Boot，把启动命令写进 `~/.termux/boot/start-biliweb.sh`。
- loopback 不需要 `--token`；想从别的设备访问就 `--host 0.0.0.0 --token 口令`。

**iSH（iOS）**

```bash
apk add python3 curl
python3 server.py --port 8090
```

iSH 是 32 位 x86 用户态模拟、无 JIT，慢但纯标准库不需要编译，能跑。
iOS 上更推荐 **[a-Shell](https://holzschu.github.io/a-Shell_iOS/)**，自带 Python 且快得多。

**其它**：群晖 / 树莓派 / 路由器 / 任一台有 python3 的机器都行。

## 下载

视频详情页点「⬇ 下载这个视频」，会列出你账号实际能拿到的档位（含画面尺寸、编码、估算大小）。

```
GET /api/formats?bvid=             列出档位
GET /api/download?bvid=&q=80       开始下载（q 是清晰度 id）
```

工作方式：

- 服务端直接用 **ffmpeg** 把 DASH 的视频流 + 音频流 `-c copy` 合并成 fragmented MP4，
  通过 chunked 编码边拉边推给浏览器，**全程不写磁盘**（也就不用担心服务器剩余空间）。
- 挑流优先 **H.264（avc1）**：hvc1/av01 在手机上经常放不出来。
- 文件大小写进 Content-Disposition 的文件名：`标题 [1080P].mp4`。
- 没有 ffmpeg 时自动退到 B 站自己 mux 好的单文件流（一般 ≤720P），这时长度已知、浏览器能显示百分比。
- 老视频没有 DASH，也走单文件流。

手机上：iOS 存进「文件 → 下载」，安卓进通知栏或 Download 目录。想用第三方下载器就「复制直链」
（直链带登录签名，有效期约 2 小时，**不要外发**）。

## 在线播放

视频详情页两个按钮：

- **▶ 在线播放**——直连。服务器只解析出一个 CDN 地址，播放流量全由你的设备直接找 B 站要，
  服务器零带宽，且带 Range 所以能拖进度。上限是账号的单文件混合档（非会员通常 720P）。
- **走服务器播放**——服务端 ffmpeg 合并后推流，能到 1080P，代价是服务器上下行带宽都翻倍，
  而且这种 chunked 流拖不了进度条。

直连播放失败时 `<video>` 的 `onerror` 会捕到，并提示切到「走服务器」。
没有自动连播、没有推荐位、播完就停——这三条是故意的，见开头「它故意不做什么」。

## 视觉规范

按 Apple「Web 应用 / iOS 系统 App」那套（Cupertino），不是 apple.com 营销页那套：

- 系统字体栈（`-apple-system` / PingFang SC），主色 `#007AFF`（深色下 `#0A84FF`）
- 分组列表：整组一张卡片，行高 ≥44px，分隔线缩进 16px
- 极简令牌：圆角（控件 12 / 卡片 16 / 弹层 20）、多层阴影、200ms `cubic-bezier(.4,0,.2,1)`
- 跟随 `prefers-color-scheme` 自动深/浅色；底部弹层带 grabber；安全区适配
- 全站无 emoji，图标用内联 SVG

## 下载与播放：只走服务器一条路

```
GET /api/formats?bvid=      列出清晰度（带估算大小）
GET /api/download?bvid=&q=  ffmpeg 合并音视频后推流（下载和预览都是它）
```

**为什么去掉了「直连 CDN」**：一开始做了让浏览器直连 B 站 CDN 的方案（服务器只发一个 302，
零服务器带宽），实测碰到两个硬障碍：

1. B 站 CDN 有 Referer 白名单，而且两套主机规则**相反**：`*.akamaized.net` 空 Referer 也放行，
   `*.bilivideo.com` 则要求 Referer 必须正好是 `bilibili.com`。浏览器无法伪造 Referer。
2. 页跑在 http、CDN 在 https，这属于协议升级，默认策略会把本页来源当 Referer 发过去，直接 403。

后来用户直接部署到手机本地——此时服务器就是手机，直连和合并的带宽差别根本不存在，
直连反而多一堆故障面。于是整个直接方案连同 `/api/direct` 路由、主机探测代码全部删掉。

## 观看历史与导出

视频详情页点「⬇ 下载这个视频（选清晰度）」，每个档位给两个按钮：

| | 流量走向 | 上限 | 服务器开销 |
|---|---|---|---|
| **直连** | 客户端 → B 站 CDN | 账号的单文件混合档（非会员实测 720P） | 只发一个 302，几百字节 |
| **合并** | 客户端 ← 服务器 ← B 站 | 所有能解到的档位，1080P/4K | 带宽翻倍（进+出） |

```
GET /api/direct?bvid=&q=&json=0    302 到 CDN（json=1 则只返回 URL 给下载器）
GET /api/download?bvid=&q=         服务端 ffmpeg 合并后推流
```

直连路线是可以成立的，因为实测 B 站 CDN：

- **不校验 Referer**，但**校验 User-Agent**：带浏览器 UA 就 200，裸请求（比如 curl 默认 UA）
  会被 Akamai 拦成 `Access Denied`。浏览器/IDM/ADM 都自带浏览器 UA，所以没影响。
- 回 `Access-Control-Allow-Origin: *`。
- 支持 `Range`，返回 206 + `Content-Range`，所以能断点续传、能给下载器分段。

因为直连时服务器不在数据通道上，**跑在远程服务器上也不吃服务器带宽**。

### ⚠ Referer 白名单：直连能用的前提

这是踩过的真坑，也是本项最值钱的发现（你手机上就中过）：

```
只带 UA                    → 200
+ Referer: bilibili.com   → 200
+ Referer: 本页地址         → 403  Access Denied（Akamai 错误页）
+ Range / Sec-Fetch / 移动 UA / 全套 Chrome 导航头 → 全部 200
```

CDN 只放行「空 Referer」和「bilibili.com」两个，其他来源一律 403。
而我们的页面跑在 **http://**、CDN 在 **https://**，属于协议**升级**（不是降级），
所以浏览器默认的 `strict-origin-when-cross-origin` 策略会把本页来源当 Referer 发过去——
在服务器上用 curl 测（默认不带 Referer）完全不复现，一到手机上就 403。

修法就一行，已写进 `<head>`：

```html
<meta name="referrer" content="no-referrer">
```

另外前端的直连链接和 `<video>` 都额外带了 `referrerpolicy="no-referrer"`；
能拿裸 CDN 地址时就不用 `/api/direct` 的 302，少一层 redirect。

代价：直连拿到的是 CDN 原始文件名（`42341631131-1-192.mp4` 这种，改不了，因为
Content-Disposition 得由响应方发，而响应方是 CDN）。手机上若点开只是播放，长按链接选「下载链接」。

**搜索/评论/详情/历史这类 API 请求仍然过服务器**（每次几 KB）。这些必须留在服务端：
WBI 签名要密钥、接口要 cookie，把 cookie 发给浏览器等于把账号交出去。量级上它们跟视频流量不是一个数量级。

直连 URL 带签名和 `deadline`，**有效期约 2 小时**，过期重新点一下就有新的。

## 观看历史与导出

顶部「历史记录」按钮，或直接调：

```
GET /api/history?start=&end=&pages=20&type=         查列表
GET /api/history/export?start=&end=&pages=20        导 JSON（附件下载）
```

`start` / `end` 接受 `YYYY-MM-DD`、`YYYY-MM-DD HH:MM` 或 epoch 秒；只给日期时 `end` 自动补到当天 23:59:59。
留空 `start` = 不限（放弃时间过滤，只靠翻页往前揠）。`pages` 是翻页上限，默认 20（约 600 条），
上限 200——**它决定了能回溯多久**，跟历史密度有关。

游标接口只能从最新往前翻，**不能直接跳到某个历史页码**。但可以用「`max` 和 `view_at` 同时传同一个时间戳」
把游标种在任意时刻，再从那里往前翻到越过 `start` 为止——这是「指定时间段」实现的关键。

返回里的 `truncated` 表示「翻了上限页数还是没取完」，为真时导出文件的 `note` 会写清楚，
提醒你调大 `pages` 重导。导出的 JSON 长这样：

```json
{
  "exported_at": "2026-10-02 01:09:11",
  "source": "biliweb（第三方网页客户端，非 B 站官方导出）",
  "account": {"mid": "<你的 mid>", "uname": "..."},
  "range": {"start": 1788192000, "start_local": "...", "end": 1788278399, "end_local": "..."},
  "count": 90, "pages": 3, "oldest": 1788..., "newest": 1788...,
  "truncated": true,
  "note": "翻了 3 页后因达到上限而停；truncated=true 说明这个时间段没取完，调大 pages 再导一遍",
  "items": [{"view_at": 1788..., "view_at_local": "2026-10-02 01:04:27", "business": "article",
              "type_label": "专栏", "oid": 15788794, "bvid": "", "title": "...",
              "author": "...", "duration": 0, "progress": 0, "percent": null,
              "is_finish": 0, "url": "https://www.bilibili.com/read/cv15788794"}]
}
```

翻页之间固定 sleep 0.35 秒，避免风控。导大时间段会慢（页面会一直转圈），这是故意的。

## 安全边界

- `SESSDATA` + `bili_jct` 只存在服务进程内存里，**不下发到前端、不写日志**。
- 前端拿到的只有渲染好的数据。
- `bili_jct` 是 CSRF token，等于「点赞/投币/评论」的权限，和 SESSDATA 一起泄露就是完整账号控制权。
- 想换账号或退出，直接删掉 `cookies.txt` 重启即可。
- 端口默认只绑 `127.0.0.1`；`--host 0.0.0.0` 需要你明确写出来。

## 接口（都走 `/api/`）

```
GET  /api/me                         登录状态 / 硬币
GET  /api/search?type=&q=&page=      type: video | bili_user | article
GET  /api/video?bvid=                详情 + 三连状态 + 关注状态
GET  /api/article?id=                专栏正文 + 统计
GET  /api/comments?oid=&type=&pn=    type: 1 视频 / 12 专栏
GET  /api/relation?fid=              UP主关注状态
GET  /api/user?mid=&page=           UP主资料 + 投稿列表
GET  /api/folders                    我的收藏夹
GET  /api/formats?bvid=              清晰度列表
GET  /api/download?bvid=&q=          ffmpeg 合并后推流（预览和下载共用）
GET  /api/history?start=&end=&pages= 观看历史
GET  /api/history/export?...         导出 JSON
GET  /biliweb.tar.gz                 自打包源码（不含 cookies，方便部署到手机）
POST /api/do                         {act: like|coin|fav|follow, ...}
```

历史记录的字段故意只留 7 个（时间、标题、UP主、bvid/oid、类型）：早先带了封面、时长、
进度、徽章等十几个字段，JSON 又大又慢，而实际只用得到「看了什么、谁的、什么时候」。

## 前端路由

状态存在 `location.hash`（`#video/BVxxx`、`#article/123`、`#user/456`、`#history`），
刷新和浏览器前进/后退都能回到原来那一页。上次的搜索词和页码存在 `localStorage`，
所以刷新详情页时，底下的列表也还在。`currentRoute` 用来去重：自己改 hash 同样会触发
`hashchange`，不拦就会重复渲染一遍。

## 四个踩过的坑（都写在代码注释里了）

1. **评论翻页不能用 `/x/v2/reply/wbi/main`**：它是游标分页，传 `pn` 无效——实测第 1、2 页首条 rpid 完全相同，
   照它写翻页会原地打转。改用传统的 `/x/v2/reply` + `pn`。
2. **yt-dlp 写 stdout 时强制用 MPEG-TS**：`-o -` 拿到的其实是 mpegts 不是 mp4，
   `--merge-output-format mp4` 和 `--postprocessor-args Merger:-movflags ...` 都改不动，
   手机播放器不友好。所以下载不用 yt-dlp，自己调 ffmpeg 产出 fragmented MP4。
3. **`frame_rate` 字段时而是数字时而是字符串**（`30.000`），直接 `round()` 会 TypeError，已包一层转换。
4. **历史记录：只传 `max` 不传 `view_at` 等于没传**。我第一版用 `max=三天前` 当种子，
   它直接返回最新记录（因为 `max` 被忽略），时间过滤完全失效。后来改成 `max = view_at = 目标时间戳` 才对。
   此外**翻页边界不等于范围过滤**：第一版只靠「翻到越过 start 就停」判断，结果首尾页
   把窗口外的条目也塞进去了，加了逐条过滤才干净。
5. **B 站 CDN 的 Referer 白名单**：curl 不带 Referer 能过，浏览器带了本页 Referer 就 403，
   而且不同 CDN 主机规则相反（见上文）。这类 bug 只在真实浏览器里出现，服务器端测不出来。
6. **写操作不要立即回读，而且要把「状态滞后」当幂等来容错**。
   `archive/relation` 有延迟：按 like → unlike 顺序测，每次读到的都是**上一步**的状态。
   更阴的是写接口自己也会脏：刚赞完 3 秒内取消，`like` 会回 65004「取消赞失败 未点赞过」——
   但过 10 秒再看，第一次的赞其实生效了。所以前端要：（1）乐观更新，以写成功为准；
   （2）把「目标状态已达成」的报错按成功处理（见 `onAct` 里的 `benign` 判定）。

## 实现说明

- 后端：`http.server.ThreadingHTTPServer`，413 行，无依赖。
- 前端：单文件 `index.html`，原生 JS + 内联 CSS，无框架无构建，移动端优先，
  适配了 iPhone 安全区。资源全部本地，不引 CDN。
- WBI 签名：`mixin_key = md5(按 reorder 表重排的 img_key+sub_key)`，密钥缓存 10 分钟。
- 搜索/评论/专栏/清晰度列表接口全部实测通过；**点赞/投币/收藏/关注四个写操作我刻意没有自动测试**
  （会在你账号上留下痕迹、投币还会消耗硬币），逻辑写好但请你自己点一遍验证。
- 外部依赖只有可选的 **ffmpeg**（合并 DASH 用）。没有它也能跑，只是下载退到单文件流。
- 直连模式不依赖 ffmpeg，也不消耗服务器带宽。
