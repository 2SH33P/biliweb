// 原生客户端：登录、搜索、页内 DASH 播放、下载、评论楼中楼、互动与历史。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'media.dart';
import 'player.dart';
import 'player_page.dart';

const Map<String, String> kSearchTypes = {
  'video': '视频',
  'bili_user': 'UP主',
  'article': '专栏',
};

String fmtNum(dynamic n) => BiliApi.fmtCount(n);
String fmtAgo(dynamic t) => BiliApi.ago(t);

class AppState extends ChangeNotifier {
  AppState(this.api) : media = BiliMedia(api);
  final BiliApi api;
  /// 清晰度与下载（客户端直连 B站 CDN，不经服务器）
  final BiliMedia media;
  Map<String, dynamic> me = {};
  bool ready = false;
  /// 播放器初始化结果，非空且不是「就绪」时在首页顶部提示
  String playerStatus = '';

  /// 播放器初始化结果由 main() 写入（notifyListeners 是受保护的，类外调不了）
  void setPlayerStatus(String status) {
    playerStatus = status;
    notifyListeners();
  }

  Future<void> refreshMe() async {
    try {
      me = await api.me();
    } catch (_) {
      me = {'isLogin': false};
    }
    ready = true;
    notifyListeners();
  }
}

class BiliApp extends StatelessWidget {
  const BiliApp({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) => MaterialApp(
        title: 'biliweb',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: const Color(0xFF007AFF),
          brightness: Brightness.light,
        ),
        darkTheme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: const Color(0xFF0A84FF),
          brightness: Brightness.dark,
        ),
        home: HomePage(state: state),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.state});
  final AppState state;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      SearchPage(state: widget.state),
      HistoryPage(state: widget.state),
      SettingsPage(state: widget.state),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(['搜索', '观看历史', '设置'][_tab]),
        actions: [
          if (_tab != 2)
            IconButton(
              tooltip: '登录状态',
              icon: Icon(widget.state.me['isLogin'] == true
                  ? Icons.account_circle
                  : Icons.account_circle_outlined),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => LoginPage(state: widget.state),
              )),
            ),
        ],
      ),
      body: pages[_tab],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.search), label: '搜索'),
          NavigationDestination(icon: Icon(Icons.history), label: '历史'),
          NavigationDestination(icon: Icon(Icons.settings), label: '设置'),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 搜索结果

class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.state});
  final AppState state;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  String _type = 'video';
  String _q = '';
  int _page = 1;
  bool _loading = false;
  bool _hasMore = false;
  String? _error;
  final List<Map<String, dynamic>> _items = [];

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final s = await loadSearchState();
    if (s != null && (s['q'] as String).isNotEmpty) {
      _controller.text = s['q'] as String;
      setState(() {
        _type = s['type'] as String;
        _q = s['q'] as String;
      });
      await _run(1);
    }
  }

  Future<void> _run(int page) async {
    if (_q.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
      if (page == 1) _items.clear();
    });
    try {
      final r = await widget.state.api.search(_type, _q, page);
      final items = (r['items'] as List).cast<Map<String, dynamic>>();
      setState(() {
        _page = page;
        _items.addAll(items);
        _hasMore = page < (r['pages'] as int? ?? 1);
      });
      await saveSearchState(_type, _q, page);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (v) {
                    setState(() => _q = v.trim());
                    _run(1);
                  },
                  decoration: const InputDecoration(
                    hintText: '搜索视频、UP主、专栏',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () {
                  setState(() => _q = _controller.text.trim());
                  _run(1);
                },
                child: const Text('搜索'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SegmentedButton<String>(
            segments: kSearchTypes.entries
                .map((e) => ButtonSegment(value: e.key, label: Text(e.value)))
                .toList(),
            selected: {_type},
            onSelectionChanged: (s) {
              setState(() => _type = s.first);
              if (_q.isNotEmpty) _run(1);
            },
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _body() {
    if (_items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            _loading ? '搜索中…' : '没有推荐流。\n想清楚要看什么，再搜。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ),
      );
    }
    return ListView.separated(
      itemCount: _items.length + 1,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        if (i == _items.length) {
          return Padding(
            padding: const EdgeInsets.all(12),
            child: _hasMore
                ? OutlinedButton(
                    onPressed: _loading ? null : () => _run(_page + 1),
                    child: const Text('下一页'))
                : const Center(child: Text('没有更多了')),
          );
        }
        final it = _items[i];
        return ResultTile(
          item: it,
          onTap: () => _open(it),
        );
      },
    );
  }

  void _open(Map<String, dynamic> it) {
    final kind = it['kind'] as String;
    final route = MaterialPageRoute<void>(
      builder: (_) => kind == 'user'
          ? UserPage(state: widget.state, mid: it['id'] as String)
          : kind == 'article'
              ? ArticlePage(state: widget.state, id: it['id'] as String)
              : VideoPage(state: widget.state, bvid: it['id'] as String),
    );
    Navigator.of(context).push(route);
  }
}

class ResultTile extends StatelessWidget {
  const ResultTile({super.key, required this.item, required this.onTap});
  final Map<String, dynamic> item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final pic = (item['pic'] ?? '').toString();
    final isUser = item['kind'] == 'user';
    final sub = isUser
        ? '粉丝 ${fmtNum(item['fans'])} · 投稿 ${fmtNum(item['videos'])}'
        : item['kind'] == 'video'
            ? '${item['author']} · ${item['duration']} · 播放 ${fmtNum(item['play'])} · ${fmtAgo(item['pubdate'])}'
            : '${item['author']} · 阅读 ${fmtNum(item['view'])} · 评论 ${fmtNum(item['reply'])}';
    final sub2 = isUser ? (item['sign'] ?? '').toString() : '';
    return ListTile(
      onTap: onTap,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(isUser ? 24 : 8),
        child: SizedBox(
          width: isUser ? 48 : 84,
          height: isUser ? 48 : 52,
          child: pic.isEmpty
              ? Container(color: Theme.of(context).colorScheme.surfaceContainerHighest)
              : Image.network(pic, fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest)),
        ),
      ),
      title: Text((item['title'] ?? '').toString(),
          maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
          if (sub2.isNotEmpty)
            Text(sub2, maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 视频详情

class VideoPage extends StatefulWidget {
  const VideoPage({super.key, required this.state, required this.bvid});
  final AppState state;
  final String bvid;

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  final _videoKey = GlobalKey<VideoState>();
  Map<String, dynamic>? _v;
  String? _error;
  String _log = '';
  final List<Map<String, dynamic>> _comments = [];
  int _pn = 0;
  bool _commentsEnd = false;
  bool _busy = false;
  bool _autoOpened = false;
  MediaInfo? _info;
  int? _q;
  bool _switchingQuality = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final v = await widget.state.api.video(widget.bvid);
      setState(() => _v = v);
      _loadComments();
      _autoPlay();
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  /// 详情就绪后异步取清晰度，按 pickDefaultQuality（720P）在详情页顶部直接开播；
  /// 只自动启动一次（用户仍可手动点「在线播放」）。
  Future<void> _autoPlay() async {
    if (_autoOpened) return;
    _autoOpened = true;
    final info = await _loadInfo();
    if (info == null || !mounted) return;
    await _playChosen(_find(_q), resumeAt: Duration.zero);
  }

  /// 取清晰度并选默认档；失败只记日志，不影响浏览/下载。
  Future<MediaInfo?> _loadInfo() async {
    try {
      final info = await widget.state.media.info(widget.bvid);
      if (!mounted) return null;
      if (info.qualities.isEmpty) {
        setState(() => _log = '没有可用的清晰度');
        return null;
      }
      setState(() {
        _info = info;
        _q = pickDefaultQuality(info.qualities)?.q;
      });
      return info;
    } catch (e) {
      if (mounted) setState(() => _log = '播放地址读取失败：$e');
      return null;
    }
  }

  QualityOption? _find(int? q) {
    final info = _info;
    if (info == null || q == null) return null;
    for (final o in info.qualities) {
      if (o.q == q) return o;
    }
    return null;
  }

  String get _title =>
      (_info?.title.isNotEmpty ?? false) ? _info!.title : (_v?['title'] ?? '').toString();
  String get _artist {
    final o = _v?['owner'];
    return o is Map ? (o['name'] ?? '').toString() : '';
  }
  String get _artUri => (_v?['pic'] ?? '').toString();

  /// 详情页内嵌播放：不跳独立页面，返回是否成功。
  Future<bool> _playChosen(QualityOption? o, {required Duration resumeAt}) async {
    final videoUrls = o?.video?.urls ?? const <String>[];
    final video = videoUrls.isEmpty ? '' : videoUrls.first;
    if (video.isEmpty) {
      if (mounted) setState(() => _log = '没有可用的播放地址');
      return false;
    }
    final audioUrls =
        (o == null || o.muxed) ? const <String>[] : (o.audio?.urls ?? const <String>[]);
    try {
      await openMedia(
        videoUrl: video,
        audioUrl: audioUrls.isEmpty ? null : audioUrls.first,
        videoUrls: videoUrls,
        audioUrls: audioUrls,
        title: _title,
        artist: _artist,
        artUri: _artUri,
      );
      if (resumeAt > Duration.zero) await biliPlayer.seek(resumeAt);
      return true;
    } catch (e) {
      if (mounted) setState(() => _log = '播放失败：$e');
      return false;
    }
  }

  /// 切清晰度：页内完成，失败回滚到旧档并重开旧流。
  Future<void> _switchQuality(QualityOption o) async {
    if (_switchingQuality || o.q == _q) return;
    final resumeAt = biliPlayer.state.position;
    final oldQ = _q;
    final old = _find(oldQ);
    setState(() {
      _switchingQuality = true;
      _q = o.q;
    });
    final ok = await _playChosen(o, resumeAt: resumeAt);
    if (!ok && mounted) {
      setState(() => _q = oldQ);
      if (old != null) await _playChosen(old, resumeAt: resumeAt);
    }
    if (mounted) setState(() => _switchingQuality = false);
  }

  Future<void> _loadComments() async {
    if (_commentsEnd || _v == null) return;
    try {
      final r = await widget.state.api.comments((_v!['aid']).toString(), 1, _pn + 1);
      setState(() {
        _pn += 1;
        _comments.addAll((r['items'] as List).cast<Map<String, dynamic>>());
        _commentsEnd = r['isEnd'] == true;
      });
    } catch (e) {
      setState(() => _log = '评论加载失败：$e');
    }
  }

  // 写操作：成功后直接改本地状态，不回读。
  // B站 的状态接口有几秒延迟，回读会把按钮打回原样，看起来像「没生效」。
  Future<void> _write(Future<void> Function() op, void Function() apply, String okMsg) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await op();
      setState(() {
        apply();
        _log = '成功：$okMsg';
      });
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(okMsg), duration: const Duration(seconds: 2)));
      }
    } catch (e) {
      setState(() => _log = '失败：$e');
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('操作失败 $e')));
      }
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = _v;
    return Scaffold(
      appBar: AppBar(title: Text(v == null ? '加载中' : (v['title'] ?? '').toString(),
          maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: _error != null
          ? Center(child: Text(_error!))
          : v == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.only(bottom: 32),
                  children: [
                    _playerSurface(v),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(v['title'].toString(),
                              style: Theme.of(context).textTheme.titleLarge),
                          const SizedBox(height: 6),
                          Text(
                            '播放 ${fmtNum(v['stat']['view'])} · 点赞 ${fmtNum(v['stat']['like'])} · '
                            '硬币 ${fmtNum(v['stat']['coin'])} · 收藏 ${fmtNum(v['stat']['favorite'])} · '
                            '${fmtAgo(v['pubdate'])}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              SelectableText(v['id'].toString(),
                                  style: const TextStyle(
                                      fontFamily: 'monospace', fontSize: 13)),
                              Text('  av${v['aid']}', style: Theme.of(context).textTheme.bodySmall),
                              const Spacer(),
                              TextButton.icon(
                                icon: const Icon(Icons.copy, size: 16),
                                label: const Text('复制 BV'),
                                onPressed: () async {
                                  await Clipboard.setData(
                                      ClipboardData(text: v['id'].toString()));
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('已复制 BV 号')));
                                },
                              ),
                            ],
                          ),
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: CircleAvatar(
                              backgroundImage: (v['owner']['face'] ?? '').toString().isEmpty
                                  ? null
                                  : NetworkImage(v['owner']['face'].toString()),
                              child: (v['owner']['face'] ?? '').toString().isEmpty
                                  ? const Icon(Icons.person)
                                  : null,
                            ),
                            title: Text((v['owner']['name'] ?? '').toString()),
                            subtitle: Text('UID ${v['owner']['mid']} · 查看投稿'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => UserPage(
                                  state: widget.state, mid: v['owner']['mid'].toString()),
                            )),
                          ),
                          if (_log.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(_log,
                                  style: Theme.of(context).textTheme.bodySmall),
                            ),
                          const SizedBox(height: 4),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              _act(context, v['liked'] == true ? Icons.favorite : Icons.favorite_border,
                                  '点赞', () => _toggleLike(v)),
                              _act(context, Icons.monetization_on_outlined, '投币',
                                  () => _coin(v)),
                              _act(context, v['favoured'] == true ? Icons.star : Icons.star_border,
                                  '收藏', () => _fav(v)),
                              _act(
                                  context,
                                  (v['follow'] == 2 || v['follow'] == 6)
                                      ? Icons.how_to_reg
                                      : Icons.person_add_alt,
                                  '关注',
                                  () => _toggleFollow(v)),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton.icon(
                                  icon: const Icon(Icons.play_arrow),
                                  label: const Text('在线播放'),
                                  onPressed: _busy ? null : () => _play(v),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: OutlinedButton.icon(
                                  icon: const Icon(Icons.download),
                                  label: const Text('下载'),
                                  onPressed: _busy ? null : () => _download(v),
                                ),
                              ),
                            ],
                          ),
                          const Divider(height: 24),
                          if ((v['desc'] ?? '').toString().isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Text(v['desc'].toString(),
                                  style: Theme.of(context).textTheme.bodyMedium),
                            ),
                          TextButton(
                            onPressed: () =>
                                launchUrl(Uri.parse(v['url'].toString()),
                                    mode: LaunchMode.externalApplication),
                            child: const Text('在 B 站打开原页'),
                          ),
                          const Divider(height: 24),
                          Text('评论', style: Theme.of(context).textTheme.titleMedium),
                        ],
                      ),
                    ),
                    ..._comments.map(_commentTile),
                    if (!_commentsEnd)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: OutlinedButton(
                            onPressed: _loadComments, child: const Text('加载更多评论')),
                      ),
                  ],
                ),
    );
  }

  Widget _commentTile(Map<String, dynamic> c) {
    final location = (c['location'] ?? '').toString();
    final count = (c['rcount'] as num?)?.toInt() ?? 0;
    return ListTile(
      isThreeLine: location.isNotEmpty || count > 0,
      leading: CircleAvatar(
        backgroundImage: (c['face'] ?? '').toString().isEmpty
            ? null
            : NetworkImage(c['face'].toString()),
      ),
      title: Row(children: [
        Expanded(child: Text((c['uname'] ?? '').toString())),
        Text('赞 ${fmtNum(c['like'])}', style: Theme.of(context).textTheme.bodySmall),
      ]),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text((c['message'] ?? '').toString()),
          if (location.isNotEmpty || count > 0)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Wrap(spacing: 12, children: [
                if (location.isNotEmpty)
                  Text(location, style: Theme.of(context).textTheme.bodySmall),
                if (count > 0)
                  Text('$count 条回复 ›',
                      style: TextStyle(color: Theme.of(context).colorScheme.primary)),
              ]),
            ),
        ],
      ),
      onTap: count <= 0
          ? null
          : () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                useSafeArea: true,
                builder: (_) => CommentRepliesSheet(
                  api: widget.state.api,
                  oid: (_v!['aid']).toString(),
                  type: 1,
                  root: (c['root'] ?? c['rpid']).toString(),
                  title: (c['uname'] ?? '').toString(),
                ),
              ),
    );
  }

  /// 详情页顶部播放区：手机保持 16:9 全宽；桌面最多 1280×720，
  /// 同时按窗口高度收缩，给控制条与标题保留空间。
  Widget _playerSurface(Map<String, dynamic> v) {
    final info = _info;
    final pic = (v['pic'] ?? '').toString();
    return Column(
      children: [
        LayoutBuilder(
          builder: (context, c) {
            var w = c.maxWidth.clamp(0.0, 1280.0).toDouble();
            if (c.maxWidth >= 700) {
              final mq = MediaQuery.of(context);
              final availableHeight = mq.size.height -
                  mq.padding.vertical -
                  kToolbarHeight -
                  190;
              final maxHeight = availableHeight.clamp(240.0, 720.0).toDouble();
              w = w.clamp(0.0, maxHeight * 16 / 9).toDouble();
            }
            final h = w * 9 / 16;
            return Center(
              child: SizedBox(
                width: w,
                height: h,
                child: ColoredBox(
                  color: Colors.black,
                  child: info == null
                      ? (pic.isEmpty
                          ? const SizedBox.expand()
                          : Image.network(pic, fit: BoxFit.cover))
                      : Video(
                          key: _videoKey,
                          controller: biliVideoController,
                          controls: NoVideoControls,
                        ),
                ),
              ),
            );
          },
        ),
        if (info != null)
          PlayerBar(
            player: biliPlayer,
            qualities: info.qualities,
            shots: info.shots,
            onFullscreen: () => _videoKey.currentState?.enterFullscreen(),
            currentQ: _q,
            onPickQuality: _switchingQuality ? null : _switchQuality,
          ),
      ],
    );
  }

  Widget _act(BuildContext context, IconData icon, String label, VoidCallback onTap) {
    return Column(
      children: [
        IconButton(onPressed: _busy ? null : onTap, icon: Icon(icon)),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  // ---------- 播放与下载（客户端直连 CDN，不经过任何中转服务器）----------

  Future<void> _play(Map<String, dynamic> v) async {
    if (_info == null) {
      setState(() => _log = '读取播放地址…');
      final info = await _loadInfo();
      if (info == null || !mounted) return;
      setState(() => _log = '');
      _autoOpened = true; // 手动开播也算启动，别再自动重复开
      await _playChosen(_find(_q), resumeAt: Duration.zero);
      return;
    }
    await _playChosen(_find(_q), resumeAt: Duration.zero);
  }

  Future<void> _download(Map<String, dynamic> v) async {
    setState(() => _log = '读取清晰度…');
    MediaInfo info;
    try {
      info = await widget.state.media.info(widget.bvid);
    } catch (e) {
      setState(() => _log = '读取清晰度失败：$e');
      return;
    }
    setState(() => _log = '');
    if (!mounted || info.qualities.isEmpty) return;
    final chosen = await showModalBottomSheet<QualityOption>(
      context: context,
      builder: (ctx) => ListView(
        shrinkWrap: true,
        children: [
          const ListTile(title: Text('选择清晰度')),
          ...info.qualities.map((o) => ListTile(
                title: Text('${o.label}　${o.muxed ? '单文件 mp4' : 'DASH 分流'}'),
                subtitle: Text('${o.width ?? '-'}×${o.height ?? '-'} · ${o.codecs} · 约 ${mbText(o.bytes)}'),
                onTap: () => Navigator.pop(ctx, o),
              )),
          const ListTile(
            title: Text('说明', style: TextStyle(fontSize: 13)),
            subtitle: Text('单文件是 B 站已合好的 mp4，通用播放器都能放；'
                'DASH 分流存成两个文件，需要在本应用里播（视频轨 + 外挂音轨）。',
                style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
    if (chosen == null) return;
    await _runDownload(v, chosen);
  }

  Future<void> _runDownload(Map<String, dynamic> v, QualityOption o) async {
    final dir = await BiliMedia.downloadDir();
    final base = BiliMedia.safeName('${v['title']} [${o.label}]');
    final progress = ValueNotifier<double>(0);
    var cancelled = false;
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text('下载 ${o.label}'),
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (_, p, __) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: p <= 0 ? null : p),
              const SizedBox(height: 10),
              Text('${(p * 100).toStringAsFixed(0)}%'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              cancelled = true;
              Navigator.pop(ctx);
            },
            child: const Text('取消'),
          ),
        ],
      ),
    );

    String? videoPath;
    String? audioPath;
    Object? failure;
    try {
      final media = widget.state.media;
      if (o.muxed) {
        videoPath = '${dir.path}/$base.mp4';
        await media.fetch(o.video!.url, videoPath,
            onProgress: (p) => progress.value = p, isCancelled: () => cancelled);
      } else {
        videoPath = '${dir.path}/$base.video.m4s';
        audioPath = '${dir.path}/$base.audio.m4s';
        await media.fetch(o.video!.url, videoPath,
            onProgress: (p) => progress.value = p * 0.8, isCancelled: () => cancelled);
        if (o.audio != null) {
          await media.fetch(o.audio!.url, audioPath,
              onProgress: (p) => progress.value = 0.8 + p * 0.2,
              isCancelled: () => cancelled);
        }
      }
    } catch (e) {
      failure = e;
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }

    if (!mounted) return;
    if (failure != null) {
      setState(() => _log = '下载失败：$failure');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('下载失败：$failure')));
      return;
    }
    setState(() => _log = '已保存到 $videoPath');
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('已下载 ${o.label}'),
      duration: const Duration(seconds: 6),
      action: SnackBarAction(
        label: '播放',
        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => PlayerPage(
            title: '${v['title']}',
            artist: (v['owner']['name'] ?? '').toString(),
            artUri: (v['pic'] ?? '').toString(),
            localVideoPath: videoPath,
            localAudioPath: audioPath,
          ),
        )),
      ),
    ));
    // 单文件可以直接分享出去；DASH 的两个文件只在本应用内可用
    if (o.muxed && videoPath != null) {
      try {
        await Share.shareXFiles([XFile(videoPath)], text: '${v['title']}');
      } catch (_) {
        // 分享失败不影响已下载的文件
      }
    }
  }

  Future<void> _toggleLike(Map<String, dynamic> v) {
    final on = v['liked'] != true;
    return _write(() => widget.state.api.like(v['id'].toString(), on), () {
      v['liked'] = on;
      final stat = v['stat'] as Map<String, dynamic>;
      stat['like'] = ((stat['like'] as int?) ?? 0) + (on ? 1 : -1);
    }, on ? '已点赞' : '已取消点赞');
  }

  Future<void> _toggleFollow(Map<String, dynamic> v) {
    final followed = v['follow'] == 2 || v['follow'] == 6;
    final on = !followed;
    final mid = v['owner']['mid'].toString();
    return _write(() => widget.state.api.follow(mid, on), () {
      v['follow'] = on ? 2 : 0;
    }, on ? '已关注' : '已取消关注');
  }

  Future<void> _coin(Map<String, dynamic> v) async {
    if ((v['coined'] as int? ?? 0) > 0) {
      setState(() => _log = '这个视频已经投过币了');
      return;
    }
    final n = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('投币'),
        content: const Text('硬币不可撤回，一天最多 5 个。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 0), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, 1), child: const Text('投 1 枚')),
          FilledButton(onPressed: () => Navigator.pop(ctx, 2), child: const Text('投 2 枚')),
        ],
      ),
    );
    if (n == null || n == 0) return;
    await _write(() => widget.state.api.coin(v['id'].toString(), n), () {
      v['coined'] = n;
      final stat = v['stat'] as Map<String, dynamic>;
      stat['coin'] = ((stat['coin'] as int?) ?? 0) + n;
    }, '已投 $n 枚硬币');
  }

  Future<void> _fav(Map<String, dynamic> v) async {
    List<Map<String, dynamic>> fs;
    try {
      fs = await widget.state.api.folders();
    } catch (e) {
      setState(() => _log = '读收藏夹失败：$e');
      return;
    }
    if (fs.isEmpty) {
      setState(() => _log = '没有可用的收藏夹');
      return;
    }
    if (!mounted) return;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => ListView(
        shrinkWrap: true,
        children: [
          const ListTile(title: Text('收藏到哪个收藏夹')),
          ...fs.map((f) => ListTile(
                title: Text(f['title'].toString()),
                subtitle: Text('${f['count']} 个'),
                onTap: () => Navigator.pop(ctx, f['id'].toString()),
              )),
        ],
      ),
    );
    if (chosen == null) return;
    await _write(
        () => widget.state.api.fav(v['aid'] as int, chosen),
        () => v['favoured'] = true,
        '已收藏');
  }
}

class CommentRepliesSheet extends StatefulWidget {
  const CommentRepliesSheet({
    super.key, required this.api, required this.oid, required this.type,
    required this.root, required this.title,
  });
  final BiliApi api;
  final String oid;
  final int type;
  final String root;
  final String title;

  @override
  State<CommentRepliesSheet> createState() => _CommentRepliesSheetState();
}

class _CommentRepliesSheetState extends State<CommentRepliesSheet> {
  final List<Map<String, dynamic>> _items = [];
  int _page = 0;
  bool _loading = false;
  bool _end = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading || _end) return;
    setState(() { _loading = true; _error = null; });
    try {
      final r = await widget.api.commentReplies(
          widget.oid, widget.type, widget.root, _page + 1);
      if (!mounted) return;
      setState(() {
        _page += 1;
        _items.addAll((r['items'] as List).cast<Map<String, dynamic>>());
        _end = r['isEnd'] == true;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      heightFactor: .88,
      child: Column(children: [
        ListTile(
          title: Text('${widget.title} 的回复'),
          trailing: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            itemCount: _items.length + 1,
            itemBuilder: (context, i) {
              if (i == _items.length) {
                if (_error != null) {
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: OutlinedButton(
                      onPressed: _load, child: Text('加载失败，点击重试：$_error'),
                    ),
                  );
                }
                if (_end) return const SizedBox(height: 24);
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Center(
                    child: _loading
                        ? const CircularProgressIndicator()
                        : OutlinedButton(onPressed: _load, child: const Text('加载更多回复')),
                  ),
                );
              }
              final c = _items[i];
              final location = (c['location'] ?? '').toString();
              return ListTile(
                leading: CircleAvatar(
                  backgroundImage: (c['face'] ?? '').toString().isEmpty
                      ? null : NetworkImage(c['face'].toString()),
                ),
                title: Row(children: [
                  Expanded(child: Text((c['uname'] ?? '').toString())),
                  Text('赞 ${fmtNum(c['like'])}',
                      style: Theme.of(context).textTheme.bodySmall),
                ]),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text((c['message'] ?? '').toString()),
                    if (location.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(location, style: Theme.of(context).textTheme.bodySmall),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------- UP主页

class UserPage extends StatefulWidget {
  const UserPage({super.key, required this.state, required this.mid});
  final AppState state;
  final String mid;

  @override
  State<UserPage> createState() => _UserPageState();
}

class _UserPageState extends State<UserPage> {
  Map<String, dynamic>? _u;
  String? _error;
  int _pn = 1;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load(1);
  }

  Future<void> _load(int pn) async {
    try {
      final u = await widget.state.api.user(widget.mid, pn);
      setState(() {
        _pn = pn;
        if (pn == 1) {
          _u = u;
        } else {
          (_u!['items'] as List).addAll(u['items'] as List);
          _u!['hasMore'] = u['hasMore'];
        }
      });
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = _u;
    return Scaffold(
      appBar: AppBar(
          title: Text(u == null ? '加载中' : (u['name'] ?? widget.mid).toString(),
              maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: _error != null
          ? Center(child: Text(_error!))
          : u == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 28,
                            backgroundImage: (u['face'] ?? '').toString().isEmpty
                                ? null
                                : NetworkImage(u['face'].toString()),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text((u['name'] ?? '').toString(),
                                    style: Theme.of(context).textTheme.titleMedium),
                                const SizedBox(height: 2),
                                Text(
                                  'UID ${u['mid']} · 粉丝 ${fmtNum(u['fans'])} · 投稿 ${fmtNum(u['total'])}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    if ((u['sign'] ?? '').toString().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(u['sign'].toString()),
                      ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: OutlinedButton(
                        onPressed: _busy ? null : () => _toggleFollow(u),
                        child: const Text('关注 / 取关'),
                      ),
                    ),
                    const Divider(height: 1),
                    ...(u['items'] as List).map((raw) {
                      final it = raw as Map<String, dynamic>;
                      return ResultTile(
                        item: it,
                        onTap: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => VideoPage(
                              state: widget.state, bvid: it['id'].toString()),
                        )),
                      );
                    }),
                    if (u['hasMore'] == true)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: OutlinedButton(
                            onPressed: () => _load(_pn + 1),
                            child: const Text('加载更多投稿')),
                      ),
                  ],
                ),
    );
  }

  Future<void> _toggleFollow(Map<String, dynamic> u) async {
    setState(() => _busy = true);
    try {
      final attr = await widget.state.api.relation(widget.mid);
      final followed = attr == 2 || attr == 6;
      await widget.state.api.follow(widget.mid, !followed);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(followed ? '已取消关注' : '已关注')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('失败 $e')));
      }
    } finally {
      setState(() => _busy = false);
    }
  }
}

// ---------------------------------------------------------------- 专栏

class ArticlePage extends StatefulWidget {
  const ArticlePage({super.key, required this.state, required this.id});
  final AppState state;
  final String id;

  @override
  State<ArticlePage> createState() => _ArticlePageState();
}

class _ArticlePageState extends State<ArticlePage> {
  Map<String, dynamic>? _a;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final a = await widget.state.api.article(widget.id);
      setState(() => _a = a);
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = _a;
    return Scaffold(
      appBar: AppBar(title: const Text('专栏')),
      body: _error != null
          ? Center(child: Text(_error!))
          : a == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text((a['title'] ?? '').toString(),
                        style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 6),
                    Text(
                      '${a['author']['name']} · 阅读 ${fmtNum(a['stat']['view'])} · 评论 ${fmtNum(a['stat']['reply'])}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const Divider(height: 24),
                    SelectableText((a['content'] ?? '').toString(),
                        style: const TextStyle(height: 1.7)),
                    const Divider(height: 24),
                    TextButton(
                      onPressed: () => launchUrl(Uri.parse(a['url'].toString()),
                          mode: LaunchMode.externalApplication),
                      child: const Text('在 B 站打开原页'),
                    ),
                  ],
                ),
    );
  }
}

// ---------------------------------------------------------------- 观看历史

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, required this.state});
  final AppState state;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  int _days = 7;
  int _pages = 5;
  bool _running = false;
  String _status = '';
  List<Map<String, dynamic>> _items = [];
  bool _truncated = false;

  Future<void> _run() async {
    setState(() {
      _running = true;
      _items = [];
      _truncated = false;
      _status = '读取中…';
    });
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final start = _days == 0 ? 0 : now - _days * 86400;
    try {
      final r = await widget.state.api.history(
        start: start,
        end: now,
        maxPages: _pages,
        onProgress: (d, t) => setState(() => _status = '已翻 $d/$t 页…'),
      );
      setState(() {
        _items = (r['items'] as List).cast<Map<String, dynamic>>();
        _truncated = r['truncated'] == true;
        _status = '共 ${r['count']} 条'
            '${_truncated ? ' · 达到页数上限，没取完' : ''}';
      });
    } catch (e) {
      setState(() => _status = '失败：$e');
    } finally {
      setState(() => _running = false);
    }
  }

  String _exportJson() {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final start = _days == 0 ? 0 : now - _days * 86400;
    final map = {
      'exported_at': BiliApi.fmtTime(now),
      'source': 'biliweb Flutter 客户端（非 B 站官方导出）',
      'account': {'mid': widget.state.me['mid'], 'uname': widget.state.me['uname']},
      'range': {
        'start': start,
        'start_local': start == 0 ? null : BiliApi.fmtTime(start),
        'end': now,
        'end_local': BiliApi.fmtTime(now),
      },
      'count': _items.length,
      'truncated': _truncated,
      'items': _items,
    };
    return const JsonEncoder.withIndent('  ').convert(map);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Wrap(
                spacing: 8,
                children: [
                  for (final d in const [0, 1, 7, 30, 365])
                    ChoiceChip(
                      label: Text(d == 0
                          ? '今天'
                          : d == 1
                              ? '近1天'
                              : d == 365
                                  ? '近一年'
                                  : '近$d天'),
                      selected: _days == d,
                      onSelected: (_) => setState(() => _days = d),
                    ),
                ],
              ),
              Row(
                children: [
                  const Text('翻页上限'),
                  const SizedBox(width: 8),
                  DropdownButton<int>(
                    value: _pages,
                    onChanged: (v) => setState(() => _pages = v ?? 5),
                    items: const [
                      DropdownMenuItem(value: 5, child: Text('5 页（约150条，快）')),
                      DropdownMenuItem(value: 15, child: Text('15 页（约450条）')),
                      DropdownMenuItem(value: 40, child: Text('40 页（约1200条）')),
                      DropdownMenuItem(value: 100, child: Text('100 页（很慢）')),
                    ],
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _running ? null : _run,
                    child: Text(_running ? '读取中' : '查询'),
                  ),
                ],
              ),
              Row(
                children: [
                  Expanded(child: Text(_status)),
                  TextButton.icon(
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('导出 JSON'),
                    onPressed: _items.isEmpty
                        ? null
                        : () async {
                            await Clipboard.setData(ClipboardData(text: _exportJson()));
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('JSON 已复制到剪贴板')));
                          },
                  ),
                ],
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _items.isEmpty
              ? const Center(child: Text('选好时间段后点「查询」'))
              : ListView.separated(
                  itemCount: _items.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final it = _items[i];
                    final bvid = (it['bvid'] ?? '').toString();
                    return ListTile(
                      title: Text((it['title'] ?? '').toString(),
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                          '${it['author']} · ${BiliApi.fmtTime(it['view_at'] as int)}'),
                      onTap: bvid.isEmpty
                          ? null
                          : () => Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => VideoPage(
                                    state: widget.state, bvid: bvid),
                              )),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- 设置 / 登录

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final me = state.me;
    return ListView(
      children: [
        ListTile(
          title: const Text('账号'),
          subtitle: Text(me['isLogin'] == true
              ? '${me['uname']} · Lv${me['level']} · 硬币 ${me['coins']}'
              : '未登录（只能浏览，不能点赞收藏）'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => LoginPage(state: state),
          )),
        ),
        ListTile(
          title: const Text('播放器'),
          subtitle: Text(state.playerStatus.isEmpty ? '初始化中…' : state.playerStatus),
        ),
        ListTile(
          title: const Text('CSRF token'),
          subtitle: Text(state.api.hasCsrf
              ? '已具备（点赞/投币/收藏/关注可用）'
              : '缺失：写操作会被拒，请重新登录'),
        ),
        ListTile(
          title: const Text('重读登录状态'),
          trailing: const Icon(Icons.refresh),
          onTap: () async {
            await state.refreshMe();
            if (context.mounted) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('已刷新')));
            }
          },
        ),
        const ListTile(
          title: Text('关于'),
          subtitle: Text('第三方 B站客户端，仅供学习与个人研究使用。'
              '与哔哩哔哩官方无关，未获官方授权。'),
        ),
      ],
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.state});
  final AppState state;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  String? _key;
  String? _url;
  String _status = '';
  bool _polling = false;

  Future<void> _start() async {
    setState(() {
      _status = '获取二维码…';
      _polling = true;
    });
    try {
      final (key, url) = await widget.state.api.qrGenerate();
      setState(() {
        _key = key;
        _url = url;
        _status = '用 B站 App 扫码，或直接点下面的链接在本机确认';
      });
      _loop(key);
    } catch (e) {
      setState(() {
        _polling = false;
        _status = '失败：$e';
      });
    }
  }

  Future<void> _loop(String key) async {
    var current = key;
    while (mounted && _polling) {
      try {
        final (code, msg) = await widget.state.api.qrPoll(current);
        if (code == 0) {
          await widget.state.api.fetchBuvid();
          await saveCookies(widget.state.api.cookies);
          await widget.state.refreshMe();
          setState(() {
            _polling = false;
            _status = '登录成功';
          });
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('登录成功')));
          }
          return;
        }
        if (code == 86038) {
          final (k, url) = await widget.state.api.qrGenerate();
          setState(() {
            current = k;
            _key = k;
            _url = url;
            _status = '二维码过期，已换一张';
          });
        } else {
          setState(() => _status = msg.isEmpty ? '等待确认…' : msg);
        }
      } catch (e) {
        setState(() => _status = '轮询出错：$e');
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('登录')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Text('登录态只保存在本机，不会发给任何第三方。'
                '与 Python 版一样，链接方式比扫码方便：同一台设备点开链接确认即可。'),
            const SizedBox(height: 16),
            if (_url != null) ...[
              Center(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  color: Colors.white,
                  child: QrImageView(data: _url!, size: 200),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.open_in_new),
                label: const Text('在本机打开链接确认登录'),
                onPressed: () => launchUrl(Uri.parse(_url!),
                    mode: LaunchMode.externalApplication),
              ),
              const SizedBox(height: 8),
            ],
            FilledButton(
              onPressed: _polling ? null : _start,
              child: Text(_key == null ? '生成登录链接/二维码' : '重新生成'),
            ),
            const SizedBox(height: 12),
            Text(_status, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 本地存储

Future<void> saveCookies(Map<String, String> cookies) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('cookies', jsonEncode(cookies));
}

Future<Map<String, String>?> loadCookies() async {
  final prefs = await SharedPreferences.getInstance();
  final s = prefs.getString('cookies');
  if (s == null) return null;
  try {
    return (jsonDecode(s) as Map<String, dynamic>)
        .map((k, v) => MapEntry(k, v.toString()));
  } catch (_) {
    return null;
  }
}

Future<void> saveSearchState(String type, String q, int page) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('search', jsonEncode({'type': type, 'q': q, 'page': page}));
}

Future<Map<String, dynamic>?> loadSearchState() async {
  final prefs = await SharedPreferences.getInstance();
  final s = prefs.getString('search');
  if (s == null) return null;
  try {
    return jsonDecode(s) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

Future<void> clearCookies() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove('cookies');
}
